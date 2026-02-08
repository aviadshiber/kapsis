#!/usr/bin/env bash
#===============================================================================
# Test: Logging Library (logging.sh)
#
# Unit tests for scripts/lib/logging.sh - the comprehensive logging system.
#
# Tests verify:
#   - Log initialization with script name and session ID
#   - Log level filtering (DEBUG, INFO, WARN, ERROR)
#   - File and console output
#   - Log rotation when file exceeds max size
#   - Utility functions (timers, sections, variable logging)
#   - Double-sourcing protection
#   - Configuration via environment variables
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Test directory for log files
TEST_LOG_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_logging_tests() {
    TEST_LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-logging-test.XXXXXX")
    log_info "Test log directory: $TEST_LOG_DIR"

    # Reset logging state for each test run
    unset _KAPSIS_LOGGING_LOADED
    unset _KAPSIS_LOG_INITIALIZED
    unset _KAPSIS_LOG_SCRIPT_NAME
    unset _KAPSIS_LOG_SESSION_ID
    unset _KAPSIS_LOG_FILE_PATH
}

cleanup_logging_tests() {
    if [[ -n "$TEST_LOG_DIR" && -d "$TEST_LOG_DIR" ]]; then
        rm -rf "$TEST_LOG_DIR"
    fi

    # Clean up any global state
    unset _KAPSIS_LOGGING_LOADED
    unset _KAPSIS_LOG_INITIALIZED
    unset _KAPSIS_LOG_SCRIPT_NAME
    unset _KAPSIS_LOG_SESSION_ID
    unset _KAPSIS_LOG_FILE_PATH
}

# Helper to source logging in a clean subshell with custom config
run_logging_test() {
    local test_script="$1"

    (
        # Reset all logging state
        unset _KAPSIS_LOGGING_LOADED
        unset _KAPSIS_LOG_INITIALIZED
        unset _KAPSIS_LOG_SCRIPT_NAME
        unset _KAPSIS_LOG_SESSION_ID
        unset _KAPSIS_LOG_FILE_PATH

        # Set test-specific configuration
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"  # Suppress console output in tests

        # Source the logging library fresh
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"

        # Run the test script
        eval "$test_script"
    )
}

#===============================================================================
# INITIALIZATION TESTS
#===============================================================================

test_log_init_creates_session() {
    log_test "log_init: creates session ID"

    local result
    result=$(run_logging_test '
        log_init "test-script"
        log_get_session
    ')

    assert_matches "$result" "^[0-9]{8}-[0-9]{6}-[0-9]+$" "Session ID should match timestamp-PID format"
}

test_log_init_uses_script_name() {
    log_test "log_init: uses provided script name"

    local log_file="$TEST_LOG_DIR/kapsis-my-test-script.log"

    run_logging_test '
        log_init "my-test-script"
        log_info "Test message"
    '

    assert_file_exists "$log_file" "Log file should be created with script name"
    assert_file_contains "$log_file" "[my-test-script]" "Log should contain script name prefix"
}

test_log_init_custom_session_id() {
    log_test "log_init: accepts custom session ID"

    local result
    result=$(run_logging_test '
        log_init "test-script" "my-custom-session-123"
        log_get_session
    ')

    assert_equals "my-custom-session-123" "$result" "Should use custom session ID"
}

test_log_init_creates_log_directory() {
    log_test "log_init: creates log directory if missing"

    local new_log_dir="$TEST_LOG_DIR/subdir/nested"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$new_log_dir"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "test-script"
        log_info "Test message"
    )

    assert_dir_exists "$new_log_dir" "Log directory should be created"
}

test_log_get_file_returns_path() {
    log_test "log_get_file: returns correct log file path"

    local expected_file="$TEST_LOG_DIR/kapsis-file-test.log"

    local result
    result=$(run_logging_test '
        log_init "file-test"
        log_get_file
    ')

    assert_equals "$expected_file" "$result" "Should return correct log file path"
}

#===============================================================================
# LOG LEVEL TESTS
#===============================================================================

test_log_level_info_filters_debug() {
    log_test "Log level INFO: filters out DEBUG messages"

    local log_file="$TEST_LOG_DIR/kapsis-level-test.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="INFO"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "level-test"
        log_debug "This should not appear"
        log_info "This should appear"
    )

    assert_file_not_contains "$log_file" "This should not appear" "DEBUG message should be filtered at INFO level"
    assert_file_contains "$log_file" "This should appear" "INFO message should appear at INFO level"
}

test_log_level_debug_shows_all() {
    log_test "Log level DEBUG: shows all messages"

    local log_file="$TEST_LOG_DIR/kapsis-debug-all.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "debug-all"
        log_debug "Debug message"
        log_info "Info message"
        log_warn "Warn message"
        log_error "Error message"
    )

    assert_file_contains "$log_file" "Debug message" "DEBUG should appear at DEBUG level"
    assert_file_contains "$log_file" "Info message" "INFO should appear at DEBUG level"
    assert_file_contains "$log_file" "Warn message" "WARN should appear at DEBUG level"
    assert_file_contains "$log_file" "Error message" "ERROR should appear at DEBUG level"
}

