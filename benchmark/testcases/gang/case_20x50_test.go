package gang_test

import "testing"

// TestGang20x50 tests gang scheduling with 20 jobs × 50 pods/job (1000 total pods).
func TestGang20x50(t *testing.T) {
	RunGangTest(t, []VCJobConfig{
		{
			Name:         "gang-20x50",
			Count:        20,
			Replicas:     50,
			MinAvailable: 50,
			CPU:          "1",
			Memory:       "1Gi",
			Queue:        "benchmark-queue",
		},
	})
}
