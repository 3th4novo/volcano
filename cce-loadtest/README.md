# CCE Deployment Batch Load Test

这个目录用于在华为云 CCE 的真实 Kubernetes 集群上模拟：

- 批量下发可配置副本数的 Deployment，默认 10 副本
- 每个 Pod 支持三种可配置加压曲线：`linear` 线性升压，`java-spike` 启动陡增后回落到平稳水位，`request-fixed` 启动后按 request 值直接加压并保持
- 每个 Pod 资源声明为 `cpu request=200m, limit=250m`，`memory request=500Mi, limit=600Mi`
- 滚动升级场景，包括稳态升级和 surge 压力升级
- 通过 Prometheus / Prometheus Adapter 观测每个节点实时水位和热点概率

当前按 3 个 `4U8G` 节点和 2 个 `4U16G` 节点计算：

- 集群 CPU 总量：`5 * 4U = 20U`
- 集群内存总量：`3 * 8Gi + 2 * 16Gi = 56Gi = 57344Mi`
- 当前真实内存峰值不到 `10%`，为了让批量负载后集群真实内存水位约 `60%`，新增负载按 `50%` 集群内存估算
- 需要新增内存：`57344Mi * (60% - 10%) = 28672Mi`
- 单 Pod 最终真实内存：`500Mi`
- 若目标是把集群真实内存水位压到约 `60%`，副本数：`28672Mi / 500Mi = 57.34`，向上取整为 `58`

默认 10 个副本时，期望最终负载约为：

- 内存：`10 * 500Mi = 5000Mi`，全集群新增约 `8.7%`
- CPU：`10 * 200m = 2 core`，全集群新增约 `10%`

当设置 `REPLICAS=58` 时，期望最终负载约为：

- 内存：`58 * 500Mi = 29000Mi`，全集群新增约 `50.6%`，叠加当前不到 `10%` 的基础水位后约 `60%`
- CPU：`58 * 200m = 11.6 core`，全集群新增约 `58%`
- CPU request：当前集群已有申请约 `40%`，叠加本次 `58%` 后约 `98%`，调度会比较贴近上限；如果出现 Pending，可临时设置 `REPLICAS=55`

因为节点内存规格不同，`REPLICAS=58` 验证的是“集群整体真实内存水位约 60%”。如果调度结果在 8Gi 节点上接近均匀分布，8Gi 节点可能比 16Gi 节点更早接近热点阈值，这正好可以用来观察增强点是否会把更多新负载引导到低水位节点。

> 注意：Kubernetes 中不要写 `500m` 表示内存。`500m` 是 milli-byte。这里使用 `500Mi` 和 `600Mi`。

## 文件

- `run-deployment-load.sh`: 主脚本，负责生成资源、下发、滚动升级、观测和 adapter 检查。
- `dashboards/grafana-cce-loadtest.json`: Grafana Dashboard 导入模板。
- `tests/test_run_deployment_load.sh`: 本地行为测试，不连接集群。

## 1. 准备 CCE 集群

确认本地 `kubectl` 指向目标 CCE 集群：

```bash
kubectl config current-context
kubectl get nodes -o wide
```

确认 Volcano scheduler 已安装并可用：

```bash
kubectl get pods -A | grep -E 'volcano|scheduler'
kubectl get crd | grep 'queues.scheduling.volcano.sh'
```

确认 Prometheus / kube-state-metrics / node-exporter / Prometheus Adapter 已安装：

```bash
kubectl get pods -A | grep -E 'prometheus|adapter|kube-state|node-exporter'
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | head
```

准备 `resource_consumer` 镜像。镜像中至少需要有：

- 必须：`stress`
- 必须：`/bin/sh`

脚本不会调用 `stress-ng`。内存压力由 `stress --vm` 产生；CPU 的 `0 -> 200m` 线性压力由脚本用轻量 duty-cycle 控制，因为普通 `stress` 没有 `--cpu-load` 这类百分比参数。

脚本默认使用你的 SWR 镜像：

```bash
IMAGE='swr.cn-north-7.myhuaweicloud.com/paas_cce_wwx588067/resource_consumer:latest'
```

如果要临时换镜像，运行脚本前覆盖 `IMAGE` 即可。

脚本默认运行在 `default` namespace，并使用 CCE 自动创建的 SWR 拉取凭据：

```yaml
metadata:
  annotations:
    workload.cce.io/swr-version: '[{"version":"Shared Edition"}]'
spec:
  template:
    spec:
      imagePullSecrets:
      - name: default-secret
```

