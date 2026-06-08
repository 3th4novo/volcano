#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
QUEUE_NAME="${QUEUE_NAME:-cce-loadtest}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-cce-resource-consumer}"
CONTAINER_NAME="${CONTAINER_NAME:-consumer}"
IMAGE="${IMAGE:-swr.cn-north-7.myhuaweicloud.com/paas_cce_wwx588067/resource_consumer:latest}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-default-secret}"
SWR_VERSION="${SWR_VERSION:-Shared Edition}"
REPLICAS="${REPLICAS:-10}"

CPU_REQUEST="${CPU_REQUEST:-200m}"
CPU_LIMIT="${CPU_LIMIT:-250m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-500Mi}"
MEMORY_LIMIT="${MEMORY_LIMIT:-600Mi}"
REQUEST_FIXED_MEMORY_MI="${REQUEST_FIXED_MEMORY_MI:-}"
REQUEST_FIXED_CPU_MILLICORES="${REQUEST_FIXED_CPU_MILLICORES:-}"

TARGET_MEMORY_MI="${TARGET_MEMORY_MI:-500}"
MEMORY_STEP_MI="${MEMORY_STEP_MI:-25}"
TARGET_CPU_MILLICORES="${TARGET_CPU_MILLICORES:-200}"
CPU_STEP_MILLICORES="${CPU_STEP_MILLICORES:-10}"
RAMP_SECONDS="${RAMP_SECONDS:-20}"
HOLD_SECONDS="${HOLD_SECONDS:-86400}"
LOAD_PROFILE="${LOAD_PROFILE:-linear}"
JAVA_PEAK_MEMORY_MI="${JAVA_PEAK_MEMORY_MI:-580}"
JAVA_PEAK_CPU_MILLICORES="${JAVA_PEAK_CPU_MILLICORES:-240}"
JAVA_PEAK_HOLD_SECONDS="${JAVA_PEAK_HOLD_SECONDS:-5}"
JAVA_DROP_SECONDS="${JAVA_DROP_SECONDS:-10}"
JAVA_STEADY_MEMORY_MI="${JAVA_STEADY_MEMORY_MI:-500}"
JAVA_STEADY_CPU_MILLICORES="${JAVA_STEADY_CPU_MILLICORES:-200}"

ROLLING_MAX_SURGE="${ROLLING_MAX_SURGE:-0}"
ROLLING_MAX_UNAVAILABLE="${ROLLING_MAX_UNAVAILABLE:-5}"
ROLLING_STEADY_MAX_SURGE="${ROLLING_STEADY_MAX_SURGE:-0}"
ROLLING_STEADY_MAX_UNAVAILABLE="${ROLLING_STEADY_MAX_UNAVAILABLE:-1}"
ROLLING_SAFE_MAX_SURGE="${ROLLING_SAFE_MAX_SURGE:-0}"
ROLLING_SAFE_MAX_UNAVAILABLE="${ROLLING_SAFE_MAX_UNAVAILABLE:-${ROLLING_MAX_UNAVAILABLE}}"
ROLLING_SURGE_MAX_SURGE="${ROLLING_SURGE_MAX_SURGE:-}"
if [[ -z "${ROLLING_SURGE_MAX_SURGE}" ]]; then
  if [[ "${ROLLING_MAX_SURGE}" == "0" ]]; then
    ROLLING_SURGE_MAX_SURGE="5"
  else
    ROLLING_SURGE_MAX_SURGE="${ROLLING_MAX_SURGE}"
  fi