test_log_level_error_filters_lower() {
    log_test "Log level ERROR: filters INFO and WARN"

    local log_file="$TEST_LOG_DIR/kapsis-error-only.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="ERROR"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "error-only"
        log_info "Info filtered"
        log_warn "Warn filtered"
        log_error "Error appears"
    )

    assert_file_not_contains "$log_file" "Info filtered" "INFO should be filtered at ERROR level"
    assert_file_not_contains "$log_file" "Warn filtered" "WARN should be filtered at ERROR level"
    assert_file_contains "$log_file" "Error appears" "ERROR should appear at ERROR level"
}

test_kapsis_debug_enables_debug_level() {
    log_test "KAPSIS_DEBUG: enables DEBUG log level"

    local log_file="$TEST_LOG_DIR/kapsis-env-debug.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_DEBUG="1"  # This should enable DEBUG level
        export KAPSIS_LOG_LEVEL="INFO"  # This should be overridden
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "env-debug"
        log_debug "Debug via KAPSIS_DEBUG"
    )

    assert_file_contains "$log_file" "Debug via KAPSIS_DEBUG" "KAPSIS_DEBUG should enable DEBUG level"
}

#===============================================================================
# LOG OUTPUT TESTS
#===============================================================================

test_log_file_contains_timestamp() {
    log_test "Log file: contains timestamps"

    local log_file="$TEST_LOG_DIR/kapsis-timestamp.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_TIMESTAMPS="true"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "timestamp"
        log_info "Timestamped message"
    )

    # Timestamp format: [YYYY-MM-DD HH:MM:SS]
    local content
    content=$(cat "$log_file")
    assert_matches "$content" "\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]" \
        "Log should contain timestamp"
}

test_log_file_contains_level_tag() {
    log_test "Log file: contains level tags"

    local log_file="$TEST_LOG_DIR/kapsis-levels.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "levels"
        log_debug "D"
        log_info "I"
        log_warn "W"
        log_error "E"
    )

    assert_file_contains "$log_file" "[DEBUG]" "Should contain DEBUG level tag"
    assert_file_contains "$log_file" "[INFO]" "Should contain INFO level tag"
    assert_file_contains "$log_file" "[WARN]" "Should contain WARN level tag"
    assert_file_contains "$log_file" "[ERROR]" "Should contain ERROR level tag"
}

test_log_file_contains_context() {
    log_test "Log file: contains function context"

    local log_file="$TEST_LOG_DIR/kapsis-context.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "context"

        my_test_function() {
            log_info "Inside function"
        }
        my_test_function
    )

    # Context format: [function:line]
    assert_file_contains "$log_file" "[my_test_function:" "Should contain function name in context"
}

test_log_to_file_disabled() {
    log_test "KAPSIS_LOG_TO_FILE=false: does not write to file"

    local log_file="$TEST_LOG_DIR/kapsis-no-file.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_TO_FILE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "no-file"
        log_info "This should not be written"
    )

    assert_file_not_exists "$log_file" "Log file should not be created when TO_FILE=false"
}

#===============================================================================
# LOG ROTATION TESTS
#===============================================================================

test_log_rotation_triggers_on_size() {
    log_test "Log rotation: triggers when file exceeds max size"

    local log_file="$TEST_LOG_DIR/kapsis-rotation.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_MAX_SIZE_MB="0"  # 0 MB = rotate immediately (any content triggers)
        export KAPSIS_LOG_MAX_FILES="3"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "rotation"

        # Write enough to trigger rotation
        # Create initial content that exceeds 0 bytes
        echo "Initial large content to exceed limit" >> "$log_file"

        # This should trigger rotation
        log_info "After rotation trigger"
    )

    # Check that rotation happened
    assert_file_exists "${log_file}.1" "Rotated log file .1 should exist"
}

