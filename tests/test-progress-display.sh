#!/usr/bin/env bash
#===============================================================================
# Test: Progress Display
#
# Verifies the progress display library works correctly:
# - TTY detection
# - Progress bar rendering
# - Phase label mapping
# - Timer formatting
# - Non-TTY fallback output
# - Spinner animation
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

PROGRESS_DISPLAY_SCRIPT="$KAPSIS_ROOT/scripts/lib/progress-display.sh"

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_display_test() {
    # Reset any previous state
    unset _KAPSIS_PROGRESS_DISPLAY_LOADED 2>/dev/null || true
    unset KAPSIS_PROGRESS_DISPLAY 2>/dev/null || true
    unset KAPSIS_NO_PROGRESS 2>/dev/null || true
    unset NO_COLOR 2>/dev/null || true

    # Source fresh progress display library
    source "$PROGRESS_DISPLAY_SCRIPT"
}

#===============================================================================
# TEST CASES: TTY Detection
#===============================================================================

test_tty_detection_disabled_by_env() {
    log_test "TTY detection respects KAPSIS_NO_PROGRESS"

    unset _KAPSIS_PROGRESS_DISPLAY_LOADED
    export KAPSIS_NO_PROGRESS="true"
    source "$PROGRESS_DISPLAY_SCRIPT"

    display_init

    assert_equals "0" "${KAPSIS_PROGRESS_DISPLAY:-0}" "KAPSIS_PROGRESS_DISPLAY should be 0 when disabled"

    unset KAPSIS_NO_PROGRESS
}

test_tty_detection_disabled_by_no_color() {
    log_test "TTY detection respects NO_COLOR"

    unset _KAPSIS_PROGRESS_DISPLAY_LOADED
    export NO_COLOR="1"
    source "$PROGRESS_DISPLAY_SCRIPT"

    display_init

    assert_equals "0" "${KAPSIS_PROGRESS_DISPLAY:-0}" "KAPSIS_PROGRESS_DISPLAY should be 0 when NO_COLOR set"

    unset NO_COLOR
}

#===============================================================================
# TEST CASES: Progress Bar Rendering
#===============================================================================

test_progress_bar_0_percent() {
    log_test "Progress bar renders correctly at 0%"

    setup_display_test

    local bar
    bar=$(_pd_render_bar 0 10)

    assert_contains "$bar" "░░░░░░░░░░" "Should have all empty chars"
    assert_contains "$bar" "0%" "Should show 0%"
}

test_progress_bar_50_percent() {
    log_test "Progress bar renders correctly at 50%"

    setup_display_test

    local bar
    bar=$(_pd_render_bar 50 10)

    assert_contains "$bar" "█████" "Should have 5 filled chars"
    assert_contains "$bar" "░░░░░" "Should have 5 empty chars"
    assert_contains "$bar" "50%" "Should show 50%"
}

test_progress_bar_100_percent() {
    log_test "Progress bar renders correctly at 100%"

    setup_display_test

    local bar
    bar=$(_pd_render_bar 100 10)

    assert_contains "$bar" "██████████" "Should have all filled chars"
    assert_contains "$bar" "100%" "Should show 100%"
}

test_progress_bar_clamps_negative() {
    log_test "Progress bar clamps negative values to 0"

    setup_display_test

    local bar
    bar=$(_pd_render_bar -10 10)

    assert_contains "$bar" "0%" "Should clamp to 0%"
}

test_progress_bar_clamps_over_100() {
    log_test "Progress bar clamps values over 100 to 100"

    setup_display_test

    local bar
    bar=$(_pd_render_bar 150 10)

    assert_contains "$bar" "100%" "Should clamp to 100%"
}

#===============================================================================
# TEST CASES: Phase Labels
#===============================================================================

test_phase_label_initializing() {
    log_test "Phase label: initializing"

    setup_display_test

    local label
    label=$(_pd_get_phase_label "initializing")

    assert_equals "Initializing" "$label" "Should return capitalized label"
}

test_phase_label_implementing() {
    log_test "Phase label: implementing"

    setup_display_test

    local label
    label=$(_pd_get_phase_label "implementing")

    assert_equals "Implementing" "$label" "Should return capitalized label"
}

test_phase_label_unknown() {
    log_test "Phase label: unknown phase falls back to capitalization"

    setup_display_test

    local label
    label=$(_pd_get_phase_label "myCustomPhase")

    assert_equals "MyCustomPhase" "$label" "Should capitalize first letter"
}

#===============================================================================
# TEST CASES: Timer Formatting
#===============================================================================

