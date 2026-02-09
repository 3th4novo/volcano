#!/bin/bash
# Copyright 2026 The Volcano Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Script to collect benchmark results from Prometheus

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Functions
# =============================================================================

query_prometheus() {
    local query="$1"
    local result=$(curl -s "${PROMETHEUS_URL}/api/v1/query" \
        --data-urlencode "query=${query}" | jq -r '.data.result[0].value[1] // "N/A"')
    echo "$result"
}

query_prometheus_range() {
    local query="$1"
    local start="$2"
    local end="$3"
    local step="${4:-1s}"
    
    curl -s "${PROMETHEUS_URL}/api/v1/query_range" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${start}" \
        --data-urlencode "end=${end}" \
        --data-urlencode "step=${step}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Collecting benchmark results from Prometheus"
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local output_dir="${RESULTS_DIR}/${timestamp}"
    mkdir -p "${output_dir}"
    
    # Query current metrics
    log_info "Querying current metrics..."
    
    # Pod counts
    local created_pods=$(query_prometheus 'count(kube_pod_created{namespace="benchmark"})')
    local scheduled_pods=$(query_prometheus 'count(kube_pod_status_scheduled{namespace="benchmark", condition="true"})')
    local running_pods=$(query_prometheus 'count(kube_pod_status_phase{namespace="benchmark", phase="Running"})')
    local pending_pods=$(query_prometheus 'count(kube_pod_status_phase{namespace="benchmark", phase="Pending"})')
    
    # Scheduling latency
    local avg_latency=$(query_prometheus 'histogram_quantile(0.5, rate(volcano_e2e_scheduling_latency_milliseconds_bucket[5m]))')
    local p99_latency=$(query_prometheus 'histogram_quantile(0.99, rate(volcano_e2e_scheduling_latency_milliseconds_bucket[5m]))')
    
    # Job scheduling duration
    local avg_job_duration=$(query_prometheus 'avg(volcano_e2e_job_scheduling_duration{job_namespace="benchmark"})')
    local max_job_duration=$(query_prometheus 'max(volcano_e2e_job_scheduling_duration{job_namespace="benchmark"})')
    
    # Save summary
    local summary_file="${output_dir}/summary.json"
    cat > "${summary_file}" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pod_counts": {
    "created": ${created_pods:-0},
    "scheduled": ${scheduled_pods:-0},
    "running": ${running_pods:-0},
    "pending": ${pending_pods:-0}
  },
  "scheduling_latency_ms": {
    "p50": ${avg_latency:-0},
    "p99": ${p99_latency:-0}
  },
  "job_scheduling_duration_s": {
    "avg": ${avg_job_duration:-0},
    "max": ${max_job_duration:-0}
  }
}
EOF
    
    log_info "Summary saved to: ${summary_file}"
    
    # Export time series data for the last 10 minutes
    log_info "Exporting time series data..."
    
    local end_time=$(date +%s)
    local start_time=$((end_time - 600))
    
    # Export pod status over time
    query_prometheus_range \
        'count(kube_pod_created{namespace="benchmark"})' \
        "${start_time}" "${end_time}" "1s" \
        > "${output_dir}/created_pods_timeseries.json"
    
    query_prometheus_range \
        'count(kube_pod_status_scheduled{namespace="benchmark", condition="true"})' \
        "${start_time}" "${end_time}" "1s" \
        > "${output_dir}/scheduled_pods_timeseries.json"
    
    query_prometheus_range \
        'count(kube_pod_status_phase{namespace="benchmark", phase="Running"})' \
        "${start_time}" "${end_time}" "1s" \
        > "${output_dir}/running_pods_timeseries.json"
    
    # Export scheduling latency histogram
    query_prometheus_range \
        'volcano_e2e_scheduling_latency_milliseconds_bucket' \
        "${start_time}" "${end_time}" "5s" \
        > "${output_dir}/scheduling_latency_histogram.json"
    
    # Export job scheduling duration
    query_prometheus_range \
        'volcano_e2e_job_scheduling_duration{job_namespace="benchmark"}' \
        "${start_time}" "${end_time}" "1s" \
        > "${output_dir}/job_scheduling_duration.json"
    
    log_info "Time series data exported to: ${output_dir}/"
    
    # Generate text report
    local report_file="${output_dir}/report.txt"
    cat > "${report_file}" <<EOF
================================================================================
Volcano Benchmark Results
Generated: $(date)
================================================================================

Test Configuration:
  - Number of Jobs: ${NUM_JOBS}
  - Pods per Job: ${PODS_PER_JOB}
  - Total Pods: ${TOTAL_PODS}
  - Gang Scheduling: enabled (minAvailable=${PODS_PER_JOB})

Pod Status:
  - Created:   ${created_pods:-N/A}
  - Scheduled: ${scheduled_pods:-N/A}
  - Running:   ${running_pods:-N/A}
  - Pending:   ${pending_pods:-N/A}

Scheduling Latency (milliseconds):
  - P50: ${avg_latency:-N/A}
  - P99: ${p99_latency:-N/A}

Job Scheduling Duration (seconds):
  - Average: ${avg_job_duration:-N/A}
  - Maximum: ${max_job_duration:-N/A}

================================================================================
Access Monitoring:
  - Prometheus: ${PROMETHEUS_URL}
  - Grafana:    ${GRAFANA_URL}
================================================================================
EOF
    
    log_info "Report saved to: ${report_file}"
    
    # Display report
    cat "${report_file}"
    
    log_info "Results collection completed!"
}

main "$@"