这两个字段来自 CCE 控制台可正常拉取该镜像的工作负载样例。镜像拉取本质上依赖同 namespace 下的 `imagePullSecrets`，`workload.cce.io/swr-version` 更像 CCE/SWR 工作负载元数据；只加 annotation 但没有可用 secret 时，kubelet 仍然可能无法鉴权拉取镜像。

如果改用非 `default` namespace，需要先确认目标 namespace 里也存在可用拉取凭据，或者覆盖 `IMAGE_PULL_SECRET`：

```bash
kubectl -n <namespace> get secret default-secret
NAMESPACE=<namespace> IMAGE_PULL_SECRET=<secret-name> ./run-deployment-load.sh apply
```

## 2. 确认当前 5 个节点

```bash
kubectl get nodes -o wide
```

当前集群只有这 5 个节点，脚本不再生成 `nodeSelector`，也不再生成 `topologySpreadConstraints`。这样可以直接观察 Volcano 增强调度在自然批量下发场景中的效果。

## 3. 确认 CCE Prometheus Adapter 暴露指标

Volcano 的 `prometheus_adaptor` 路径需要 Custom Metrics API 暴露：

- `node_cpu_usage_avg`
- `node_memory_usage_avg`

执行：

```bash
./run-deployment-load.sh check-adapter
```

如果只想看脚本会执行哪些检查：

```bash
./run-deployment-load.sh check-adapter --print-only
```

等价手工检查：

```bash
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | grep -E "node_cpu_usage_avg|node_memory_usage_avg"
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/nodes/*/node_cpu_usage_avg"
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/nodes/*/node_memory_usage_avg"
```

确认点：

- discovery 中能看到两个 metric 名称。
- 每个 metric 返回 `items`。
- `describedObject.kind` 是 `Node`。
- `value` 的量纲应是 `0~1` 的比例。Custom Metrics API 常见输出如 `532m`，代表 `0.532`，Volcano 会乘以 100 后作为 `53.2%`。如果直接返回 `53`，Volcano 会理解成 `5300%`，需要调整 adapter 规则。

## 4. 批量下发负载

先预览生成的 YAML：

```bash
./run-deployment-load.sh render
```

默认下发 10 副本：

```bash
./run-deployment-load.sh apply
./run-deployment-load.sh wait
```

如果要按前面的计算把集群真实内存水位压到约 `60%`，显式设置 58 副本：

```bash
REPLICAS=58 ./run-deployment-load.sh apply
./run-deployment-load.sh wait
```

查看 Pod 分布：

```bash
kubectl -n default get pods -o wide
```

默认负载曲线为 `LOAD_PROFILE=linear`：

- 第 1 秒：`25Mi` 内存，约 `10m` CPU
- 第 20 秒：`500Mi` 内存，约 `200m` CPU
- 20 秒后保持最终压力水位

如果需要 Pod 启动后立即达到 request 对应的压力水位，可以使用 `request-fixed`：

```bash
LOAD_PROFILE=request-fixed ./run-deployment-load.sh apply
./run-deployment-load.sh wait
```

`request-fixed` 默认会根据当前 Pod 的 `CPU_REQUEST` 和 `MEMORY_REQUEST` 生成压力值。默认规格下，每个 Pod 启动后直接施加 `500Mi` 内存和约 `200m` CPU，并持续保持。

如果希望 Deployment 的申请值和真实稳定加压值分开，可以显式覆盖稳定加压值：

```bash
LOAD_PROFILE=request-fixed \
CPU_REQUEST=300m \
CPU_LIMIT=500m \
MEMORY_REQUEST=1Gi \
MEMORY_LIMIT=1200Mi \
REQUEST_FIXED_MEMORY_MI=700 \
REQUEST_FIXED_CPU_MILLICORES=150 \
./run-deployment-load.sh apply
```

上面的配置会让 Pod 的资源申请保持为 `1Gi/300m`，但启动后的真实压力保持在约 `700Mi/150m`。`REQUEST_FIXED_MEMORY_MI` 的单位固定为 `Mi`，`REQUEST_FIXED_CPU_MILLICORES` 的单位固定为 millicores，配置时只填写整数。加压值如果超过 limit，内存可能触发 OOMKilled，CPU 会被 CFS throttling 限流。

也可以切换成 Java 类业务启动曲线：

```bash
LOAD_PROFILE=java-spike ./run-deployment-load.sh apply
./run-deployment-load.sh wait
```

`java-spike` 默认曲线：

- Pod 启动后立即升到峰值：`580Mi` 内存，约 `240m` CPU
- 峰值保持 `5` 秒
- 随后用 `10` 秒回落到平稳水位：`500Mi` 内存，约 `200m` CPU
- 回落后持续保持平稳水位

