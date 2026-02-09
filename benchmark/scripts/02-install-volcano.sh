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

# Script to install Volcano for Benchmark

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Installing Volcano ${VOLCANO_VERSION}"
    
    # Check if Helm chart exists
    if [[ ! -d "${HELM_CHART_PATH}" ]]; then
        log_error "Volcano Helm chart not found at: ${HELM_CHART_PATH}"
        log_error "Please ensure you are running this from the volcano repository"
        exit 1
    fi
    
    # Create volcano-system namespace if not exists
    kubectl create namespace volcano-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Volcano using Helm
    log_info "Installing Volcano with Helm..."
    helm upgrade --install volcano "${HELM_CHART_PATH}" \
        --namespace volcano-system \
        --set basic.image_pull_policy="IfNotPresent" \
        --set basic.image_tag_version="${VOLCANO_VERSION}" \
        --set custom.scheduler_metrics_enable=true \
        --set custom.controller_metrics_enable=true \
        --set custom.scheduler_kube_api_qps=10000 \
        --set custom.scheduler_kube_api_burst=10000 \
        --set custom.controller_kube_api_qps=3000 \
        --set custom.controller_kube_api_burst=3000 \
        --set-file custom.scheduler_config_override="${CONFIG_DIR}/volcano-scheduler-config.yaml" \
        --wait \
        --timeout 300s
    
    # Wait for Volcano components to be ready
    log_info "Waiting for Volcano components to be ready..."
    
    # Wait for controller
    wait_for_deployment "volcano-system" "volcano-controller-manager" 120
    
    # Wait for scheduler
    wait_for_deployment "volcano-system" "volcano-scheduler" 120
    
    # Verify Volcano is working
    log_info "Verifying Volcano installation..."
    kubectl get pods -n volcano-system
    
    # Create default queue if not exists
    log_info "Creating default queue..."
    kubectl apply -f - <<EOF
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: default
spec:
  weight: 1
  reclaimable: false
  capability:
    cpu: "1000"
    memory: "10000Gi"
EOF
    
    log_info "Volcano ${VOLCANO_VERSION} installed successfully!"
}

main "$@"
