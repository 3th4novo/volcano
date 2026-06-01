#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-volcano-loadtest}"
QUEUE_NAME="${QUEUE_NAME:-cce-loadtest}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-cce-resource-consumer}"
CONTAINER_NAME="${CONTAINER_NAME:-consumer}"
IMAGE="${IMAGE:-swr.cn-north-7.myhuaweicloud.com/paas_cce_wwx588067/resource_consumer:latest}"
REPLICAS="${REPLICAS:-58}"

CPU_REQUEST="${CPU_REQUEST:-200m}"
CPU_LIMIT="${CPU_LIMIT:-250m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-500Mi}"
MEMORY_LIMIT="${MEMORY_LIMIT:-600Mi}"

TARGET_MEMORY_MI="${TARGET_MEMORY_MI:-500}"
MEMORY_STEP_MI="${MEMORY_STEP_MI:-25}"
TARGET_CPU_MILLICORES="${TARGET_CPU_MILLICORES:-200}"
CPU_STEP_MILLICORES="${CPU_STEP_MILLICORES:-10}"
RAMP_SECONDS="${RAMP_SECONDS:-20}"
HOLD_SECONDS="${HOLD_SECONDS:-86400}"

ROLLING_MAX_SURGE="${ROLLING_MAX_SURGE:-0}"
ROLLING_MAX_UNAVAILABLE="${ROLLING_MAX_UNAVAILABLE:-5}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
KUBECTL="${KUBECTL:-kubectl}"
HOTSPOT_MEMORY_THRESHOLD="${HOTSPOT_MEMORY_THRESHOLD:-80}"
PROMETHEUS_URL="${PROMETHEUS_URL:-}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") render
  $(basename "$0") apply
  $(basename "$0") wait
  $(basename "$0") rollout [--safe|--surge]
  $(basename "$0") observe
  $(basename "$0") watch-waterline
  $(basename "$0") check-adapter [--print-only]
  $(basename "$0") promql
  $(basename "$0") cleanup

Common environment variables:
  IMAGE                      resource_consumer image, default: ${IMAGE}
  NAMESPACE                  default: ${NAMESPACE}
  QUEUE_NAME                 default: ${QUEUE_NAME}
  DEPLOYMENT_NAME            default: ${DEPLOYMENT_NAME}
  REPLICAS                   default: ${REPLICAS}
  PROMETHEUS_URL             optional, for observe queries
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

render_manifest() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: volcano-cce-loadtest
---
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: ${QUEUE_NAME}
spec:
  weight: 1
  reclaimable: false
  capability:
    cpu: "20"
    memory: "56Gi"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${DEPLOYMENT_NAME}-scripts
  namespace: ${NAMESPACE}
