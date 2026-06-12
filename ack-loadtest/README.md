# ACK Deployment Batch Load Test

这个目录用于在阿里云 ACK 集群上复用 `cce-loadtest` 的压测流程，但不依赖自定义调度器。所有 Deployment 都显式使用 Kubernetes `default-scheduler`。

默认镜像来自已验证可在 ACK 正常运行的 `stress` 镜像：

```text
crpi-5s8klfipd4nbbznk.cn-shanghai.personal.cr.aliyuncs.com/usage-batch/usage-batch:resource-consumer
```

功能覆盖：

- 批量下发可配置副本数的 Deployment，默认 `10` 副本。
- 每个 Pod 支持 `linear`、`java-spike`、`request-fixed` 三种加压曲线。
- 默认资源规格对齐 `cce-loadtest`：`cpu request=200m, limit=250m`，`memory request=500Mi, limit=600Mi`。
- 默认真实压力对齐 `cce-loadtest`：`200m` CPU，`500Mi` 内存，保持 `86400s`。
- 支持 BestEffort Pod。
- 支持普通滚动升级和 skewed 三 Deployment 滚动升级场景。
- 支持 `kubectl top`、Prometheus PromQL 和 Grafana 观测节点水位、热点概率和 Pod 分布。

## 文件

- `run-deployment-load.sh`: 主脚本，负责生成资源、下发、等待、滚动升级、观测和清理。
- `run-best-effort-load.sh`: BestEffort 包装脚本，复用主脚本能力，但默认不渲染 request/limit。
- `dashboards/grafana-ack-loadtest.json`: ACK Grafana Dashboard 导入模板。
- `tests/test_run_deployment_load.sh`: 本地行为测试，不连接集群。
- `tests/test_grafana_dashboard.sh`: Dashboard JSON 和 PromQL 结构测试。

## 1. 准备 ACK 集群

确认本地 `kubectl` 指向目标 ACK 集群：

```bash
kubectl config current-context
kubectl get nodes -o wide
```

确认基础 metrics 可用：

```bash
kubectl top nodes
kubectl get pods -A | grep -E 'prometheus|kube-state|node-exporter|metrics-server'
```

脚本不会创建自定义 scheduler、Queue 或 CRD。渲染出的 Pod 使用：

```yaml
schedulerName: default-scheduler
```

## 2. 镜像和拉取凭据

脚本默认镜像：

```bash
IMAGE='crpi-5s8klfipd4nbbznk.cn-shanghai.personal.cr.aliyuncs.com/usage-batch/usage-batch:resource-consumer'
```

这个镜像至少需要包含：

- `stress`
- `/bin/sh`

脚本默认不渲染 `imagePullSecrets`，因为你提供的 ACK YAML 已经可以直接拉取镜像。如果目标集群需要 ACR 拉取凭据，显式传入：

```bash
IMAGE_PULL_SECRET=<secret-name> ./run-deployment-load.sh apply
```

如果换镜像：

```bash
IMAGE='<your-acr-image-with-stress>' ./run-deployment-load.sh render
```

## 3. 批量下发负载

预览 YAML：

```bash
./run-deployment-load.sh render
```

下发并等待：

```bash
./run-deployment-load.sh apply
./run-deployment-load.sh wait
```

调整副本数：

```bash
REPLICAS=58 ./run-deployment-load.sh apply
./run-deployment-load.sh wait
```

默认曲线为 `LOAD_PROFILE=linear`，20 秒内逐步升到：

- 内存：`500Mi`
- CPU：`200m`

如果希望 Pod 启动后直接达到 request 对应压力：

```bash
LOAD_PROFILE=request-fixed ./run-deployment-load.sh apply
```

此时默认使用 `MEMORY_REQUEST=500Mi` 和 `CPU_REQUEST=200m` 作为真实压力。也可以显式分离 request 和真实压力：

```bash
LOAD_PROFILE=request-fixed \
CPU_REQUEST=300m \
CPU_LIMIT=2 \
MEMORY_REQUEST=1Gi \
MEMORY_LIMIT=1Gi \
REQUEST_FIXED_MEMORY_MI=700 \
REQUEST_FIXED_CPU_MILLICORES=150 \
./run-deployment-load.sh apply
```

Java 类启动尖峰：

```bash
LOAD_PROFILE=java-spike ./run-deployment-load.sh apply
```

## 4. BestEffort Pod

使用包装脚本：

```bash
./run-best-effort-load.sh render
./run-best-effort-load.sh apply
./run-best-effort-load.sh wait
```

包装脚本默认：

```bash
POD_QOS_CLASS=best-effort
DEPLOYMENT_NAME=ack-best-effort-consumer
```

BestEffort 模式不渲染 `resources.requests` 和 `resources.limits`，但容器内仍会运行 `stress` 产生真实压力。注意如果 namespace 中有 `LimitRange` 默认值，Pod 可能会被自动注入 request/limit，不再是 BestEffort。

## 5. 滚动升级

稳态滚动升级：

```bash
./run-deployment-load.sh rollout --safe
```

压力滚动升级：

```bash
./run-deployment-load.sh rollout --surge
```

按比例 surge：

```bash
./run-deployment-load.sh rollout --surge maxSurge=25% maxUnavailable=0
```

首次 `apply` 就使用百分比策略：

```bash
ROLLING_MAX_SURGE=25% ROLLING_MAX_UNAVAILABLE=0 ./run-deployment-load.sh apply
```

## 6. 构造 skewed 三 Deployment 场景

先获取 ACK 节点的 `kubernetes.io/hostname`：

```bash
kubectl get nodes -L kubernetes.io/hostname
```

初始下发时，三个 Deployment 会用强制节点亲和把 Pod 压到指定节点。必须把默认占位节点替换成真实节点值：

```bash
SKEWED_NODE_1=<node-hostname-1> SKEWED_REPLICAS_1=10 \
SKEWED_NODE_2=<node-hostname-2> SKEWED_REPLICAS_2=6 \
SKEWED_NODE_3=<node-hostname-3> SKEWED_REPLICAS_3=2 \
./run-deployment-load.sh apply-skewed
./run-deployment-load.sh wait-skewed
```

触发滚动升级并删除新 Pod 模板里的节点亲和：

```bash
./run-deployment-load.sh rollout-skewed --steady
```

压力滚动升级：

```bash
./run-deployment-load.sh rollout-skewed --surge maxSurge=25% maxUnavailable=0
```

两个 Deployment 之间默认等待 `45s` 采集指标：

```bash
SKEWED_ROLLOUT_METRICS_WAIT_SECONDS=60 ./run-deployment-load.sh rollout-skewed --steady
```

## 7. 观测

CLI 观测：

```bash
./run-deployment-load.sh observe
```

持续刷新：

```bash
INTERVAL_SECONDS=5 ./run-deployment-load.sh watch-waterline
```

打印 PromQL：

```bash
./run-deployment-load.sh promql
```

Grafana 导入：

```text
ack-loadtest/dashboards/grafana-ack-loadtest.json
```

Pod 分布面板默认统计 `default` namespace 下名称包含 `ack` 的 Pod：

```promql
count by (node) (kube_pod_info{namespace="default",pod=~".*ack.*",node!=""})
```

如果你改了 `NAMESPACE` 或 Deployment 名，需要同步调整 dashboard 的 Pod 过滤条件。

## 8. 清理

普通场景：

```bash
./run-deployment-load.sh cleanup
```

skewed 场景：

```bash
./run-deployment-load.sh cleanup-skewed
```
