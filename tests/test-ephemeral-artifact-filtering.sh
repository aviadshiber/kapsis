#!/usr/bin/env bash
#===============================================================================
# Test: Ephemeral Artifact Filtering (Issue #227)
#
# Verifies that constants for ephemeral artifact filtering and push timeouts
# are properly defined and have valid values.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Import constants and post-container-git
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/post-container-git.sh"

# Global variables
TEST_REPO=""

#===============================================================================
# SETUP AND TEARDOWN
#===============================================================================

setup_test_repo() {
    TEST_REPO=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-test-ephem-XXXXXX")
    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false
    echo "# Test Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"
}

cleanup_test_repo() {
    [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]] && rm -rf "$TEST_REPO"
    TEST_REPO=""
}

#===============================================================================
# TEST CASES
#===============================================================================

test_push_timeout_constant_exists() {
    log_test "KAPSIS_DEFAULT_PUSH_TIMEOUT constant exists and is numeric"
    assert_true '[[ -n "${KAPSIS_DEFAULT_PUSH_TIMEOUT:-}" ]]' \
        "KAPSIS_DEFAULT_PUSH_TIMEOUT should be defined"
    assert_true '[[ "${KAPSIS_DEFAULT_PUSH_TIMEOUT}" =~ ^[0-9]+$ ]]' \
        "KAPSIS_DEFAULT_PUSH_TIMEOUT should be numeric"
}

test_ephemeral_patterns_constant_exists() {
    log_test "KAPSIS_DEFAULT_EPHEMERAL_PATTERNS constant exists and is non-empty"
    assert_true '[[ -n "${KAPSIS_DEFAULT_EPHEMERAL_PATTERNS:-}" ]]' \
        "KAPSIS_DEFAULT_EPHEMERAL_PATTERNS should be defined"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Ephemeral Artifact Filtering (Issue #227)"

    run_test test_push_timeout_constant_exists
    run_test test_ephemeral_patterns_constant_exists

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