test_log_rotation_shifts_files() {
    log_test "Log rotation: shifts existing backup files"

    local log_file="$TEST_LOG_DIR/kapsis-shift.log"

    # Pre-create some backup files
    echo "backup1" > "${log_file}.1"
    echo "backup2" > "${log_file}.2"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_MAX_SIZE_MB="0"
        export KAPSIS_LOG_MAX_FILES="5"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "shift"

        # Create content to trigger rotation
        echo "content to rotate" >> "$log_file"
        log_info "Trigger rotation"
    )

    # Original .1 should be shifted to .2
    assert_file_contains "${log_file}.2" "backup1" "Original .1 should shift to .2"
    # Original .2 should be shifted to .3
    assert_file_contains "${log_file}.3" "backup2" "Original .2 should shift to .3"
}

#===============================================================================
# UTILITY FUNCTION TESTS
#===============================================================================

test_log_section_formats_header() {
    log_test "log_section: formats section header"

    local log_file="$TEST_LOG_DIR/kapsis-section.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "section"
        log_section "My Section Title"
    )

    # Note: Can't use assert_file_contains for dashes (grep interprets as options)
    # Instead verify section title appears and file has expected line count
    assert_file_contains "$log_file" "My Section Title" "Should contain section title"
    assert_file_contains "$log_file" "log_section:" "Should contain section context"

    # Verify separator lines exist by checking file structure
    local separator_count
    separator_count=$(grep -c "log_section:" "$log_file" || echo 0)
    assert_equals "3" "$separator_count" "Should have 3 log_section entries (2 separators + 1 title)"
}

test_log_var_outputs_variable() {
    log_test "log_var: outputs variable name and value"

    local log_file="$TEST_LOG_DIR/kapsis-var.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "var"

        # shellcheck disable=SC2034  # Variable used by log_var
        MY_TEST_VAR="hello world"
        log_var MY_TEST_VAR
    )

    assert_file_contains "$log_file" "MY_TEST_VAR=hello world" "Should contain variable name=value"
}

test_log_var_unset_variable() {
    log_test "log_var: handles unset variables"

    local log_file="$TEST_LOG_DIR/kapsis-unset.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "unset"

        unset UNSET_VAR
        log_var UNSET_VAR
    )

    assert_file_contains "$log_file" "UNSET_VAR=<unset>" "Should show <unset> for undefined variables"
}

test_log_timer() {
    log_test "log_timer: measures elapsed time"

    local log_file="$TEST_LOG_DIR/kapsis-timer.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "timer"

        # Note: Timer names must be valid bash variable names (no hyphens)
        log_timer_start "test_timer"
        sleep 1
        log_timer_end "test_timer"
    )

    assert_file_contains "$log_file" "Timer [test_timer]:" "Should contain timer name"
    assert_file_contains "$log_file" "elapsed" "Should contain elapsed text"
}

test_log_timer_rejects_invalid_names() {
    log_test "log_timer: rejects invalid timer names (security)"

    local exit_code

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "timer-security"

        # Valid names should succeed
        log_timer_start "valid_name" || exit 1
        log_timer_start "CamelCase123" || exit 1

        # Invalid names should fail (security: prevents eval injection)
        log_timer_start "invalid;name" 2>/dev/null && exit 2
        log_timer_start "with spaces" 2>/dev/null && exit 3
        log_timer_start "hyphen-name" 2>/dev/null && exit 4
        log_timer_start 'foo$(rm -rf /)' 2>/dev/null && exit 5

        exit 0
    )
    exit_code=$?

    case $exit_code in
        0) log_pass "Timer name validation works correctly" ;;
        1) log_fail "Valid timer name was rejected"; return 1 ;;
        2) log_fail "Timer name with semicolon should be rejected"; return 1 ;;
        3) log_fail "Timer name with spaces should be rejected"; return 1 ;;
        4) log_fail "Timer name with hyphens should be rejected"; return 1 ;;
        5) log_fail "Timer name with command substitution should be rejected"; return 1 ;;
        *) log_fail "Unexpected exit code: $exit_code"; return 1 ;;
    esac
}

