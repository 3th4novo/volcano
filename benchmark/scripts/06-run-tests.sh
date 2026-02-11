#!/usr/bin/env bash
# 06-run-tests.sh — Run tests (accepts test case name as parameter)
# Usage:
#   ./scripts/06-run-tests.sh gang              # Run all tests under the gang directory
#   ./scripts/06-run-tests.sh gang/case_20x50   # Run a specific test case TestGang20x50

source "$(dirname "$0")/common.sh"
require_cmd go

TEST_CASE="${1:-gang}"
SCENE_DIR="${TEST_CASE%%/*}"
TEST_FUNC=""

# If a specific case is specified, extract the test function name
if [[ "${TEST_CASE}" == *"/"* ]]; then
    CASE_NAME="${TEST_CASE##*/}"
    # case_20x50 -> TestGang20x50
    TEST_FUNC="TestGang${CASE_NAME#case_}"
    TEST_FUNC=$(echo "${TEST_FUNC}" | sed 's/_//g' | sed 's/x/x/g')
fi

log_info "Compiling test binary: testcases/${SCENE_DIR}..."
mkdir -p "${BENCHMARK_DIR}/bin"
cd "${VOLCANO_ROOT}"
go test -c -o "${BENCHMARK_DIR}/bin/test-${SCENE_DIR}" "./benchmark/testcases/${SCENE_DIR}/..."

log_info "Running tests..."
RUN_ARGS="-test.v -test.timeout 600s"
if [[ -n "${TEST_FUNC}" ]]; then
    RUN_ARGS="-test.run ${TEST_FUNC} ${RUN_ARGS}"
    log_info "  Test function: ${TEST_FUNC}"
fi

export KUBECONFIG="${KUBECONFIG}"
"${BENCHMARK_DIR}/bin/test-${SCENE_DIR}" ${RUN_ARGS} 2>&1 | tee "${BENCHMARK_DIR}/results/test-${SCENE_DIR}-$(date +%Y%m%d-%H%M%S).log"

log_info "Tests completed"
