# CCE Deployment Batch Load Test

这个目录用于在华为云 CCE 的真实 Kubernetes 集群上模拟：

- 批量下发可配置副本数的 Deployment，默认 10 副本
- 每个 Pod 从 0 线性升压到 `500Mi` 内存和 `200m` CPU
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

负载曲线：

- 第 1 秒：`25Mi` 内存，约 `10m` CPU
- 第 20 秒：`500Mi` 内存，约 `200m` CPU
- 20 秒后保持最终压力水位

## 5. 滚动升级

稳态滚动升级，总副本数不超过当前 Deployment 副本数：

```bash
./run-deployment-load.sh rollout --safe
```

对应策略：

- `maxSurge: 0`
- `maxUnavailable: 5`

压力滚动升级，最多临时增加 5 个 Pod：

```bash
./run-deployment-load.sh rollout --surge
```

对应策略：

- `maxSurge: 5`
- `maxUnavailable: 0`

当 `REPLICAS=58` 时，压力滚动升级期间理论峰值内存约为：

```text
63 * 500Mi = 31500Mi
```

全集群新增约 `55%`，叠加基础水位后约 `65%`。这个模式更容易暴露“新 Pod 尚未被 Prometheus 采到时，调度是否倾向局部热点”的问题。

## 6. 实时水位观测

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

关键 PromQL：

```promql
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

每节点总内存水位。

```promql
100 * sum by (node) (container_memory_working_set_bytes{namespace="default",pod=~"cce-resource-consumer-.*",container="consumer"}) / sum by (node) (kube_node_status_allocatable{resource="memory",unit="byte"})
```

每节点本次测试负载贡献的内存水位。

```promql
sum by (node) (rate(container_cpu_usage_seconds_total{namespace="default",pod=~"cce-resource-consumer-.*",container="consumer"}[1m]))
```

每节点本次测试负载贡献的 CPU core 数。

## 7. 热点出现概率

当前热点定义为节点真实内存利用率超过 `80%`：

```bash
export HOTSPOT_MEMORY_THRESHOLD=80
```

单节点过去 30 分钟热点概率：

```promql
100 * avg_over_time(((100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > bool 80)[30m:30s])
```

集群任一节点出现热点的概率：

```promql
100 * avg_over_time((max(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > bool 80)[30m:30s])
```

节点间水位离散度：

```promql
stddev(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))
```

节点间最大水位差：

```promql
max(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) - min(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))
```

增强点有效时，批量下发和滚动升级期间应看到：

- 高水位节点更少。
- `stddev` 更低。
- 最大水位差更小。
- `cluster hotspot probability` 更低。
- 节点真实内存水位更接近目标水位，且 8Gi 节点超过 `80%` 的时间占比更低。

## 8. Grafana 可视化

导入面板：

```text
cce-loadtest/dashboards/grafana-cce-loadtest.json
```

导入后设置变量：

- `namespace`: `default`
- `deployment`: `cce-resource-consumer`
- `container`: `consumer`
- `threshold`: `80`

推荐同时打开这些面板：

- Per-node total memory waterline
- Load-test memory waterline
- Load-test CPU cores
- Per-node hotspot probability
- Cluster hotspot probability
- Memory waterline skew

观察窗口建议：

- 批量下发：`Last 15 minutes`
- 滚动升级：`Last 30 minutes`
- Prometheus scrape interval 较长时，窗口可放大到 `1 hour`

## 9. 清理

```bash
./run-deployment-load.sh cleanup
```

脚本不会创建或依赖节点标签，因此不需要额外清理节点标签。
