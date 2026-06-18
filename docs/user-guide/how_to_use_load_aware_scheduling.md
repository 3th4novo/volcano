# Volcano 负载感知调度用户手册

## 前提条件

使用负载感知调度前，请确认集群满足以下条件：

- 已安装 Volcano，并且业务 Pod 使用 Volcano scheduler 调度。普通 Pod 需要配置 `spec.schedulerName`；Volcano Job 会按 Volcano 的作业配置进入调度流程。
- 已部署可提供节点 CPU、内存利用率的指标源。Volcano 当前支持 `prometheus_adaptor`、`prometheus` 和 `elasticsearch`。
- 如果使用 `prometheus_adaptor`，集群中需要有可用的 Custom Metrics API，并提供 `node_cpu_usage_avg` 和 `node_memory_usage_avg` 两个节点指标。
- 如果使用 CCE，请按 CCE 现网文档完成 Volcano 插件、云原生监控插件或自建 Prometheus 的安装和配置。
- 需要有修改 `volcano-scheduler-configmap` 并重启 Volcano scheduler 的权限。

负载感知调度只处理 CPU 和内存两个维度。GPU、NPU、网络和磁盘 IO 不在当前 usage 插件的计算范围内。

## 功能介绍

Kubernetes 默认调度主要使用 Pod 的 request 和节点 allocatable 做判断。这个机制可以判断资源是否还能分配，但它看不到节点当前的真实负载。实际集群中，经常会遇到 request 和运行时用量差异较大的情况：有些节点分配率很高但真实负载不高，有些节点分配率不高却已经被存量任务打满。

Volcano 的 `usage` 插件会读取节点 CPU、内存的真实利用率，把 Pod 优先调度到负载更低的节点。开启硬约束后，插件还可以过滤真实负载超过阈值的节点。

新版本对这项能力做了增强。调度器现在不只使用监控系统已经上报的真实负载，还会把刚调度成功、但尚未出现在监控指标里的 Pod 计入临时负载。这样可以减少一批 Pod 在监控延迟窗口内持续落到同一个低负载节点的情况。

## 工作原理

负载感知调度链路包括指标采集、节点筛选和节点排序：

1. 指标采集：scheduler cache 周期性从指标源拉取节点 CPU、内存利用率，并写入节点缓存。
2. 节点筛选：`usage` 插件在 Predicate 阶段检查真实负载阈值。启用硬约束时，CPU 或内存真实利用率超过阈值的节点不会继续接收新 Pod。
3. 节点排序：`usage` 插件在 NodeOrder 阶段计算节点分数。分数越高，节点越容易被选中。

增强后的 NodeOrder 使用“真实负载 + 影子负载”做排序。影子负载是调度器在当前 session 内维护的一份估算值，用来表示已经分配到节点、但指标系统还没有观测到的 Pod 消耗。

```text
节点排序负载 = 指标源上报的真实负载 + 调度器估算的影子负载
```

### 节点筛选

节点筛选只使用指标源上报的真实负载，不使用影子负载。

- `enablePredicate: true` 或不配置该字段时，阈值按硬约束生效。节点 CPU 或内存真实利用率超过阈值后，不再调度新 Pod。
- `enablePredicate: false` 时，阈值不做硬过滤，节点仍可参与调度，但 NodeOrder 会按负载排序。

如果节点指标为空，或者指标更新时间距离当前时间超过 5 分钟，`usage` 插件会降级处理：Predicate 放行该节点，NodeOrder 返回 0 分。此时调度结果主要由其他插件决定。

### 节点排序

节点排序使用复合利用率计算得分：

```text
CPU复合利用率 = (CPU真实利用率 / 100 * 节点CPU容量 + CPU影子负载估算值) / 节点CPU容量
内存复合利用率 = (内存真实利用率 / 100 * 节点内存容量 + 内存影子负载估算值) / 节点内存容量
```