data:
  load.sh: |
    #!/bin/sh
    set -eu

    TARGET_MEMORY_MI="${TARGET_MEMORY_MI:-500}"
    MEMORY_STEP_MI="${MEMORY_STEP_MI:-25}"
    TARGET_CPU_MILLICORES="${TARGET_CPU_MILLICORES:-200}"
    CPU_STEP_MILLICORES="${CPU_STEP_MILLICORES:-10}"
    RAMP_SECONDS="${RAMP_SECONDS:-20}"
    HOLD_SECONDS="${HOLD_SECONDS:-86400}"

    MEM_PID=""
    CPU_PID=""

    cleanup() {
      [ -n "\${MEM_PID}" ] && kill "\${MEM_PID}" 2>/dev/null || true
      [ -n "\${CPU_PID}" ] && kill "\${CPU_PID}" 2>/dev/null || true
    }
    trap cleanup TERM INT EXIT

    now_ms() {
      ts="\$(date +%s%3N 2>/dev/null || true)"
      case "\${ts}" in
        ""|*[!0-9]*) echo "\$(date +%s)000" ;;
        *) echo "\${ts}" ;;
      esac
    }

    cpu_loop() {
      millicores="\$1"
      [ "\${millicores}" -lt 1 ] && millicores=1
      [ "\${millicores}" -gt 1000 ] && millicores=1000
      idle_ms=\$((1000 - millicores))
      while true; do
        start="\$(now_ms)"
        end=\$((start + millicores))
        while [ "\$(now_ms)" -lt "\${end}" ]; do :; done
        if [ "\${idle_ms}" -gt 0 ]; then
          sleep "0.\$(printf '%03d' "\${idle_ms}")"
        fi
      done
    }

    start_stress() {
      mem_mi="\$1"
      cpu_millicores="\$2"
      [ -n "\${MEM_PID}" ] && kill "\${MEM_PID}" 2>/dev/null || true
      [ -n "\${CPU_PID}" ] && kill "\${CPU_PID}" 2>/dev/null || true
      stress --vm 1 --vm-bytes "\${mem_mi}M" --vm-keep --timeout "\${HOLD_SECONDS}" &
      MEM_PID="\$!"
      cpu_loop "\${cpu_millicores}" &
      CPU_PID="\$!"
    }

    echo "resource ramp: memory 0 -> \${TARGET_MEMORY_MI}Mi, cpu 0 -> \${TARGET_CPU_MILLICORES}m, seconds=\${RAMP_SECONDS}"

    i=1
    while [ "\${i}" -le "\${RAMP_SECONDS}" ]; do
      mem_mi=\$((MEMORY_STEP_MI * i))
      cpu_millicores=\$((CPU_STEP_MILLICORES * i))
      [ "\${mem_mi}" -gt "\${TARGET_MEMORY_MI}" ] && mem_mi="\${TARGET_MEMORY_MI}"
      [ "\${cpu_millicores}" -gt "\${TARGET_CPU_MILLICORES}" ] && cpu_millicores="\${TARGET_CPU_MILLICORES}"

      if ! command -v stress >/dev/null 2>&1; then
        echo "stress is not available in the image" >&2
        exit 1
      fi
      start_stress "\${mem_mi}" "\${cpu_millicores}"

      echo "ramp step=\${i} memory=\${mem_mi}Mi cpu=\${cpu_millicores}m"
      i=\$((i + 1))
      sleep 1
    done

    echo "holding memory=\${TARGET_MEMORY_MI}Mi cpu=\${TARGET_CPU_MILLICORES}m for \${HOLD_SECONDS}s"
    wait
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${DEPLOYMENT_NAME}
spec:
  replicas: ${REPLICAS}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: ${ROLLING_MAX_SURGE}
      maxUnavailable: ${ROLLING_MAX_UNAVAILABLE}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${DEPLOYMENT_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${DEPLOYMENT_NAME}
      annotations:
        scheduling.volcano.sh/queue-name: ${QUEUE_NAME}
        loadtest.volcano.sh/rollout-id: "initial"
    spec:
      schedulerName: volcano
      terminationGracePeriodSeconds: 5
      containers:
      - name: ${CONTAINER_NAME}
        image: ${IMAGE}
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - /scripts/load.sh
        env:
        - name: TARGET_MEMORY_MI
          value: "${TARGET_MEMORY_MI}"
        - name: MEMORY_STEP_MI
          value: "${MEMORY_STEP_MI}"
        - name: TARGET_CPU_MILLICORES
          value: "${TARGET_CPU_MILLICORES}"
        - name: CPU_STEP_MILLICORES
          value: "${CPU_STEP_MILLICORES}"
        - name: RAMP_SECONDS
          value: "${RAMP_SECONDS}"
        - name: HOLD_SECONDS
          value: "${HOLD_SECONDS}"
        resources:
          requests:
            cpu: ${CPU_REQUEST}
            memory: ${MEMORY_REQUEST}
          limits:
            cpu: ${CPU_LIMIT}
            memory: ${MEMORY_LIMIT}
        volumeMounts:
        - name: load-scripts
          mountPath: /scripts
          readOnly: true
      volumes:
      - name: load-scripts
        configMap:
          name: ${DEPLOYMENT_NAME}-scripts
          defaultMode: 0755
EOF
}

apply_manifest() {
  require_cmd "${KUBECTL}"
  render_manifest | "${KUBECTL}" apply -f -
}

wait_ready() {
  require_cmd "${KUBECTL}"
  "${KUBECTL}" -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT_NAME}" --timeout="${WAIT_TIMEOUT}"
  "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready "pod" -l "app.kubernetes.io/name=${DEPLOYMENT_NAME}" --timeout="${WAIT_TIMEOUT}"
}

patch_rollout_strategy() {
  mode="$1"
  case "${mode}" in
    --safe|"")
      surge=0
      unavailable=5
      ;;
    --surge)
      surge=5
      unavailable=0
      ;;
    *)
      echo "invalid rollout mode: ${mode}; expected --safe or --surge" >&2
      exit 1
      ;;
  esac

  "${KUBECTL}" -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type merge \
    -p "{\"spec\":{\"strategy\":{\"type\":\"RollingUpdate\",\"rollingUpdate\":{\"maxSurge\":${surge},\"maxUnavailable\":${unavailable}}}}}"
}

rollout() {
  require_cmd "${KUBECTL}"
  patch_rollout_strategy "${1:-}"
  rollout_id="$(date +%Y%m%d%H%M%S)"
  "${KUBECTL}" -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"loadtest.volcano.sh/rollout-id\":\"${rollout_id}\"}}}}}"
  wait_ready
}

print_adapter_commands() {
  cat <<EOF
# Confirm Custom Metrics API discovery includes both node metrics:
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | grep -E "node_cpu_usage_avg|node_memory_usage_avg"

# Confirm per-node CPU usage metric is exposed:
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/nodes/*/node_cpu_usage_avg"

# Confirm per-node memory usage metric is exposed:
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/nodes/*/node_memory_usage_avg"

# Expected scale for Volcano prometheus_adaptor mode:
# values should be ratios around 0.00-1.00. Volcano multiplies Value.AsApproximateFloat64() by 100.
EOF
}

