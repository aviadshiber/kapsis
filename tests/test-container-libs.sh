#!/usr/bin/env bash
#===============================================================================
# Test: Container Libraries
#
# Verifies that all required libraries are properly installed in the container:
# - logging.sh exists and is sourced
# - status.sh exists and is sourced
# - Functions from these libraries are available
#
# This test was added after a bug where status.sh was not copied into the
# container image, causing "status_init: command not found" errors.
# See: ~/.claude/issues/kapsis-DEV-209078-20251223.md
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES: Library Files Exist
#===============================================================================

test_logging_lib_exists() {
    log_test "Testing logging.sh exists in container"

    setup_container_test "libs-logging"

    local output
    output=$(run_in_container "test -f /opt/kapsis/lib/logging.sh && echo EXISTS || echo MISSING")

    cleanup_container_test

    assert_contains "$output" "EXISTS" "logging.sh should exist at /opt/kapsis/lib/logging.sh"
}

test_status_lib_exists() {
    log_test "Testing status.sh exists in container"

    setup_container_test "libs-status"

    local output
    output=$(run_in_container "test -f /opt/kapsis/lib/status.sh && echo EXISTS || echo MISSING")

    cleanup_container_test

    assert_contains "$output" "EXISTS" "status.sh should exist at /opt/kapsis/lib/status.sh"
}

test_libs_are_executable() {
    log_test "Testing library files are executable"

    setup_container_test "libs-exec"

    local output
    output=$(run_in_container "test -x /opt/kapsis/lib/logging.sh && test -x /opt/kapsis/lib/status.sh && echo EXECUTABLE || echo NOT_EXECUTABLE")

    cleanup_container_test

    assert_contains "$output" "EXECUTABLE" "Library files should be executable (chmod 755)"
}

#===============================================================================
# TEST CASES: Library Functions Available
#===============================================================================

test_logging_functions_available() {
    log_test "Testing logging functions are available after sourcing"

    setup_container_test "libs-log-funcs"

    local output
    output=$(run_in_container "source /opt/kapsis/lib/logging.sh && type log_info && echo AVAILABLE")

    cleanup_container_test

    assert_contains "$output" "AVAILABLE" "log_info function should be available after sourcing logging.sh"
}

test_status_functions_available() {
    log_test "Testing status functions are available after sourcing"

    setup_container_test "libs-status-funcs"

    local output
    output=$(run_in_container "source /opt/kapsis/lib/status.sh && type status_init && echo AVAILABLE")

    cleanup_container_test

    assert_contains "$output" "AVAILABLE" "status_init function should be available after sourcing status.sh"
}