复合利用率会被限制在 `[0, 1]` 范围内。节点分数计算如下：

```text
节点分数 = usage.weight *
         ((1 - CPU复合利用率) * cpu.weight + (1 - 内存复合利用率) * memory.weight) /
         (cpu.weight + memory.weight) *
         MaxNodeScore
```

`MaxNodeScore` 来自 Kubernetes scheduler framework，当前为 100。CPU 和内存权重用于控制排序时更偏向哪一类资源。

### 影子负载

`usage` 插件在每个调度 session 中创建一个 `ShadowLoadCache`。这个缓存按节点保存 CPU 和内存的估算值，也会为每个 Pod 保存一份估算快照。

影子负载有两种来源：

- session 打开时的 warm-up：扫描已经分配到节点上的任务，把仍处在监控延迟窗口内的 Pod 加入影子负载。包括 `Allocated`、`Binding`、`Bound` 状态的任务，以及刚进入 `Running`、运行时间还短于 `metrics.interval` 的任务。
- 当前 session 的 Allocate 事件：当 Pod 被分配到某个节点时，插件立即估算它的 CPU 和内存消耗，并加到该节点的影子负载中。

如果调度过程发生回滚或 Deallocate，插件不会重新估算一次，而是扣减 Allocate 时记录的快照值。这样可以避免因为节点压力或配置变化导致加减不一致。

### Pod 负载估算

对于 Guaranteed 和 Burstable Pod，估算公式如下：

```text
pod_estimate = (request * request_ratio + (effective_limit - request) * burst_ratio) * applied_risk_factor
```

`effective_limit` 的规则：

- 如果配置了 limit，并且 limit 大于等于 request，则使用 limit。
- 如果没有配置 limit，或 limit 小于 request，则使用 request。
- 估算结果会被限制在 `[0, effective_limit]` 范围内。

Init Container 按 Kubernetes 资源语义处理：普通容器资源按总和计算，Init Container 取单个 Init Container 中最大的 request 或 limit，并与普通容器总和比较后取较大值。

BestEffort Pod 没有 request 和 limit，插件使用固定估算值：

```text
BestEffort CPU估算值 = estimator.be_cpu * applied_risk_factor
BestEffort 内存估算值 = estimator.be_mem * applied_risk_factor
```

### 风险系数

当节点已经接近高负载时，新 Pod 带来的风险更高。`usage` 插件会用 CPU、内存复合利用率计算节点的综合负载：

```text
综合负载 = (CPU复合利用率 * cpu.weight + 内存复合利用率 * memory.weight) /
          (cpu.weight + memory.weight)
```

当综合负载大于等于 `estimator.risk_threshold` 时，估算值乘以 `estimator.risk_factor`；否则风险系数为 1。

`risk_factor` 不能小于 1。配置小于 1 的值会被忽略，插件继续使用默认值。

## 配置负载感知调度

以下示例使用 `prometheus_adaptor`。如果您直接使用 Prometheus 或 Elasticsearch，请参考后文的指标源配置。

```yaml
actions: "enqueue, allocate, backfill"
tiers:
  - plugins:
      - name: priority
      - name: gang
      - name: conformance
  - plugins:
      - name: overcommit
      - name: drf
      - name: predicates
      - name: proportion
      - name: nodeorder
      - name: usage
        enablePredicate: true
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
  type: prometheus_adaptor
  interval: 30s
```

修改配置后，重启 Volcano scheduler。部署名可能因安装方式不同而变化，请按实际环境调整：

```bash
kubectl rollout restart deployment volcano-scheduler -n volcano-system
```

## 参数说明