test_log_enter_exit() {
    log_test "log_enter/log_exit: logs function entry and exit"

    local log_file="$TEST_LOG_DIR/kapsis-enter-exit.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "enter-exit"

        my_logged_function() {
            log_enter "arg1" "arg2"
            log_exit 0
        }
        my_logged_function
    )

    assert_file_contains "$log_file" ">>> Entering my_logged_function()" "Should log function entry"
    assert_file_contains "$log_file" "arg1" "Should log function arguments"
    assert_file_contains "$log_file" "<<< Exiting my_logged_function()" "Should log function exit"
}

test_log_cmd_executes_command() {
    log_test "log_cmd: executes command and logs it"

    local log_file="$TEST_LOG_DIR/kapsis-cmd.log"
    local output_file="$TEST_LOG_DIR/cmd-output.txt"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "cmd"

        log_cmd echo "command output" > "$output_file"
    )

    assert_file_contains "$log_file" "Executing: echo command output" "Should log the command"
    assert_file_contains "$output_file" "command output" "Command should execute and produce output"
}

test_log_finalize() {
    log_test "log_finalize: logs completion with exit code"

    local log_file="$TEST_LOG_DIR/kapsis-finalize.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "finalize"
        log_finalize 42
    )

    assert_file_contains "$log_file" "Script completed with exit code: 42" "Should log exit code"
}

#===============================================================================
# CONFIGURATION TESTS
#===============================================================================

test_kapsis_log_file_override() {
    log_test "KAPSIS_LOG_FILE: overrides log file path"

    local custom_file="$TEST_LOG_DIR/my-custom-log.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_FILE="$custom_file"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "custom-file"
        log_info "Custom file message"
    )

    assert_file_exists "$custom_file" "Custom log file should be created"
    assert_file_contains "$custom_file" "Custom file message" "Message should be in custom file"
}

test_timestamps_disabled() {
    log_test "KAPSIS_LOG_TIMESTAMPS=false: disables timestamps"

    local log_file="$TEST_LOG_DIR/kapsis-no-ts.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_TIMESTAMPS="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "no-ts"
        log_info "No timestamp here"
    )

    # Get the INFO line for the test message
    local info_line
    info_line=$(grep "No timestamp here" "$log_file" || true)

    # Should NOT start with timestamp pattern
    if [[ "$info_line" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        _log_failure "Should not contain timestamp when disabled"
        return 1
    fi
    return 0
}

#===============================================================================
# DOUBLE-SOURCING PROTECTION
#===============================================================================

test_double_source_protection() {
    log_test "Double-sourcing: only loads once"

    local log_file="$TEST_LOG_DIR/kapsis-double.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "double"

        # Source again - should be no-op
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_info "After double source"
    )

    # Count "Logging initialized" lines - should be exactly 1
    local init_count
    init_count=$(grep -c "Logging initialized" "$log_file" || echo 0)

    assert_equals "1" "$init_count" "Should only initialize once despite double-sourcing"
}

#===============================================================================
# SUCCESS LOGGING TEST
#===============================================================================

test_log_success() {
    log_test "log_success: logs at INFO level with success indicator"

    local log_file="$TEST_LOG_DIR/kapsis-success.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "success"
        log_success "Operation completed"
    )

    assert_file_contains "$log_file" "Operation completed" "Success message should be logged"
    assert_file_contains "$log_file" "[INFO]" "Success should use INFO level in file"
}

#===============================================================================
# LEGACY COMPATIBILITY TESTS
#===============================================================================

test_legacy_log_functions() {
    log_test "Legacy functions: route through new logging system"

    local log_file="$TEST_LOG_DIR/kapsis-legacy.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "legacy"
        log_info_legacy "PREFIX" "Legacy info message"
        log_warn_legacy "PREFIX" "Legacy warn message"
    )

    assert_file_contains "$log_file" "[PREFIX] Legacy info message" "Legacy info should work"
    assert_file_contains "$log_file" "[PREFIX] Legacy warn message" "Legacy warn should work"
}

#===============================================================================
# SECRET SANITIZATION TESTS
#===============================================================================

