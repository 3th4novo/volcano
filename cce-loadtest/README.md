# CCE Deployment Batch Load Test

这个目录用于在华为云 CCE 的真实 Kubernetes 集群上模拟：

- 批量下发 50 副本 Deployment
- 每个 Pod 从 0 线性升压到 `500Mi` 内存和 `200m` CPU
- 每个 Pod 资源声明为 `cpu request=200m, limit=250m`，`memory request=500Mi, limit=600Mi`
- 滚动升级场景，包括稳态升级和 surge 压力升级
- 通过 Prometheus / Prometheus Adapter 观测每个节点实时水位和热点概率

默认 5 个 `4U8G` 节点、50 个副本时，期望最终负载约为：

- 内存：`50 * 500Mi = 25000Mi`，全集群约 `61%`
- 每节点：均匀时约 `10 Pod * 500Mi = 5000Mi`，单节点约 `61%`
- CPU：`50 * 200m = 10 core`，全集群约 `50%`

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

- 推荐：`stress-ng`
- 可接受：`stress`
- 必须：`/bin/sh`

如果镜像不在默认仓库，运行脚本时设置 `IMAGE`：

```bash
export IMAGE='swr.cn-north-4.myhuaweicloud.com/<org>/resource_consumer:<tag>'
```

## 2. 选择并标记 5 个测试节点

建议只让测试负载落在指定 5 个 `4U8G` 节点上。先选节点：

```bash
kubectl get nodes -o wide
```

给 5 个节点打标签：

```bash
kubectl label node <node-1> volcano-loadtest/enabled=true
kubectl label node <node-2> volcano-loadtest/enabled=true
kubectl label node <node-3> volcano-loadtest/enabled=true
kubectl label node <node-4> volcano-loadtest/enabled=true
kubectl label node <node-5> volcano-loadtest/enabled=true
```

脚本运行时使用这个标签：

```bash
export TARGET_NODE_LABEL_KEY='volcano-loadtest/enabled'
export TARGET_NODE_LABEL_VALUE='true'
```

如果你想观察增强点在“不强制打散”时的调度效果，保持默认：

```bash
export SPREAD_MODE=none
```

如果想先校准镜像和指标，让 Pod 尽量均匀分布，可以用软打散：

```bash
export SPREAD_MODE=soft
```

硬打散 `SPREAD_MODE=hard` 会掩盖调度增强点效果，只建议做基准校准时使用。

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

## 4. 批量下发 50 副本

先预览生成的 YAML：

```bash
./run-deployment-load.sh render
```

下发资源：

```bash
./run-deployment-load.sh apply
./run-deployment-load.sh wait
```

查看 Pod 分布：

```bash
kubectl -n volcano-loadtest get pods -o wide
```

负载曲线：

- 第 1 秒：`25Mi` 内存，约 `10m` CPU
- 第 20 秒：`500Mi` 内存，约 `200m` CPU
- 20 秒后保持最终压力水位

## 5. 滚动升级

稳态滚动升级，总副本数不超过 50：

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

压力滚动升级期间，理论峰值内存约为：

```text
55 * 500Mi = 27500Mi
```

全集群约 `67%`。这个模式更容易暴露“新 Pod 尚未被 Prometheus 采到时，调度是否倾向局部热点”的问题。

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
kubectl -n volcano-loadtest top pods --containers
kubectl -n volcano-loadtest get pods -o wide
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
100 * sum by (node) (container_memory_working_set_bytes{namespace="volcano-loadtest",pod=~"cce-resource-consumer-.*",container="consumer"}) / sum by (node) (kube_node_status_allocatable{resource="memory",unit="byte"})
```

每节点本次测试负载贡献的内存水位。

```promql
sum by (node) (rate(container_cpu_usage_seconds_total{namespace="volcano-loadtest",pod=~"cce-resource-consumer-.*",container="consumer"}[1m]))
```

每节点本次测试负载贡献的 CPU core 数。

## 7. 热点出现概率

建议先定义热点阈值，例如节点总内存水位超过 `70%` 算热点：

```bash
export HOTSPOT_MEMORY_THRESHOLD=70
```

单节点过去 30 分钟热点概率：

```promql
100 * avg_over_time(((100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > bool 70)[30m:30s])
```

集群任一节点出现热点的概率：

```promql
100 * avg_over_time((max(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > bool 70)[30m:30s])
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
- 每节点 Pod 数更接近 `10`，或内存水位更接近 `60%`。

## 8. Grafana 可视化

导入面板：

```text
cce-loadtest/dashboards/grafana-cce-loadtest.json
```

导入后设置变量：

- `namespace`: `volcano-loadtest`
- `deployment`: `cce-resource-consumer`
- `container`: `consumer`
- `threshold`: `70`

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

如需移除节点标签：

```bash
kubectl label node <node-1> volcano-loadtest/enabled-
kubectl label node <node-2> volcano-loadtest/enabled-
kubectl label node <node-3> volcano-loadtest/enabled-
kubectl label node <node-4> volcano-loadtest/enabled-
kubectl label node <node-5> volcano-loadtest/enabled-
```
