#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/run-deployment-load.sh"

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

manifest="$(${SCRIPT} render)"

[[ "${manifest}" != *"kind: Namespace"* ]] || fail "default render should not create or manage the default namespace"
assert_contains "${manifest}" "kind: Deployment"
assert_contains "${manifest}" "name: cce-resource-consumer"
assert_contains "${manifest}" "namespace: default"
assert_contains "${manifest}" "workload.cce.io/swr-version: '[{\"version\":\"Shared Edition\"}]'"
assert_contains "${manifest}" "image: swr.cn-north-7.myhuaweicloud.com/paas_cce_wwx588067/resource_consumer:latest"
assert_contains "${manifest}" "imagePullSecrets:"
assert_contains "${manifest}" "- name: default-secret"
assert_contains "${manifest}" "replicas: 10"
assert_contains "${manifest}" "schedulerName: volcano"
assert_contains "${manifest}" "scheduling.volcano.sh/queue-name: cce-loadtest"
assert_contains "${manifest}" "memory: \"56Gi\""
assert_contains "${manifest}" "memory: 500Mi"
assert_contains "${manifest}" "memory: 600Mi"
assert_contains "${manifest}" "cpu: 200m"
assert_contains "${manifest}" "cpu: 250m"
assert_contains "${manifest}" "maxSurge: 0"
assert_contains "${manifest}" "maxUnavailable: 5"
assert_contains "${manifest}" "TARGET_MEMORY_MI=\"500\""
assert_contains "${manifest}" "MEMORY_STEP_MI=\"25\""
assert_contains "${manifest}" "TARGET_CPU_MILLICORES=\"200\""
assert_contains "${manifest}" "CPU_STEP_MILLICORES=\"10\""
assert_contains "${manifest}" "LOAD_PROFILE=\"linear\""
assert_contains "${manifest}" "REQUEST_FIXED_MEMORY_MI=\"500\""
assert_contains "${manifest}" "REQUEST_FIXED_CPU_MILLICORES=\"200\""
assert_contains "${manifest}" "JAVA_PEAK_MEMORY_MI=\"580\""
assert_contains "${manifest}" "JAVA_PEAK_CPU_MILLICORES=\"240\""
assert_contains "${manifest}" "JAVA_PEAK_HOLD_SECONDS=\"5\""
assert_contains "${manifest}" "JAVA_DROP_SECONDS=\"10\""
assert_contains "${manifest}" "JAVA_STEADY_MEMORY_MI=\"500\""
assert_contains "${manifest}" "JAVA_STEADY_CPU_MILLICORES=\"200\""
assert_contains "${manifest}" "run_linear_profile()"
assert_contains "${manifest}" "run_java_spike_profile()"
assert_contains "${manifest}" "run_request_fixed_profile()"
assert_contains "${manifest}" "request-fixed)"
assert_contains "${manifest}" "unsupported LOAD_PROFILE="

[[ "${manifest}" != *"stress-ng"* ]] || fail "manifest should not use stress-ng"
[[ "${manifest}" != *"nodeSelector:"* ]] || fail "manifest should not render nodeSelector"
[[ "${manifest}" != *"topologySpreadConstraints:"* ]] || fail "manifest should not render topologySpreadConstraints"

adapter_commands="$(${SCRIPT} check-adapter --print-only)"
assert_contains "${adapter_commands}" "node_cpu_usage_avg"
assert_contains "${adapter_commands}" "node_memory_usage_avg"
assert_contains "${adapter_commands}" "kubectl get --raw"

queries="$(${SCRIPT} promql)"
assert_contains "${queries}" "namespace=\"default\""
assert_contains "${queries}" "pod=~\".*cce.*\""
assert_contains "${queries}" "kube_pod_info"
assert_contains "${queries}" "node_cpu_seconds_total"
assert_contains "${queries}" "node_memory_MemAvailable_bytes"
assert_contains "${queries}" "stdvar"
assert_contains "${queries}" "max_over_time"
assert_contains "${queries}" "[5m:30s]"
assert_contains "${queries}" "> bool 80"
assert_contains "${queries}" "< bool 30"
[[ "${queries}" != *"container_memory_working_set_bytes"* ]] || fail "promql output should not include container memory metrics"
[[ "${queries}" != *"container_cpu_usage_seconds_total"* ]] || fail "promql output should not include container CPU metrics"
[[ "${queries}" != *"30m"* ]] || fail "promql output should use 5m windows, not 30m"
[[ "${queries}" != *"10m"* ]] || fail "promql output should use 5m windows, not 10m"