fi
ROLLING_SURGE_MAX_UNAVAILABLE="${ROLLING_SURGE_MAX_UNAVAILABLE:-0}"
SKEWED_DEPLOYMENT_PREFIX="${SKEWED_DEPLOYMENT_PREFIX:-cce-skewed}"
SKEWED_NODE_1="${SKEWED_NODE_1:-192.168.9.134}"
SKEWED_NODE_2="${SKEWED_NODE_2:-192.168.9.133}"
SKEWED_NODE_3="${SKEWED_NODE_3:-192.168.9.182}"
SKEWED_REPLICAS_1="${SKEWED_REPLICAS_1:-10}"
SKEWED_REPLICAS_2="${SKEWED_REPLICAS_2:-6}"
SKEWED_REPLICAS_3="${SKEWED_REPLICAS_3:-2}"
SKEWED_MEMORY_MI="${SKEWED_MEMORY_MI:-500}"
SKEWED_CPU_MILLICORES="${SKEWED_CPU_MILLICORES:-200}"
SKEWED_ROLLOUT_METRICS_WAIT_SECONDS="${SKEWED_ROLLOUT_METRICS_WAIT_SECONDS:-45}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
KUBECTL="${KUBECTL:-kubectl}"
SLEEP_CMD="${SLEEP_CMD:-sleep}"
HOTSPOT_MEMORY_THRESHOLD="${HOTSPOT_MEMORY_THRESHOLD:-80}"
PROMETHEUS_URL="${PROMETHEUS_URL:-}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") render
  $(basename "$0") render-skewed
  $(basename "$0") apply
  $(basename "$0") apply-skewed
  $(basename "$0") wait
  $(basename "$0") wait-skewed
  $(basename "$0") rollout [--safe|--steady|--surge] [maxSurge=25%] [maxUnavailable=0]
  $(basename "$0") rollout-skewed [--safe|--steady|--surge] [maxSurge=25%] [maxUnavailable=0]
  $(basename "$0") observe
  $(basename "$0") watch-waterline
  $(basename "$0") check-adapter [--print-only]
  $(basename "$0") promql
  $(basename "$0") cleanup
  $(basename "$0") cleanup-skewed

Common environment variables:
  IMAGE                      resource_consumer image, default: ${IMAGE}
  NAMESPACE                  default: ${NAMESPACE}
  QUEUE_NAME                 default: ${QUEUE_NAME}
  DEPLOYMENT_NAME            default: ${DEPLOYMENT_NAME}
  IMAGE_PULL_SECRET          default: ${IMAGE_PULL_SECRET}
  SWR_VERSION                default: ${SWR_VERSION}
  REPLICAS                   default: ${REPLICAS}
  LOAD_PROFILE               linear|java-spike|request-fixed, default: ${LOAD_PROFILE}
  REQUEST_FIXED_MEMORY_MI    request-fixed memory pressure in Mi, default: MEMORY_REQUEST
  REQUEST_FIXED_CPU_MILLICORES request-fixed CPU pressure in millicores, default: CPU_REQUEST
  ROLLING_STEADY_MAX_SURGE default steady maxSurge: ${ROLLING_STEADY_MAX_SURGE}
  ROLLING_STEADY_MAX_UNAVAILABLE default steady maxUnavailable: ${ROLLING_STEADY_MAX_UNAVAILABLE}
  ROLLING_MAX_SURGE          default Deployment maxSurge: ${ROLLING_MAX_SURGE}
  ROLLING_MAX_UNAVAILABLE    default Deployment maxUnavailable: ${ROLLING_MAX_UNAVAILABLE}
  ROLLING_SURGE_MAX_SURGE    rollout --surge maxSurge: ${ROLLING_SURGE_MAX_SURGE}
  ROLLING_SURGE_MAX_UNAVAILABLE rollout --surge maxUnavailable: ${ROLLING_SURGE_MAX_UNAVAILABLE}
  SKEWED_NODE_1              default: ${SKEWED_NODE_1}
  SKEWED_NODE_2              default: ${SKEWED_NODE_2}
  SKEWED_NODE_3              default: ${SKEWED_NODE_3}
  SKEWED_REPLICAS_1          default: ${SKEWED_REPLICAS_1}
  SKEWED_REPLICAS_2          default: ${SKEWED_REPLICAS_2}
  SKEWED_REPLICAS_3          default: ${SKEWED_REPLICAS_3}
  SKEWED_ROLLOUT_METRICS_WAIT_SECONDS seconds to wait between skewed rollouts: ${SKEWED_ROLLOUT_METRICS_WAIT_SECONDS}
  PROMETHEUS_URL             optional, for observe queries