可配置参数：

```bash
LOAD_PROFILE=java-spike
JAVA_PEAK_MEMORY_MI=580
JAVA_PEAK_CPU_MILLICORES=240
JAVA_PEAK_HOLD_SECONDS=5
JAVA_DROP_SECONDS=10
JAVA_STEADY_MEMORY_MI=500
JAVA_STEADY_CPU_MILLICORES=200
```

默认峰值留在 `memory limit=600Mi` 和 `cpu limit=250m` 以内，避免测试负载因为启动峰值直接 OOMKilled 或被过度限流。如果调整峰值，建议内存峰值不要超过 `590Mi`，CPU 峰值不要超过 `245m`。

## 5. 滚动升级

稳态滚动升级，总副本数不超过当前 Deployment 副本数：

```bash
./run-deployment-load.sh rollout --safe
```

对应策略：

- `maxSurge: 0`
- `maxUnavailable: 5`

压力滚动升级默认最多临时增加 5 个 Pod：

```bash
./run-deployment-load.sh rollout --surge
```

对应策略：

- `maxSurge: 5`
- `maxUnavailable: 0`

如果希望按比例临时增加 Pod，可以直接传 Kubernetes RollingUpdate 的 IntOrString 值。例如 `maxSurge=25%`：

```bash
./run-deployment-load.sh rollout --surge maxSurge=25% maxUnavailable=0
```

等价的环境变量写法：

```bash
ROLLING_SURGE_MAX_SURGE=25% ROLLING_SURGE_MAX_UNAVAILABLE=0 ./run-deployment-load.sh rollout --surge
```

如果希望首次 `apply` 时 Deployment 默认策略也使用百分比 surge：

```bash
ROLLING_MAX_SURGE=25% ROLLING_MAX_UNAVAILABLE=0 ./run-deployment-load.sh apply
```

当 `REPLICAS=58` 且默认 `maxSurge=5` 时，压力滚动升级期间理论峰值内存约为：

```text
63 * 500Mi = 31500Mi
```

如果使用 `maxSurge=25%`，Kubernetes 对 surge 百分比向上取整，58 副本会最多临时增加约 15 个 Pod：

```text
73 * 500Mi = 36500Mi
```

这个模式更容易暴露“新 Pod 尚未被 Prometheus 采到时，调度是否倾向局部热点”的问题。对比 Koordinator 时，建议使用 `LOAD_PROFILE=java-spike` 和 `maxSurge=25%` 放大启动尖峰和指标滞后窗口。

## 6. 构造不均匀三 Deployment 场景

这个模式用于先人为制造三个不同水位的热点节点，再通过滚动升级删除节点亲和，让新 Pod 重新交给调度器自由分布。

默认节点和副本数：

| Deployment | 目标节点 `kubernetes.io/hostname` | 副本数 | 新增内存压力 |
|---|---|---:|---:|
| `cce-skewed-1` | `192.168.9.134` | `10` | 约 `61%` |
| `cce-skewed-2` | `192.168.9.133` | `6` | 约 `36.6%` |
| `cce-skewed-3` | `192.168.9.182` | `2` | 约 `12.2%` |
| 空闲观察节点 | `192.168.9.47` | `0` | `0%` |

计算口径：单 Pod 内存压力为 `500Mi`，4U8Gi 节点上约等于 `500 / 8192 = 6.1%`。如果节点已有 DaemonSet 占用约 `10%`，三个目标节点初始真实水位约为 `71%`、`46.6%`、`22.2%`，第四个节点约 `10%`。

初始下发：

```bash
SKEWED_NODE_1=192.168.9.134 SKEWED_REPLICAS_1=10 \
SKEWED_NODE_2=192.168.9.133 SKEWED_REPLICAS_2=6 \
SKEWED_NODE_3=192.168.9.182 SKEWED_REPLICAS_3=2 \
./run-deployment-load.sh apply-skewed
./run-deployment-load.sh wait-skewed
```

初始下发时，三个 Deployment 都会带强制节点亲和：

```yaml
key: kubernetes.io/hostname
operator: In
```

Skewed 模式不使用 `linear` 或 `java-spike`。每个 Pod 启动后直接施加固定压力并保持：

- 内存：`500Mi`
- CPU：`200m`

触发三组 Deployment 轮流滚动升级，并删除新 Pod 模板里的节点亲和：

稳态滚动升级，不临时增加 Pod，每个 Deployment 一次最多允许 1 个不可用：

