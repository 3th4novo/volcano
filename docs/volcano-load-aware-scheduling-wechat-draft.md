# 让可观测数据进入调度闭环：Volcano 负载感知调度实践

在 Kubernetes 集群里，调度器做的是一件看起来很简单的事：来了一个 Pod，把它放到一台合适的节点上。

麻烦在于，"合适"并不总是等于"看起来还有资源"。很多时候，节点上应用提前申报的资源和它真正跑起来后用掉的资源并不一致。调度器如果只看申报值，就可能把新 Pod 放到已经很忙的节点上；也可能避开一些看起来被占满、实际还很空的节点。

这篇文章想讲清楚一件事：Volcano 的负载感知调度到底在解决什么问题，以及这次增强为什么能让批量发布、重部署这类场景更稳。

## 从用户痛点出发：负载感知调度到底解决了什么问题

真实集群里的业务很难用一个 request 精准描述。

有些服务平时很轻，但启动时会突然吃掉很多 CPU。有些任务内存申请得保守，实际使用却不高。还有一些 BestEffort 任务没有 request 和 limit，调度器从资源声明里几乎看不出它将来会占多少资源。

这些情况混在一起后，调度器看到的节点状态就容易失真。

举个简单例子。节点 A 上的 Pod request 不高，按传统调度逻辑看还有空间；但节点 A 的真实 CPU 已经接近高水位。节点 B 上的 Pod request 很高，看起来资源快满了；实际 CPU 和内存却还比较空。如果调度器只看 request，新 Pod 很可能继续落到节点 A。业务跑起来后，节点 A 就变成热点。

上一篇《基于 Volcano 实现节点真实负载感知调度》讲的就是这个问题：Kubernetes 默认调度主要根据 Pod request 和节点 allocatable 计算可调度资源。这个模型保证了 Kubernetes 的资源语义，但它不会自动知道节点此刻真实 CPU、内存利用率。

客户在主站业务迁移和日常发布中遇到的问题更集中。批量新建 Pod 或滚动重部署时，调度器会连续做很多次选择。如果某个节点在当时的指标里分数最高，大量 Pod 会被放到这个节点上。刚开始看不出问题，因为新 Pod 的资源消耗还没有进入监控曲线；等这些 Pod 真正启动后，节点已经热起来了。

这里有两个时间差。

第一个时间差，是资源声明和真实消耗之间的差。request 只是业务提前写下的声明，不等于运行时一定会用掉的资源。

第二个时间差，是监控指标和调度动作之间的差。Prometheus、Custom Metrics API、云原生监控插件都需要采集、聚合、上报。调度器刚把 Pod 放到某个节点时，它已经知道这件事了，但监控系统还没来得及把新 Pod 的消耗反映出来。

负载感知调度要解决的，就是这两个差。它让调度器不只看"申报资源"，也看"节点真实水位"；在监控还没刷新时，还要把刚刚放上去的新 Pod 先记进来。

## 主流厂商目前的方案分析

从公开资料和实际产品形态看，业界大致有两类做法。

Kueue 更偏队列准入和配额管理。它通过 ClusterQueue、ResourceFlavor、nominalQuota、borrowingLimit、lendingLimit 等机制，决定一批任务能不能进入集群，以及不同队列之间怎么共享资源。这个方向适合批任务准入、公平共享和配额治理。它更像是在入口处把关：先判断这批任务有没有资格进来。

Koordinator 更偏节点视角的负载感知调度。它通过 NodeMetric 获取节点真实负载，在调度时过滤高负载节点、优先选择低负载节点。它也会考虑指标延迟窗口内的新 Pod，对已经分配但还没进入指标的数据做估算。这类方案更关注 Pod 进来之后应该落到哪台节点。

云厂商的 ACK、CCE 等托管 Kubernetes 产品，也通常会围绕真实指标、节点打分、阈值过滤、Pod 资源估算这些方向增强调度能力。背后的思路并不复杂：入口处要管配额，节点上要看真实负载；批量调度时，还要处理监控指标慢半拍的问题。

Volcano 这次负载感知调度增强，主要做的是节点侧这件事。它把真实指标、资源预估、影子负载和调度回滚放到同一条调度链路里。

## Volcano 的方案：真实负载、影子负载与资源预估

Volcano usage 插件做调度时，会同时看两类信息。

一类来自外部监控，比如 Prometheus、Custom Metrics API 或云原生监控插件。这些指标告诉调度器：节点现在 CPU、内存水位大概是多少。

另一类来自调度器自己。调度器知道哪些 Pod 刚被分配到节点上，也知道这些 Pod 还可能没有出现在监控曲线里。Volcano 会先给它们估一份资源占用，临时记到节点上。

### 先看节点上的真实压力

usage 插件会把节点真实 CPU/Mem 利用率带入调度流程。

