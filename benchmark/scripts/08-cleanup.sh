#!/usr/bin/env bash
# 08-cleanup.sh — Clean up resources
# Usage:
#   ./scripts/08-cleanup.sh                   # Clean up resources only, keep the cluster
#   ./scripts/08-cleanup.sh --delete-cluster   # Clean up resources and delete the cluster

source "$(dirname "$0")/common.sh"
require_cmd kubectl

DELETE_CLUSTER=false
for arg in "$@"; do
    case "${arg}" in
        --delete-cluster) DELETE_CLUSTER=true ;;
    esac
done

log_info "Cleaning up test VCJobs..."
kubectl delete vcjob --all -n default --ignore-not-found=true 2>/dev/null || true

log_info "Cleaning up KWOK simulated nodes..."
kubectl delete node -l type=kwok --ignore-not-found=true 2>/dev/null || true

log_info "Cleaning up monitoring components..."
kubectl delete -f "${BENCHMARK_DIR}/manifests/monitoring/grafana.yaml" --ignore-not-found=true 2>/dev/null || true
kubectl delete -f "${BENCHMARK_DIR}/manifests/monitoring/prometheus.yaml" --ignore-not-found=true 2>/dev/null || true

log_info "Cleaning up Volcano..."
helm uninstall volcano -n volcano-system 2>/dev/null || true
kubectl delete namespace volcano-system --ignore-not-found=true 2>/dev/null || true

log_info "Cleaning up test queue..."
kubectl delete -f "${BENCHMARK_DIR}/manifests/volcano/queue.yaml" --ignore-not-found=true 2>/dev/null || true

if [[ "${DELETE_CLUSTER}" == "true" ]]; then
    require_cmd kind
    log_info "Deleting Kind cluster ${CLUSTER_NAME}..."
    kind delete cluster --name "${CLUSTER_NAME}"
    rm -f "${BENCHMARK_DIR}/kubeconfig"
    log_info "Cluster deleted"
else
    log_info "Cluster ${CLUSTER_NAME} retained (use --delete-cluster to remove)"
fi

log_info "Cleanup complete"
