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

# Script to cleanup benchmark environment

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Cleaning up benchmark environment"
    
    # Parse arguments
    local delete_cluster=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --delete-cluster)
                delete_cluster=true
                shift
                ;;
            *)
                log_warn "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    # Delete benchmark namespace and all resources
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_info "Deleting benchmark namespace '${NAMESPACE}'..."
        kubectl delete namespace "${NAMESPACE}" --wait=false
        
        # Wait for namespace deletion
        log_info "Waiting for namespace deletion..."
        local timeout=120
        local start_time=$(date +%s)
        while kubectl get namespace "${NAMESPACE}" &>/dev/null; do
            local elapsed=$(($(date +%s) - start_time))
            if [[ $elapsed -ge $timeout ]]; then
                log_warn "Timeout waiting for namespace deletion"
                break
            fi
            sleep 2
        done
    else
        log_info "Benchmark namespace '${NAMESPACE}' does not exist"
    fi
    
    # Optionally delete the Kind cluster
    if [[ "$delete_cluster" == "true" ]]; then
        log_info "Deleting Kind cluster '${CLUSTER_NAME}'..."
        kind delete cluster --name "${CLUSTER_NAME}" || true
        log_info "Kind cluster deleted"
    else
        log_info "Kind cluster '${CLUSTER_NAME}' preserved"
        log_info "To delete the cluster, run: $0 --delete-cluster"
    fi
    
    log_info "Cleanup completed!"
}

main "$@"
