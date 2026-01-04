#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-commit: Check Test Coverage
#
# Verifies that modified scripts have corresponding test files and that
# those tests are included in the test runner.
#
# Exit codes:
#   0 - All modified scripts have tests
#   1 - Missing tests detected
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "precommit-check-tests"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { :; }
fi

# Get staged script files
STAGED_SCRIPTS=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '^scripts/.*\.sh$' | grep -v '/hooks/' || true)

if [[ -z "$STAGED_SCRIPTS" ]]; then
    log_debug "No script files staged"
    exit 0
fi

MISSING_TESTS=()
NOT_IN_RUNNER=()

# Read QUICK_TESTS from run-all-tests.sh
QUICK_TESTS=""
if [[ -f "$REPO_ROOT/tests/run-all-tests.sh" ]]; then
    QUICK_TESTS=$(grep -E '^QUICK_TESTS=' "$REPO_ROOT/tests/run-all-tests.sh" | sed 's/QUICK_TESTS=//' | tr -d '"' || true)
fi

log_info "Checking test coverage for staged scripts..."

while IFS= read -r script; do
    [[ -z "$script" ]] && continue

    # Extract script name (e.g., scripts/lib/logging.sh -> logging)
    SCRIPT_NAME=$(basename "$script" .sh)

    # Look for corresponding test file
    # Pattern: test-<script-name>.sh
    TEST_FILE="tests/test-${SCRIPT_NAME}.sh"

    if [[ ! -f "$REPO_ROOT/$TEST_FILE" ]]; then
        # Try alternative patterns
        ALT_TEST=$(find "$REPO_ROOT/tests" -name "test-*${SCRIPT_NAME}*.sh" -type f 2>/dev/null | head -1)
        if [[ -z "$ALT_TEST" ]]; then
            MISSING_TESTS+=("$script -> $TEST_FILE")
        else
            TEST_FILE=$(basename "$ALT_TEST")
        fi
    else
        TEST_FILE="test-${SCRIPT_NAME}.sh"
    fi

    # Check if test is in QUICK_TESTS
    if [[ -n "$TEST_FILE" && ! "$QUICK_TESTS" =~ $TEST_FILE ]]; then
        NOT_IN_RUNNER+=("$TEST_FILE")
    fi

done <<< "$STAGED_SCRIPTS"

# Report findings
EXIT_CODE=0

if [[ ${#MISSING_TESTS[@]} -gt 0 ]]; then
    log_warn "Scripts missing test coverage:"
    for missing in "${MISSING_TESTS[@]}"; do
        echo "  - $missing"
    done
    # Don't fail on missing tests, just warn
fi

if [[ ${#NOT_IN_RUNNER[@]} -gt 0 ]]; then
    log_warn "Tests not in QUICK_TESTS (may not run in CI):"
    for test in "${NOT_IN_RUNNER[@]}"; do
        echo "  - $test"
    done
fi

if [[ ${#MISSING_TESTS[@]} -eq 0 && ${#NOT_IN_RUNNER[@]} -eq 0 ]]; then
    log_info "Test coverage check passed"
fi

exit $EXIT_CODE
