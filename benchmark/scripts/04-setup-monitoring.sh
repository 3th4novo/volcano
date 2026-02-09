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

# Script to setup monitoring stack (Prometheus + Grafana) for Benchmark

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

# =============================================================================
# Main
# =============================================================================

main() {
    log_step "Setting up monitoring stack"
    
    # Deploy Prometheus
    log_info "Deploying Prometheus..."
    kubectl apply -f "${MANIFESTS_DIR}/monitoring/prometheus.yaml"
    
    # Deploy Kube-State-Metrics
    log_info "Deploying Kube-State-Metrics..."
    kubectl apply -f "${MANIFESTS_DIR}/monitoring/kube-state-metrics.yaml"
    
    # Create Grafana dashboard ConfigMap
    log_info "Creating Grafana dashboard ConfigMap..."
    kubectl create configmap grafana-dashboards \
        --from-file=volcano-benchmark.json="${DASHBOARDS_DIR}/volcano-benchmark.json" \
        -n monitoring \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy Grafana
    log_info "Deploying Grafana..."
    kubectl apply -f "${MANIFESTS_DIR}/monitoring/grafana.yaml"
    
    # Wait for monitoring components to be ready
    log_info "Waiting for monitoring components to be ready..."
    
    wait_for_deployment "monitoring" "prometheus" 120
    wait_for_deployment "monitoring" "kube-state-metrics" 120
    wait_for_deployment "monitoring" "grafana" 120
    
    # Display monitoring status
    log_info "Monitoring stack status:"
    kubectl get pods -n monitoring
    
    # Display access URLs
    log_info ""
    log_info "=========================================="
    log_info "Monitoring Access URLs:"
    log_info "  Prometheus: ${PROMETHEUS_URL}"
    log_info "  Grafana:    ${GRAFANA_URL}"
    log_info "  Grafana credentials: admin/admin"
    log_info "=========================================="
    
    log_info "Monitoring stack setup completed successfully!"
}

main "$@"
