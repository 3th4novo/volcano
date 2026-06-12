#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/run-deployment-load.sh"
BEST_EFFORT_SCRIPT="${ROOT_DIR}/run-best-effort-load.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" == *"${needle}"* ]] || fail "expected output to contain: ${needle}"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" != *"${needle}"* ]] || fail "expected output not to contain: ${needle}"
}

assert_line_order() {
  local haystack="$1"
  shift
  local previous_line=0
  local needle line
  for needle in "$@"; do
    line="$(printf '%s\n' "${haystack}" | awk -v needle="${needle}" -v previous_line="${previous_line}" 'NR > previous_line && index($0, needle) { print NR; exit }')"
    [[ -n "${line}" ]] || fail "expected output to contain ordered item: ${needle}"
    [[ "${line}" -gt "${previous_line}" ]] || fail "expected ${needle} to appear after previous ordered item"
    previous_line="${line}"
  done
}

manifest="$(${SCRIPT} render)"

[[ "${manifest}" != *"kind: Namespace"* ]] || fail "default render should not create or manage the default namespace"
assert_contains "${manifest}" "kind: Deployment"
assert_contains "${manifest}" "name: ack-resource-consumer"
assert_contains "${manifest}" "namespace: default"
assert_contains "${manifest}" "image: crpi-5s8klfipd4nbbznk.cn-shanghai.personal.cr.aliyuncs.com/usage-batch/usage-batch:resource-consumer"
assert_contains "${manifest}" "replicas: 10"
assert_contains "${manifest}" "schedulerName: default-scheduler"
assert_not_contains "${manifest}" "apiVersion: scheduling.volcano.sh"
assert_not_contains "${manifest}" "kind: Queue"
assert_not_contains "${manifest}" "scheduling.volcano.sh/queue-name"
assert_not_contains "${manifest}" "loadtest.volcano.sh"
assert_contains "${manifest}" "memory: 512Mi"
assert_contains "${manifest}" "memory: 1Gi"
assert_contains "${manifest}" "cpu: 500m"
assert_contains "${manifest}" "cpu: 2"
assert_contains "${manifest}" "maxSurge: 0"
assert_contains "${manifest}" "maxUnavailable: 5"
assert_contains "${manifest}" "TARGET_MEMORY_MI=\"256\""
assert_contains "${manifest}" "TARGET_CPU_MILLICORES=\"2000\""
assert_contains "${manifest}" "CPU_STEP_MILLICORES=\"100\""
assert_contains "${manifest}" "REQUEST_FIXED_MEMORY_MI=\"512\""
assert_contains "${manifest}" "REQUEST_FIXED_CPU_MILLICORES=\"500\""
assert_contains "${manifest}" "run_linear_profile()"
assert_contains "${manifest}" "run_java_spike_profile()"
assert_contains "${manifest}" "run_request_fixed_profile()"
assert_contains "${manifest}" "request-fixed)"
assert_contains "${manifest}" "unsupported LOAD_PROFILE="
assert_not_contains "${manifest}" "workload.cce.io/swr-version"
assert_not_contains "${manifest}" "swr.cn-north-7.myhuaweicloud.com"
assert_not_contains "${manifest}" "default-secret"
assert_not_contains "${manifest}" "imagePullSecrets:"

secret_manifest="$(IMAGE_PULL_SECRET=ack-acr-secret ${SCRIPT} render)"
assert_contains "${secret_manifest}" "imagePullSecrets:"
assert_contains "${secret_manifest}" "- name: ack-acr-secret"

[[ "${manifest}" != *"stress-ng"* ]] || fail "manifest should not use stress-ng"
[[ "${manifest}" != *"nodeSelector:"* ]] || fail "manifest should not render nodeSelector"
[[ "${manifest}" != *"topologySpreadConstraints:"* ]] || fail "manifest should not render topologySpreadConstraints"

