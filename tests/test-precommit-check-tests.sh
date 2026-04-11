#!/usr/bin/env bash
#===============================================================================
# Test: Pre-commit Check Tests Hook
#
# Tests the test coverage verification pre-commit hook.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

CHECK_TESTS_SCRIPT="$KAPSIS_ROOT/scripts/hooks/precommit/check-tests.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_script_exists() {
    log_test "Testing check-tests script exists"
    assert_file_exists "$CHECK_TESTS_SCRIPT" "Check-tests script should exist"
}

test_script_is_executable() {
    log_test "Testing check-tests script is executable"
    assert_true "[[ -x \"$CHECK_TESTS_SCRIPT\" ]]" "Script should be executable"
}

test_script_passes_shellcheck() {
    log_test "Testing script passes shellcheck"

    if ! command -v shellcheck &>/dev/null; then
        log_skip "shellcheck not available"
        return 0
    fi

    local exit_code=0
    shellcheck -x -S warning "$CHECK_TESTS_SCRIPT" || exit_code=$?
    assert_equals 0 "$exit_code" "Script should pass shellcheck"
}

test_handles_no_staged_scripts() {
    log_test "Testing handling of no staged script files"

    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    git init --quiet

    local output
    local exit_code=0

    output=$("$CHECK_TESTS_SCRIPT" 2>&1) || exit_code=$?

    cd - >/dev/null || exit 1
    rm -rf "$temp_dir"

    assert_equals 0 "$exit_code" "Should succeed with no staged scripts"
}

test_excludes_hook_files() {
    log_test "Testing that hook files are excluded from test requirement"

    # The script should exclude files in scripts/hooks/ from test requirements
    # since hooks are tested differently
    local output
    output=$(grep -E "grep -v '/hooks/'" "$CHECK_TESTS_SCRIPT" || true)

    assert_true "[[ -n \"$output\" ]]" "Should exclude hooks directory from check"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Pre-commit Check Tests Hook"

    run_test test_script_exists
    run_test test_script_is_executable
    run_test test_script_passes_shellcheck
    run_test test_handles_no_staged_scripts
    run_test test_excludes_hook_files

    print_summary
}

main "$@"
