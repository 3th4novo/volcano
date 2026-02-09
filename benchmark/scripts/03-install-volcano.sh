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
# Functions
# =============================================================================

# Load local images into Kind cluster
load_local_images() {
    log_info "Loading locally built Volcano images into Kind cluster..."
    
    # Unified image names: volcano-controllers, volcano-scheduler, volcano-admission
    local images=(
        "${VOLCANO_IMAGE_REPO}/volcano-controllers:${LOCAL_IMAGE_TAG}"
        "${VOLCANO_IMAGE_REPO}/volcano-scheduler:${LOCAL_IMAGE_TAG}"
        "${VOLCANO_IMAGE_REPO}/volcano-admission:${LOCAL_IMAGE_TAG}"
    )
    
    for image in "${images[@]}"; do
        log_info "Loading image: ${image}"
        if docker image inspect "${image}" &> /dev/null; then
            kind load docker-image "${image}" --name "${CLUSTER_NAME}"
        else
            log_error "Image not found: ${image}"
            log_error "Please run 'make images' first to build local images"
            exit 1
        fi
    done
    
    log_info "All local images loaded successfully"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local version_display="${VOLCANO_VERSION}"
    if [[ "${USE_LOCAL_IMAGES}" == "true" ]]; then
        version_display="local (${LOCAL_IMAGE_TAG})"
    fi
    log_step "Installing Volcano ${version_display}"
    
    # Check if Volcano is already installed via Helm
    if helm status volcano -n volcano-system &> /dev/null; then
        log_info "Volcano is already installed via Helm"
        
        # Check if we need to upgrade (different version or local images)
        if [[ "${FORCE_REINSTALL:-false}" == "true" ]]; then
            log_info "FORCE_REINSTALL=true, will reinstall Volcano"
        else
            log_info "Skipping installation. Set FORCE_REINSTALL=true to reinstall."
            log_info "Current Volcano pods:"
            kubectl get pods -n volcano-system
            return 0
        fi
    fi
    
    # Check if Helm chart exists
    if [[ ! -d "${HELM_CHART_PATH}" ]]; then
        log_error "Volcano Helm chart not found at: ${HELM_CHART_PATH}"
        log_error "Please ensure you are running this from the volcano repository"
        exit 1
    fi
    
    # Create volcano-system namespace if not exists
    kubectl create namespace volcano-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Load local images if using local build
    if [[ "${USE_LOCAL_IMAGES}" == "true" ]]; then
        load_local_images
    fi
    
    # Build Helm install arguments
    local helm_args=(
        --namespace volcano-system
        --set basic.image_pull_policy="IfNotPresent"
        --set custom.scheduler_metrics_enable=true
        --set custom.controller_metrics_enable=true
        --set custom.scheduler_kube_api_qps=10000
        --set custom.scheduler_kube_api_burst=10000
        --set custom.controller_kube_api_qps=3000
        --set custom.controller_kube_api_burst=3000
        --set-file custom.scheduler_config_override="${CONFIG_DIR}/volcano-scheduler-config.yaml"
        --wait
        --timeout 300s
    )
    
    # Add image configuration based on USE_LOCAL_IMAGES
    if [[ "${USE_LOCAL_IMAGES}" == "true" ]]; then
        log_info "Using locally built images: ${VOLCANO_IMAGE_REPO}/*:${LOCAL_IMAGE_TAG}"
        helm_args+=(
            --set basic.image_tag_version="${LOCAL_IMAGE_TAG}"
            --set basic.controller_image_name="${VOLCANO_IMAGE_REPO}/volcano-controllers"
            --set basic.scheduler_image_name="${VOLCANO_IMAGE_REPO}/volcano-scheduler"
            --set basic.admission_image_name="${VOLCANO_IMAGE_REPO}/volcano-admission"
        )
    else
        log_info "Using official images: volcanosh/*:${VOLCANO_VERSION}"
        helm_args+=(
            --set basic.image_tag_version="${VOLCANO_VERSION}"
        )
    fi
    
    # Install Volcano using Helm
    log_info "Installing Volcano with Helm..."
    helm upgrade --install volcano "${HELM_CHART_PATH}" "${helm_args[@]}"
    
    # Wait for Volcano components to be ready
    log_info "Waiting for Volcano components to be ready..."
    
    # Wait for controller (deployment name is 'volcano-controllers' in Helm chart)
    wait_for_deployment "volcano-system" "volcano-controllers" 120
    
    # Wait for scheduler
    wait_for_deployment "volcano-system" "volcano-scheduler" 120
    
    # Wait for admission webhook (critical for queue creation)
    wait_for_deployment "volcano-system" "volcano-admission" 120
    
    # Additional wait for webhook to be fully ready
    log_info "Waiting for admission webhook to be fully ready..."
    sleep 10
    
    # Verify Volcano is working
    log_info "Verifying Volcano installation..."
    kubectl get pods -n volcano-system
    
    # Create default queue if not exists (with retry)
    log_info "Creating default queue..."
    local retry_count=0
    local max_retries=5
    while [[ $retry_count -lt $max_retries ]]; do
        if kubectl apply -f - <<EOF
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
        then
            log_info "Default queue created successfully"
            break
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warn "Failed to create queue, retrying in 5 seconds... (${retry_count}/${max_retries})"
                sleep 5
            else
                log_error "Failed to create default queue after ${max_retries} attempts"
                exit 1
            fi
        fi
    done
    
    log_info "Volcano ${version_display} installed successfully!"
}

main "$@"