test_sanitize_secrets_masks_env_vars() {
    log_test "sanitize_secrets: masks -e VAR=value format"

    local result
    result=$(run_logging_test '
        local input="podman run -e API_KEY=secret123 -e NORMAL_VAR=ok -e MY_TOKEN=abc"
        sanitize_secrets "$input"
    ')

    # Should mask API_KEY and MY_TOKEN but not NORMAL_VAR
    assert_contains "$result" "API_KEY=***MASKED***" "API_KEY should be masked"
    assert_contains "$result" "MY_TOKEN=***MASKED***" "MY_TOKEN should be masked"
    assert_contains "$result" "NORMAL_VAR=ok" "NORMAL_VAR should NOT be masked"
}

test_sanitize_secrets_masks_secret_patterns() {
    log_test "sanitize_secrets: masks various secret patterns"

    local patterns=(
        "-e MY_SECRET=hidden"
        "-e DB_PASSWORD=pass123"
        "-e CREDENTIALS_FILE=/path"
        "-e AUTH_TOKEN=xyz"
        "-e BEARER_TOKEN=abc"
        "-e PRIVATE_KEY=key"
    )

    for pattern in "${patterns[@]}"; do
        local result
        result=$(run_logging_test "
            sanitize_secrets '$pattern'
        ")

        # All of these should be masked
        if [[ "$result" == *"=***MASKED***"* ]]; then
            log_pass "Pattern '$pattern' was correctly masked"
        else
            log_fail "Pattern '$pattern' should be masked but got: $result"
            return 1
        fi
    done
}

test_sanitize_secrets_case_insensitive() {
    log_test "sanitize_secrets: case insensitive matching"

    local result
    result=$(run_logging_test '
        local input="-e api_key=lower -e API_KEY=upper -e Api_Key=mixed"
        sanitize_secrets "$input"
    ')

    # Count masked values - should be 3
    local masked_count
    masked_count=$(echo "$result" | grep -o '=\*\*\*MASKED\*\*\*' | wc -l | tr -d ' ')

    assert_equals "3" "$masked_count" "All case variants should be masked"
}

test_sanitize_secrets_preserves_safe_vars() {
    log_test "sanitize_secrets: preserves non-sensitive variables"

    local result
    result=$(run_logging_test '
        local input="-e HOME=/home/user -e PATH=/bin -e KAPSIS_PROJECT=myproject"
        sanitize_secrets "$input"
    ')

    assert_contains "$result" "HOME=/home/user" "HOME should NOT be masked"
    assert_contains "$result" "PATH=/bin" "PATH should NOT be masked"
    assert_contains "$result" "KAPSIS_PROJECT=myproject" "KAPSIS_PROJECT should NOT be masked"
}

test_is_secret_var_name() {
    log_test "is_secret_var_name: correctly identifies secret names"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "secret-name-test"

        # Should return true (0) for secret names
        is_secret_var_name "API_KEY" || exit 1
        is_secret_var_name "MY_TOKEN" || exit 2
        is_secret_var_name "DB_PASSWORD" || exit 3
        is_secret_var_name "AUTH_SECRET" || exit 4

        # Should return false (1) for safe names
        is_secret_var_name "HOME" && exit 5
        is_secret_var_name "PATH" && exit 6
        is_secret_var_name "KAPSIS_PROJECT" && exit 7

        exit 0
    )
    local result=$?

    case $result in
        0) log_pass "is_secret_var_name works correctly" ;;
        1) log_fail "API_KEY should be detected as secret"; return 1 ;;
        2) log_fail "MY_TOKEN should be detected as secret"; return 1 ;;
        3) log_fail "DB_PASSWORD should be detected as secret"; return 1 ;;
        4) log_fail "AUTH_SECRET should be detected as secret"; return 1 ;;
        5) log_fail "HOME should NOT be detected as secret"; return 1 ;;
        6) log_fail "PATH should NOT be detected as secret"; return 1 ;;
        7) log_fail "KAPSIS_PROJECT should NOT be detected as secret"; return 1 ;;
        *) log_fail "Unexpected exit code: $result"; return 1 ;;
    esac
}