| 参数 | 说明 | 默认值 | 取值 |
| --- | --- | --- | --- |
| `enablePredicate` | 是否启用真实负载阈值硬过滤。设为 `false` 时只做排序，不按阈值过滤节点。 | 未配置时按启用处理 | `true` 或 `false` |
| `usage.weight` | usage 插件在节点排序中的权重。 | `5` | 整数，建议大于 0 |
| `cpu.weight` | CPU 维度在负载评分中的权重。 | `1` | 整数，建议大于 0 |
| `memory.weight` | 内存维度在负载评分中的权重。 | `1` | 整数，建议大于 0 |
| `thresholds.cpu` | CPU 真实利用率阈值。启用硬约束时，超过该值的节点会被过滤。 | `80` | `[0, 100]` |
| `thresholds.mem` | 内存真实利用率阈值。启用硬约束时，超过该值的节点会被过滤。 | `80` | `[0, 100]` |
| `estimator.request_ratio` | request 对估算值的贡献比例。 | `0.7` | `[0, 1]` |
| `estimator.burst_ratio` | request 到 effective limit 之间 burst 空间的贡献比例。 | `0` | `[0, 1]` |
| `estimator.risk_threshold` | 触发风险系数的综合负载阈值。`0.6` 表示 60%。 | `0.6` | `[0, 1]` |
| `estimator.risk_factor` | 达到风险阈值后的估算放大系数。 | `1.2` | `>= 1` |
| `estimator.be_cpu` | BestEffort Pod 的固定 CPU 估算值，单位为 Kubernetes CPU quantity。 | `250m` | 非负值 |
| `estimator.be_mem` | BestEffort Pod 的固定内存估算值，单位为 Kubernetes memory quantity。 | `200Mi` | 非负值 |
| `metrics.type` | 指标源类型。 | 无 | `prometheus_adaptor`、`prometheus`、`elasticsearch` |
| `metrics.interval` | 指标拉取间隔，同时用作 Running Pod 的监控延迟窗口。 | `30s` | 正数时间，例如 `15s`、`30s`、`1m` |
| `metrics.address` | Prometheus 或 Elasticsearch 地址。 | 无 | URL |
| `tls.insecureSkipVerify` | 是否跳过 TLS 证书校验。 | `false` | `true` 或 `false` |
| `elasticsearch.index` | Elasticsearch 索引名。 | `metricbeat-*` | 字符串 |
| `elasticsearch.username` | Elasticsearch 用户名。 | 空 | 字符串 |
| `elasticsearch.password` | Elasticsearch 密码。 | 空 | 字符串 |
| `elasticsearch.hostnameFieldName` | Elasticsearch 中节点名字段。 | `host.hostname` | 字符串 |

配置超出取值范围时，插件会保留默认值并打印 warning 日志。`be_cpu` 和 `be_mem` 支持字符串形式的 Kubernetes quantity，例如 `500m`、`300Mi`。

## 配置指标源

### 使用 Custom Metrics API

使用 `prometheus_adaptor` 时，Prometheus Adapter 必须暴露以下两个节点指标：

- `node_cpu_usage_avg`
- `node_memory_usage_avg`

Prometheus Adapter 示例规则如下：

```yaml
rules:
  - seriesQuery: '{__name__=~"node_cpu_seconds_total"}'
    resources:
      overrides:
        node:
          resource: node
    name:
      matches: node_cpu_seconds_total
      as: node_cpu_usage_avg
    metricsQuery: avg_over_time((1 - avg(irate(<<.Series>>{mode="idle"}[5m])) by (node))[10m:30s])
  - seriesQuery: '{__name__=~"node_memory_MemTotal_bytes"}'
    resources:
      overrides:
        node:
          resource: node
    name:
      matches: node_memory_MemTotal_bytes
      as: node_memory_usage_avg
    metricsQuery: avg_over_time(((1 - node_memory_MemAvailable_bytes / <<.Series>>))[10m:30s])
```

部分 Prometheus Adapter 版本使用 `instance` 作为节点资源映射字段。如果您的环境使用这种格式，请把 `resources.overrides.node` 改为 `resources.overrides.instance`，并把 CPU 查询中的 `by (node)` 改为 `by (instance)`。