EOF
}

validate_int_or_percent() {
  name="$1"
  value="$2"
  if [[ ! "${value}" =~ ^[0-9]+%?$ ]]; then
    echo "${name} must be a non-negative integer or percentage, for example 5 or 25%" >&2
    exit 1
  fi
}

json_int_or_percent() {
  value="$1"
  validate_int_or_percent "rolling update value" "${value}"
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${value}"
  else
    printf '"%s"' "${value}"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

validate_non_negative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "${name} must be a non-negative integer without unit" >&2
    exit 1
  fi
}

cpu_request_to_millicores() {
  local value="$1"
  if [[ "${value}" =~ ^([0-9]+)m$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v value="${value}" 'BEGIN { printf "%.0f", value * 1000 }'
  else
    echo "CPU_REQUEST must be millicores like 200m or cores like 1 or 0.2" >&2
    exit 1
  fi
}

memory_request_to_mi() {
  local value="$1"
  if [[ "${value}" =~ ^([0-9]+)Mi$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "${value}" =~ ^([0-9]+)Gi$ ]]; then
    printf '%s' "$((BASH_REMATCH[1] * 1024))"
  else
    echo "MEMORY_REQUEST must use Mi or Gi, for example 500Mi or 1Gi" >&2
    exit 1
  fi
}

render_namespace() {
  if [[ "${NAMESPACE}" != "default" ]]; then
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: volcano-cce-loadtest
---
EOF
  fi
}

render_image_pull_secrets() {
  if [[ -n "${IMAGE_PULL_SECRET}" ]]; then
    cat <<EOF
      imagePullSecrets:
      - name: ${IMAGE_PULL_SECRET}
EOF
  fi
}

render_manifest() {
  validate_int_or_percent "ROLLING_MAX_SURGE" "${ROLLING_MAX_SURGE}"
  validate_int_or_percent "ROLLING_MAX_UNAVAILABLE" "${ROLLING_MAX_UNAVAILABLE}"
  local request_memory_mi request_cpu_millicores request_fixed_memory_mi request_fixed_cpu_millicores
  request_memory_mi="$(memory_request_to_mi "${MEMORY_REQUEST}")"
  request_cpu_millicores="$(cpu_request_to_millicores "${CPU_REQUEST}")"
  request_fixed_memory_mi="${REQUEST_FIXED_MEMORY_MI:-${request_memory_mi}}"
  request_fixed_cpu_millicores="${REQUEST_FIXED_CPU_MILLICORES:-${request_cpu_millicores}}"
  validate_non_negative_integer "REQUEST_FIXED_MEMORY_MI" "${request_fixed_memory_mi}"
  validate_non_negative_integer "REQUEST_FIXED_CPU_MILLICORES" "${request_fixed_cpu_millicores}"
  render_namespace
  cat <<EOF
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
    LOAD_PROFILE="${LOAD_PROFILE:-linear}"
    REQUEST_FIXED_MEMORY_MI="${request_fixed_memory_mi}"
    REQUEST_FIXED_CPU_MILLICORES="${request_fixed_cpu_millicores}"
    JAVA_PEAK_MEMORY_MI="${JAVA_PEAK_MEMORY_MI:-580}"
    JAVA_PEAK_CPU_MILLICORES="${JAVA_PEAK_CPU_MILLICORES:-240}"
    JAVA_PEAK_HOLD_SECONDS="${JAVA_PEAK_HOLD_SECONDS:-5}"
    JAVA_DROP_SECONDS="${JAVA_DROP_SECONDS:-10}"
    JAVA_STEADY_MEMORY_MI="${JAVA_STEADY_MEMORY_MI:-500}"
    JAVA_STEADY_CPU_MILLICORES="${JAVA_STEADY_CPU_MILLICORES:-200}"

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

    ensure_stress() {
      if ! command -v stress >/dev/null 2>&1; then
        echo "stress is not available in the image" >&2
        exit 1
      fi
    }

    run_linear_profile() {
      echo "linear profile: memory 0 -> \${TARGET_MEMORY_MI}Mi, cpu 0 -> \${TARGET_CPU_MILLICORES}m, seconds=\${RAMP_SECONDS}"

      i=1
      while [ "\${i}" -le "\${RAMP_SECONDS}" ]; do
        mem_mi=\$((MEMORY_STEP_MI * i))
        cpu_millicores=\$((CPU_STEP_MILLICORES * i))
        [ "\${mem_mi}" -gt "\${TARGET_MEMORY_MI}" ] && mem_mi="\${TARGET_MEMORY_MI}"
        [ "\${cpu_millicores}" -gt "\${TARGET_CPU_MILLICORES}" ] && cpu_millicores="\${TARGET_CPU_MILLICORES}"

        start_stress "\${mem_mi}" "\${cpu_millicores}"

        echo "linear step=\${i} memory=\${mem_mi}Mi cpu=\${cpu_millicores}m"
        i=\$((i + 1))
        sleep 1
      done

      echo "holding memory=\${TARGET_MEMORY_MI}Mi cpu=\${TARGET_CPU_MILLICORES}m for \${HOLD_SECONDS}s"
      wait
    }

    run_java_spike_profile() {
      echo "java-spike profile: peak \${JAVA_PEAK_MEMORY_MI}Mi/\${JAVA_PEAK_CPU_MILLICORES}m, hold \${JAVA_PEAK_HOLD_SECONDS}s, drop \${JAVA_DROP_SECONDS}s, steady \${JAVA_STEADY_MEMORY_MI}Mi/\${JAVA_STEADY_CPU_MILLICORES}m"

      start_stress "\${JAVA_PEAK_MEMORY_MI}" "\${JAVA_PEAK_CPU_MILLICORES}"
      sleep "\${JAVA_PEAK_HOLD_SECONDS}"

      i=1
      while [ "\${i}" -le "\${JAVA_DROP_SECONDS}" ]; do
        mem_delta=\$((JAVA_PEAK_MEMORY_MI - JAVA_STEADY_MEMORY_MI))
        cpu_delta=\$((JAVA_PEAK_CPU_MILLICORES - JAVA_STEADY_CPU_MILLICORES))
        mem_mi=\$((JAVA_PEAK_MEMORY_MI - (mem_delta * i / JAVA_DROP_SECONDS)))
        cpu_millicores=\$((JAVA_PEAK_CPU_MILLICORES - (cpu_delta * i / JAVA_DROP_SECONDS)))

        start_stress "\${mem_mi}" "\${cpu_millicores}"

        echo "java-spike drop step=\${i} memory=\${mem_mi}Mi cpu=\${cpu_millicores}m"
        i=\$((i + 1))
        sleep 1
      done

      start_stress "\${JAVA_STEADY_MEMORY_MI}" "\${JAVA_STEADY_CPU_MILLICORES}"
      echo "holding memory=\${JAVA_STEADY_MEMORY_MI}Mi cpu=\${JAVA_STEADY_CPU_MILLICORES}m for \${HOLD_SECONDS}s"
      wait
    }

    run_request_fixed_profile() {
      echo "request-fixed profile: memory=\${REQUEST_FIXED_MEMORY_MI}Mi cpu=\${REQUEST_FIXED_CPU_MILLICORES}m"
      start_stress "\${REQUEST_FIXED_MEMORY_MI}" "\${REQUEST_FIXED_CPU_MILLICORES}"
      wait
    }

    ensure_stress
    case "\${LOAD_PROFILE}" in
      linear)
        run_linear_profile
        ;;
      java-spike)
        run_java_spike_profile
        ;;
      request-fixed)
        run_request_fixed_profile
        ;;
      *)
        echo "unsupported LOAD_PROFILE=\${LOAD_PROFILE}; expected linear, java-spike, or request-fixed" >&2
        exit 2
        ;;
    esac
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  annotations:
    description: ""
    workload.cce.io/swr-version: '[{"version":"${SWR_VERSION}"}]'
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
$(render_image_pull_secrets)
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
        - name: LOAD_PROFILE
          value: "${LOAD_PROFILE}"
        - name: REQUEST_FIXED_MEMORY_MI
          value: "${request_fixed_memory_mi}"
        - name: REQUEST_FIXED_CPU_MILLICORES
          value: "${request_fixed_cpu_millicores}"
        - name: JAVA_PEAK_MEMORY_MI
          value: "${JAVA_PEAK_MEMORY_MI}"
        - name: JAVA_PEAK_CPU_MILLICORES
          value: "${JAVA_PEAK_CPU_MILLICORES}"
        - name: JAVA_PEAK_HOLD_SECONDS
          value: "${JAVA_PEAK_HOLD_SECONDS}"
        - name: JAVA_DROP_SECONDS
          value: "${JAVA_DROP_SECONDS}"
        - name: JAVA_STEADY_MEMORY_MI
          value: "${JAVA_STEADY_MEMORY_MI}"
        - name: JAVA_STEADY_CPU_MILLICORES
          value: "${JAVA_STEADY_CPU_MILLICORES}"
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

