#!/usr/bin/env bash
#===============================================================================
# Test: Pre-push Orchestrator
#
# Tests the pre-push orchestrator and its component scripts.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

ORCHESTRATOR_SCRIPT="$KAPSIS_ROOT/scripts/hooks/prepush-orchestrator.sh"
PREPUSH_DIR="$KAPSIS_ROOT/scripts/hooks/prepush"

#===============================================================================
# TEST CASES
#===============================================================================

test_orchestrator_exists() {
    log_test "Testing orchestrator script exists"
    assert_file_exists "$ORCHESTRATOR_SCRIPT" "Orchestrator script should exist"
}

test_orchestrator_is_executable() {
    log_test "Testing orchestrator script is executable"
    assert_true "[[ -x \"$ORCHESTRATOR_SCRIPT\" ]]" "Script should be executable"
}

test_orchestrator_passes_shellcheck() {
    log_test "Testing orchestrator passes shellcheck"

    if ! command -v shellcheck &>/dev/null; then
        log_skip "shellcheck not available"
        return 0
    fi

    local exit_code=0
    shellcheck -x -S warning "$ORCHESTRATOR_SCRIPT" || exit_code=$?
    assert_equals 0 "$exit_code" "Orchestrator should pass shellcheck"
}

test_prepush_scripts_exist() {
    log_test "Testing all pre-push scripts exist"

    local scripts=("pr-comments.sh" "check-docs.sh" "unbiased-review.sh" "create-pr.sh")
    for script in "${scripts[@]}"; do
        assert_file_exists "$PREPUSH_DIR/$script" "$script should exist"
    done
}

test_prepush_scripts_executable() {
    log_test "Testing all pre-push scripts are executable"

    local scripts=("pr-comments.sh" "check-docs.sh" "unbiased-review.sh" "create-pr.sh")
    for script in "${scripts[@]}"; do
        assert_true "[[ -x \"$PREPUSH_DIR/$script\" ]]" "$script should be executable"
    done
}

test_prepush_scripts_pass_shellcheck() {
    log_test "Testing all pre-push scripts pass shellcheck"

    if ! command -v shellcheck &>/dev/null; then
        log_skip "shellcheck not available"
        return 0
    fi

    local scripts=("pr-comments.sh" "check-docs.sh" "unbiased-review.sh" "create-pr.sh")
    for script in "${scripts[@]}"; do
        local exit_code=0
        shellcheck -x -S warning "$PREPUSH_DIR/$script" || exit_code=$?
        assert_equals 0 "$exit_code" "$script should pass shellcheck"
    done
}

test_orchestrator_help() {
    log_test "Testing orchestrator --help option"

    local output
    local exit_code=0

    output=$("$ORCHESTRATOR_SCRIPT" --help 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Help should exit 0"
    assert_contains "$output" "Usage" "Should show usage"
    assert_contains "$output" "--no-review" "Should document --no-review"
    assert_contains "$output" "--no-pr" "Should document --no-pr"
}

test_orchestrator_no_review_option() {
    log_test "Testing orchestrator --no-review option"

    local output
    output=$("$ORCHESTRATOR_SCRIPT" --no-review --no-pr 2>&1) || true

    assert_contains "$output" "Skipping LLM review" "Should skip LLM review"
}

test_orchestrator_no_pr_option() {
    log_test "Testing orchestrator --no-pr option"

    local output
    output=$("$ORCHESTRATOR_SCRIPT" --no-review --no-pr 2>&1) || true

    assert_contains "$output" "Skipping PR creation" "Should skip PR creation"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Pre-push Orchestrator"

    run_test test_orchestrator_exists
    run_test test_orchestrator_is_executable
    run_test test_orchestrator_passes_shellcheck
    run_test test_prepush_scripts_exist
    run_test test_prepush_scripts_executable
    run_test test_prepush_scripts_pass_shellcheck
    run_test test_orchestrator_help
    run_test test_orchestrator_no_review_option
    run_test test_orchestrator_no_pr_option

    print_summary
}

main "$@"
