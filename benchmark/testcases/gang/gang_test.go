package gang_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	benchpkg "volcano.sh/volcano/benchmark/pkg"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// VCJobConfig defines the configuration for a single VCJob.
type VCJobConfig struct {
	Name         string
	Count        int    // number of VCJobs to create
	Replicas     int32  // pods per job
	MinAvailable int32  // gang scheduling minAvailable
	CPU          string // cpu request per pod
	Memory       string // memory request per pod
	Queue        string // volcano queue name
}

func TestMain(m *testing.M) {
	benchpkg.InitTestMain(m)
}

// GangProvider encapsulates gang scheduling test operations.
type GangProvider struct {
	benchpkg.Options
}

// AddNodes creates KWOK fake nodes via the Go client.
func (p *GangProvider) AddNodes(ctx context.Context) error {
	builder := benchpkg.NewNodeBuilder().
		WithFastReady().
		WithCPU(p.CpuPerNode).
		WithMemory(p.MemoryPerNode)
	for i := 0; i < p.NodeSize; i++ {
		err := benchpkg.Resources.Create(ctx,
			builder.WithName(fmt.Sprintf("kwok-node-%d", i)).Build(),
		)
		if err != nil {
			return fmt.Errorf("creating node %d: %w", i, err)
		}
	}
	return nil
}

// BuildVCJob constructs a Volcano Job as an unstructured object using pure Go structs.
func BuildVCJob(cfg VCJobConfig, index uint64) *unstructured.Unstructured {
	name := fmt.Sprintf("%s-%d", cfg.Name, index)

	// Build container resources
	containers := []interface{}{
		map[string]interface{}{
			"name":  "worker",
			"image": "busybox:1.36",
			"command": []interface{}{
				"sh", "-c", "sleep 30",
			},
			"resources": map[string]interface{}{
				"requests": map[string]interface{}{
					"cpu":    cfg.CPU,
					"memory": cfg.Memory,
				},
			},
		},
	}

	// Build tolerations for KWOK nodes
	tolerations := []interface{}{
		map[string]interface{}{
			"key":      "kwok.x-k8s.io/node",
			"operator": "Exists",
			"effect":   "NoSchedule",
		},
	}

	// Build node selector for KWOK nodes
	nodeSelector := map[string]interface{}{
		"type": "kwok",
	}

	// Build task spec
	task := map[string]interface{}{
		"name":     "worker",
		"replicas": int64(cfg.Replicas),
		"template": map[string]interface{}{
			"spec": map[string]interface{}{
				"schedulerName": "volcano",
				"containers":    containers,
				"tolerations":   tolerations,
				"nodeSelector":  nodeSelector,
				"restartPolicy": "Never",
			},
		},
	}

	// Build the VCJob
	obj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "batch.volcano.sh/v1alpha1",
			"kind":       "Job",
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": "default",
			},
			"spec": map[string]interface{}{
				"schedulerName": "volcano",
				"minAvailable":  int64(cfg.MinAvailable),
				"queue":         cfg.Queue,
				"tasks":         []interface{}{task},
				"plugins": map[string]interface{}{
					"svc": []interface{}{},
					"env": []interface{}{},
				},
			},
		},
	}

	return obj
}

// CreateGangJobs creates multiple VCJobs and returns the submission timestamp.
func CreateGangJobs(ctx context.Context, cfg VCJobConfig) (time.Time, error) {
	submitTime := time.Now()
	for i := 0; i < cfg.Count; i++ {
		obj := BuildVCJob(cfg, benchpkg.Index())
		if err := benchpkg.Resources.Create(ctx, obj); err != nil {
			return submitTime, fmt.Errorf("creating vcjob %d: %w", i, err)
		}
	}
	return submitTime, nil
}

// RunGangTest is the common test runner for gang scheduling benchmarks.
func RunGangTest(t *testing.T, configs []VCJobConfig) {
	ctx := context.Background()

	// Clean up any pre-existing VCJobs to allow re-runs without conflicts
	t.Log("Cleaning up pre-existing VCJobs...")
	if err := benchpkg.CleanupVCJobs(ctx, "default"); err != nil {
		t.Logf("Warning: failed to cleanup old VCJobs: %v", err)
	}
	// Wait briefly for cleanup to propagate
	time.Sleep(3 * time.Second)

	totalPods := 0
	for _, cfg := range configs {
		totalPods += cfg.Count * int(cfg.Replicas)
	}

	t.Logf("Starting gang scheduling test: total %d pods", totalPods)

	var firstSubmitTime time.Time
	for i, cfg := range configs {
		submitTime, err := CreateGangJobs(ctx, cfg)
		if err != nil {
			t.Fatalf("Failed to create gang jobs for config %d: %v", i, err)
		}
		if i == 0 {
			firstSubmitTime = submitTime
		}
		t.Logf("Created %d VCJobs (%s): %d pods/job, minAvailable=%d",
			cfg.Count, cfg.Name, cfg.Replicas, cfg.MinAvailable)
	}

	// Wait for all pods to be scheduled
	t.Log("Waiting for all pods to be scheduled...")
	err := benchpkg.WaitForPodsScheduled(ctx, "default", "volcano.sh/job-name", totalPods, 10*time.Minute)
	if err != nil {
		t.Fatalf("Pods scheduling timeout: %v", err)
	}

	// Measure pod creation latency
	latency, err := benchpkg.MeasurePodsCreationLatency(
		ctx, "default", "volcano.sh/job-name", totalPods,
		firstSubmitTime, 10*time.Minute,
	)
	if err != nil {
		t.Fatalf("Failed to measure latency: %v", err)
	}

	t.Logf("=== Results ===")
	t.Logf("Total pods: %d", totalPods)
	t.Logf("Pod creation latency (vcjob submit -> all pods created): %v", latency)
	t.Logf("Throughput: %.1f pods/sec", float64(totalPods)/latency.Seconds())

	// Verify pod count
	var pods corev1.PodList
	err = benchpkg.Resources.WithNamespace("default").List(ctx, &pods)
	if err != nil {
		t.Fatalf("Failed to list pods: %v", err)
	}
	// Filter pods with volcano label
	count := 0
	for _, p := range pods.Items {
		if _, ok := p.Labels["volcano.sh/job-name"]; ok {
			count++
		}
	}
	t.Logf("Verified: %d volcano pods found", count)
}