skewed_deployment_name() {
  printf '%s-%s' "${SKEWED_DEPLOYMENT_PREFIX}" "$1"
}

render_skewed_scripts_configmap() {
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${SKEWED_DEPLOYMENT_PREFIX}-scripts
  namespace: ${NAMESPACE}
data:
  fixed-load.sh: |
    #!/bin/sh
    set -eu

    FIXED_MEMORY_MI="${SKEWED_MEMORY_MI}"
    FIXED_CPU_MILLICORES="${SKEWED_CPU_MILLICORES}"
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

    if ! command -v stress >/dev/null 2>&1; then
      echo "stress is not available in the image" >&2
      exit 1
    fi

    echo "fixed profile: memory=\${FIXED_MEMORY_MI}Mi cpu=\${FIXED_CPU_MILLICORES}m"
    stress --vm 1 --vm-bytes "\${FIXED_MEMORY_MI}M" --vm-keep --timeout "\${HOLD_SECONDS}" &
    MEM_PID="\$!"
    cpu_loop "\${FIXED_CPU_MILLICORES}" &
    CPU_PID="\$!"
    wait
EOF
}

render_skewed_deployment() {
  idx="$1"
  node_var="SKEWED_NODE_${idx}"
  replicas_var="SKEWED_REPLICAS_${idx}"
  node_name="${!node_var}"
  replicas="${!replicas_var}"
  deployment_name="$(skewed_deployment_name "${idx}")"

  if [[ -z "${node_name}" ]]; then
    echo "${node_var} must not be empty" >&2
    exit 1
  fi
  if [[ ! "${replicas}" =~ ^[0-9]+$ ]]; then
    echo "${replicas_var} must be a non-negative integer" >&2
    exit 1
  fi

  cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${deployment_name}
  namespace: ${NAMESPACE}
  annotations:
    description: ""
    workload.cce.io/swr-version: '[{"version":"${SWR_VERSION}"}]'
  labels:
    app.kubernetes.io/name: ${deployment_name}
    loadtest.volcano.sh/mode: skewed
    loadtest.volcano.sh/group: ${SKEWED_DEPLOYMENT_PREFIX}
spec:
  replicas: ${replicas}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: ${ROLLING_MAX_SURGE}
      maxUnavailable: ${ROLLING_MAX_UNAVAILABLE}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${deployment_name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${deployment_name}
        loadtest.volcano.sh/mode: skewed
        loadtest.volcano.sh/group: ${SKEWED_DEPLOYMENT_PREFIX}
      annotations:
        scheduling.volcano.sh/queue-name: ${QUEUE_NAME}
        loadtest.volcano.sh/rollout-id: "initial"
    spec:
      schedulerName: volcano
      terminationGracePeriodSeconds: 5
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - ${node_name}
$(render_image_pull_secrets)
      containers:
      - name: ${CONTAINER_NAME}
        image: ${IMAGE}
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - /scripts/fixed-load.sh
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
          name: ${SKEWED_DEPLOYMENT_PREFIX}-scripts
          defaultMode: 0755
EOF
}

render_skewed_manifest() {
  validate_int_or_percent "ROLLING_MAX_SURGE" "${ROLLING_MAX_SURGE}"
  validate_int_or_percent "ROLLING_MAX_UNAVAILABLE" "${ROLLING_MAX_UNAVAILABLE}"
  render_namespace
  cat <<EOF
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
EOF
  render_skewed_scripts_configmap
  render_skewed_deployment 1
  render_skewed_deployment 2
  render_skewed_deployment 3
}

apply_manifest() {
  require_cmd "${KUBECTL}"
  render_manifest | "${KUBECTL}" apply -f -
}

apply_skewed_manifest() {
  require_cmd "${KUBECTL}"
  render_skewed_manifest | "${KUBECTL}" apply -f -
}

wait_ready() {
  require_cmd "${KUBECTL}"
  "${KUBECTL}" -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT_NAME}" --timeout="${WAIT_TIMEOUT}"
  "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready "pod" -l "app.kubernetes.io/name=${DEPLOYMENT_NAME}" --timeout="${WAIT_TIMEOUT}"
}

