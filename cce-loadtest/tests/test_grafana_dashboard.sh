#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD="${ROOT_DIR}/dashboards/grafana-cce-loadtest.json"
dashboard="$(cat "${DASHBOARD}")"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" == *"${needle}"* ]] || fail "expected dashboard to contain: ${needle}"
}

ruby -e 'require "json"; JSON.parse(File.read(ARGV.fetch(0))); puts "JSON parse ok"' "${DASHBOARD}" >/dev/null

assert_contains "${dashboard}" "\"name\": \"node\""
assert_contains "${dashboard}" "label_values(node_memory_MemTotal_bytes, instance)"
assert_contains "${dashboard}" "\"title\": \"Node CPU usage - \$node\""
assert_contains "${dashboard}" "\"title\": \"Node memory usage - \$node\""
assert_contains "${dashboard}" "\"repeat\": \"node\""
assert_contains "${dashboard}" "node_cpu_seconds_total{mode=\\\"idle\\\",instance=~\\\"\$node\\\"}"
assert_contains "${dashboard}" "node_memory_MemAvailable_bytes{instance=~\\\"\$node\\\"}"
assert_contains "${dashboard}" "\"title\": \"Load-test memory usage\""
assert_contains "${dashboard}" "container_memory_working_set_bytes"
assert_contains "${dashboard}" "\"unit\": \"bytes\""
assert_contains "${dashboard}" "\"title\": \"Peak CPU waterline, last 30m\""
assert_contains "${dashboard}" "max_over_time((100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\\\"idle\\\"}[1m]))))[30m:30s])"

echo "PASS: grafana dashboard panels"