override_manifest="$(REPLICAS=58 ${SCRIPT} render)"
assert_contains "${override_manifest}" "replicas: 58"

surge_manifest="$(ROLLING_MAX_SURGE=25% ROLLING_MAX_UNAVAILABLE=0 ${SCRIPT} render)"
assert_contains "${surge_manifest}" "maxSurge: 25%"
assert_contains "${surge_manifest}" "maxUnavailable: 0"

java_manifest="$(LOAD_PROFILE=java-spike JAVA_PEAK_MEMORY_MI=590 JAVA_PEAK_CPU_MILLICORES=245 ${SCRIPT} render)"
assert_contains "${java_manifest}" "LOAD_PROFILE=\"java-spike\""
assert_contains "${java_manifest}" "JAVA_PEAK_MEMORY_MI=\"590\""
assert_contains "${java_manifest}" "JAVA_PEAK_CPU_MILLICORES=\"245\""

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

tmpdir="$(mktemp -d)"
fake_kubectl="${tmpdir}/kubectl"
kubectl_log="${tmpdir}/kubectl.log"
cat > "${fake_kubectl}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KUBECTL_LOG}"
EOF
chmod +x "${fake_kubectl}"

KUBECTL_LOG="${kubectl_log}" KUBECTL="${fake_kubectl}" WAIT_TIMEOUT=1s "${SCRIPT}" rollout --surge maxSurge=25% maxUnavailable=0
rollout_log="$(cat "${kubectl_log}")"
assert_contains "${rollout_log}" '"maxSurge":"25%"'
assert_contains "${rollout_log}" '"maxUnavailable":0'
assert_contains "${rollout_log}" "rollout status deployment/cce-resource-consumer"
assert_not_contains "${rollout_log}" "wait --for=condition=Ready pod"

skewed_manifest="$(${SCRIPT} render-skewed)"
assert_contains "${skewed_manifest}" "name: cce-skewed-1"
assert_contains "${skewed_manifest}" "name: cce-skewed-2"
assert_contains "${skewed_manifest}" "name: cce-skewed-3"
assert_contains "${skewed_manifest}" "replicas: 10"
assert_contains "${skewed_manifest}" "replicas: 6"
assert_contains "${skewed_manifest}" "replicas: 2"
assert_contains "${skewed_manifest}" "key: kubernetes.io/hostname"
assert_contains "${skewed_manifest}" "- 192.168.9.134"
assert_contains "${skewed_manifest}" "- 192.168.9.133"
assert_contains "${skewed_manifest}" "- 192.168.9.182"
assert_contains "${skewed_manifest}" "FIXED_MEMORY_MI=\"500\""
assert_contains "${skewed_manifest}" "FIXED_CPU_MILLICORES=\"200\""
assert_contains "${skewed_manifest}" "stress --vm 1 --vm-bytes \"\${FIXED_MEMORY_MI}M\""
assert_contains "${skewed_manifest}" "schedulerName: volcano"
assert_contains "${skewed_manifest}" "scheduling.volcano.sh/queue-name: cce-loadtest"
assert_contains "${skewed_manifest}" "memory: 500Mi"
assert_contains "${skewed_manifest}" "cpu: 200m"

[[ "${skewed_manifest}" != *"key: metadata.name"* ]] || fail "skewed node affinity should use kubernetes.io/hostname"
[[ "${skewed_manifest}" != *"LOAD_PROFILE"* ]] || fail "skewed deployments should not render ramp load profile env"

: > "${kubectl_log}"
KUBECTL_LOG="${kubectl_log}" KUBECTL="${fake_kubectl}" WAIT_TIMEOUT=1s "${SCRIPT}" rollout-skewed --surge maxSurge=25% maxUnavailable=0
skewed_rollout_log="$(cat "${kubectl_log}")"
assert_contains "${skewed_rollout_log}" "patch deployment cce-skewed-1"
assert_contains "${skewed_rollout_log}" "patch deployment cce-skewed-2"
assert_contains "${skewed_rollout_log}" "patch deployment cce-skewed-3"
assert_contains "${skewed_rollout_log}" '"maxSurge":"25%"'
assert_contains "${skewed_rollout_log}" '"affinity":null'
assert_contains "${skewed_rollout_log}" "rollout status deployment/cce-skewed-1"
assert_contains "${skewed_rollout_log}" "rollout status deployment/cce-skewed-2"
assert_contains "${skewed_rollout_log}" "rollout status deployment/cce-skewed-3"

echo "PASS: run-deployment-load.sh behavior"