wait_rollout_status() {
  require_cmd "${KUBECTL}"
  "${KUBECTL}" -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT_NAME}" --timeout="${WAIT_TIMEOUT}"
}

wait_skewed_ready() {
  require_cmd "${KUBECTL}"
  for idx in 1 2 3; do
    deployment_name="$(skewed_deployment_name "${idx}")"
    "${KUBECTL}" -n "${NAMESPACE}" rollout status "deployment/${deployment_name}" --timeout="${WAIT_TIMEOUT}"
  done
  "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready "pod" -l "loadtest.volcano.sh/group=${SKEWED_DEPLOYMENT_PREFIX}" --timeout="${WAIT_TIMEOUT}"
}

wait_skewed_rollout_status() {
  require_cmd "${KUBECTL}"
  for idx in 1 2 3; do
    deployment_name="$(skewed_deployment_name "${idx}")"
    "${KUBECTL}" -n "${NAMESPACE}" rollout status "deployment/${deployment_name}" --timeout="${WAIT_TIMEOUT}"
  done
}

wait_between_skewed_rollouts() {
  idx="$1"
  [[ "${idx}" -lt 3 ]] || return 0
  validate_non_negative_integer "SKEWED_ROLLOUT_METRICS_WAIT_SECONDS" "${SKEWED_ROLLOUT_METRICS_WAIT_SECONDS}"
  [[ "${SKEWED_ROLLOUT_METRICS_WAIT_SECONDS}" -gt 0 ]] || return 0

  next_idx=$((idx + 1))
  echo "waiting ${SKEWED_ROLLOUT_METRICS_WAIT_SECONDS}s for metrics collection before rolling out $(skewed_deployment_name "${next_idx}")"
  "${SLEEP_CMD}" "${SKEWED_ROLLOUT_METRICS_WAIT_SECONDS}"
}

