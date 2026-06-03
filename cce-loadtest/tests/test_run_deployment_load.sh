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
assert_contains "${manifest}" "JAVA_PEAK_MEMORY_MI=\"580\""
assert_contains "${manifest}" "JAVA_PEAK_CPU_MILLICORES=\"240\""
assert_contains "${manifest}" "JAVA_PEAK_HOLD_SECONDS=\"5\""
assert_contains "${manifest}" "JAVA_DROP_SECONDS=\"10\""
assert_contains "${manifest}" "JAVA_STEADY_MEMORY_MI=\"500\""
assert_contains "${manifest}" "JAVA_STEADY_CPU_MILLICORES=\"200\""
assert_contains "${manifest}" "run_linear_profile()"
assert_contains "${manifest}" "run_java_spike_profile()"
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
assert_contains "${queries}" "container_memory_working_set_bytes"
assert_contains "${queries}" "container_cpu_usage_seconds_total"
assert_contains "${queries}" "stddev"
assert_contains "${queries}" "max_over_time"
assert_contains "${queries}" "threshold=80%"
assert_contains "${queries}" "> bool 80"

override_manifest="$(REPLICAS=58 ${SCRIPT} render)"
assert_contains "${override_manifest}" "replicas: 58"

surge_manifest="$(ROLLING_MAX_SURGE=25% ROLLING_MAX_UNAVAILABLE=0 ${SCRIPT} render)"
assert_contains "${surge_manifest}" "maxSurge: 25%"
assert_contains "${surge_manifest}" "maxUnavailable: 0"

java_manifest="$(LOAD_PROFILE=java-spike JAVA_PEAK_MEMORY_MI=590 JAVA_PEAK_CPU_MILLICORES=245 ${SCRIPT} render)"
assert_contains "${java_manifest}" "LOAD_PROFILE=\"java-spike\""
assert_contains "${java_manifest}" "JAVA_PEAK_MEMORY_MI=\"590\""
assert_contains "${java_manifest}" "JAVA_PEAK_CPU_MILLICORES=\"245\""

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

echo "PASS: run-deployment-load.sh behavior"
