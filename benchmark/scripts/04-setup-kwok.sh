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

# Script to setup KWOK and fake nodes for Benchmark

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Setting up KWOK and fake nodes"
    
    # Install KWOK CRDs first
    log_info "Installing KWOK CRDs..."
    kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
    
    # Wait for CRDs to be established
    log_info "Waiting for KWOK CRDs to be ready..."
    kubectl wait --for=condition=Established crd/stages.kwok.x-k8s.io --timeout=60s || true
    
    # Deploy KWOK controller and stages
    log_info "Deploying KWOK controller..."
    kubectl apply -f "${MANIFESTS_DIR}/kwok/kwok-deployment.yaml"
    
    # Wait for KWOK controller to be ready
    log_info "Waiting for KWOK controller to be ready..."
    kubectl wait --for=condition=available deployment/kwok-controller \
        -n kube-system --timeout=120s
    
    # Create fake nodes
    log_info "Creating ${NUM_FAKE_NODES} fake nodes..."
    kubectl apply -f "${MANIFESTS_DIR}/kwok/fake-nodes.yaml"
    
    # Wait for nodes to be ready
    log_info "Waiting for fake nodes to be ready..."
    local timeout=60
    local start_time=$(date +%s)
    
    while true; do
        local ready_nodes=$(kubectl get nodes -l type=kwok --no-headers 2>/dev/null | \
            grep -c " Ready" || echo "0")
        
        if [[ "$ready_nodes" -ge "$NUM_FAKE_NODES" ]]; then
            log_info "All ${NUM_FAKE_NODES} fake nodes are ready"
            break
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for fake nodes"
            exit 1
        fi
        
        log_debug "Waiting for fake nodes... ($ready_nodes/${NUM_FAKE_NODES} ready)"
        sleep 2
    done
    
    # Display node status
    log_info "Fake nodes status:"
    kubectl get nodes -l type=kwok
    
    log_info "KWOK setup completed successfully!"
}

main "$@"