在过滤阶段，如果节点 CPU 或内存已经超过用户设置的阈值，插件可以阻止新 Pod 继续调度到这个节点。这里尽量使用真实监控数据做硬判断。原因很直接：如果要说一台节点"不能再放了"，最好基于已经观测到的事实，而不是只靠估算。

在打分阶段，节点负载越低，得分越高；节点越忙，得分越低。CPU 和内存的权重也可以调。比如 CPU 密集型业务可以提高 CPU 权重，内存敏感业务可以提高内存权重。

这样，调度器不会只问"节点还有多少申报资源"，还会问"节点现在是不是真的忙"。

### 再考虑同session中调度到节点的的预估值

真实指标有延迟。这个问题在批量调度时很明显。

假设调度器刚把 10 个 Pod 放到节点 A。外部监控还没刷新，节点 A 看起来还是很空。如果接下来又有 10 个 Pod 要调度，只看监控数据，调度器可能继续选择节点 A。

Volcano 的做法是维护一份 Shadow Load，可以理解成调度器自己的临时账本。已经调度到节点、但还没有被监控系统看见的新 Pod，会先被估算出 CPU 和内存占用，记到节点 A 的账上。下一次打分时，节点 A 用的就不是单纯的真实指标，而是：

```text
真实负载 + 影子负载
```

这样，节点 A 的分数会随着新 Pod 的分配逐步下降，后续 Pod 更容易分散到其他合适节点。

`metrics.interval` 会用来判断这个"监控还没看见"的窗口有多长。Allocated、Binding、Bound 状态的任务，以及刚 Running 不久的 Pod，会进入影子负载。Pending、Succeeded、Failed 这类不应该影响当前节点压力的任务，不会被算进去。

### 如何准确做资源预估

影子负载要有用，关键是估得不能太离谱。

对有 request 和 limit 的 Pod，Volcano 使用下面这个估算公式：

```text
pod_estimate = (request * request_ratio + (limit - request) * burst_ratio) * applied_risk_factor
```

可以不用一开始就看公式。简单理解是：request 代表业务正常情况下预计要用的资源；limit 和 request 之间的空间，代表业务可能冲高的部分。`request_ratio` 控制要相信 request 多少，`burst_ratio` 控制要不要把突发空间也算进去。

默认配置更相信 request，避免所有 Pod 都按 limit 估算，导致调度过度保守。如果某类业务启动时容易冲高，或者 request 普遍偏低，就可以提高 `burst_ratio`。

BestEffort Pod 没有 request 和 limit。对这类 Pod，Volcano 提供 `be_cpu` 和 `be_mem` 两个默认估算值。默认是 `250m` CPU 和 `200Mi` 内存。这样 BestEffort Pod 不会在调度时完全"不记账"。

估算结果也会被限制在合理范围内。比如 limit 缺失或小于 request 时，以 request 作为有效上限；估算值不会小于 0，也不会超过有效 limit。这些边界处理是为了避免个别异常配置把调度结果带偏。

### 节点综合水位高时更谨慎

同样一个新 Pod，放到空闲节点和放到高水位节点，风险不一样。

Volcano 用 `risk_threshold` 和 `risk_factor` 处理这个差别。节点复合负载达到 `risk_threshold` 后，新 Pod 的估算值会乘以 `risk_factor`。这不会直接把节点踢出候选列表，但会让它在打分时更吃亏。

这相当于告诉调度器：这台节点已经比较热了，后面再往上放 Pod 时要更谨慎。

### 如何准确做预估值回滚

Volcano 常用于批处理和 AI 任务，Gang 调度很常见。一组 Pod 要么整体调度成功，要么整体等待。调度器可能先给其中一部分 Pod 选好了节点，最后发现整个 PodGroup 条件不满足，需要回滚。

如果影子负载只在 Allocate 时增加，不在 Deallocate 时扣回，就会留下错误记录。已经回滚的 Pod 并不会真的运行，但节点账本里还留着它的估算负载。后续调度就会被误导。

所以 Volcano 会在加入影子负载时保存快照，记录这个 Pod 当时估了多少 CPU、多少内存、落在哪个节点。回滚时直接按快照扣回，不重新估算。这样即使节点水位或风险系数在中间发生变化，也不会影响加减一致性。

这点对批处理场景很重要。它保证调度失败不会污染下一轮调度。

## 如何结合业务深度调优

不同业务对资源的使用方式差很多。Volcano 没有把所有场景写死，而是把常用判断做成参数。

下面是一个配置示例。

