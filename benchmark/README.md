# Volcano Benchmark Framework

A Kind + KWOK based performance benchmark framework for the Volcano scheduler.

## Quick Start

```bash
# Full workflow (local source): create cluster -> build images -> install -> run tests -> report
cd benchmark
make all

# Full workflow (release version): skip image build, install from Helm repo
make all VOLCANO_VERSION=v1.10.0

# Run a specific test case
make test-gang-20x50    # 20 jobs × 50 pods/job
make test-gang-10x100   # 10 jobs × 100 pods/job

# Cleanup
make cleanup            # Keep the cluster
make cleanup-all        # Delete the cluster
```

## Directory Structure

```
benchmark/
├── Makefile                    # Main entry point
├── config/                     # Configuration files
├── manifests/                  # K8s resource manifests
│   ├── kwok/                   # KWOK Stages
│   ├── monitoring/             # Prometheus + Grafana
│   └── volcano/                # Scheduler config + Queue
├── scripts/                    # Bash scripts
├── pkg/                        # Go shared library
├── testcases/gang/             # Gang scheduling test cases
└── results/                    # Test results (git ignored)
```

## Monitoring

- Prometheus: http://localhost:30090
- Grafana: http://localhost:30080 (admin/admin)

### Metrics Reference

| Metric | Source | Description |
|--------|--------|-------------|
| VCJob submission to pod creation latency | Go code `MeasurePodsCreationLatency()` | Pod creation completion timestamp - VCJob submission timestamp |
| Core scheduling latency | Prometheus: `volcano_e2e_scheduling_latency_milliseconds` | Volcano internal scheduling latency histogram |
| Pod status statistics | kube-state-metrics | Three curves: created / scheduled / deleted |

## Adding New Test Cases

1. Create a new scenario directory under `testcases/`
2. Create `*_test.go` files
3. Run: `make test TEST_CASE=<scenario_name>`

## Step-by-Step Testing Guide

This section walks you through running the benchmark from scratch. Follow each step in order.

### Prerequisites

Ensure the following tools are installed and available in your `PATH`:

- **Go** >= 1.24.0
- **Docker** (running)
- **kind** >= 0.20.0 — for creating local Kubernetes clusters
- **kubectl** — matching your cluster version
- **helm** >= 3.0 — for installing Volcano
- **curl** and **jq** — for collecting Prometheus metrics
- **make** — for running Makefile targets

Verify with:

```bash
go version && docker info > /dev/null && kind version && kubectl version --client && helm version && jq --version
```

### Step 1: Create the Kind Cluster

```bash
cd benchmark
make create-cluster
```

This creates a Kind cluster named `volcano-benchmark` with high API server QPS/burst settings and NodePort mappings for Prometheus (30090) and Grafana (30080). The kubeconfig is exported to `benchmark/kubeconfig`.

### Step 2: Create KWOK Simulated Nodes

```bash
make create-nodes
```

By default, 100 KWOK nodes are created, each with 32 CPU and 256Gi memory. Customize via environment variables:

```bash
KWOK_NODE_COUNT=200 CPU_PER_NODE=64 MEMORY_PER_NODE=512Gi make create-nodes
```

### Step 3: Build Volcano Images (local mode only)

```bash
make build-images
```

This runs `make images` in the Volcano root directory and loads the resulting images into the Kind cluster. This step is automatically skipped when using `VOLCANO_VERSION`.

### Step 4: Install Volcano

**Option A — Local source (default):**

```bash
make install-volcano
```

Installs Volcano from the local Helm chart at `installer/helm/chart/volcano`.

**Option B — Specific release version:**

```bash
make install-volcano VOLCANO_VERSION=v1.10.0
```

Downloads and installs the specified version from the official Volcano Helm repository (`https://volcano-sh.github.io/volcano`). No local image build is needed.

Both options apply the gang scheduling plugin config, create the benchmark queue, and restart the scheduler.

### Step 5: Install Monitoring

```bash
make install-monitoring
```

Deploys Prometheus (with 1-second scrape interval), kube-state-metrics, and Grafana with a pre-configured dashboard. Access:

- Prometheus: http://localhost:30090
- Grafana: http://localhost:30080 (credentials: admin/admin)

### Step 6: Run Tests

Run all gang scheduling tests:

```bash
make test
```

Run a specific test case:

```bash
make test-gang-20x50     # 20 jobs × 50 pods/job, minAvailable=50
make test-gang-10x100    # 10 jobs × 100 pods/job, minAvailable=100
```

Or use the test script directly with more control:

```bash
# Run with custom timeout
bash scripts/run-tests.sh gang/case_20x50
```

The test binary is compiled from Go test files under `testcases/gang/` and executed with `-test.v` for verbose output. Results are saved to `results/`.

### Step 7: Collect Report

```bash
make report
```

Queries Prometheus for scheduling latency (P50/P99), pod counts, and job E2E duration. Outputs a JSON report to `results/report-<timestamp>.json`.

### Step 8: View Results

Open the Grafana dashboard at http://localhost:30080/d/volcano-benchmark to see:

- **Pod Scheduling Progress**: time-series chart with created/scheduled/deleted pod counts (X-axis: time, Y-axis: pod count, 1-second refresh)
- **Scheduling Latency**: P50 and P99 latency over time
- **Job E2E Duration**: table of per-job scheduling durations

The Go test output also prints:
- Total pod count
- Pod creation latency (VCJob submit → all pods created)
- Throughput (pods/sec)

### Step 9: Cleanup

```bash
make cleanup          # Remove test resources, keep the cluster
make cleanup-all      # Remove everything including the Kind cluster
```

### Configuring Test Parameters

Key environment variables (set before running `make` or export in your shell):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `volcano-benchmark` | Kind cluster name |
| `KWOK_NODE_COUNT` | `100` | Number of KWOK simulated nodes |
| `CPU_PER_NODE` | `32` | CPU capacity per KWOK node |
| `MEMORY_PER_NODE` | `256Gi` | Memory capacity per KWOK node |
| `KWOK_VERSION` | `v0.7.0` | KWOK release version |
| `TEST_CASE` | `gang` | Test case to run (used by `make test`) |
| `VOLCANO_VERSION` | _(empty)_ | Set to a release tag (e.g. `v1.10.0`) to install from Helm repo instead of local source |

### Troubleshooting

- **Kind cluster creation fails**: Ensure Docker is running and has sufficient resources (at least 4 CPU, 8GB RAM recommended).
- **KWOK nodes not becoming Ready**: Check KWOK controller logs: `kubectl logs -n kube-system deployment/kwok-controller`.
- **Volcano pods CrashLoopBackOff**: Verify images were loaded correctly: `docker exec volcano-benchmark-control-plane crictl images | grep volcanosh`.
- **Prometheus shows no data**: Wait 30 seconds after test completion for metrics to be scraped. Verify targets at http://localhost:30090/targets.
- **Tests timeout**: Increase the timeout: `bash scripts/run-tests.sh gang` (default is 600s). Ensure enough KWOK nodes are available for the pod count.

## Dependencies

- Go >= 1.24.0
- Docker
- kind >= 0.20.0
- kubectl
- helm >= 3.0
- curl, jq
- sigs.k8s.io/e2e-framework (Go module)