test_sanitize_var_value_masks_secrets() {
    log_test "sanitize_var_value: masks values for secret variable names"

    local result
    result=$(run_logging_test '
        echo "$(sanitize_var_value "API_KEY" "super-secret-value")"
    ')

    assert_equals "***MASKED***" "$result" "Secret variable value should be masked"
}

test_sanitize_var_value_preserves_safe() {
    log_test "sanitize_var_value: preserves values for non-secret names"

    local result
    result=$(run_logging_test '
        echo "$(sanitize_var_value "HOME" "/home/user")"
    ')

    assert_equals "/home/user" "$result" "Non-secret variable value should NOT be masked"
}

test_log_var_masks_secrets() {
    log_test "log_var: masks values of variables with secret names"

    local log_file="$TEST_LOG_DIR/kapsis-var-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "var-secret"

        # shellcheck disable=SC2034  # Variable used by log_var
        API_KEY="super-secret-value"
        log_var API_KEY
    )

    assert_file_contains "$log_file" "API_KEY=***MASKED***" "Secret variable should be masked in log_var"
    assert_file_not_contains "$log_file" "super-secret-value" "Actual secret value should NOT appear"
}

test_log_cmd_sanitizes_command() {
    log_test "log_cmd: sanitizes secrets in logged commands"

    local log_file="$TEST_LOG_DIR/kapsis-cmd-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "cmd-secret"

        # Run a command that includes what looks like a secret
        log_cmd echo "-e API_KEY=secret123 test" >/dev/null 2>&1 || true
    )

    assert_file_not_contains "$log_file" "secret123" "Secret value should NOT appear in command log"
    assert_file_contains "$log_file" "API_KEY=***MASKED***" "Secret should be masked in command log"
}

test_log_enter_sanitizes_args() {
    log_test "log_enter: sanitizes secrets in function arguments"

    local log_file="$TEST_LOG_DIR/kapsis-enter-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "enter-secret"

        my_secret_function() {
            log_enter "-e API_TOKEN=mysecret123"
        }
        my_secret_function
    )

    assert_file_not_contains "$log_file" "mysecret123" "Secret should NOT appear in log_enter"
    assert_file_contains "$log_file" "API_TOKEN=***MASKED***" "Secret should be masked in log_enter"
}

test_log_info_sanitizes_secrets() {
    log_test "log_info: sanitizes secrets in messages"

    local log_file="$TEST_LOG_DIR/kapsis-info-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "info-secret"

        log_info "Setting API_KEY=supersecret123 for user"
    )

    assert_file_not_contains "$log_file" "supersecret123" "Secret value should NOT appear in log_info"
    assert_file_contains "$log_file" "API_KEY=***MASKED***" "Secret should be masked in log_info"
}

test_log_warn_sanitizes_secrets() {
    log_test "log_warn: sanitizes secrets in messages"

    local log_file="$TEST_LOG_DIR/kapsis-warn-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "warn-secret"

        log_warn "Token expired: MY_TOKEN=abc123xyz"
    )

    assert_file_not_contains "$log_file" "abc123xyz" "Secret value should NOT appear in log_warn"
    assert_file_contains "$log_file" "MY_TOKEN=***MASKED***" "Secret should be masked in log_warn"
}

test_log_error_sanitizes_secrets() {
    log_test "log_error: sanitizes secrets in messages"

    local log_file="$TEST_LOG_DIR/kapsis-error-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "error-secret"

        log_error "Auth failed with DB_PASSWORD=mypassword123"
    )

    assert_file_not_contains "$log_file" "mypassword123" "Secret value should NOT appear in log_error"
    assert_file_contains "$log_file" "DB_PASSWORD=***MASKED***" "Secret should be masked in log_error"
}

test_log_success_sanitizes_secrets() {
    log_test "log_success: sanitizes secrets in messages"

    local log_file="$TEST_LOG_DIR/kapsis-success-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "success-secret"

        log_success "Connected with AUTH_SECRET=topsecret456"
    )

    assert_file_not_contains "$log_file" "topsecret456" "Secret value should NOT appear in log_success"
    assert_file_contains "$log_file" "AUTH_SECRET=***MASKED***" "Secret should be masked in log_success"
}

test_log_debug_sanitizes_secrets() {
    log_test "log_debug: sanitizes secrets in messages"

    local log_file="$TEST_LOG_DIR/kapsis-debug-secret.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        export KAPSIS_LOG_LEVEL="DEBUG"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "debug-secret"

        log_debug "Debug info: BEARER_TOKEN=secretbearer789"
    )

    assert_file_not_contains "$log_file" "secretbearer789" "Secret value should NOT appear in log_debug"
    assert_file_contains "$log_file" "BEARER_TOKEN=***MASKED***" "Secret should be masked in log_debug"
}

#===============================================================================
# LOG TAIL TEST
#===============================================================================

test_log_tail() {
    log_test "log_tail: returns last N lines"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "tail-test"

        # Write several log entries
        for i in {1..10}; do
            log_info "Line number $i"
        done

        # Get last 3 lines
        local tail_output
        tail_output=$(log_tail 3)

        # Should contain line 10 (last entry)
        echo "$tail_output" | grep -qF "Line number 10" || exit 1

        # Should NOT contain "Line number 1" (first entry) without also matching 10
        # Use word boundary to ensure we don't match 10, 11, etc.
        echo "$tail_output" | grep -q "Line number 1[^0-9]" && exit 1 || true
    )

    local result=$?
    assert_equals "0" "$result" "log_tail should return last N lines only"
}

