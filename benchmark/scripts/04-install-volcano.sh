#!/usr/bin/env bash
# 04-install-volcano.sh — Install Volcano

source "$(dirname "$0")/common.sh"
require_cmd kubectl helm

# Clean up any pre-existing Volcano CRDs that lack Helm ownership labels.
# This prevents "invalid ownership metadata" errors during helm install.
log_info "Cleaning up any pre-existing Volcano CRDs..."
kubectl get crd -o name 2>/dev/null | grep 'volcano\.sh' | while read -r crd; do
    log_info "  Deleting $crd"
    kubectl delete "$crd" --ignore-not-found
done

# Also uninstall any previous Helm release to ensure a clean state
if helm status volcano -n volcano-system &>/dev/null; then
    log_info "Removing previous Volcano Helm release..."
    helm uninstall volcano -n volcano-system --wait
fi

log_info "Installing Volcano via Helm..."
helm install volcano "${VOLCANO_ROOT}/installer/helm/chart/volcano" \
    --namespace volcano-system \
    --create-namespace \
    --set basic.scheduler_config_file=volcano-scheduler-configmap \
    --set basic.image_pull_policy=IfNotPresent \
    --wait --timeout 120s

log_info "Applying scheduler configuration (enabling gang plugin)..."
kubectl apply -f "${BENCHMARK_DIR}/manifests/volcano/scheduler-config.yaml"

log_info "Restarting volcano-scheduler to load new configuration..."
kubectl rollout restart deployment/volcano-scheduler -n volcano-system
kubectl rollout status deployment/volcano-scheduler -n volcano-system --timeout=120s

log_info "Creating test queue..."
kubectl apply -f "${BENCHMARK_DIR}/manifests/volcano/queue.yaml"

log_info "Volcano installation complete"
kubectl get pods -n volcano-system
