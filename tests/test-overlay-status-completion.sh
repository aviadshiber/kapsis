#!/usr/bin/env bash
#===============================================================================
# Test: Overlay Mode Status Completion (Regression test for #168)
#
# Verifies that:
# 1. The _cleanup_with_completion trap calls status_complete on abnormal exit
# 2. _STATUS_COMPLETE_SHOWN guards against double-completion
# 3. post_container_overlay sets commit status metadata
#
# Bug #168: In overlay mode, status JSON stayed at "phase": "running" after
# the agent finished because status_complete was never called on abnormal exit,
# and overlay mode lacked commit status metadata.
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_AGENT_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"
STATUS_SCRIPT="$KAPSIS_ROOT/scripts/lib/status.sh"

#===============================================================================
# TEST CASES: Cleanup Trap
#===============================================================================

test_cleanup_trap_calls_status_complete() {
    log_test "Cleanup trap calls status_complete on abnormal exit"

    # Extract the _cleanup_with_completion function body and verify it calls status_complete
    if grep -A 20 '_cleanup_with_completion()' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'status_complete'; then
        log_info "  ✓ _cleanup_with_completion calls status_complete"
    else
        log_fail "_cleanup_with_completion does not call status_complete"
        return 1
    fi
}

test_cleanup_trap_guards_status_complete() {
    log_test "Cleanup trap guards status_complete with _STATUS_COMPLETE_SHOWN"

    # Verify the trap checks _STATUS_COMPLETE_SHOWN before calling status_complete
    if grep -A 20 '_cleanup_with_completion()' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q '_STATUS_COMPLETE_SHOWN.*!=.*true'; then
        log_info "  ✓ Trap checks _STATUS_COMPLETE_SHOWN before calling status_complete"
    else
        log_fail "Trap does not guard status_complete with _STATUS_COMPLETE_SHOWN"
        return 1
    fi
}

test_status_complete_shown_initialized() {
    log_test "_STATUS_COMPLETE_SHOWN is initialized to false"

    if grep -q '_STATUS_COMPLETE_SHOWN=false' "$LAUNCH_AGENT_SCRIPT"; then
        log_info "  ✓ _STATUS_COMPLETE_SHOWN initialized to false"
    else
        log_fail "_STATUS_COMPLETE_SHOWN not initialized"
        return 1
    fi
}

test_status_complete_shown_set_after_normal_calls() {
    log_test "_STATUS_COMPLETE_SHOWN=true set after each status_complete in normal flow"

    # Count status_complete calls in the normal flow (excluding the trap)
    # Each should be followed by _STATUS_COMPLETE_SHOWN=true
    local status_complete_count
    local guard_set_count

    # Count status_complete calls (exclude trap block and comments)
    status_complete_count=$(grep -c 'status_complete' "$LAUNCH_AGENT_SCRIPT" | tr -d ' ')

    # Count _STATUS_COMPLETE_SHOWN=true assignments
    guard_set_count=$(grep -c '_STATUS_COMPLETE_SHOWN=true' "$LAUNCH_AGENT_SCRIPT" | tr -d ' ')

    # The trap has 2 status_complete calls (success/error) and the init has 1 false assignment
    # Normal flow calls should each have a corresponding _STATUS_COMPLETE_SHOWN=true
    # Trap calls (2) + comment (1) = 3 that don't need guards
    # So guard_set_count should be >= (status_complete_count - 3)
    local expected_min
    expected_min=$((status_complete_count - 3))

    if [[ "$guard_set_count" -ge "$expected_min" ]]; then
        log_info "  ✓ Found $guard_set_count _STATUS_COMPLETE_SHOWN=true for $status_complete_count status_complete calls"
    else
        log_fail "Only $guard_set_count guards for $status_complete_count status_complete calls (expected >= $expected_min)"
        return 1
    fi
}

#===============================================================================
# TEST CASES: Overlay Commit Status Metadata
#===============================================================================

test_overlay_sets_commit_info_pending() {
    log_test "post_container_overlay sets commit info to overlay_pending"

    # Verify that post_container_overlay calls status_set_commit_info with overlay_pending
    if grep -A 50 'post_container_overlay()' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'status_set_commit_info "overlay_pending"'; then
        log_info "  ✓ Overlay mode sets commit status to overlay_pending when changes exist"
    else
        log_fail "post_container_overlay does not set overlay_pending commit status"
        return 1
    fi
}

test_overlay_sets_commit_info_no_changes() {
    log_test "post_container_overlay sets commit info to no_changes"

    # Verify that post_container_overlay calls status_set_commit_info with no_changes
    if grep -A 50 'post_container_overlay()' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'status_set_commit_info "no_changes"'; then
        log_info "  ✓ Overlay mode sets commit status to no_changes when no changes"
    else
        log_fail "post_container_overlay does not set no_changes commit status"
        return 1
    fi
}

test_overlay_handles_missing_upper_dir() {
    log_test "post_container_overlay handles missing UPPER_DIR"

    # Verify there is an else branch for when UPPER_DIR doesn't exist
    # The function should have: if [[ -d "$UPPER_DIR" ]]; then ... else ... fi
    local func_body
    func_body=$(sed -n '/^post_container_overlay()/,/^[^ ]/p' "$LAUNCH_AGENT_SCRIPT")

    if echo "$func_body" | grep -q 'No upper directory found'; then
        log_info "  ✓ Overlay mode handles missing UPPER_DIR"
    else
        log_fail "post_container_overlay does not handle missing UPPER_DIR"
        return 1
    fi
}

#===============================================================================
# TEST CASES: Status Library (functional tests)
#===============================================================================

test_status_overlay_pending_functional() {
    log_test "status_set_commit_info accepts overlay_pending value"

    # Create isolated test status directory
    local test_dir
    test_dir=$(mktemp -d)
    export KAPSIS_STATUS_DIR="$test_dir"
    export KAPSIS_STATUS_ENABLED="true"

    # Reset status library state
    unset _KAPSIS_STATUS_LOADED 2>/dev/null || true
    unset _KAPSIS_STATUS_FILE 2>/dev/null || true
    unset _KAPSIS_STATUS_INITIALIZED 2>/dev/null || true
    unset _KAPSIS_STATUS_PROJECT 2>/dev/null || true
    unset _KAPSIS_STATUS_AGENT_ID 2>/dev/null || true
    unset _KAPSIS_COMMIT_STATUS 2>/dev/null || true

    # Source fresh status library
    source "$STATUS_SCRIPT"

    # Initialize and set overlay_pending
    status_init "test-project" "test-agent" "" "overlay" ""
    status_set_commit_info "overlay_pending" "" "5"

    local result
    result=$(status_get_commit_status)

    if [[ "$result" == "overlay_pending" ]]; then
        log_info "  ✓ status_get_commit_status returns overlay_pending"
    else
        log_fail "Expected overlay_pending, got: $result"
        rm -rf "$test_dir"
        return 1
    fi

    rm -rf "$test_dir"
}

#===============================================================================
# RUNNER
#===============================================================================

run_test test_cleanup_trap_calls_status_complete
run_test test_cleanup_trap_guards_status_complete
run_test test_status_complete_shown_initialized
run_test test_status_complete_shown_set_after_normal_calls
run_test test_overlay_sets_commit_info_pending
run_test test_overlay_sets_commit_info_no_changes
run_test test_overlay_handles_missing_upper_dir
run_test test_status_overlay_pending_functional

print_summary
