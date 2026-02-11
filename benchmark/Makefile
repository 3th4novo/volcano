CLUSTER_NAME ?= volcano-benchmark
KWOK_NODE_COUNT ?= 100
TEST_CASE ?= gang

export CLUSTER_NAME
export KWOK_NODE_COUNT

# Full test workflow
.PHONY: all
all: setup test report

# Environment setup
.PHONY: setup
setup: create-cluster create-nodes build-images install-volcano install-monitoring

.PHONY: create-cluster
create-cluster:
	bash scripts/01-create-cluster.sh

.PHONY: create-nodes
create-nodes:
	bash scripts/02-create-kwok-nodes.sh

.PHONY: build-images
build-images:
	bash scripts/03-build-images.sh

.PHONY: install-volcano
install-volcano:
	bash scripts/04-install-volcano.sh

.PHONY: install-monitoring
install-monitoring:
	bash scripts/05-install-monitoring.sh

.PHONY: test
test:
	bash scripts/06-run-tests.sh $(TEST_CASE)

.PHONY: report
report:
	bash scripts/07-collect-report.sh

.PHONY: cleanup
cleanup:
	bash scripts/08-cleanup.sh

.PHONY: cleanup-all
cleanup-all:
	bash scripts/08-cleanup.sh --delete-cluster

# Shortcut targets
.PHONY: test-gang-20x50
test-gang-20x50:
	bash scripts/06-run-tests.sh gang/case_20x50

.PHONY: test-gang-10x100
test-gang-10x100:
	bash scripts/06-run-tests.sh gang/case_10x100

.PHONY: test-all-gang
test-all-gang:
	bash scripts/06-run-tests.sh gang
