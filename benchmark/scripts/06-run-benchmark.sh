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

# Script to run the Volcano benchmark test

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Functions
# =============================================================================

create_vcjobs() {
    log_info "Creating ${NUM_JOBS} VCJobs with ${PODS_PER_JOB} pods each..."
    
    local template="${MANIFESTS_DIR}/workloads/vcjob-template.yaml"
    
    for i in $(seq 0 $((NUM_JOBS - 1))); do
        local job_name="benchmark-job-${i}"
        log_debug "Creating VCJob: ${job_name}"
        
        # Replace INDEX placeholder with actual index
        sed "s/INDEX/${i}/g" "${template}" | kubectl apply -f -
    done
    
    log_info "All ${NUM_JOBS} VCJobs created"
}

wait_for_all_pods_scheduled() {
    log_info "Waiting for all ${TOTAL_PODS} pods to be scheduled..."
    
    local timeout=300
    local start_time=$(date +%s)
    local last_count=0
    
    while true; do
        local scheduled_count=$(kubectl get pods -n "${NAMESPACE}" \
            -o jsonpath='{.items[*].status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null | \
            tr ' ' '\n' | grep -c "True" || echo "0")
        
        if [[ "$scheduled_count" -ge "$TOTAL_PODS" ]]; then
            log_info "All ${TOTAL_PODS} pods have been scheduled!"
            return 0
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout reached. ${scheduled_count}/${TOTAL_PODS} pods scheduled."
            return 1
        fi
        
        # Only log if count changed
        if [[ "$scheduled_count" -ne "$last_count" ]]; then
            log_info "Progress: ${scheduled_count}/${TOTAL_PODS} pods scheduled (${elapsed}s elapsed)"
            last_count=$scheduled_count
        fi
        
        sleep 1
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Running Volcano Benchmark"
    log_info "Test configuration:"
    log_info "  - Number of Jobs: ${NUM_JOBS}"
    log_info "  - Pods per Job: ${PODS_PER_JOB}"
    log_info "  - Total Pods: ${TOTAL_PODS}"
    log_info "  - Gang Scheduling: enabled (minAvailable=${PODS_PER_JOB})"
    
    # Create benchmark namespace
    log_info "Creating benchmark namespace..."
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    # Record test start time
    local test_start_time=$(date +%s)
    local test_start_time_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_info "Test started at: ${test_start_time_iso}"
    
    # Create VCJobs
    create_vcjobs
    
    # Wait for all pods to be scheduled
    wait_for_all_pods_scheduled
    local schedule_result=$?
    
    # Record test end time
    local test_end_time=$(date +%s)
    local test_end_time_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local test_duration=$((test_end_time - test_start_time))
    
    log_info "Test ended at: ${test_end_time_iso}"
    log_info "Total test duration: ${test_duration} seconds"
    
    # Calculate throughput
    local throughput=$(echo "scale=2; ${TOTAL_PODS} / ${test_duration}" | bc)
    log_info "Scheduling throughput: ${throughput} pods/second"
    
    # Save test metadata
    local result_file="${RESULTS_DIR}/benchmark-$(date +%Y%m%d-%H%M%S).json"
    cat > "${result_file}" <<EOF
{
  "test_config": {
    "num_jobs": ${NUM_JOBS},
    "pods_per_job": ${PODS_PER_JOB},
    "total_pods": ${TOTAL_PODS},
    "gang_scheduling": true,
    "min_available": ${PODS_PER_JOB}
  },
  "test_results": {
    "start_time": "${test_start_time_iso}",
    "end_time": "${test_end_time_iso}",
    "duration_seconds": ${test_duration},
    "throughput_pods_per_second": ${throughput},
    "success": $([[ $schedule_result -eq 0 ]] && echo "true" || echo "false")
  },
  "environment": {
    "volcano_version": "${VOLCANO_VERSION}",
    "num_fake_nodes": ${NUM_FAKE_NODES},
    "cluster_name": "${CLUSTER_NAME}"
  }
}
EOF
    
    log_info "Test results saved to: ${result_file}"
    
    # Display summary
    log_info ""
    log_info "=========================================="
    log_info "Benchmark Summary"
    log_info "=========================================="
    log_info "Total Pods:     ${TOTAL_PODS}"
    log_info "Duration:       ${test_duration} seconds"
    log_info "Throughput:     ${throughput} pods/second"
    log_info ""
    log_info "View real-time metrics:"
    log_info "  Prometheus: ${PROMETHEUS_URL}"
    log_info "  Grafana:    ${GRAFANA_URL}"
    log_info "=========================================="
    
    if [[ $schedule_result -eq 0 ]]; then
        log_info "Benchmark completed successfully!"
    else
        log_warn "Benchmark completed with warnings (not all pods scheduled)"
    fi
}

main "$@"