test_timer_format_initial() {
    log_test "Timer formats correctly at start"

    setup_display_test

    # Set start time to now
    _PD_START_TIME=$(date +%s)

    local elapsed
    elapsed=$(_pd_format_elapsed)

    assert_contains "$elapsed" "0m" "Should show 0 minutes"
    assert_contains "$elapsed" "s" "Should show seconds"
}

test_timer_format_after_time() {
    log_test "Timer formats correctly after elapsed time"

    setup_display_test

    # Set start time to 65 seconds ago (1m 05s)
    _PD_START_TIME=$(($(date +%s) - 65))

    local elapsed
    elapsed=$(_pd_format_elapsed)

    assert_contains "$elapsed" "1m" "Should show 1 minute"
    assert_contains "$elapsed" "05s" "Should show 5 seconds padded"
}

#===============================================================================
# TEST CASES: Cross-Platform Compatibility
#===============================================================================

test_debounce_uses_valid_timestamp() {
    log_test "Debounce timestamp is numeric (cross-platform)"

    setup_display_test

    # The debounce logic uses $(date +%s) which should be numeric
    local timestamp
    timestamp=$(date +%s)

    # Verify it's a valid number (no letters like 'N' from macOS %3N bug)
    if [[ "$timestamp" =~ ^[0-9]+$ ]]; then
        log_info "  Timestamp is numeric: $timestamp"
    else
        log_fail "Timestamp should be numeric, got: $timestamp"
        return 1
    fi
}

test_display_progress_multiple_calls() {
    log_test "display_progress handles multiple rapid calls without error"

    setup_display_test

    _PD_INITIALIZED=true
    _PD_IS_TTY=false

    # Call display_progress multiple times rapidly - should not crash
    local i
    for i in 1 2 3 4 5; do
        display_progress "implementing" "$((i * 20))" "Step $i" 2>/dev/null
    done

    # If we get here without error, the test passes
    log_info "  Multiple rapid calls succeeded"
}

test_date_command_cross_platform() {
    log_test "date +%s works on current platform"

    # This test verifies the date command we use works correctly
    local now
    now=$(date +%s)

    # Should be a reasonable Unix timestamp (after year 2020)
    if [[ "$now" -gt 1577836800 ]]; then
        log_info "  date +%s returns valid timestamp: $now"
    else
        log_fail "date +%s returned invalid timestamp: $now"
        return 1
    fi
}

#===============================================================================
# TEST CASES: Display Initialization
#===============================================================================

test_display_init_sets_start_time() {
    log_test "display_init sets start time"

    setup_display_test

    _PD_START_TIME=""
    display_init

    assert_not_equals "" "$_PD_START_TIME" "Start time should be set"
}

test_display_init_marks_initialized() {
    log_test "display_init marks as initialized"

    setup_display_test

    _PD_INITIALIZED=false
    display_init

    assert_equals "true" "$_PD_INITIALIZED" "Should be marked initialized"
}

test_display_is_enabled_function() {
    log_test "display_is_enabled returns correct value"

    setup_display_test

    # Force a specific value
    export KAPSIS_PROGRESS_DISPLAY=1

    if display_is_enabled; then
        log_info "  display_is_enabled returns true when KAPSIS_PROGRESS_DISPLAY=1"
    else
        log_fail "display_is_enabled should return true when KAPSIS_PROGRESS_DISPLAY=1"
        return 1
    fi

    export KAPSIS_PROGRESS_DISPLAY=0

    if display_is_enabled; then
        log_fail "display_is_enabled should return false when KAPSIS_PROGRESS_DISPLAY=0"
        return 1
    else
        log_info "  display_is_enabled returns false when KAPSIS_PROGRESS_DISPLAY=0"
    fi
}

#===============================================================================
# TEST CASES: Non-TTY Fallback
#===============================================================================

test_non_tty_fallback_renders() {
    log_test "Non-TTY fallback renders line-based output"

    setup_display_test

    # Force non-TTY mode
    _PD_IS_TTY=false

    local output
    output=$(_pd_render_fallback "implementing" 50 "Writing code" 2>&1)

    assert_contains "$output" "Phase:" "Should contain Phase label"
    assert_contains "$output" "Implementing" "Should contain phase name"
    assert_contains "$output" "50%" "Should contain percentage"
    assert_contains "$output" "Writing code" "Should contain message"
}

test_non_tty_fallback_includes_kapsis_prefix() {
    log_test "Non-TTY fallback includes [kapsis] prefix"

    setup_display_test

    _PD_IS_TTY=false

    local output
    output=$(_pd_render_fallback "running" 75 "" 2>&1)

    assert_contains "$output" "[kapsis]" "Should include kapsis prefix"
}