queries="$(${SCRIPT} promql)"
assert_contains "${queries}" "namespace=\"default\""
assert_contains "${queries}" "pod=~\".*ack.*\""
assert_contains "${queries}" "kube_pod_info"
assert_contains "${queries}" "node_cpu_seconds_total"
assert_contains "${queries}" "node_memory_MemAvailable_bytes"
assert_contains "${queries}" "stdvar"
assert_contains "${queries}" "max_over_time"
assert_contains "${queries}" "[1m:15s]"
assert_contains "${queries}" "[1m]"
assert_contains "${queries}" "irate(node_cpu_seconds_total"
assert_contains "${queries}" "> bool 80"
assert_contains "${queries}" "< bool 30"
[[ "${queries}" != *"container_memory_working_set_bytes"* ]] || fail "promql output should not include container memory metrics"
[[ "${queries}" != *"container_cpu_usage_seconds_total"* ]] || fail "promql output should not include container CPU metrics"
[[ "${queries}" != *"[10m:30s]"* ]] || fail "promql output should use 1m windows, not 10m statistical windows"
[[ "${queries}" != *"[5m]"* ]] || fail "promql output should use 1m CPU irate windows, not 5m"
[[ "${queries}" != *":30s]"* ]] || fail "promql output should use 15s subquery steps, not 30s"
[[ ! "${queries}" =~ (^|[^i])rate\(node_cpu_seconds_total ]] || fail "promql output should use adapter-aligned irate CPU queries"
[[ "${queries}" != *"30m"* ]] || fail "promql output should use 1m windows, not 30m"

override_manifest="$(REPLICAS=58 ${SCRIPT} render)"
assert_contains "${override_manifest}" "replicas: 58"

surge_manifest="$(ROLLING_MAX_SURGE=25% ROLLING_MAX_UNAVAILABLE=0 ${SCRIPT} render)"
assert_contains "${surge_manifest}" "maxSurge: 25%"
assert_contains "${surge_manifest}" "maxUnavailable: 0"

java_manifest="$(LOAD_PROFILE=java-spike JAVA_PEAK_MEMORY_MI=590 JAVA_PEAK_CPU_MILLICORES=1900 ${SCRIPT} render)"
assert_contains "${java_manifest}" "LOAD_PROFILE=\"java-spike\""
assert_contains "${java_manifest}" "JAVA_PEAK_MEMORY_MI=\"590\""
assert_contains "${java_manifest}" "JAVA_PEAK_CPU_MILLICORES=\"1900\""

fixed_manifest="$(LOAD_PROFILE=request-fixed CPU_REQUEST=300m MEMORY_REQUEST=1Gi ${SCRIPT} render)"
assert_contains "${fixed_manifest}" "LOAD_PROFILE=\"request-fixed\""
assert_contains "${fixed_manifest}" "REQUEST_FIXED_MEMORY_MI=\"1024\""
assert_contains "${fixed_manifest}" "REQUEST_FIXED_CPU_MILLICORES=\"300\""
assert_contains "${fixed_manifest}" "memory: 1Gi"
assert_contains "${fixed_manifest}" "cpu: 300m"

fixed_override_manifest="$(LOAD_PROFILE=request-fixed CPU_REQUEST=300m MEMORY_REQUEST=1Gi REQUEST_FIXED_MEMORY_MI=700 REQUEST_FIXED_CPU_MILLICORES=150 ${SCRIPT} render)"
assert_contains "${fixed_override_manifest}" "LOAD_PROFILE=\"request-fixed\""
assert_contains "${fixed_override_manifest}" "REQUEST_FIXED_MEMORY_MI=\"700\""
assert_contains "${fixed_override_manifest}" "REQUEST_FIXED_CPU_MILLICORES=\"150\""
assert_contains "${fixed_override_manifest}" "memory: 1Gi"
assert_contains "${fixed_override_manifest}" "cpu: 300m"

best_effort_manifest="$(POD_QOS_CLASS=best-effort ${SCRIPT} render)"
assert_contains "${best_effort_manifest}" "kind: Deployment"
assert_contains "${best_effort_manifest}" "name: ack-resource-consumer"
assert_contains "${best_effort_manifest}" "schedulerName: default-scheduler"
assert_not_contains "${best_effort_manifest}" "scheduling.volcano.sh/queue-name"
assert_not_contains "${best_effort_manifest}" "loadtest.volcano.sh"
assert_contains "${best_effort_manifest}" "LOAD_PROFILE=\"linear\""
assert_not_contains "${best_effort_manifest}" "        resources:"
assert_not_contains "${best_effort_manifest}" "          requests:"
assert_not_contains "${best_effort_manifest}" "          limits:"
assert_not_contains "${best_effort_manifest}" "cpu: 500m"
assert_not_contains "${best_effort_manifest}" "cpu: 2"
assert_not_contains "${best_effort_manifest}" "memory: 512Mi"
assert_not_contains "${best_effort_manifest}" "memory: 1Gi"

best_effort_fixed_manifest="$(POD_QOS_CLASS=best-effort LOAD_PROFILE=request-fixed ${SCRIPT} render)"
assert_contains "${best_effort_fixed_manifest}" "LOAD_PROFILE=\"request-fixed\""
assert_contains "${best_effort_fixed_manifest}" "REQUEST_FIXED_MEMORY_MI=\"256\""
assert_contains "${best_effort_fixed_manifest}" "REQUEST_FIXED_CPU_MILLICORES=\"2000\""
assert_not_contains "${best_effort_fixed_manifest}" "        resources:"

best_effort_fixed_override_manifest="$(POD_QOS_CLASS=best-effort LOAD_PROFILE=request-fixed REQUEST_FIXED_MEMORY_MI=700 REQUEST_FIXED_CPU_MILLICORES=150 ${SCRIPT} render)"
assert_contains "${best_effort_fixed_override_manifest}" "REQUEST_FIXED_MEMORY_MI=\"700\""
assert_contains "${best_effort_fixed_override_manifest}" "REQUEST_FIXED_CPU_MILLICORES=\"150\""
assert_not_contains "${best_effort_fixed_override_manifest}" "        resources:"

best_effort_wrapper_manifest="$(${BEST_EFFORT_SCRIPT} render)"
assert_contains "${best_effort_wrapper_manifest}" "name: ack-best-effort-consumer"
assert_contains "${best_effort_wrapper_manifest}" "schedulerName: default-scheduler"
assert_not_contains "${best_effort_wrapper_manifest}" "scheduling.volcano.sh/queue-name"
assert_not_contains "${best_effort_wrapper_manifest}" "loadtest.volcano.sh"
assert_not_contains "${best_effort_wrapper_manifest}" "        resources:"

tmpdir="$(mktemp -d)"
fake_kubectl="${tmpdir}/kubectl"
fake_sleep="${tmpdir}/sleep"
kubectl_log="${tmpdir}/kubectl.log"
cat > "${fake_kubectl}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KUBECTL_LOG}"
EOF
chmod +x "${fake_kubectl}"
cat > "${fake_sleep}" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "${KUBECTL_LOG}"
EOF
chmod +x "${fake_sleep}"

KUBECTL_LOG="${kubectl_log}" KUBECTL="${fake_kubectl}" WAIT_TIMEOUT=1s "${SCRIPT}" rollout --surge maxSurge=25% maxUnavailable=0
rollout_log="$(cat "${kubectl_log}")"
assert_contains "${rollout_log}" '"maxSurge":"25%"'
assert_contains "${rollout_log}" '"maxUnavailable":0'
assert_contains "${rollout_log}" "rollout status deployment/ack-resource-consumer"
assert_not_contains "${rollout_log}" "wait --for=condition=Ready pod"

skewed_manifest="$(${SCRIPT} render-skewed)"
assert_contains "${skewed_manifest}" "name: ack-skewed-1"
assert_contains "${skewed_manifest}" "name: ack-skewed-2"
assert_contains "${skewed_manifest}" "name: ack-skewed-3"
assert_contains "${skewed_manifest}" "replicas: 10"
assert_contains "${skewed_manifest}" "replicas: 6"
assert_contains "${skewed_manifest}" "replicas: 2"
assert_contains "${skewed_manifest}" "key: kubernetes.io/hostname"
assert_contains "${skewed_manifest}" "- ack-node-1"
assert_contains "${skewed_manifest}" "- ack-node-2"
assert_contains "${skewed_manifest}" "- ack-node-3"
assert_contains "${skewed_manifest}" "FIXED_MEMORY_MI=\"256\""
assert_contains "${skewed_manifest}" "FIXED_CPU_MILLICORES=\"2000\""
assert_contains "${skewed_manifest}" "stress --vm 1 --vm-bytes \"\${FIXED_MEMORY_MI}M\""
assert_contains "${skewed_manifest}" "schedulerName: default-scheduler"
assert_not_contains "${skewed_manifest}" "apiVersion: scheduling.volcano.sh"
assert_not_contains "${skewed_manifest}" "kind: Queue"
assert_not_contains "${skewed_manifest}" "scheduling.volcano.sh/queue-name"
assert_not_contains "${skewed_manifest}" "loadtest.volcano.sh"
assert_contains "${skewed_manifest}" "memory: 512Mi"
assert_contains "${skewed_manifest}" "cpu: 500m"
assert_not_contains "${skewed_manifest}" "workload.cce.io/swr-version"

custom_skewed_manifest="$(SKEWED_NODE_1=cn-shanghai.10.0.0.1 SKEWED_NODE_2=cn-shanghai.10.0.0.2 SKEWED_NODE_3=cn-shanghai.10.0.0.3 ${SCRIPT} render-skewed)"
assert_contains "${custom_skewed_manifest}" "- cn-shanghai.10.0.0.1"
assert_contains "${custom_skewed_manifest}" "- cn-shanghai.10.0.0.2"
assert_contains "${custom_skewed_manifest}" "- cn-shanghai.10.0.0.3"

best_effort_skewed_manifest="$(POD_QOS_CLASS=best-effort ${SCRIPT} render-skewed)"
assert_contains "${best_effort_skewed_manifest}" "name: ack-skewed-1"
assert_contains "${best_effort_skewed_manifest}" "FIXED_MEMORY_MI=\"256\""
assert_contains "${best_effort_skewed_manifest}" "FIXED_CPU_MILLICORES=\"2000\""
assert_contains "${best_effort_skewed_manifest}" "schedulerName: default-scheduler"
assert_not_contains "${best_effort_skewed_manifest}" "loadtest.volcano.sh"
assert_not_contains "${best_effort_skewed_manifest}" "        resources:"

[[ "${skewed_manifest}" != *"key: metadata.name"* ]] || fail "skewed node affinity should use kubernetes.io/hostname"
[[ "${skewed_manifest}" != *"LOAD_PROFILE"* ]] || fail "skewed deployments should not render ramp load profile env"

: > "${kubectl_log}"
KUBECTL_LOG="${kubectl_log}" KUBECTL="${fake_kubectl}" SLEEP_CMD="${fake_sleep}" WAIT_TIMEOUT=1s "${SCRIPT}" rollout-skewed --surge maxSurge=25% maxUnavailable=0 >/dev/null
skewed_rollout_log="$(cat "${kubectl_log}")"
assert_contains "${skewed_rollout_log}" "patch deployment ack-skewed-1"
assert_contains "${skewed_rollout_log}" "patch deployment ack-skewed-2"
assert_contains "${skewed_rollout_log}" "patch deployment ack-skewed-3"
assert_contains "${skewed_rollout_log}" '"maxSurge":"25%"'
assert_contains "${skewed_rollout_log}" '"affinity":null'
assert_contains "${skewed_rollout_log}" "rollout status deployment/ack-skewed-1"
assert_contains "${skewed_rollout_log}" "rollout status deployment/ack-skewed-2"
assert_contains "${skewed_rollout_log}" "rollout status deployment/ack-skewed-3"
assert_line_order "${skewed_rollout_log}" \
  "patch deployment ack-skewed-1 --type merge -p {\"spec\":{\"strategy\"" \
  "patch deployment ack-skewed-1 --type merge -p {\"spec\":{\"template\"" \
  "rollout status deployment/ack-skewed-1" \
  "sleep 45" \
  "patch deployment ack-skewed-2 --type merge -p {\"spec\":{\"strategy\"" \
  "patch deployment ack-skewed-2 --type merge -p {\"spec\":{\"template\"" \
  "rollout status deployment/ack-skewed-2" \
  "sleep 45" \
  "patch deployment ack-skewed-3 --type merge -p {\"spec\":{\"strategy\"" \
  "patch deployment ack-skewed-3 --type merge -p {\"spec\":{\"template\"" \
  "rollout status deployment/ack-skewed-3"

: > "${kubectl_log}"
KUBECTL_LOG="${kubectl_log}" KUBECTL="${fake_kubectl}" SLEEP_CMD="${fake_sleep}" WAIT_TIMEOUT=1s "${SCRIPT}" rollout-skewed --steady >/dev/null
skewed_steady_rollout_log="$(cat "${kubectl_log}")"
assert_contains "${skewed_steady_rollout_log}" "patch deployment ack-skewed-1"
assert_contains "${skewed_steady_rollout_log}" "patch deployment ack-skewed-2"
assert_contains "${skewed_steady_rollout_log}" "patch deployment ack-skewed-3"
assert_contains "${skewed_steady_rollout_log}" '"maxSurge":0'
assert_contains "${skewed_steady_rollout_log}" '"maxUnavailable":1'
assert_contains "${skewed_steady_rollout_log}" '"affinity":null'
assert_contains "${skewed_steady_rollout_log}" "rollout status deployment/ack-skewed-1"
assert_contains "${skewed_steady_rollout_log}" "rollout status deployment/ack-skewed-2"
assert_contains "${skewed_steady_rollout_log}" "rollout status deployment/ack-skewed-3"
assert_not_contains "${skewed_steady_rollout_log}" "wait --for=condition=Ready pod"
assert_line_order "${skewed_steady_rollout_log}" \
  "patch deployment ack-skewed-1 --type merge -p {\"spec\":{\"strategy\"" \
  "patch deployment ack-skewed-1 --type merge -p {\"spec\":{\"template\"" \
  "rollout status deployment/ack-skewed-1" \
  "sleep 45" \
  "patch deployment ack-skewed-2 --type merge -p {\"spec\":{\"strategy\"" \
  "patch deployment ack-skewed-2 --type merge -p {\"spec\":{\"template\"" \
  "rollout status deployment/ack-skewed-2" \
  "sleep 45" \
  "patch deployment ack-skewed-3 --type merge -p {\"spec\":{\"strategy\"" \
  "patch deployment ack-skewed-3 --type merge -p {\"spec\":{\"template\"" \
  "rollout status deployment/ack-skewed-3"

echo "PASS: ACK run-deployment-load.sh behavior"