patch_deployment_rollout_strategy() {
  deployment_name="$1"
  shift
  mode="$1"
  max_surge_override="$2"
  max_unavailable_override="$3"
  case "${mode}" in
    --safe|"")
      surge="${ROLLING_SAFE_MAX_SURGE}"
      unavailable="${ROLLING_SAFE_MAX_UNAVAILABLE}"
      ;;
    --steady)
      surge="${ROLLING_STEADY_MAX_SURGE}"
      unavailable="${ROLLING_STEADY_MAX_UNAVAILABLE}"
      ;;
    --surge)
      surge="${ROLLING_SURGE_MAX_SURGE}"
      unavailable="${ROLLING_SURGE_MAX_UNAVAILABLE}"
      ;;
    *)
      echo "invalid rollout mode: ${mode}; expected --safe, --steady, or --surge" >&2
      exit 1
      ;;
  esac
  if [[ -n "${max_surge_override}" ]]; then
    surge="${max_surge_override}"
  fi
  if [[ -n "${max_unavailable_override}" ]]; then
    unavailable="${max_unavailable_override}"
  fi
  validate_int_or_percent "maxSurge" "${surge}"
  validate_int_or_percent "maxUnavailable" "${unavailable}"
  surge_json="$(json_int_or_percent "${surge}")"
  unavailable_json="$(json_int_or_percent "${unavailable}")"

  "${KUBECTL}" -n "${NAMESPACE}" patch deployment "${deployment_name}" --type merge \
    -p "{\"spec\":{\"strategy\":{\"type\":\"RollingUpdate\",\"rollingUpdate\":{\"maxSurge\":${surge_json},\"maxUnavailable\":${unavailable_json}}}}}"
}

