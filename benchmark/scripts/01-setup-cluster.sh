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

# Script to create Kind cluster for Volcano Benchmark

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Setting up Kind cluster for Volcano Benchmark"
    
    # Check dependencies
    check_dependencies
    
    # Delete existing cluster if it exists
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_warn "Cluster '${CLUSTER_NAME}' already exists. Deleting..."
        kind delete cluster --name "${CLUSTER_NAME}"
    fi
    
    # Create cluster
    log_info "Creating Kind cluster '${CLUSTER_NAME}'..."
    kind create cluster \
        --name "${CLUSTER_NAME}" \
        --config "${CONFIG_DIR}/kind-config.yaml" \
        --wait 120s
    
    # Verify cluster is ready
    log_info "Verifying cluster is ready..."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    
    # Wait for all system pods to be ready
    log_info "Waiting for system pods to be ready..."
    kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=120s
    
    # Create results directory
    mkdir -p "${RESULTS_DIR}"
    
    log_info "Kind cluster '${CLUSTER_NAME}' is ready!"
    log_info "Kubectl context: kind-${CLUSTER_NAME}"
}

main "$@"
