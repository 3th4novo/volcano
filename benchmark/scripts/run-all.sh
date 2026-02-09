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

# One-click script to run the complete Volcano benchmark

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Main
# =============================================================================

main() {
    local start_time=$(date +%s)
    
    local version_display="${VOLCANO_VERSION}"
    if [[ "${USE_LOCAL_IMAGES}" == "true" ]]; then
        version_display="local (${LOCAL_IMAGE_TAG})"
    fi
    
    log_step "Starting Volcano Benchmark Suite"
    log_info "Configuration:"
    log_info "  - Cluster Name: ${CLUSTER_NAME}"
    log_info "  - Volcano Version: ${version_display}"
    log_info "  - Use Local Images: ${USE_LOCAL_IMAGES}"
    log_info "  - Test Scale: ${NUM_JOBS} jobs x ${PODS_PER_JOB} pods = ${TOTAL_PODS} total pods"
    log_info "  - Fake Nodes: ${NUM_FAKE_NODES}"
    log_info ""
    
    # Step 1: Setup Kind cluster
    log_step "Step 1/7: Setting up Kind cluster"
    "${SCRIPT_DIR}/01-setup-cluster.sh"
    
    # Step 2: Build Volcano images (if using local images)
    if [[ "${USE_LOCAL_IMAGES}" == "true" ]]; then
        log_step "Step 2/7: Building Volcano images from source"
        "${SCRIPT_DIR}/02-build-images.sh"
    else
        log_step "Step 2/7: Skipping image build (using official images)"
    fi
    
    # Step 3: Install Volcano
    log_step "Step 3/7: Installing Volcano"
    "${SCRIPT_DIR}/03-install-volcano.sh"
    
    # Step 4: Setup KWOK
    log_step "Step 4/7: Setting up KWOK and fake nodes"
    "${SCRIPT_DIR}/04-setup-kwok.sh"
    
    # Step 5: Setup monitoring
    log_step "Step 5/7: Setting up monitoring stack"
    "${SCRIPT_DIR}/05-setup-monitoring.sh"
    
    # Wait a bit for monitoring to stabilize
    log_info "Waiting for monitoring to stabilize..."
    sleep 10
    
    # Step 6: Run benchmark
    log_step "Step 6/7: Running benchmark"
    "${SCRIPT_DIR}/06-run-benchmark.sh"
    
    # Step 7: Collect results
    log_step "Step 7/7: Collecting results"
    "${SCRIPT_DIR}/07-collect-results.sh"
    
    # Calculate total time
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    log_info ""
    log_info "=========================================="
    log_info "Volcano Benchmark Suite Completed!"
    log_info "=========================================="
    log_info "Total execution time: ${total_time} seconds"
    log_info ""
    log_info "Access monitoring dashboards:"
    log_info "  Prometheus: ${PROMETHEUS_URL}"
    log_info "  Grafana:    ${GRAFANA_URL} (admin/admin)"
    log_info ""
    log_info "Results saved to: ${RESULTS_DIR}/"
    log_info ""
    log_info "To cleanup, run:"
    log_info "  ${SCRIPT_DIR}/99-cleanup.sh              # Keep cluster"
    log_info "  ${SCRIPT_DIR}/99-cleanup.sh --delete-cluster  # Delete cluster"
    log_info "=========================================="
}

main "$@"
