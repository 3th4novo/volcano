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

# Environment variables and common functions for Volcano Benchmark

set -e

# =============================================================================
# Configuration Variables
# =============================================================================

# Cluster configuration
export CLUSTER_NAME="${CLUSTER_NAME:-volcano-benchmark}"
export NAMESPACE="${NAMESPACE:-benchmark}"
export MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

# Test parameters
export NUM_JOBS="${NUM_JOBS:-20}"
export PODS_PER_JOB="${PODS_PER_JOB:-50}"
export NUM_FAKE_NODES="${NUM_FAKE_NODES:-10}"
export TOTAL_PODS=$((NUM_JOBS * PODS_PER_JOB))

# Version configuration
# Set USE_LOCAL_IMAGES=true to use locally built images (requires `make images` first)
export USE_LOCAL_IMAGES="${USE_LOCAL_IMAGES:-true}"
export VOLCANO_VERSION="${VOLCANO_VERSION:-v1.10.0}"
export KWOK_VERSION="${KWOK_VERSION:-v0.6.0}"

# Local image configuration (used when USE_LOCAL_IMAGES=true)
export LOCAL_IMAGE_TAG="${LOCAL_IMAGE_TAG:-latest}"
export VOLCANO_IMAGE_REPO="${VOLCANO_IMAGE_REPO:-volcanosh}"

# Paths
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCHMARK_DIR="$(dirname "$SCRIPT_DIR")"
export CONFIG_DIR="${BENCHMARK_DIR}/config"
export MANIFESTS_DIR="${BENCHMARK_DIR}/manifests"
export DASHBOARDS_DIR="${BENCHMARK_DIR}/dashboards"
export RESULTS_DIR="${BENCHMARK_DIR}/results"

# Helm chart path (relative to volcano repo root)
# Fix: BENCHMARK_DIR is already at volcano-repo/benchmark, so only need one dirname
export VOLCANO_REPO_ROOT="$(dirname "$BENCHMARK_DIR")"
export HELM_CHART_PATH="${VOLCANO_REPO_ROOT}/installer/helm/chart/volcano"

# Access URLs
export PROMETHEUS_URL="http://localhost:30090"
export GRAFANA_URL="http://localhost:30030"

# =============================================================================
# Logging Functions
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
    fi
}

log_step() {
    echo -e "\n${BLUE}==>${NC} $*"
}

# =============================================================================
# Utility Functions
# =============================================================================

# Check if a command exists
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found. Please install it first."
        return 1
    fi
    log_debug "Command '$cmd' found"
}

# Check all required dependencies
check_dependencies() {
    log_step "Checking dependencies..."
    local deps=("docker" "kind" "kubectl" "helm" "jq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install them before running the benchmark."
        return 1
    fi
    
    log_info "All dependencies are available"
}

# Wait for pods to be ready
wait_for_pods_ready() {
    local namespace="$1"
    local label_selector="$2"
    local expected_count="$3"
    local timeout="${4:-300}"
    
    log_info "Waiting for $expected_count pods with selector '$label_selector' in namespace '$namespace'..."
    
    local start_time=$(date +%s)
    while true; do
        local ready_count=$(kubectl get pods -n "$namespace" -l "$label_selector" \
            --field-selector=status.phase=Running -o json 2>/dev/null | \
            jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
        
        if [[ "$ready_count" -ge "$expected_count" ]]; then
            log_info "All $expected_count pods are ready"
            return 0
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for pods (${elapsed}s elapsed, $ready_count/$expected_count ready)"
            return 1
        fi
        
        log_debug "Waiting... ($ready_count/$expected_count ready, ${elapsed}s elapsed)"
        sleep 2
    done
}

# Wait for deployment to be ready
wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-120}"
    
    log_info "Waiting for deployment '$deployment' in namespace '$namespace'..."
    
    if kubectl wait --for=condition=available deployment/"$deployment" \
        -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        log_info "Deployment '$deployment' is ready"
        return 0
    else
        log_error "Timeout waiting for deployment '$deployment'"
        return 1
    fi
}