```bash
./run-deployment-load.sh rollout-skewed --steady
```

对应策略：

- `maxSurge: 0`
- `maxUnavailable: 1`

压力滚动升级，允许按比例临时增加 Pod：

```bash
./run-deployment-load.sh rollout-skewed --surge maxSurge=25% maxUnavailable=0
```

滚动升级时脚本会：

- 先处理 `cce-skewed-1`，等待它完成 rollout。
- 再处理 `cce-skewed-2`，等待它完成 rollout。
- 最后处理 `cce-skewed-3`，等待它完成 rollout。
- 每个 Deployment 都会 patch RollingUpdate 策略。
- 每个 Deployment 都会 patch Pod template，设置 `affinity: null`。
- 更新 `loadtest.volcano.sh/rollout-id`，触发新 ReplicaSet。
- 每个 Deployment 完成后才进入下一个 Deployment。

`rollout-skewed` 完成条件使用 Deployment `rollout status`。它不会额外等待同组所有 Pod Ready，避免旧 ReplicaSet 的 Terminating Pod 被宽 selector 匹配后导致脚本在 rollout 成功后继续阻塞。

清理：

```bash
./run-deployment-load.sh cleanup-skewed
```

预期现象：初始阶段 Pod 明显集中在前三个节点；滚动升级后，新 ReplicaSet 的 Pod 不再指定节点，应观察调度器是否把三个 Deployment 的副本重新打散到四个节点上。

## 7. 实时水位观测

CLI 快速观测：

```bash
./run-deployment-load.sh observe
```

持续刷新节点水位和 Pod 分布：

```bash
INTERVAL_SECONDS=5 ./run-deployment-load.sh watch-waterline
```

也可以直接运行：

```bash
kubectl top nodes
kubectl -n default top pods --containers
kubectl -n default get pods -o wide
```

Prometheus 查询：

```bash
./run-deployment-load.sh promql
```

Grafana Dashboard 现在只关注节点水位、节点间离散度和 Pod 分布。压测 Pod 统计固定使用 `default` namespace 下名称包含 `cce` 的 Pod：

```promql
count by (node) (kube_pod_info{namespace="default",pod=~".*cce.*",node!=""})
```

各节点 CPU 水位：

```promql
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])))
```

各节点内存水位：

```promql
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

## 8. 热点出现概率

当前热点定义为节点综合水位超过 `80%`。综合水位取 CPU 水位和内存水位的较高值；空闲定义为综合水位低于 `30%`。

单节点过去 5 分钟热点概率：

```promql
100 * avg_over_time(((max by (instance) (
  label_replace(100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m]))), "resource", "cpu", "instance", ".*")
  or
  label_replace(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes), "resource", "memory", "instance", ".*")
)) > bool 80)[5m:30s])
```

单节点过去 5 分钟空闲概率：

```promql
100 * avg_over_time(((max by (instance) (
  label_replace(100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m]))), "resource", "cpu", "instance", ".*")
  or
  label_replace(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes), "resource", "memory", "instance", ".*")
)) < bool 30)[5m:30s])
```

过去 5 分钟 CPU / 内存峰值水位：

```promql
max_over_time((100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m]))))[5m:30s])
```

```promql
max_over_time((100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))[5m:30s])
```

节点间 CPU 水位方差：

```promql
stdvar(100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m]))))
```

节点间内存水位方差：

```promql
stdvar(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))
```

增强点有效时，批量下发和滚动升级期间应看到：

- 高水位节点更少。
- CPU / 内存水位方差更低。
- 各节点 Pod 数更接近。
- 各节点超过 `80%` 的时间占比更低，低于 `30%` 的空闲概率更符合预期。

## 9. Grafana 可视化

导入面板：

```text
cce-loadtest/dashboards/grafana-cce-loadtest.json
```

导入后设置变量：

- `node`: 默认 `All`，也可以只选择部分节点

Dashboard 只保留这些面板：

- Scheduled CCE pods per node
- Per-node hotspot probability, last 5m
- Per-node idle probability, last 5m
- Peak CPU waterline, last 5m
- Peak memory waterline, last 5m
- Per-node CPU waterline
- Per-node memory waterline
- CPU waterline variance across nodes
- Memory waterline variance across nodes

观察窗口建议：

- 批量下发：`Last 5 minutes`
- 滚动升级：`Last 5 minutes`
- Prometheus scrape interval 较长时，窗口可放大到 `1 hour`

## 10. 清理

```bash
./run-deployment-load.sh cleanup
```

脚本不会创建或依赖节点标签，因此不需要额外清理节点标签。
