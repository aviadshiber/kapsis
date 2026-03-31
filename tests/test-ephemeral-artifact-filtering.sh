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

# Import constants
source "$KAPSIS_ROOT/scripts/lib/constants.sh"

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