patch_rollout_strategy() {
  patch_deployment_rollout_strategy "${DEPLOYMENT_NAME}" "$@"
}

parse_rollout_args() {
  ROLLOUT_MODE=""
  ROLLOUT_MAX_SURGE_OVERRIDE=""
  ROLLOUT_MAX_UNAVAILABLE_OVERRIDE=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --safe|--steady|--surge)
        ROLLOUT_MODE="$1"
        shift
        ;;
      --max-surge|--maxSurge)
        [[ "$#" -ge 2 ]] || {
          echo "$1 requires a value" >&2
          exit 1
        }
        ROLLOUT_MAX_SURGE_OVERRIDE="$2"
        shift 2
        ;;
      --max-surge=*|--maxSurge=*|maxSurge=*)
        ROLLOUT_MAX_SURGE_OVERRIDE="${1#*=}"
        shift
        ;;
      --max-unavailable|--maxUnavailable)
        [[ "$#" -ge 2 ]] || {
          echo "$1 requires a value" >&2
          exit 1
        }
        ROLLOUT_MAX_UNAVAILABLE_OVERRIDE="$2"
        shift 2
        ;;
      --max-unavailable=*|--maxUnavailable=*|maxUnavailable=*)
        ROLLOUT_MAX_UNAVAILABLE_OVERRIDE="${1#*=}"
        shift
        ;;
      *)
        echo "invalid rollout argument: $1" >&2
        exit 1
        ;;
    esac
  done
}

rollout() {
  require_cmd "${KUBECTL}"
  parse_rollout_args "$@"
  patch_rollout_strategy "${ROLLOUT_MODE}" "${ROLLOUT_MAX_SURGE_OVERRIDE}" "${ROLLOUT_MAX_UNAVAILABLE_OVERRIDE}"
  rollout_id="$(date +%Y%m%d%H%M%S)"
  "${KUBECTL}" -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"loadtest.volcano.sh/rollout-id\":\"${rollout_id}\"}}}}}"
  wait_rollout_status
}