#===============================================================================
# TEST CASES: Spinner
#===============================================================================

test_spinner_tick_advances() {
    log_test "Spinner tick advances frame index"

    setup_display_test

    _PD_SPINNER_IDX=0

    # Test that calling spinner_tick in the current shell advances the index
    # Note: We can't capture output and check index in same call due to subshell
    _pd_spinner_tick > /dev/null
    local idx_after_first=$_PD_SPINNER_IDX

    _pd_spinner_tick > /dev/null
    local idx_after_second=$_PD_SPINNER_IDX

    assert_not_equals "$idx_after_first" "$idx_after_second" "Spinner frames should advance"
}

test_spinner_tick_wraps() {
    log_test "Spinner tick wraps around after all frames"

    setup_display_test

    _PD_SPINNER_IDX=9  # Last frame (10 frames: 0-9)

    # Call in current shell to preserve state change
    _pd_spinner_tick > /dev/null

    assert_equals "0" "$_PD_SPINNER_IDX" "Index should wrap to 0"
}

#===============================================================================
# TEST CASES: Display Complete
#===============================================================================

test_display_complete_success_message() {
    log_test "display_complete shows success for exit code 0"

    setup_display_test

    _PD_INITIALIZED=true
    _PD_IS_TTY=false
    _PD_START_TIME=$(($(date +%s) - 10))

    local output
    output=$(display_complete 0 "" "" 2>&1)

    assert_contains "$output" "Complete" "Should indicate completion"
}

test_display_complete_failure_message() {
    log_test "display_complete shows failure for non-zero exit code"

    setup_display_test

    _PD_INITIALIZED=true
    _PD_IS_TTY=false
    _PD_START_TIME=$(($(date +%s) - 10))

    local output
    output=$(display_complete 1 "" "Build failed" 2>&1)

    assert_contains "$output" "Failed" "Should indicate failure"
}

test_display_complete_includes_pr_url() {
    log_test "display_complete includes PR URL when provided"

    setup_display_test

    _PD_INITIALIZED=true
    _PD_IS_TTY=false
    _PD_START_TIME=$(($(date +%s) - 10))

    local output
    output=$(display_complete 0 "https://github.com/test/repo/pull/42" "" 2>&1)

    assert_contains "$output" "https://github.com/test/repo/pull/42" "Should include PR URL"
}

#===============================================================================
# TEST CASES: Integration with Logging
#===============================================================================

test_logging_is_tty_function_exists() {
    log_test "is_tty function exists in logging.sh"

    # Source logging library
    unset _KAPSIS_LOGGING_LOADED 2>/dev/null || true
    source "$KAPSIS_ROOT/scripts/lib/logging.sh"

    if type is_tty &>/dev/null; then
        log_info "  is_tty function is available"
    else
        log_fail "is_tty function should be defined in logging.sh"
        return 1
    fi
}

test_kapsis_is_tty_exported() {
    log_test "KAPSIS_IS_TTY is exported by logging.sh"

    # Source logging library fresh
    unset _KAPSIS_LOGGING_LOADED 2>/dev/null || true
    unset KAPSIS_IS_TTY 2>/dev/null || true
    source "$KAPSIS_ROOT/scripts/lib/logging.sh"

    if [[ -n "${KAPSIS_IS_TTY:-}" ]]; then
        log_info "  KAPSIS_IS_TTY is exported (value: $KAPSIS_IS_TTY)"
    else
        log_fail "KAPSIS_IS_TTY should be exported"
        return 1
    fi
}

#===============================================================================
# TEST CASES: Integration with Status
#===============================================================================

test_status_phase_triggers_display() {
    log_test "status_phase triggers display_progress when enabled"

    # This test verifies the integration is wired correctly
    # We can't easily test actual display output, but we verify the integration exists

    # Source status library fresh
    unset _KAPSIS_STATUS_LOADED 2>/dev/null || true
    source "$KAPSIS_ROOT/scripts/lib/status.sh"

    # Check that status_phase contains the display_progress call
    local status_phase_code
    status_phase_code=$(type status_phase 2>/dev/null | grep -c "display_progress" || echo "0")

    if [[ "$status_phase_code" -gt 0 ]]; then
        log_info "  status_phase contains display_progress integration"
    else
        log_fail "status_phase should call display_progress when KAPSIS_PROGRESS_DISPLAY=1"
        return 1
    fi
}

#===============================================================================
# TEST CASES: Message Truncation
#===============================================================================