check_adapter() {
  if [[ "${1:-}" == "--print-only" ]]; then
    print_adapter_commands
    return 0
  fi

  require_cmd "${KUBECTL}"
  discovery="$("${KUBECTL}" get --raw "/apis/custom.metrics.k8s.io/v1beta1")"
  echo "${discovery}" | grep -q "node_cpu_usage_avg" || {
    echo "node_cpu_usage_avg is not present in Custom Metrics API discovery" >&2
    exit 1
  }
  echo "${discovery}" | grep -q "node_memory_usage_avg" || {
    echo "node_memory_usage_avg is not present in Custom Metrics API discovery" >&2
    exit 1
  }

  for metric in node_cpu_usage_avg node_memory_usage_avg; do
    echo "checking ${metric}"
    output="$("${KUBECTL}" get --raw "/apis/custom.metrics.k8s.io/v1beta1/nodes/*/${metric}")"
    echo "${output}" | grep -q '"items"' || {
      echo "${metric} returned no items" >&2
      exit 1
    }
    echo "${output}" | grep -q '"kind":"Node"' || {
      echo "${metric} did not return node-scoped metrics" >&2
      exit 1
    }
    echo "${output}" | grep -q '"value"' || {
      echo "${metric} did not return metric values" >&2
      exit 1
    }
  done

  echo "Custom Metrics API exposes node_cpu_usage_avg and node_memory_usage_avg."
}

print_promql() {
  cat <<EOF
# Per-node total memory waterline (%):
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# Per-node load-test pod memory waterline over allocatable memory (%):
100 * sum by (node) (container_memory_working_set_bytes{namespace="${NAMESPACE}",pod=~"${DEPLOYMENT_NAME}-.*",container="${CONTAINER_NAME}"}) / sum by (node) (kube_node_status_allocatable{resource="memory",unit="byte"})

# Per-node load-test CPU cores:
sum by (node) (rate(container_cpu_usage_seconds_total{namespace="${NAMESPACE}",pod=~"${DEPLOYMENT_NAME}-.*",container="${CONTAINER_NAME}"}[1m]))

# Hotspot probability over the last 30m, threshold=${HOTSPOT_MEMORY_THRESHOLD}%:
100 * avg_over_time(((100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > bool ${HOTSPOT_MEMORY_THRESHOLD})[30m:30s])

# Cluster hotspot probability: at least one node is above threshold during each sample:
100 * avg_over_time((max(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > bool ${HOTSPOT_MEMORY_THRESHOLD})[30m:30s])

# Per-node memory skew; lower means better balance:
stddev(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))

# Peak per-node memory waterline in the last 30m:
max_over_time((100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))[30m:30s])
EOF
}

prometheus_query() {
  query="$1"
  if [[ -z "${PROMETHEUS_URL}" ]]; then
    echo "PROMETHEUS_URL is not set; skip Prometheus query" >&2
    return 0
  fi
  require_cmd curl
  curl -fsS -G "${PROMETHEUS_URL%/}/api/v1/query" --data-urlencode "query=${query}"
  echo
}

observe() {
  require_cmd "${KUBECTL}"
  "${KUBECTL}" -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${DEPLOYMENT_NAME}" -o wide
  echo
  "${KUBECTL}" top nodes || true
  echo
  "${KUBECTL}" -n "${NAMESPACE}" top pods --containers || true
  echo
  echo "PromQL for dashboard panels:"
  print_promql

  if [[ -n "${PROMETHEUS_URL}" ]]; then
    echo
    echo "Current per-node memory waterline from Prometheus:"
    prometheus_query '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'
  fi
}

watch_waterline() {
  require_cmd "${KUBECTL}"
  interval="${INTERVAL_SECONDS:-5}"
  while true; do
    date
    "${KUBECTL}" top nodes || true
    echo
    "${KUBECTL}" -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${DEPLOYMENT_NAME}" -o wide --no-headers | awk '{count[$7]++} END {for (node in count) printf "%s pods=%d\n", node, count[node]}'
    echo "----"
    sleep "${interval}"
  done
}

cleanup() {
  require_cmd "${KUBECTL}"
  "${KUBECTL}" delete namespace "${NAMESPACE}" --ignore-not-found
  "${KUBECTL}" delete queue "${QUEUE_NAME}" --ignore-not-found
}

action="${1:-help}"
shift || true

case "${action}" in
  render)
    render_manifest
    ;;
  apply)
    apply_manifest
    ;;
  wait)
    wait_ready
    ;;
  rollout)
    rollout "${1:-}"
    ;;
  observe)
    observe
    ;;
  watch-waterline)
    watch_waterline
    ;;
  check-adapter)
    check_adapter "${1:-}"
    ;;
  promql)
    print_promql
    ;;
  cleanup)
    cleanup
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
