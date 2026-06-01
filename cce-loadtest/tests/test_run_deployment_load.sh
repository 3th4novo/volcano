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

assert_contains "${manifest}" "kind: Deployment"
assert_contains "${manifest}" "name: cce-resource-consumer"
assert_contains "${manifest}" "replicas: 58"
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

[[ "${manifest}" != *"stress-ng"* ]] || fail "manifest should not use stress-ng"
[[ "${manifest}" != *"nodeSelector:"* ]] || fail "manifest should not render nodeSelector"
[[ "${manifest}" != *"topologySpreadConstraints:"* ]] || fail "manifest should not render topologySpreadConstraints"

adapter_commands="$(${SCRIPT} check-adapter --print-only)"
assert_contains "${adapter_commands}" "node_cpu_usage_avg"
assert_contains "${adapter_commands}" "node_memory_usage_avg"
assert_contains "${adapter_commands}" "kubectl get --raw"

queries="$(${SCRIPT} promql)"
assert_contains "${queries}" "container_memory_working_set_bytes"
assert_contains "${queries}" "container_cpu_usage_seconds_total"
assert_contains "${queries}" "stddev"
assert_contains "${queries}" "max_over_time"
assert_contains "${queries}" "threshold=80%"
assert_contains "${queries}" "> bool 80"

echo "PASS: run-deployment-load.sh behavior"