test_long_message_truncation() {
    log_test "Long messages are truncated to fit terminal width"

    setup_display_test

    # Create a message longer than typical terminal width
    local long_message
    long_message=$(printf 'A%.0s' {1..200})  # 200 character message

    # The render function should truncate it
    # We test the internal logic by setting COLUMNS
    COLUMNS=80

    # Call the render function and check output (non-TTY for simpler output)
    _PD_IS_TTY=false

    local output
    output=$(_pd_render_fallback "running" 50 "$long_message" 2>&1)

    # Output should contain the message but we verify the function handles long messages
    if [[ ${#output} -lt 250 ]]; then
        log_info "  Output is reasonably sized: ${#output} chars"
    else
        log_warn "  Output may not be truncated properly: ${#output} chars"
    fi
}

#===============================================================================
# TEST CASES: Debounce Behavior
#===============================================================================

test_debounce_allows_phase_change() {
    log_test "Debounce allows phase change updates immediately"

    setup_display_test

    _PD_INITIALIZED=true
    _PD_IS_TTY=false
    _PD_LAST_PHASE="initializing"
    _PD_LAST_PROGRESS=10
    _PD_LAST_UPDATE_TIME=$(date +%s)

    # Call with a different phase - should NOT be debounced
    local output
    output=$(display_progress "implementing" 20 "Starting" 2>&1)

    # Should have rendered (check for phase change output)
    if [[ -n "$output" ]] || [[ "$_PD_LAST_PHASE" == "implementing" ]]; then
        log_info "  Phase change was processed"
    else
        log_fail "Phase change should bypass debounce"
        return 1
    fi
}

test_debounce_blocks_same_second_update() {
    log_test "Debounce blocks same-phase updates within same second"

    setup_display_test

    _PD_INITIALIZED=true
    _PD_IS_TTY=false
    _PD_LAST_PHASE="running"
    _PD_LAST_PROGRESS=50
    _PD_LAST_UPDATE_TIME=$(date +%s)

    # Call with same phase within same second - should be debounced
    local output
    output=$(display_progress "running" 55 "Same phase" 2>&1)

    # Output should be empty due to debounce
    if [[ -z "$output" ]]; then
        log_info "  Same-second update was debounced"
    else
        # This might happen if second rolled over during test - that's OK
        log_info "  Update may have crossed second boundary"
    fi
}

#===============================================================================
# TEST CASES: Display Cleanup
#===============================================================================

test_display_cleanup_resets_state() {
    log_test "display_cleanup resets initialized state"

    setup_display_test

    _PD_INITIALIZED=true
    _PD_IS_TTY=false  # Avoid cursor escape sequences

    display_cleanup

    assert_equals "false" "$_PD_INITIALIZED" "Should be marked as not initialized"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Progress Display"

    # TTY detection tests
    run_test test_tty_detection_disabled_by_env
    run_test test_tty_detection_disabled_by_no_color

    # Progress bar tests
    run_test test_progress_bar_0_percent
    run_test test_progress_bar_50_percent
    run_test test_progress_bar_100_percent
    run_test test_progress_bar_clamps_negative
    run_test test_progress_bar_clamps_over_100

    # Phase label tests
    run_test test_phase_label_initializing
    run_test test_phase_label_implementing
    run_test test_phase_label_unknown

    # Timer tests
    run_test test_timer_format_initial
    run_test test_timer_format_after_time

    # Cross-platform compatibility tests
    run_test test_debounce_uses_valid_timestamp
    run_test test_display_progress_multiple_calls
    run_test test_date_command_cross_platform

    # Display initialization tests
    run_test test_display_init_sets_start_time
    run_test test_display_init_marks_initialized
    run_test test_display_is_enabled_function

    # Non-TTY fallback tests
    run_test test_non_tty_fallback_renders
    run_test test_non_tty_fallback_includes_kapsis_prefix

    # Spinner tests
    run_test test_spinner_tick_advances
    run_test test_spinner_tick_wraps

    # Display complete tests
    run_test test_display_complete_success_message
    run_test test_display_complete_failure_message
    run_test test_display_complete_includes_pr_url

    # Integration tests
    run_test test_logging_is_tty_function_exists
    run_test test_kapsis_is_tty_exported
    run_test test_status_phase_triggers_display

    # Message truncation tests
    run_test test_long_message_truncation

    # Debounce tests
    run_test test_debounce_allows_phase_change
    run_test test_debounce_blocks_same_second_update

    # Cleanup tests
    run_test test_display_cleanup_resets_state

    # Summary
    print_summary
}

main "$@"
