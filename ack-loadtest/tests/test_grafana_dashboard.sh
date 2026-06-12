#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD="${ROOT_DIR}/dashboards/grafana-ack-loadtest.json"
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
ruby -e '
  require "json"
  dashboard = JSON.parse(File.read(ARGV.fetch(0)))
  expected_titles = [
    "Scheduled ACK pods per node",
    "Per-node hotspot probability, last 1m",
    "Per-node idle probability, last 1m",
    "Peak CPU waterline, last 1m",
    "Peak memory waterline, last 1m",
    "Per-node CPU waterline, 1m avg",
    "Per-node memory waterline, 1m avg",
    "CPU waterline variance across nodes, 1m avg",
    "Memory waterline variance across nodes, 1m avg"
  ]
  actual_titles = dashboard.fetch("panels").map { |panel| panel.fetch("title") }
  abort("expected exactly 9 dashboard panels") unless actual_titles.length == 9
  abort("unexpected panel titles: #{actual_titles.inspect}") unless actual_titles == expected_titles
  expected_grid = [
    { "x" => 0, "y" => 0, "w" => 8, "h" => 8 },
    { "x" => 8, "y" => 0, "w" => 8, "h" => 8 },
    { "x" => 16, "y" => 0, "w" => 8, "h" => 8 },
    { "x" => 0, "y" => 8, "w" => 8, "h" => 8 },
    { "x" => 8, "y" => 8, "w" => 8, "h" => 8 },
    { "x" => 16, "y" => 8, "w" => 8, "h" => 8 },
    { "x" => 0, "y" => 16, "w" => 8, "h" => 8 },
    { "x" => 8, "y" => 16, "w" => 8, "h" => 8 },
    { "x" => 16, "y" => 16, "w" => 8, "h" => 8 }
  ]
  actual_grid = dashboard.fetch("panels").map { |panel| panel.fetch("gridPos") }
  abort("dashboard panels should be arranged as a 3x3 grid: #{actual_grid.inspect}") unless actual_grid == expected_grid

  variable_names = dashboard.fetch("templating").fetch("list").map { |variable| variable.fetch("name") }
  abort("unexpected variables: #{variable_names.inspect}") unless variable_names == ["datasource", "node"]
  abort("unexpected dashboard title") unless dashboard.fetch("title") == "ACK Load Test"
  abort("unexpected dashboard uid") unless dashboard.fetch("uid") == "ack-loadtest"

  scheduled_panel = dashboard.fetch("panels").fetch(0)
  scheduled_calcs = scheduled_panel.fetch("options").fetch("legend").fetch("calcs")
  abort("scheduled pod panel should only show current lastNotNull value: #{scheduled_calcs.inspect}") unless scheduled_calcs == ["lastNotNull"]
' "${DASHBOARD}"

assert_contains "${dashboard}" "\"name\": \"node\""
assert_contains "${dashboard}" "label_values(node_memory_MemTotal_bytes, instance)"
assert_contains "${dashboard}" "\"title\": \"Scheduled ACK pods per node\""
assert_contains "${dashboard}" "kube_pod_info{namespace=\\\"default\\\",pod=~\\\"ack-resource-consumer-.*\\\",node!=\\\"\\\"}"
assert_contains "${dashboard}" "\"title\": \"Per-node hotspot probability, last 1m\""
assert_contains "${dashboard}" "> bool 80"
assert_contains "${dashboard}" "[1m:15s]"
assert_contains "${dashboard}" "\"title\": \"Per-node idle probability, last 1m\""
assert_contains "${dashboard}" "< bool 30"
assert_contains "${dashboard}" "\"title\": \"Peak CPU waterline, last 1m\""
assert_contains "${dashboard}" "max_over_time((100 * (1 - avg by (instance) (irate(node_cpu_seconds_total{mode=\\\"idle\\\",instance=~\\\"\$node\\\"}[1m]))))[1m:15s])"
assert_contains "${dashboard}" "\"title\": \"Peak memory waterline, last 1m\""
assert_contains "${dashboard}" "max_over_time((100 * (1 - node_memory_MemAvailable_bytes{instance=~\\\"\$node\\\"} / node_memory_MemTotal_bytes{instance=~\\\"\$node\\\"}))[1m:15s])"
assert_contains "${dashboard}" "\"title\": \"Per-node CPU waterline, 1m avg\""
assert_contains "${dashboard}" "node_cpu_seconds_total{mode=\\\"idle\\\",instance=~\\\"\$node\\\"}"
assert_contains "${dashboard}" "\"title\": \"Per-node memory waterline, 1m avg\""
assert_contains "${dashboard}" "node_memory_MemAvailable_bytes{instance=~\\\"\$node\\\"}"
assert_contains "${dashboard}" "\"title\": \"CPU waterline variance across nodes, 1m avg\""
assert_contains "${dashboard}" "stdvar(100 * avg_over_time((1 - avg by (instance) (irate(node_cpu_seconds_total{mode=\\\"idle\\\",instance=~\\\"\$node\\\"}[1m])))[1m:15s]))"
assert_contains "${dashboard}" "\"title\": \"Memory waterline variance across nodes, 1m avg\""
assert_contains "${dashboard}" "stdvar(100 * avg_over_time((1 - node_memory_MemAvailable_bytes{instance=~\\\"\$node\\\"} / node_memory_MemTotal_bytes{instance=~\\\"\$node\\\"})[1m:15s]))"

if [[ "${dashboard}" == *"[10m:30s]"* || "${dashboard}" == *"[5m]"* || "${dashboard}" == *":30s]"* || "${dashboard}" =~ (^|[^i])rate\(node_cpu_seconds_total || "${dashboard}" == *"30m"* ]]; then
  fail "expected all dashboard statistical windows to use adapter-aligned 1m:15s windows"
fi

for removed in \
  "Scheduled CCE pods per node" \
  "CCE Volcano Load Test" \
  "cce-volcano-loadtest" \
  "ACK Volcano Load Test" \
  "ack-volcano-loadtest" \
  "volcano" \
  "Load-test memory usage" \
  "Load-test CPU cores" \
  "Load-test memory waterline" \
  "Peak CPU / memory waterline" \
  "Cluster hotspot probability" \
  "Cluster idle-node probability" \
  "Memory waterline skew" \
  "Node CPU usage - \$node" \
  "Node memory usage - \$node" \
  "container_memory_working_set_bytes" \
  "container_cpu_usage_seconds_total" \
  "pod=~\\\".*ack.*\\\"" \
  "\$deployment" \
  "\$container" \
  "\$threshold"; do
  if [[ "${dashboard}" == *"${removed}"* ]]; then
    fail "dashboard should not contain removed item: ${removed}"
  fi
done

if [[ "${dashboard}" == *"\"repeat\": \"node\""* ]]; then
  fail "dashboard should use per-node series panels instead of repeated single-node panels"
fi

echo "PASS: ACK grafana dashboard panels"
