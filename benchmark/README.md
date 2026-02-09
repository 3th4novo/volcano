# Volcano Benchmark

This directory contains the performance benchmark suite for Volcano scheduler. It uses Kind to create a local Kubernetes cluster, KWOK to simulate nodes, and Prometheus + Grafana for monitoring.

## Overview

The benchmark tests Volcano's scheduling performance with the following configuration:
- **Test Scale**: 20 Jobs × 50 Pods/Job = 1000 Pods
- **Scheduling Mode**: Gang Scheduling (minAvailable=50)
- **Simulated Nodes**: 10 KWOK fake nodes (32 CPU, 256Gi memory each)

## Prerequisites

Before running the benchmark, ensure you have the following tools installed:

| Tool | Version | Installation |
|------|---------|--------------|
| Docker | >= 20.10 | [Install Docker](https://docs.docker.com/get-docker/) |
| Kind | >= 0.20.0 | `go install sigs.k8s.io/kind@latest` |
| kubectl | >= 1.28 | [Install kubectl](https://kubernetes.io/docs/tasks/tools/) |
| Helm | >= 3.12 | [Install Helm](https://helm.sh/docs/intro/install/) |
| jq | >= 1.6 | `brew install jq` (macOS) |

## Quick Start

Run the complete benchmark with a single command:

```bash
cd benchmark/scripts
chmod +x *.sh
./run-all.sh
```

This will:
1. Create a Kind cluster
2. Install Volcano
3. Deploy KWOK and fake nodes
4. Setup Prometheus and Grafana
5. Run the benchmark (20 jobs × 50 pods)
6. Collect results

## Directory Structure

```
benchmark/
├── README.md                           # This file
├── config/
│   ├── kind-config.yaml               # Kind cluster configuration
│   ├── volcano-scheduler-config.yaml  # Volcano scheduler configuration
│   └── prometheus-config.yaml         # Prometheus scrape configuration
├── manifests/
│   ├── kwok/
│   │   ├── kwok-deployment.yaml       # KWOK controller and stages
│   │   └── fake-nodes.yaml            # Simulated node definitions
│   ├── monitoring/
│   │   ├── prometheus.yaml            # Prometheus deployment
│   │   ├── kube-state-metrics.yaml    # Kube-State-Metrics deployment
│   │   └── grafana.yaml               # Grafana deployment
│   └── workloads/
│       └── vcjob-template.yaml        # VCJob template for benchmark
├── dashboards/
│   └── volcano-benchmark.json         # Grafana dashboard configuration
├── scripts/
│   ├── 00-env.sh                      # Environment variables and functions
│   ├── 01-setup-cluster.sh            # Create Kind cluster
│   ├── 02-install-volcano.sh          # Install Volcano
│   ├── 03-setup-kwok.sh               # Deploy KWOK and fake nodes
│   ├── 04-setup-monitoring.sh         # Deploy monitoring stack
│   ├── 05-run-benchmark.sh            # Run the benchmark test
│   ├── 06-collect-results.sh          # Collect results from Prometheus
│   ├── 99-cleanup.sh                  # Cleanup resources
│   └── run-all.sh                     # One-click run all steps
└── results/                           # Benchmark results output
```

## Running Individual Steps

You can run each step individually:

```bash
cd benchmark/scripts

# Step 1: Create Kind cluster
./01-setup-cluster.sh

# Step 2: Install Volcano
./02-install-volcano.sh

# Step 3: Setup KWOK and fake nodes
./03-setup-kwok.sh

# Step 4: Setup monitoring
./04-setup-monitoring.sh

# Step 5: Run benchmark
./05-run-benchmark.sh

# Step 6: Collect results
./06-collect-results.sh
```

## Monitoring

After running the benchmark, access the monitoring dashboards:

| Service | URL | Credentials |
|---------|-----|-------------|
| Prometheus | http://localhost:30090 | N/A |
| Grafana | http://localhost:30030 | admin/admin |

### Grafana Dashboard

The pre-configured dashboard shows:
1. **Pod Status Over Time**: Created/Scheduled/Running pods count
2. **Scheduling Latency Distribution**: Heatmap of scheduling latency
3. **Job Scheduling Duration**: Table of per-job scheduling time
4. **Summary Stats**: Total pods, average latency, throughput

## Metrics

### Key Metrics Collected

| Metric | Source | Description |
|--------|--------|-------------|
| `volcano_e2e_job_scheduling_duration` | Volcano Scheduler | Time from job creation to all pods scheduled |
| `volcano_e2e_scheduling_latency_milliseconds` | Volcano Scheduler | Per-scheduling-cycle latency |
| `kube_pod_created` | Kube-State-Metrics | Pod creation timestamp |
| `kube_pod_status_scheduled` | Kube-State-Metrics | Pod scheduling status |

### PromQL Queries

```promql
# Created pods count
count(kube_pod_created{namespace="benchmark"})

# Scheduled pods count
count(kube_pod_status_scheduled{namespace="benchmark", condition="true"})

# Average scheduling latency (P50)
histogram_quantile(0.5, rate(volcano_e2e_scheduling_latency_milliseconds_bucket[5m]))

# Job scheduling duration
volcano_e2e_job_scheduling_duration{job_namespace="benchmark"}
```

## Configuration

### Customizing Test Parameters

Edit `scripts/00-env.sh` to customize:

```bash
# Number of jobs to create
export NUM_JOBS=20

# Pods per job (also used as minAvailable for Gang Scheduling)
export PODS_PER_JOB=50

# Number of fake nodes
export NUM_FAKE_NODES=10

# Volcano version
export VOLCANO_VERSION="v1.10.0"
```

### Customizing Volcano Scheduler

Edit `config/volcano-scheduler-config.yaml` to modify scheduler behavior:

```yaml
actions: "enqueue, allocate, backfill"
tiers:
- plugins:
  - name: priority
  - name: gang
    enablePreemptable: false
  - name: conformance
- plugins:
  - name: predicates
  - name: proportion
  - name: nodeorder
```

## Cleanup

```bash
# Cleanup benchmark namespace only (keep cluster)
./scripts/99-cleanup.sh

# Cleanup everything including Kind cluster
./scripts/99-cleanup.sh --delete-cluster
```

## Results

Benchmark results are saved to `results/` directory:

- `benchmark-YYYYMMDD-HHMMSS.json`: Test configuration and summary
- `YYYYMMDD-HHMMSS/summary.json`: Detailed metrics summary
- `YYYYMMDD-HHMMSS/report.txt`: Human-readable report
- `YYYYMMDD-HHMMSS/*_timeseries.json`: Time series data

## Troubleshooting

### Common Issues

1. **Kind cluster creation fails**
   - Ensure Docker is running
   - Check available disk space

2. **Volcano installation fails**
   - Verify Helm chart path exists
   - Check kubectl context

3. **Pods not scheduling**
   - Verify KWOK nodes are Ready: `kubectl get nodes -l type=kwok`
   - Check Volcano scheduler logs: `kubectl logs -n volcano-system -l app=volcano-scheduler`

4. **Prometheus not scraping metrics**
   - Verify Volcano scheduler metrics endpoint: `kubectl port-forward -n volcano-system svc/volcano-scheduler 8080:8080`
   - Check Prometheus targets: http://localhost:30090/targets

## License

Copyright 2024 The Volcano Authors.

Licensed under the Apache License, Version 2.0.
