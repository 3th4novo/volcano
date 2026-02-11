#!/usr/bin/env bash
# 04-install-volcano.sh — Install Volcano

source "$(dirname "$0")/common.sh"
require_cmd kubectl helm

log_info "Installing Volcano CRDs..."
kubectl apply -f "${VOLCANO_ROOT}/config/crd/volcano/bases/"

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
