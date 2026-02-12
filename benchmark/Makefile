CLUSTER_NAME ?= volcano-benchmark
KWOK_NODE_COUNT ?= 100
TEST_CASE ?= gang
VOLCANO_VERSION ?=

export CLUSTER_NAME
export KWOK_NODE_COUNT

# Full test workflow
.PHONY: all
all: setup test report

# Environment setup
.PHONY: setup
ifdef VOLCANO_VERSION
setup: create-cluster create-nodes install-volcano install-monitoring
else
setup: create-cluster create-nodes build-images install-volcano install-monitoring
endif

.PHONY: create-cluster
create-cluster:
	bash scripts/create-cluster.sh

.PHONY: create-nodes
create-nodes:
	bash scripts/create-kwok-nodes.sh

.PHONY: build-images
build-images:
ifdef VOLCANO_VERSION
	@echo "Skipping image build (using release version $(VOLCANO_VERSION))"
else
	bash scripts/build-images.sh
endif

.PHONY: install-volcano
install-volcano:
ifdef VOLCANO_VERSION
	bash scripts/install-volcano.sh --release $(VOLCANO_VERSION)
else
	bash scripts/install-volcano.sh --local
endif

.PHONY: install-monitoring
install-monitoring:
	bash scripts/install-monitoring.sh

.PHONY: test
test:
	bash scripts/run-tests.sh $(TEST_CASE)

.PHONY: report
report:
	bash scripts/collect-report.sh

.PHONY: export-charts
export-charts:
	bash scripts/export-grafana-charts.sh

.PHONY: cleanup
cleanup:
	bash scripts/cleanup.sh

.PHONY: cleanup-all
cleanup-all:
	bash scripts/cleanup.sh --delete-cluster

# Shortcut targets
.PHONY: test-gang-20x50
test-gang-20x50:
	bash scripts/run-tests.sh gang/case_20x50

.PHONY: test-gang-10x100
test-gang-10x100:
	bash scripts/run-tests.sh gang/case_10x100

.PHONY: test-all-gang
test-all-gang:
	bash scripts/run-tests.sh gang