# Wait for all pods in namespace to be scheduled
wait_for_pods_scheduled() {
    local namespace="$1"
    local expected_count="$2"
    local timeout="${3:-300}"
    
    log_info "Waiting for $expected_count pods to be scheduled in namespace '$namespace'..."
    
    local start_time=$(date +%s)
    while true; do
        local scheduled_count=$(kubectl get pods -n "$namespace" \
            -o jsonpath='{.items[*].status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null | \
            tr ' ' '\n' | grep -c "True" || echo "0")
        
        if [[ "$scheduled_count" -ge "$expected_count" ]]; then
            log_info "All $expected_count pods are scheduled"
            return 0
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for pods to be scheduled (${elapsed}s elapsed, $scheduled_count/$expected_count scheduled)"
            return 1
        fi
        
        log_debug "Waiting... ($scheduled_count/$expected_count scheduled, ${elapsed}s elapsed)"
        sleep 1
    done
}

# Check cluster health
check_cluster_health() {
    log_step "Checking cluster health..."
    
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster"
        return 1
    fi
    
    local not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "Ready" | wc -l)
    if [[ $not_ready -gt 0 ]]; then
        log_warn "$not_ready nodes are not ready"
    fi
    
    log_info "Cluster is healthy"
}

# Create results directory
ensure_results_dir() {
    mkdir -p "$RESULTS_DIR"
    log_debug "Results directory: $RESULTS_DIR"
}

# Display progress bar
show_progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r[%s%s] %d%% (%d/%d)" \
        "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null) 2>/dev/null)" \
        "$(printf '.%.0s' $(seq 1 $empty 2>/dev/null) 2>/dev/null)" \
        "$percent" "$current" "$total"
}

# Sleep with progress display
sleep_with_progress() {
    local duration="$1"
    local message="${2:-Waiting}"
    
    for ((i = 0; i <= duration; i++)); do
        local percent=$((i * 100 / duration))
        printf "\r%s: [" "$message"
        for ((j = 0; j < 50; j++)); do
            if [[ $j -lt $((percent / 2)) ]]; then
                printf "="
            else
                printf " "
            fi
        done
        printf "] %d%%" "$percent"
        sleep 1
    done
    printf "\n"
}

# Get timestamp in ISO format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get timestamp in seconds
get_timestamp_seconds() {
    date +%s
}

# =============================================================================
# Kubernetes Helper Functions
# =============================================================================

# Check if namespace exists
namespace_exists() {
    local namespace="$1"
    kubectl get namespace "$namespace" &>/dev/null
}

# Create namespace if not exists
ensure_namespace() {
    local namespace="$1"
    if ! namespace_exists "$namespace"; then
        log_info "Creating namespace '$namespace'..."
        kubectl create namespace "$namespace"
    else
        log_debug "Namespace '$namespace' already exists"
    fi
}

# Delete namespace if exists
delete_namespace() {
    local namespace="$1"
    if namespace_exists "$namespace"; then
        log_info "Deleting namespace '$namespace'..."
        kubectl delete namespace "$namespace" --wait=false
    fi
}

# Get pod count in namespace
get_pod_count() {
    local namespace="$1"
    local selector="${2:-}"
    
    if [[ -n "$selector" ]]; then
        kubectl get pods -n "$namespace" -l "$selector" --no-headers 2>/dev/null | wc -l
    else
        kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l
    fi
}

# =============================================================================
# Print Configuration
# =============================================================================

print_config() {
    log_step "Benchmark Configuration"
    echo "  Cluster Name:     $CLUSTER_NAME"
    echo "  Namespace:        $NAMESPACE"
    echo "  Number of Jobs:   $NUM_JOBS"
    echo "  Pods per Job:     $PODS_PER_JOB"
    echo "  Total Pods:       $TOTAL_PODS"
    echo "  Fake Nodes:       $NUM_FAKE_NODES"
    echo "  Volcano Version:  $VOLCANO_VERSION"
    echo "  KWOK Version:     $KWOK_VERSION"
    echo ""
    echo "  Prometheus URL:   $PROMETHEUS_URL"
    echo "  Grafana URL:      $GRAFANA_URL"
}