#===============================================================================
# PER-INSTANCE LOGGING TESTS
#===============================================================================

test_log_reinit_with_agent_id() {
    log_test "log_reinit_with_agent_id: creates agent-specific log file"

    local agent_id="abc123"
    local expected_file="$TEST_LOG_DIR/kapsis-${agent_id}.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "launch-agent"
        log_info "Before reinit"
        log_reinit_with_agent_id "$agent_id"
        log_info "After reinit"
    )

    assert_file_exists "$expected_file" "Agent-specific log file should be created"
    assert_file_contains "$expected_file" "Log reinitialized for agent: $agent_id" \
        "Should log reinit message to new file"
    assert_file_contains "$expected_file" "After reinit" \
        "Messages after reinit should go to new file"
}

test_log_reinit_creates_symlink() {
    log_test "log_reinit_with_agent_id: creates latest symlink"

    local agent_id="def456"
    local symlink_path="$TEST_LOG_DIR/kapsis-latest.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "launch-agent"
        log_reinit_with_agent_id "$agent_id" "true"
    )

    assert_true "[[ -L '$symlink_path' ]]" "Latest symlink should exist"

    # Verify symlink points to correct file
    local target
    target=$(readlink "$symlink_path")
    assert_equals "kapsis-${agent_id}.log" "$target" "Symlink should point to agent log"
}

test_log_reinit_symlink_disabled() {
    log_test "log_reinit_with_agent_id: symlink can be disabled"

    # Clean any existing symlink first
    rm -f "$TEST_LOG_DIR/kapsis-latest.log"

    local agent_id="ghi789"
    local symlink_path="$TEST_LOG_DIR/kapsis-latest.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "launch-agent"
        log_reinit_with_agent_id "$agent_id" "false"
    )

    assert_false "[[ -L '$symlink_path' ]]" "Symlink should not exist when disabled"
}

test_log_reinit_prunes_old_logs() {
    log_test "log_reinit_with_agent_id: prunes old logs"

    # Create fake old log files with old modification times
    local old_log1="$TEST_LOG_DIR/kapsis-old111.log"
    local old_log2="$TEST_LOG_DIR/kapsis-old222.log"
    echo "old log 1" > "$old_log1"
    echo "old log 2" > "$old_log2"

    # Set modification time to 10 days ago
    # macOS uses different touch syntax than Linux
    if [[ "$(uname)" == "Darwin" ]]; then
        touch -t "$(date -v-10d +%Y%m%d%H%M.%S)" "$old_log1" "$old_log2"
    else
        touch -d "10 days ago" "$old_log1" "$old_log2"
    fi

    local agent_id="new333"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "launch-agent"
        log_reinit_with_agent_id "$agent_id" "true" "7"  # Prune logs older than 7 days
    )

    assert_file_not_exists "$old_log1" "Old log 1 should be pruned"
    assert_file_not_exists "$old_log2" "Old log 2 should be pruned"
    assert_file_exists "$TEST_LOG_DIR/kapsis-${agent_id}.log" "New log should still exist"
}

test_log_reinit_prune_disabled() {
    log_test "log_reinit_with_agent_id: prune can be disabled"

    # Create fake old log file
    local old_log="$TEST_LOG_DIR/kapsis-keepme.log"
    echo "should keep" > "$old_log"

    # Set modification time to 10 days ago
    if [[ "$(uname)" == "Darwin" ]]; then
        touch -t "$(date -v-10d +%Y%m%d%H%M.%S)" "$old_log"
    else
        touch -d "10 days ago" "$old_log"
    fi

    local agent_id="xyz999"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "launch-agent"
        log_reinit_with_agent_id "$agent_id" "true" "0"  # Disable pruning
    )

    assert_file_exists "$old_log" "Old log should NOT be pruned when disabled"
}

test_log_reinit_without_agent_id_warns() {
    log_test "log_reinit_with_agent_id: warns when called without agent ID"

    local log_file="$TEST_LOG_DIR/kapsis-reinit-warn.log"

    local result
    result=$(
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "reinit-warn"
        log_reinit_with_agent_id ""
        echo "exit_code=$?"
    )

    assert_contains "$result" "exit_code=1" "Should return error code when agent ID missing"
}

