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

# Script to build Volcano images from source code

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Building Volcano images from source"
    
    # Check if we're in the volcano repository
    if [[ ! -f "${VOLCANO_REPO_ROOT}/Makefile" ]]; then
        log_error "Makefile not found at: ${VOLCANO_REPO_ROOT}/Makefile"
        log_error "Please ensure you are running this from the volcano repository"
        exit 1
    fi
    
    # Check required tools
    check_command docker
    check_command make
    
    # Build images using Makefile
    log_info "Building Volcano images with tag: ${LOCAL_IMAGE_TAG}"
    log_info "Image repository: ${VOLCANO_IMAGE_REPO}"
    
    cd "${VOLCANO_REPO_ROOT}"
    
    # Build images with specified tag
    log_info "Running: make images TAG=${LOCAL_IMAGE_TAG} IMAGE_PREFIX=${VOLCANO_IMAGE_REPO}"
    make images TAG="${LOCAL_IMAGE_TAG}" IMAGE_PREFIX="${VOLCANO_IMAGE_REPO}"
    
    # Re-tag images to use unified naming convention
    # Makefile produces: vc-controller-manager, vc-scheduler, vc-webhook-manager
    # We re-tag to: volcano-controllers, volcano-scheduler, volcano-admission
    log_info "Re-tagging images to unified naming convention..."
    
    local tag_mappings=(
        "vc-controller-manager:volcano-controllers"
        "vc-scheduler:volcano-scheduler"
        "vc-webhook-manager:volcano-admission"
    )
    
    for mapping in "${tag_mappings[@]}"; do
        local src_name="${mapping%%:*}"
        local dst_name="${mapping##*:}"
        local src_image="${VOLCANO_IMAGE_REPO}/${src_name}:${LOCAL_IMAGE_TAG}"
        local dst_image="${VOLCANO_IMAGE_REPO}/${dst_name}:${LOCAL_IMAGE_TAG}"
        
        log_info "  Tagging ${src_image} -> ${dst_image}"
        docker tag "${src_image}" "${dst_image}"
    done
    
    # Verify images were built and tagged
    log_info "Verifying built images..."
    local images=(
        "${VOLCANO_IMAGE_REPO}/volcano-controllers:${LOCAL_IMAGE_TAG}"
        "${VOLCANO_IMAGE_REPO}/volcano-scheduler:${LOCAL_IMAGE_TAG}"
        "${VOLCANO_IMAGE_REPO}/volcano-admission:${LOCAL_IMAGE_TAG}"
    )
    
    local all_found=true
    for image in "${images[@]}"; do
        if docker image inspect "${image}" &> /dev/null; then
            log_info "  ✓ ${image}"
        else
            log_error "  ✗ ${image} not found"
            all_found=false
        fi
    done
    
    if [[ "${all_found}" != "true" ]]; then
        log_error "Some images failed to build"
        exit 1
    fi
    
    log_info "All Volcano images built successfully!"
}

main "$@"