```yaml
actions: "enqueue, allocate, backfill"
tiers:
  - plugins:
      - name: usage
        enablePredicate: false
        arguments:
          usage.weight: 5
          cpu.weight: 1
          memory.weight: 1
          thresholds:
            cpu: 80
            mem: 80
          estimator:
            request_ratio: 0.7
            burst_ratio: 0
            risk_threshold: 0.6
            risk_factor: 1.2
            be_cpu: 250m
            be_mem: 200Mi
metrics:
  type: prometheus
  address: http://prometheus:9090
  interval: 30s
```

`thresholds.cpu` 和 `thresholds.mem` 默认建议是 `80` / `80`。它们控制节点真实负载水位。业务稳定性要求高，可以调低一点；更看重资源利用率，可以在压测验证后适当调高。

`cpu.weight` 和 `memory.weight` 默认都是 `1`。CPU 密集型业务可以提高 CPU 权重，内存敏感型业务可以提高 Memory 权重。

`request_ratio` 默认是 `0.7`。如果业务 request 配得比较准，这个值可以保持默认，甚至适当提高。

`burst_ratio` 默认是 `0`。如果业务启动时经常冲高，或者 request 明显偏低，可以把它调大一些，让调度器把 request 到 limit 之间的弹性空间也考虑进去。

`risk_threshold` 默认是 `0.6`。这个值越低，节点越早进入谨慎状态。发布批次大、对热点敏感的业务，可以考虑调低。

`risk_factor` 默认是 `1.2`。它控制节点进入风险水位后，新 Pod 估算值放大多少。OOM 风险高、业务波动大的场景，可以适当提高。

`be_cpu` 默认是 `250m`，`be_mem` 默认是 `200Mi`。如果集群里 BestEffort 任务很多，而且实际资源消耗不低，建议结合历史监控校准这两个值。

`metrics.interval` 建议和监控采集、聚合周期保持一致，例如 `30s`。监控周期较长时，可以调大；监控更实时，可以适当调小。

实际调参不需要一次改很多。稳态业务先看 `request_ratio`；突发业务重点看 `burst_ratio` 和 `risk_factor`；BestEffort 多的集群先校准 `be_cpu`、`be_mem`；批量发布场景重点观察 `risk_threshold` 和 `metrics.interval`。

## 方案收益与测试数据

这类调度增强，不能只看某个 Pod 最后落在哪台节点上。更应该看一段时间内节点负载怎么变化，热点有没有缩短，发布过程中有没有 OOM。

正式发布前，建议把测试报告按下面几个场景补进来。

待补充

## 演进方向

这次先围绕 CPU 和内存处理监控延迟问题。后面可以继续往智算资源扩展。

AI 训练、推理、视频处理等场景里，GPU/NPU 利用率、显存、设备队列等待时间都会影响调度质量。只看 CPU 和内存还不够。未来可以把影子负载和风险估算扩展到这些指标上。

任务画像也值得做。当前估算主要依赖 request、limit、QoS 和配置参数。后面如果能结合历史运行数据，就可以把"人工配置的经验值"变成更贴近业务的预测。

节点池粒度也需要考虑。生产集群常按节点池区分规格、可用区、业务类型或成本模型。只看单节点，可能会留下节点池层面的冷热不均。

最后，影子负载本身也应该更容易被看到。运维需要知道某个节点为什么降分，哪些 Pod 贡献了影子负载，风险系数什么时候生效。把这些信息做成指标或诊断信息，会比只给一个调度结果更有用。

## 总结

负载感知调度解决的是一个很日常的问题：业务申报的资源和真实消耗不总是一致，监控指标也不总是和调度动作同步。

Volcano usage 插件把真实指标、节点阈值、节点打分、影子负载、资源预估和回滚一致性放到同一条调度链路里。外部监控告诉调度器节点现在忙不忙；影子负载告诉调度器刚刚又往节点上放了什么；资源预估让不同类型的 Pod 都能被算进去；快照回退保证 Gang 调度失败后不会留下错误记录。

对用户来说，这套能力的价值比较直接：批量新建、滚动重部署、扩缩容时，不容易把新负载继续堆到已经变热的节点上；业务 request 不够准确时，也可以通过参数把经验写进调度策略里。它不是把所有问题一次解决完，但能把最容易在发布和迁移中踩到的热点问题提前挡掉一部分。

## 参考资料

- [基于 Volcano 实现节点真实负载感知调度](https://mp.weixin.qq.com/s/Yn51YGVBdwqBmxnj5pecJA)
- [Kubernetes Scheduler 官方文档](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)
- [Kueue ClusterQueue 官方文档](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/)
- [Koordinator Load Aware Scheduling 设计](https://github.com/koordinator-sh/koordinator/blob/main/docs/proposals/scheduling/20220510-load-aware-scheduling.md)
- [Kubernetes Scheduler Plugins Trimaran: Real Load Aware Scheduling](https://github.com/kubernetes-sigs/scheduler-plugins/blob/master/site/content/en/docs/kep/61-Trimaran-real-load-aware-scheduling/README.md)