验证 Custom Metrics API：

```bash
kubectl get --raw=/apis/custom.metrics.k8s.io/v1beta1
kubectl get nodes
kubectl get --raw=/apis/custom.metrics.k8s.io/v1beta1/nodes/<node-name>/node_cpu_usage_avg
kubectl get --raw=/apis/custom.metrics.k8s.io/v1beta1/nodes/<node-name>/node_memory_usage_avg
```

能返回节点指标后，再把 scheduler 配置中的 `metrics.type` 设置为 `prometheus_adaptor`。

### 直接使用 Prometheus

直接访问 Prometheus 时，需要配置 `metrics.address`：

```yaml
metrics:
  type: prometheus
  address: http://prometheus.monitoring.svc:9090
  interval: 30s
  tls:
    insecureSkipVerify: "false"
```

Prometheus 中需要存在 `node_cpu_seconds_total`、`node_memory_MemAvailable_bytes` 和 `node_memory_MemTotal_bytes` 指标。Volcano 会按节点查询最近 10 分钟的 CPU、内存平均利用率。

### 使用 Elasticsearch

使用 Elasticsearch 时，需要配置地址和可选认证信息：

```yaml
metrics:
  type: elasticsearch
  address: http://elasticsearch.monitoring.svc:9200
  interval: 30s
  tls:
    insecureSkipVerify: "false"
  elasticsearch:
    index: "metricbeat-*"
    username: ""
    password: ""
    hostnameFieldName: "host.hostname"
```

Elasticsearch 文档中需要包含以下字段：

- 节点名字段，默认 `host.hostname`
- CPU 利用率字段 `host.cpu.usage`
- 内存利用率字段 `system.memory.actual.used.pct`

## 使用建议

- 负载阈值只用于排序、不用于准入时，把 `enablePredicate` 设置为 `false`。
- 节点超过 CPU 或内存阈值后需要拒绝新 Pod 时，把 `enablePredicate` 设置为 `true`。
- 对 request 比较可信的业务，可以适当提高 `request_ratio`。
- 对启动或运行时突发明显的业务，可以提高 `burst_ratio`。
- 对热点更敏感的集群，可以降低 `risk_threshold` 或提高 `risk_factor`。
- BestEffort Pod 较多时，建议用历史监控数据校准 `be_cpu` 和 `be_mem`。
- 如果同时开启 binpack，binpack 会倾向于把 Pod 调度到资源使用更多的节点，可能削弱负载感知调度的效果。需要按业务目标调整两个插件的权重，或者关闭其中一个策略。
- 如果集群启用了自动扩缩容，硬阈值可能让 Pod 进入 Pending，从而触发扩容。请结合容量水位和扩缩容策略一起配置。

## 验证调度效果

可以用以下方式验证配置是否生效：

1. 查看 scheduler 日志，确认 usage 插件读取到了 estimator 和 threshold 配置。
2. 查询 Custom Metrics API、Prometheus 或 Elasticsearch，确认节点 CPU、内存指标有返回值。
3. 准备多个节点，并在其中一个节点上制造较高 CPU 或内存负载。
4. 连续创建一批使用 Volcano scheduler 的 Pod，观察它们是否更倾向于调度到低负载节点。
5. 调整 `enablePredicate`，验证软约束和硬约束的差异。

示例 Pod：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-load-aware
spec:
  replicas: 6
  selector:
    matchLabels:
      app: nginx-load-aware
  template:
    metadata:
      labels:
        app: nginx-load-aware
    spec:
      schedulerName: volcano
      containers:
        - name: nginx
          image: nginx
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

查看 Pod 分布：

```bash
kubectl get pod -l app=nginx-load-aware -o wide
```

如果一批 Pod 没有全部调度到当前最低负载节点，这是符合预期的。增强后的 usage 插件会把刚分配但还没被监控系统采集到的 Pod 算入影子负载，避免新的热点。