test_log_reinit_multiple_times() {
    log_test "log_reinit_with_agent_id: can be called multiple times"

    local agent_id1="agent1"
    local agent_id2="agent2"
    local log1="$TEST_LOG_DIR/kapsis-${agent_id1}.log"
    local log2="$TEST_LOG_DIR/kapsis-${agent_id2}.log"

    (
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "launch-agent"
        log_reinit_with_agent_id "$agent_id1"
        log_info "Message to agent1"
        log_reinit_with_agent_id "$agent_id2"
        log_info "Message to agent2"
    )

    assert_file_exists "$log1" "First agent log should exist"
    assert_file_exists "$log2" "Second agent log should exist"
    assert_file_contains "$log1" "Message to agent1" "First message in first log"
    assert_file_contains "$log2" "Message to agent2" "Second message in second log"
}

test_log_reinit_updates_log_get_file() {
    log_test "log_reinit_with_agent_id: updates log_get_file path"

    local agent_id="pathtest"
    local expected_path="$TEST_LOG_DIR/kapsis-${agent_id}.log"

    local result
    result=$(
        unset _KAPSIS_LOGGING_LOADED
        export KAPSIS_LOG_DIR="$TEST_LOG_DIR"
        export KAPSIS_LOG_CONSOLE="false"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh"
        log_init "launch-agent"
        log_reinit_with_agent_id "$agent_id"
        log_get_file
    )

    assert_equals "$expected_path" "$result" "log_get_file should return new path"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Logging Library (logging.sh)"

    # Setup
    setup_logging_tests

    # Ensure cleanup on exit
    trap cleanup_logging_tests EXIT

    # Initialization tests
    run_test test_log_init_creates_session
    run_test test_log_init_uses_script_name
    run_test test_log_init_custom_session_id
    run_test test_log_init_creates_log_directory
    run_test test_log_get_file_returns_path

    # Log level tests
    run_test test_log_level_info_filters_debug
    run_test test_log_level_debug_shows_all
    run_test test_log_level_error_filters_lower
    run_test test_kapsis_debug_enables_debug_level

    # Log output tests
    run_test test_log_file_contains_timestamp
    run_test test_log_file_contains_level_tag
    run_test test_log_file_contains_context
    run_test test_log_to_file_disabled

    # Log rotation tests
    run_test test_log_rotation_triggers_on_size
    run_test test_log_rotation_shifts_files

    # Utility function tests
    run_test test_log_section_formats_header
    run_test test_log_var_outputs_variable
    run_test test_log_var_unset_variable
    run_test test_log_timer
    run_test test_log_timer_rejects_invalid_names
    run_test test_log_enter_exit
    run_test test_log_cmd_executes_command
    run_test test_log_finalize

    # Configuration tests
    run_test test_kapsis_log_file_override
    run_test test_timestamps_disabled

    # Protection tests
    run_test test_double_source_protection

    # Success and legacy tests
    run_test test_log_success
    run_test test_legacy_log_functions

    # Tail test
    run_test test_log_tail

    # Secret sanitization tests
    run_test test_sanitize_secrets_masks_env_vars
    run_test test_sanitize_secrets_masks_secret_patterns
    run_test test_sanitize_secrets_case_insensitive
    run_test test_sanitize_secrets_preserves_safe_vars
    run_test test_is_secret_var_name
    run_test test_sanitize_var_value_masks_secrets
    run_test test_sanitize_var_value_preserves_safe
    run_test test_log_var_masks_secrets
    run_test test_log_cmd_sanitizes_command
    run_test test_log_enter_sanitizes_args
    run_test test_log_info_sanitizes_secrets
    run_test test_log_warn_sanitizes_secrets
    run_test test_log_error_sanitizes_secrets
    run_test test_log_success_sanitizes_secrets
    run_test test_log_debug_sanitizes_secrets

    # Per-instance logging tests
    run_test test_log_reinit_with_agent_id
    run_test test_log_reinit_creates_symlink
    run_test test_log_reinit_symlink_disabled
    run_test test_log_reinit_prunes_old_logs
    run_test test_log_reinit_prune_disabled
    run_test test_log_reinit_without_agent_id_warns
    run_test test_log_reinit_multiple_times
    run_test test_log_reinit_updates_log_get_file

    # Summary
    print_summary
}

main "$@"
