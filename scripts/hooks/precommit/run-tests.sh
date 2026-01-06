#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-commit: Run Tests
#
# Runs the quick test suite before allowing a commit.
# Uses --quick mode for fast feedback (no container tests).
#
# Exit codes:
#   0 - All tests passed
#   1 - Tests failed
#===============================================================================

set -euo pipefail

# CRITICAL: Unset git environment variables before running tests
# Git exports GIT_DIR/GIT_INDEX_FILE during hook execution, which can cause
# test git operations to corrupt the main repository's index.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "precommit-run-tests"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

TEST_RUNNER="$REPO_ROOT/tests/run-all-tests.sh"

if [[ ! -x "$TEST_RUNNER" ]]; then
    log_error "Test runner not found: $TEST_RUNNER"
    exit 1
fi

log_info "Running quick tests..."

# Run tests in quiet mode for cleaner pre-commit output
if "$TEST_RUNNER" --quick -q; then
    log_info "All tests passed"
    exit 0
else
    log_error "Tests failed. Fix them before committing."
    exit 1
fi