## 常见问题

### 为什么节点已经超过阈值，仍然调度了新 Pod？

先检查 `enablePredicate`。如果设置为 `false`，阈值只影响排序，不会过滤节点。

再检查指标是否过期。节点指标超过 5 分钟没有更新时，usage 插件会放行 Predicate，NodeOrder 返回 0 分。此时需要检查指标源、adapter 规则或网络连通性。

### 为什么新创建的一批 Pod 没有全部落到最低负载节点？

这是增强后的正常行为。如果调度器把一批 Pod 全部放到同一个最低负载节点，这个节点可能在下一轮指标上报前变成热点。usage 插件会为已分配但尚未被监控系统观测到的 Pod 增加影子负载，后续 Pod 会更倾向于分散到其他节点。

### 为什么负载感知调度效果不明显？

通常先检查这几项：

- 指标源没有返回数据，或指标时间过旧。
- 其他 NodeOrder 插件权重更高，例如 binpack、nodeorder 中的其他策略。
- Pod 的 request/limit 与真实用量差异很大，estimator 参数需要按业务重新校准。

### BestEffort Pod 如何参与估算？

BestEffort Pod 没有 request 和 limit。usage 插件使用 `estimator.be_cpu` 和 `estimator.be_mem` 作为固定估算值，并在节点达到风险阈值后乘以 `risk_factor`。

### 指标窗口能否调整？

可以在 Prometheus Adapter 或 Prometheus 查询规则中调整统计窗口。例如示例规则使用最近 10 分钟平均值。`metrics.interval` 控制调度器拉取指标的间隔，也会影响 Running Pod 被视为“监控尚未覆盖”的时间窗口。

## 本次修改点

- 新增“影子负载”说明：解释 `ShadowLoadCache` 如何把当前 session 内已分配但未出现在指标里的 Pod 计入节点负载。
- 更新节点排序公式：从只使用真实 CPU、内存利用率，改为使用真实负载和影子负载合成后的复合利用率。
- 新增 Pod 负载估算公式：补充 `request_ratio`、`burst_ratio`、`effective_limit` 和 `applied_risk_factor` 的含义。
- 新增 BestEffort Pod 估算说明：记录默认 `be_cpu=250m`、`be_mem=200Mi`，并说明风险系数同样生效。
- 新增风险系数说明：说明 `risk_threshold` 和 `risk_factor` 的触发逻辑，以及 `risk_factor` 小于 1 时不会生效。
- 修正 estimator 字段名：参数表和示例统一使用代码实际支持的 `estimator.be_mem`。
- 补充配置参数表：列出 usage 权重、CPU/内存权重、真实负载阈值、estimator 参数和 metrics 参数的默认值与取值范围。
- 补充监控延迟窗口：说明 `metrics.interval` 同时用于指标拉取和 Running Pod 的影子负载判断。
- 补充指标过期降级行为：说明指标超过 5 分钟未更新时，Predicate 放行，NodeOrder 返回 0 分。
- 补充三类指标源配置：保留 `prometheus_adaptor`、`prometheus`、`elasticsearch` 的使用方式和验证命令。
- 补充使用建议和 FAQ：说明硬约束、软约束、binpack、自动扩缩容、BestEffort Pod 和批量 Pod 分散调度的影响。

## 参考资料

- 华为云 CCE 负载感知调度文档：https://support.huaweicloud.com/intl/zh-cn/usermanual-cce/cce_10_0789.html
- 阿里云 ACK 负载感知调度文档：https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/use-load-aware-pod-scheduling
- Volcano usage 插件设计文档：`docs/design/usage-based-scheduling.md`
- 相关实现：`pkg/scheduler/plugins/usage/usage.go`、`pkg/scheduler/plugins/usage/estimator.go`、`pkg/scheduler/plugins/usage/shadow_cache.go`
