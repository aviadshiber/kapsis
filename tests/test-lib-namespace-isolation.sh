#!/usr/bin/env bash
# Test: Library Script Namespace Isolation
# Verifies that lib scripts don't pollute parent namespace
#
# This test ensures that library scripts in scripts/lib/ use unique internal
# variable names (e.g., _VALIDATE_SCOPE_DIR) instead of generic names like
# SCRIPT_DIR that would overwrite the parent script's variables when sourced.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# =============================================================================
# Test: validate-scope.sh namespace isolation
# =============================================================================
test_validate_scope_does_not_overwrite_script_dir() {
    local original_dir="/test/original/path"
    SCRIPT_DIR="$original_dir"

    # Source the lib script
    source "$KAPSIS_ROOT/scripts/lib/validate-scope.sh"

    # SCRIPT_DIR should be unchanged
    assert_equals "$SCRIPT_DIR" "$original_dir" \
        "validate-scope.sh should not overwrite SCRIPT_DIR"
}

# =============================================================================
# Test: progress-monitor.sh namespace isolation
# =============================================================================
test_progress_monitor_does_not_overwrite_script_dir() {
    local original_dir="/test/original/path"
    SCRIPT_DIR="$original_dir"

    # Source the lib script
    source "$KAPSIS_ROOT/scripts/lib/progress-monitor.sh"

    # SCRIPT_DIR should be unchanged
    assert_equals "$SCRIPT_DIR" "$original_dir" \
        "progress-monitor.sh should not overwrite SCRIPT_DIR"
}

# =============================================================================
# Test: config-verifier.sh namespace isolation
# =============================================================================
test_config_verifier_does_not_overwrite_script_dir() {
    local original_dir="/test/original/path"
    SCRIPT_DIR="$original_dir"

    # Source the lib script
    source "$KAPSIS_ROOT/scripts/lib/config-verifier.sh"

    # SCRIPT_DIR should be unchanged
    assert_equals "$SCRIPT_DIR" "$original_dir" \
        "config-verifier.sh should not overwrite SCRIPT_DIR"
}

# =============================================================================
# Test: All lib scripts follow naming convention
# =============================================================================
test_lib_scripts_use_prefixed_dir_variables() {
    local lib_dir="$KAPSIS_ROOT/scripts/lib"
    local -a violation_list=()

    # Check for any lib script that defines SCRIPT_DIR without underscore prefix
    # Exclude files that legitimately use SCRIPT_DIR in comments or strings
    for script in "$lib_dir"/*.sh; do
        local script_basename
        script_basename=$(basename "$script")

        # Look for SCRIPT_DIR= at the start of a line (actual assignment)
        if grep -qE '^SCRIPT_DIR=' "$script" 2>/dev/null; then
            violation_list+=("$script_basename")
        fi
    done

    if [[ ${#violation_list[@]} -gt 0 ]]; then
        _log_failure "Scripts with SCRIPT_DIR pollution: ${violation_list[*]}"
        return 1
    fi

    # Test passes - no violations found
    return 0
}

# =============================================================================
# Run all tests
# =============================================================================
print_test_header "Library Script Namespace Isolation"

run_test test_validate_scope_does_not_overwrite_script_dir
run_test test_progress_monitor_does_not_overwrite_script_dir
run_test test_config_verifier_does_not_overwrite_script_dir
run_test test_lib_scripts_use_prefixed_dir_variables

print_summary
