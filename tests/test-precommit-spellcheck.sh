#!/usr/bin/env bash
#===============================================================================
# Test: Pre-commit Spellcheck Hook
#
# Tests the spellcheck pre-commit hook functionality.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

SPELLCHECK_SCRIPT="$KAPSIS_ROOT/scripts/hooks/precommit/spellcheck.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_script_exists() {
    log_test "Testing spellcheck script exists"
    assert_file_exists "$SPELLCHECK_SCRIPT" "Spellcheck script should exist"
}

test_script_is_executable() {
    log_test "Testing spellcheck script is executable"
    assert_true "[[ -x \"$SPELLCHECK_SCRIPT\" ]]" "Script should be executable"
}

test_script_passes_shellcheck() {
    log_test "Testing script passes shellcheck"

    if ! command -v shellcheck &>/dev/null; then
        log_skip "shellcheck not available"
        return 0
    fi

    local exit_code=0
    shellcheck -x -S warning "$SPELLCHECK_SCRIPT" || exit_code=$?
    assert_equals 0 "$exit_code" "Script should pass shellcheck"
}

test_exits_gracefully_without_codespell() {
    log_test "Testing graceful exit when codespell not available"

    local output
    local exit_code=0

    # If codespell exists, test would fail - we can't easily hide it
    if command -v codespell &>/dev/null; then
        log_skip "codespell is installed, can't test missing scenario"
        return 0
    fi

    output=$("$SPELLCHECK_SCRIPT" 2>&1) || exit_code=$?
    assert_equals 0 "$exit_code" "Should exit 0 when codespell missing"
    assert_contains "$output" "codespell" "Should mention codespell in output"
}

test_handles_no_staged_files() {
    log_test "Testing handling of no staged files"

    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    git init --quiet

    local output
    local exit_code=0

    output=$("$SPELLCHECK_SCRIPT" 2>&1) || exit_code=$?

    cd - >/dev/null || exit 1
    rm -rf "$temp_dir"

    # Should succeed with no staged files
    assert_equals 0 "$exit_code" "Should succeed with no staged files"
    # Verify script ran (output should exist, even if empty or just logging)
    assert_true "[[ -n \"\$output\" || \$exit_code -eq 0 ]]" "Should produce output or succeed silently"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Pre-commit Spellcheck Hook"

    run_test test_script_exists
    run_test test_script_is_executable
    run_test test_script_passes_shellcheck
    run_test test_exits_gracefully_without_codespell
    run_test test_handles_no_staged_files

    print_summary
}

main "$@"
