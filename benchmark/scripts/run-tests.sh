#!/usr/bin/env bash
# run-tests.sh — Run benchmark tests
#
# Two modes of operation:
#
# Mode 1: Run predefined Go test cases
#   ./scripts/run-tests.sh gang              # Run all tests under the gang directory
#   ./scripts/run-tests.sh gang/case_20x50   # Run a specific test case TestGang20x50
#
# Mode 2: Run with CLI parameters (ad-hoc, no predefined test case needed)
#   SCENARIO=gang JOBS=10 PODS=100 CPU=1 MEMORY=1Gi ./scripts/run-tests.sh
#   The script passes these as env vars to the Go test binary which reads them via TestFromCLI.

source "$(dirname "$0")/common.sh"
require_cmd go

# Check if CLI params mode (JOBS env var is set)
JOBS="${JOBS:-}"
PODS="${PODS:-}"
CPU="${CPU:-1}"
MEMORY="${MEMORY:-1Gi}"
MIN_AVAILABLE="${MIN_AVAILABLE:-}"
QUEUE="${QUEUE:-benchmark-queue}"

TEST_CASE="${1:-${SCENARIO}}"
SCENE_DIR="${TEST_CASE%%/*}"
TEST_FUNC=""

# If JOBS is set, we're in CLI params mode — run TestFromCLI
if [[ -n "${JOBS}" ]]; then
    SCENE_DIR="${SCENARIO}"
    TEST_FUNC="TestFromCLI"
    # Default MIN_AVAILABLE to PODS if not set
    MIN_AVAILABLE="${MIN_AVAILABLE:-${PODS}}"
    log_info "CLI params mode: scenario=${SCENARIO}, jobs=${JOBS}, pods=${PODS}, cpu=${CPU}, memory=${MEMORY}, minAvailable=${MIN_AVAILABLE}, queue=${QUEUE}"
elif [[ "${TEST_CASE}" == *"/"* ]]; then
    # Predefined test case mode: extract test function name
    CASE_NAME="${TEST_CASE##*/}"
    # case_20x50 -> TestGang20x50
    TEST_FUNC="TestGang${CASE_NAME#case_}"
    TEST_FUNC=$(echo "${TEST_FUNC}" | sed 's/_//g' | sed 's/x/x/g')
fi

log_info "Compiling test binary: testcases/${SCENE_DIR}..."
mkdir -p "${BENCHMARK_DIR}/bin"
mkdir -p "${BENCHMARK_DIR}/results"
cd "${VOLCANO_ROOT}"
go test -c -o "${BENCHMARK_DIR}/bin/test-${SCENE_DIR}" "./benchmark/testcases/${SCENE_DIR}/..."

log_info "Running tests..."
RUN_ARGS="-test.v -test.timeout 600s"
if [[ -n "${TEST_FUNC}" ]]; then
    RUN_ARGS="-test.run ${TEST_FUNC} ${RUN_ARGS}"
    log_info "  Test function: ${TEST_FUNC}"
fi

# Export env vars for Go test binary to read
export KUBECONFIG="${KUBECONFIG}"
export BENCHMARK_JOBS="${JOBS}"
export BENCHMARK_PODS="${PODS}"
export BENCHMARK_CPU="${CPU}"
export BENCHMARK_MEMORY="${MEMORY}"
export BENCHMARK_MIN_AVAILABLE="${MIN_AVAILABLE}"
export BENCHMARK_QUEUE="${QUEUE}"
export BENCHMARK_SCENARIO="${SCENARIO}"
export BENCHMARK_SCENARIO_DIR="${SCENARIO_DIR}"

"${BENCHMARK_DIR}/bin/test-${SCENE_DIR}" ${RUN_ARGS} 2>&1 | tee "${BENCHMARK_DIR}/results/test-${SCENE_DIR}-$(date +%Y%m%d-%H%M%S).log"

log_info "Tests completed"
