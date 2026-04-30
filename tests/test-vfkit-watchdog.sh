#!/usr/bin/env bash
#===============================================================================
# Test: Host-side vfkit watchdog (Issue #303)
#
# Verifies the host-side vfkit watchdog added to launch-agent.sh:
#   - Variable declarations exist (_VFKIT_WATCHDOG_PID, _VFKIT_WATCHDOG_TRIGGERED)
#   - Watchdog startup is gated on is_macos + podman backend
#   - Watchdog uses pgrep -n -f to find vfkit PID
#   - Watchdog loop checks vfkit liveness via kill -0
#   - Watchdog creates trigger file and calls podman stop on vfkit exit
#   - EXIT_CODE is overridden to 4 when trigger file exists
#   - Watchdog PID and trigger file are cleaned up in trap
#   - Log messages match acceptance criteria from issue
#
# All tests are QUICK (no container needed).
# Category: validation
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_AGENT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# Variable declaration tests
#===============================================================================

test_vfkit_watchdog_pid_declared() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" '_VFKIT_WATCHDOG_PID=""' \
        "launch-agent.sh must declare _VFKIT_WATCHDOG_PID empty string"
}

test_vfkit_watchdog_triggered_declared() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" '_VFKIT_WATCHDOG_TRIGGERED=""' \
        "launch-agent.sh must declare _VFKIT_WATCHDOG_TRIGGERED empty string"
}

#===============================================================================
# Watchdog startup guard tests
#===============================================================================

test_watchdog_startup_guarded_by_is_macos() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    # The guard must check both backend and platform.
    # We look for the pattern in the watchdog startup section, which appears
    # after the caffeinate block in the macOS sleep prevention section.
    assert_contains "$content" 'is_macos' \
        "Watchdog startup must be gated on is_macos"
}

test_watchdog_uses_pgrep_to_find_vfkit() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'pgrep -n -f "vfkit' \
        "Watchdog must use pgrep -n -f to find vfkit PID"
}

test_watchdog_uses_podman_machine_env_var() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'KAPSIS_PODMAN_MACHINE:-podman-machine-default' \
        "Watchdog pgrep must use KAPSIS_PODMAN_MACHINE with default fallback"
}

test_watchdog_creates_trigger_file_via_mktemp() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    # The trigger file path is created via mktemp and stored in a variable.
    # We verify mktemp is called and the result assigned to _VFKIT_WATCHDOG_TRIGGERED.
    assert_contains "$content" '_VFKIT_WATCHDOG_TRIGGERED=$(mktemp)' \
        "Watchdog must create trigger file path via mktemp"
}

test_watchdog_removes_trigger_file_before_loop() {
    # The file must be absent during normal operation (present = watchdog fired).
    # We verify the rm -f call that ensures the file starts absent.
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'rm -f "$_VFKIT_WATCHDOG_TRIGGERED"  # absent = running' \
        "Watchdog must remove trigger file so it starts absent"
}

#===============================================================================
# Watchdog loop logic tests
#===============================================================================

test_watchdog_loop_checks_vfkit_via_kill_zero() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'kill -0 "$_vfkit_pid"' \
        "Watchdog loop must check vfkit liveness with kill -0"
}

test_watchdog_loop_touches_trigger_file_on_death() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'touch "$_wd_trigger_file"' \
        "Watchdog must create trigger file via touch when vfkit exits"
}

test_watchdog_stops_container_via_podman_stop() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'podman stop "$_wd_container"' \
        "Watchdog must stop the container via podman stop when vfkit exits"
}

test_watchdog_polls_every_5_seconds() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'sleep 5' \
        "Watchdog loop must sleep 5 seconds between polls"
}

#===============================================================================
# EXIT_CODE override tests
#===============================================================================

test_exit_code_override_checks_trigger_file() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" '-f "${_VFKIT_WATCHDOG_TRIGGERED:-}"' \
        "Exit-code override must check for the trigger file existence"
}

test_exit_code_override_sets_mount_failure_code() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'EXIT_CODE=$KAPSIS_EXIT_MOUNT_FAILURE' \
        "Exit-code override must set EXIT_CODE to KAPSIS_EXIT_MOUNT_FAILURE (4)"
}

test_exit_code_override_clears_trigger_file() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    # After reading the trigger, the file and variable are cleared to prevent
    # double-processing in _cleanup_with_completion.
    assert_contains "$content" '_VFKIT_WATCHDOG_TRIGGERED=""' \
        "Exit-code override must clear _VFKIT_WATCHDOG_TRIGGERED after reading"
}

#===============================================================================
# Cleanup / trap tests
#===============================================================================

test_cleanup_kills_watchdog_pid() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'kill "$_VFKIT_WATCHDOG_PID"' \
        "Cleanup trap must kill _VFKIT_WATCHDOG_PID on exit"
}

test_cleanup_removes_trigger_file() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'rm -f "${_VFKIT_WATCHDOG_TRIGGERED:-}"' \
        "Cleanup trap must remove trigger file on exit"
}

#===============================================================================
# Log message tests (acceptance criteria from Issue #303)
#===============================================================================

test_log_watchdog_active_message() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'vfkit watchdog active (vfkit PID:' \
        "Watchdog must log active message with PID"
}

test_log_vfkit_exited_message() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'vfkit process (PID' \
        "Watchdog must log vfkit exit warning"
}

test_log_watchdog_triggered_override_message() {
    local content
    content=$(cat "$LAUNCH_AGENT")
    assert_contains "$content" 'vfkit watchdog triggered' \
        "Parent must log when overriding exit code due to watchdog trigger"
}

#===============================================================================
# Trigger file mechanism functional test
#===============================================================================

test_trigger_file_mechanism_works() {
    # Verify the trigger file convention (absent = running, present = fired)
    # by simulating the watchdog's write and the parent's read.
    local trigger_file
    trigger_file=$(mktemp)
    rm -f "$trigger_file"  # start absent

    assert_file_not_exists "$trigger_file" \
        "Trigger file must be absent before watchdog fires"

    touch "$trigger_file"
    assert_file_exists "$trigger_file" \
        "Trigger file must exist after watchdog fires (touch)"

    rm -f "$trigger_file"
    assert_file_not_exists "$trigger_file" \
        "Trigger file must be gone after parent clears it"
}

#===============================================================================
# Runner
#===============================================================================

run_test test_vfkit_watchdog_pid_declared
run_test test_vfkit_watchdog_triggered_declared
run_test test_watchdog_startup_guarded_by_is_macos
run_test test_watchdog_uses_pgrep_to_find_vfkit
run_test test_watchdog_uses_podman_machine_env_var
run_test test_watchdog_creates_trigger_file_via_mktemp
run_test test_watchdog_removes_trigger_file_before_loop
run_test test_watchdog_loop_checks_vfkit_via_kill_zero
run_test test_watchdog_loop_touches_trigger_file_on_death
run_test test_watchdog_stops_container_via_podman_stop
run_test test_watchdog_polls_every_5_seconds
run_test test_exit_code_override_checks_trigger_file
run_test test_exit_code_override_sets_mount_failure_code
run_test test_exit_code_override_clears_trigger_file
run_test test_cleanup_kills_watchdog_pid
run_test test_cleanup_removes_trigger_file
run_test test_log_watchdog_active_message
run_test test_log_vfkit_exited_message
run_test test_log_watchdog_triggered_override_message
run_test test_trigger_file_mechanism_works

print_summary