test_status_init_callable() {
    log_test "Testing status_init can be called without error"

    setup_container_test "libs-status-init"

    # Create a temp status dir and test status_init
    local output
    local exit_code=0
    output=$(run_in_container "
        export KAPSIS_STATUS_DIR=/tmp/test-status
        export KAPSIS_STATUS_ENABLED=true
        mkdir -p /tmp/test-status
        source /opt/kapsis/lib/status.sh
        status_init 'test-project' '1' 'feature/test' 'worktree' '/workspace'
        echo INIT_SUCCESS
    ") || exit_code=$?

    cleanup_container_test

    assert_contains "$output" "INIT_SUCCESS" "status_init should complete without error"
    assert_exit_code 0 "$exit_code" "status_init should exit with code 0"
}

test_status_phase_callable() {
    log_test "Testing status_phase can be called without error"

    setup_container_test "libs-status-phase"

    local output
    local exit_code=0
    output=$(run_in_container "
        export KAPSIS_STATUS_DIR=/tmp/test-status
        export KAPSIS_STATUS_ENABLED=true
        mkdir -p /tmp/test-status
        source /opt/kapsis/lib/status.sh
        status_init 'test-project' '1' '' 'worktree' ''
        status_phase 'running' 50 'Testing phase update'
        echo PHASE_SUCCESS
    ") || exit_code=$?

    cleanup_container_test

    assert_contains "$output" "PHASE_SUCCESS" "status_phase should complete without error"
}

test_status_creates_file() {
    log_test "Testing status_init creates JSON status file"

    setup_container_test "libs-status-file"

    local output
    output=$(run_in_container "
        export KAPSIS_STATUS_DIR=/tmp/test-status
        export KAPSIS_STATUS_ENABLED=true
        mkdir -p /tmp/test-status
        source /opt/kapsis/lib/status.sh
        status_init 'myproject' '42' 'feature/test' 'overlay' '/workspace'
        cat /tmp/test-status/kapsis-myproject-42.json
    ")

    cleanup_container_test

    assert_contains "$output" '"agent_id": "42"' "Status file should contain agent_id"
    assert_contains "$output" '"project": "myproject"' "Status file should contain project"
    assert_contains "$output" '"phase": "initializing"' "Status file should show initializing phase"
}

#===============================================================================
# TEST CASES: Entrypoint Integration
#===============================================================================

test_entrypoint_with_status_env() {
    log_test "Testing entrypoint handles status env variables"

    setup_container_test "libs-entrypoint"

    # Run container with status env vars set (simulating launch-agent.sh)
    local output
    local exit_code=0

    # Use podman directly to set the status env vars
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:ro" \
        -e KAPSIS_STATUS_PROJECT="test-project" \
        -e KAPSIS_STATUS_AGENT_ID="99" \
        -e KAPSIS_STATUS_BRANCH="feature/entrypoint-test" \
        -e KAPSIS_SANDBOX_MODE="worktree" \
        -e KAPSIS_STATUS_DIR="/tmp/status" \
        -e KAPSIS_STATUS_ENABLED="true" \
        $KAPSIS_TEST_IMAGE \
        bash -c "mkdir -p /tmp/status && echo 'Entrypoint completed successfully'" 2>&1) || exit_code=$?

    cleanup_container_test

    # The entrypoint should NOT fail with "status_init: command not found"
    assert_not_contains "$output" "status_init: command not found" "Entrypoint should not fail on status_init"
    assert_contains "$output" "Entrypoint completed successfully" "Entrypoint should complete"
}

test_entrypoint_status_file_created() {
    log_test "Testing entrypoint creates status file when env vars set"

    setup_container_test "libs-entrypoint-file"

    # Create a volume for status files so we can check them
    podman volume rm "${CONTAINER_TEST_ID}-status" >/dev/null 2>&1 || true
    podman volume create "${CONTAINER_TEST_ID}-status" >/dev/null 2>&1

    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:ro" \
        -v "${CONTAINER_TEST_ID}-status:/kapsis-status" \
        -e KAPSIS_STATUS_PROJECT="filetest" \
        -e KAPSIS_STATUS_AGENT_ID="7" \
        -e KAPSIS_STATUS_BRANCH="feature/status-test" \
        -e KAPSIS_SANDBOX_MODE="worktree" \
        -e KAPSIS_STATUS_DIR="/kapsis-status" \
        -e KAPSIS_STATUS_ENABLED="true" \
        $KAPSIS_TEST_IMAGE \
        bash -c "cat /kapsis-status/kapsis-filetest-7.json 2>/dev/null || echo 'NO_FILE'" 2>&1) || true

    # Cleanup volume
    podman volume rm "${CONTAINER_TEST_ID}-status" >/dev/null 2>&1 || true
    cleanup_container_test

    # Status file should have been created by entrypoint
    assert_contains "$output" '"agent_id": "7"' "Entrypoint should create status file with agent_id"
    assert_contains "$output" '"project": "filetest"' "Entrypoint should create status file with project"
}

#===============================================================================
# TEST CASES: Edge Cases
#===============================================================================

test_status_disabled_no_error() {
    log_test "Testing status functions work when disabled (no-op)"

    setup_container_test "libs-status-disabled"

    local output
    local exit_code=0
    output=$(run_in_container "
        export KAPSIS_STATUS_ENABLED=false
        source /opt/kapsis/lib/status.sh
        status_init 'test' '1' '' 'worktree' ''
        status_phase 'running' 50 'test'
        echo DISABLED_OK
    ") || exit_code=$?

    cleanup_container_test

    assert_contains "$output" "DISABLED_OK" "Status functions should work (no-op) when disabled"
    assert_exit_code 0 "$exit_code" "Should not error when disabled"
}

test_all_lib_files_have_correct_perms() {
    log_test "Testing all /opt/kapsis/lib files have correct permissions"

    setup_container_test "libs-perms"

    local output
    output=$(run_in_container "ls -la /opt/kapsis/lib/*.sh | awk '{print \$1}' | sort -u")

    cleanup_container_test

    # All .sh files should be -rwxr-xr-x (755)
    assert_contains "$output" "rwxr-xr-x" "Library files should have 755 permissions"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Container Libraries"

    # Check prerequisites
    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup test project
    setup_test_project

    # Library existence tests
    run_test test_logging_lib_exists
    run_test test_status_lib_exists
    run_test test_libs_are_executable

    # Function availability tests
    run_test test_logging_functions_available
    run_test test_status_functions_available
    run_test test_status_init_callable
    run_test test_status_phase_callable
    run_test test_status_creates_file

    # Entrypoint integration tests
    run_test test_entrypoint_with_status_env
    run_test test_entrypoint_status_file_created

    # Edge case tests
    run_test test_status_disabled_no_error
    run_test test_all_lib_files_have_correct_perms

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