rollout_skewed() {
  require_cmd "${KUBECTL}"
  parse_rollout_args "$@"
  rollout_id="$(date +%Y%m%d%H%M%S)"
  for idx in 1 2 3; do
    deployment_name="$(skewed_deployment_name "${idx}")"
    patch_deployment_rollout_strategy "${deployment_name}" "${ROLLOUT_MODE}" "${ROLLOUT_MAX_SURGE_OVERRIDE}" "${ROLLOUT_MAX_UNAVAILABLE_OVERRIDE}"
    "${KUBECTL}" -n "${NAMESPACE}" patch deployment "${deployment_name}" --type merge \
      -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"loadtest.volcano.sh/rollout-id\":\"${rollout_id}\"}},\"spec\":{\"affinity\":null}}}}"
    "${KUBECTL}" -n "${NAMESPACE}" rollout status "deployment/${deployment_name}" --timeout="${WAIT_TIMEOUT}"
    wait_between_skewed_rollouts "${idx}"
  done
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
# Scheduled CCE pods per node:
count by (node) (kube_pod_info{namespace="default",pod=~".*cce.*",node!=""})

# Per-node hotspot probability over the last 10m; hotspot means max(cpu, memory) > 80%:
100 * avg_over_time(((max by (instance) (label_replace(100 * (1 - avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m]))), "resource", "cpu", "instance", ".*") or label_replace(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes), "resource", "memory", "instance", ".*"))) > bool 80)[10m:30s])

# Per-node idle probability over the last 10m; idle means max(cpu, memory) < 30%:
100 * avg_over_time(((max by (instance) (label_replace(100 * (1 - avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m]))), "resource", "cpu", "instance", ".*") or label_replace(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes), "resource", "memory", "instance", ".*"))) < bool 30)[10m:30s])

# Peak per-node CPU waterline over the last 10m:
max_over_time((100 * (1 - avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m]))))[10m:30s])

# Peak per-node memory waterline over the last 10m:
max_over_time((100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))[10m:30s])

# Per-node CPU waterline, 10m average:
100 * avg_over_time((1 - avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])))[10m:30s])

# Per-node memory waterline, 10m average:
100 * avg_over_time((1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)[10m:30s])

# CPU waterline variance across nodes, 10m average:
stdvar(100 * avg_over_time((1 - avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])))[10m:30s]))

# Memory waterline variance across nodes, 10m average:
stdvar(100 * avg_over_time((1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)[10m:30s]))
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
  "${KUBECTL}" -n "${NAMESPACE}" delete deployment "${DEPLOYMENT_NAME}" --ignore-not-found
  "${KUBECTL}" -n "${NAMESPACE}" delete configmap "${DEPLOYMENT_NAME}-scripts" --ignore-not-found
  "${KUBECTL}" delete queue "${QUEUE_NAME}" --ignore-not-found
  if [[ "${NAMESPACE}" != "default" ]]; then
    "${KUBECTL}" delete namespace "${NAMESPACE}" --ignore-not-found
  fi
}

cleanup_skewed() {
  require_cmd "${KUBECTL}"
  for idx in 1 2 3; do
    deployment_name="$(skewed_deployment_name "${idx}")"
    "${KUBECTL}" -n "${NAMESPACE}" delete deployment "${deployment_name}" --ignore-not-found
  done
  "${KUBECTL}" -n "${NAMESPACE}" delete configmap "${SKEWED_DEPLOYMENT_PREFIX}-scripts" --ignore-not-found
  "${KUBECTL}" delete queue "${QUEUE_NAME}" --ignore-not-found
  if [[ "${NAMESPACE}" != "default" ]]; then
    "${KUBECTL}" delete namespace "${NAMESPACE}" --ignore-not-found
  fi
}

action="${1:-help}"
shift || true

case "${action}" in
  render)
    render_manifest
    ;;
  render-skewed)
    render_skewed_manifest
    ;;
  apply)
    apply_manifest
    ;;
  apply-skewed)
    apply_skewed_manifest
    ;;
  wait)
    wait_ready
    ;;
  wait-skewed)
    wait_skewed_ready
    ;;
  rollout)
    rollout "$@"
    ;;
  rollout-skewed)
    rollout_skewed "$@"
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
  cleanup-skewed)
    cleanup_skewed
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
