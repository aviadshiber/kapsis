#!/usr/bin/env bash
#===============================================================================
# Test: Status Reporting
#
# Verifies the status reporting feature works correctly:
# - Status files created on initialization
# - Phases progress correctly
# - Atomic writes (no partial JSON)
# - Multiple parallel agents have separate files
# - Exit code and PR URL captured correctly
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

STATUS_SCRIPT="$KAPSIS_ROOT/scripts/lib/status.sh"
STATUS_CLI="$KAPSIS_ROOT/scripts/kapsis-status.sh"

# Test status directory (isolated from real status)
TEST_STATUS_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_status_test() {
    # Create isolated test status directory
    TEST_STATUS_DIR=$(mktemp -d)
    export KAPSIS_STATUS_DIR="$TEST_STATUS_DIR"
    export KAPSIS_STATUS_ENABLED="true"

    # Reset status library internal state by unsourcing
    unset _KAPSIS_STATUS_LOADED 2>/dev/null || true
    unset _KAPSIS_STATUS_FILE 2>/dev/null || true
    unset _KAPSIS_STATUS_INITIALIZED 2>/dev/null || true
    unset _KAPSIS_STATUS_PROJECT 2>/dev/null || true
    unset _KAPSIS_STATUS_AGENT_ID 2>/dev/null || true

    # Source fresh status library
    source "$STATUS_SCRIPT"
}

cleanup_status_test() {
    if [[ -n "$TEST_STATUS_DIR" && -d "$TEST_STATUS_DIR" ]]; then
        rm -rf "$TEST_STATUS_DIR"
    fi
    TEST_STATUS_DIR=""
}

#===============================================================================
# TEST CASES: Library Functions
#===============================================================================

test_status_init_creates_file() {
    log_test "Status init creates JSON file"

    setup_status_test

    status_init "test-project" "1" "feature/test" "worktree" "/tmp/worktree"

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"
    assert_file_exists "$status_file" "Status file should be created"

    # Verify JSON is valid
    if python3 -c "import json; json.load(open('$status_file'))" 2>/dev/null; then
        log_info "  JSON is valid"
    else
        log_fail "Status file contains invalid JSON"
        cleanup_status_test
        return 1
    fi

    cleanup_status_test
}

test_status_init_sets_fields() {
    log_test "Status init sets correct fields"

    setup_status_test

    status_init "myproject" "42" "feature/DEV-123" "overlay" "/path/to/worktree"

    local status_file="$TEST_STATUS_DIR/kapsis-myproject-42.json"
    local content
    content=$(cat "$status_file")

    assert_contains "$content" '"agent_id": "42"' "Should contain agent_id"
    assert_contains "$content" '"project": "myproject"' "Should contain project"
    assert_contains "$content" '"branch": "feature/DEV-123"' "Should contain branch"
    assert_contains "$content" '"sandbox_mode": "overlay"' "Should contain sandbox_mode"
    assert_contains "$content" '"phase": "initializing"' "Should start in initializing phase"
    assert_contains "$content" '"progress": 0' "Should start at 0 progress"

    cleanup_status_test
}

test_status_phase_updates() {
    log_test "Status phase updates correctly"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""
    status_phase "preparing" 15 "Setting up sandbox"

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"
    local content
    content=$(cat "$status_file")

    assert_contains "$content" '"phase": "preparing"' "Phase should be updated"
    assert_contains "$content" '"progress": 15' "Progress should be updated"
    assert_contains "$content" '"message": "Setting up sandbox"' "Message should be updated"

    cleanup_status_test
}

test_status_phase_progression() {
    log_test "Status phases progress through lifecycle"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"

    # Test each phase
    local phases=("initializing:5" "preparing:18" "starting:22" "running:50" "committing:92" "pushing:97")
    for phase_prog in "${phases[@]}"; do
        local phase="${phase_prog%%:*}"
        local progress="${phase_prog##*:}"

        status_phase "$phase" "$progress" "Testing $phase"

        local content
        content=$(cat "$status_file")
        assert_contains "$content" "\"phase\": \"$phase\"" "Should be in $phase phase"
        assert_contains "$content" "\"progress\": $progress" "Progress should be $progress"
    done

    cleanup_status_test
}

test_status_complete_success() {
    log_test "Status complete records success"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""
    status_complete 0 "" "https://github.com/example/repo/pull/123"

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"
    local content
    content=$(cat "$status_file")

    assert_contains "$content" '"phase": "complete"' "Should be complete"
    assert_contains "$content" '"progress": 100' "Progress should be 100"
    assert_contains "$content" '"exit_code": 0' "Exit code should be 0"
    assert_contains "$content" '"pr_url": "https://github.com/example/repo/pull/123"' "PR URL should be set"

    cleanup_status_test
}

test_status_complete_failure() {
    log_test "Status complete records failure"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""
    status_complete 1 "Build failed with compilation errors"

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"
    local content
    content=$(cat "$status_file")

    assert_contains "$content" '"phase": "complete"' "Should be complete"
    assert_contains "$content" '"exit_code": 1' "Exit code should be 1"
    assert_contains "$content" '"error": "Build failed with compilation errors"' "Error should be set"

    cleanup_status_test
}

test_status_timestamps() {
    log_test "Status timestamps are updated"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"
    local content
    content=$(cat "$status_file")

    # Verify timestamps exist and are in ISO 8601 format
    if echo "$content" | grep -q '"started_at": "[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T'; then
        log_info "  started_at timestamp valid"
    else
        log_fail "started_at timestamp missing or invalid"
        cleanup_status_test
        return 1
    fi

    if echo "$content" | grep -q '"updated_at": "[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T'; then
        log_info "  updated_at timestamp valid"
    else
        log_fail "updated_at timestamp missing or invalid"
        cleanup_status_test
        return 1
    fi

    cleanup_status_test
}

test_status_json_escaping() {
    log_test "Status escapes special characters in JSON"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""
    status_phase "running" 50 'Message with "quotes" and backslash \ and newline
here'

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"

    # Verify JSON is still valid after escaping
    if python3 -c "import json; json.load(open('$status_file'))" 2>/dev/null; then
        log_info "  JSON is valid after escaping special characters"
    else
        log_fail "JSON became invalid after escaping"
        cleanup_status_test
        return 1
    fi

    cleanup_status_test
}

test_status_atomic_write() {
    log_test "Status writes are atomic"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""

    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"

    # Rapid updates to test atomic writes
    for i in {1..10}; do
        status_phase "running" "$((i * 10))" "Update $i"
    done

    # Verify file is valid JSON after rapid updates
    if python3 -c "import json; json.load(open('$status_file'))" 2>/dev/null; then
        log_info "  JSON valid after rapid updates"
    else
        log_fail "JSON invalid after rapid updates - atomic write may have failed"
        cleanup_status_test
        return 1
    fi

    # Verify no temp files left behind
    local temp_count
    temp_count=$(find "$TEST_STATUS_DIR" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$temp_count" -eq 0 ]]; then
        log_info "  No temp files left behind"
    else
        log_fail "Temp files left behind: $temp_count"
        cleanup_status_test
        return 1
    fi

    cleanup_status_test
}

test_status_multiple_agents() {
    log_test "Multiple agents have separate status files"

    setup_status_test

    # Initialize multiple agents
    _KAPSIS_STATUS_INITIALIZED=false
    status_init "project-a" "1" "" "worktree" ""

    # Reset and init another
    _KAPSIS_STATUS_INITIALIZED=false
    unset _KAPSIS_STATUS_FILE
    status_init "project-a" "2" "" "overlay" ""

    # Reset and init third
    _KAPSIS_STATUS_INITIALIZED=false
    unset _KAPSIS_STATUS_FILE
    status_init "project-b" "1" "" "worktree" ""

    # Verify all three files exist
    assert_file_exists "$TEST_STATUS_DIR/kapsis-project-a-1.json" "Agent 1 file should exist"
    assert_file_exists "$TEST_STATUS_DIR/kapsis-project-a-2.json" "Agent 2 file should exist"
    assert_file_exists "$TEST_STATUS_DIR/kapsis-project-b-1.json" "Agent 3 file should exist"

    # Verify they have different content
    local content_a1 content_a2 content_b1
    content_a1=$(cat "$TEST_STATUS_DIR/kapsis-project-a-1.json")
    content_a2=$(cat "$TEST_STATUS_DIR/kapsis-project-a-2.json")
    content_b1=$(cat "$TEST_STATUS_DIR/kapsis-project-b-1.json")

    assert_contains "$content_a1" '"agent_id": "1"' "Agent A-1 should have id 1"
    assert_contains "$content_a2" '"agent_id": "2"' "Agent A-2 should have id 2"
    assert_contains "$content_b1" '"project": "project-b"' "Agent B-1 should have project-b"

    cleanup_status_test
}

test_status_disabled() {
    log_test "Status disabled when KAPSIS_STATUS_ENABLED=false"

    setup_status_test
    export KAPSIS_STATUS_ENABLED="false"

    # Re-source to pick up disabled flag
    unset _KAPSIS_STATUS_LOADED
    source "$STATUS_SCRIPT"

    status_init "test-project" "1" "" "worktree" ""

    # Should not create file when disabled
    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"
    assert_file_not_exists "$status_file" "Status file should not be created when disabled"

    export KAPSIS_STATUS_ENABLED="true"
    cleanup_status_test
}

#===============================================================================
# TEST CASES: CLI Tool
#===============================================================================

test_cli_list_empty() {
    log_test "CLI lists empty status correctly"

    setup_status_test

    local output
    output=$("$STATUS_CLI" 2>&1) || true

    assert_contains "$output" "No agent status files found" "Should indicate no files found"

    cleanup_status_test
}

test_cli_list_agents() {
    log_test "CLI lists agents correctly"

    setup_status_test

    # Create some status files
    status_init "project-x" "1" "feature/test" "worktree" ""
    status_phase "running" 50 "Working"

    _KAPSIS_STATUS_INITIALIZED=false
    unset _KAPSIS_STATUS_FILE
    status_init "project-y" "2" "" "overlay" ""
    status_phase "complete" 100 "Done"

    local output
    output=$("$STATUS_CLI" 2>&1) || true

    assert_contains "$output" "project-x" "Should list project-x"
    assert_contains "$output" "project-y" "Should list project-y"
    assert_contains "$output" "running" "Should show running phase"
    assert_contains "$output" "complete" "Should show complete phase"

    cleanup_status_test
}

test_cli_specific_agent() {
    log_test "CLI shows specific agent details"

    setup_status_test

    status_init "myproject" "42" "feature/DEV-999" "worktree" "/path/to/wt"
    status_phase "running" 75 "Processing"

    local output
    output=$("$STATUS_CLI" myproject 42 2>&1) || true

    assert_contains "$output" "Project:" "Should show project label"
    assert_contains "$output" "myproject" "Should show project name"
    assert_contains "$output" "Agent ID:" "Should show agent ID label"
    assert_contains "$output" "42" "Should show agent ID"
    assert_contains "$output" "feature/DEV-999" "Should show branch"
    assert_contains "$output" "75%" "Should show progress"

    cleanup_status_test
}

test_cli_json_output() {
    log_test "CLI outputs valid JSON with --json flag"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""
    status_phase "running" 50 "Working"

    local output
    output=$("$STATUS_CLI" --json 2>&1) || true

    # Verify JSON array
    if python3 -c "import json; data = json.loads('''$output'''); assert isinstance(data, list)" 2>/dev/null; then
        log_info "  Output is valid JSON array"
    else
        log_fail "CLI --json output is not valid JSON array"
        cleanup_status_test
        return 1
    fi

    cleanup_status_test
}

test_cli_specific_agent_json() {
    log_test "CLI outputs specific agent as JSON"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""
    status_phase "running" 50 "Working"

    local output
    output=$("$STATUS_CLI" test-project 1 --json 2>&1) || true

    # Verify JSON object (not array)
    if python3 -c "import json; data = json.loads('''$output'''); assert isinstance(data, dict)" 2>/dev/null; then
        log_info "  Output is valid JSON object"
    else
        log_fail "CLI specific agent --json output is not valid JSON object"
        cleanup_status_test
        return 1
    fi

    cleanup_status_test
}

test_cli_nonexistent_agent() {
    log_test "CLI handles nonexistent agent gracefully"

    setup_status_test

    local exit_code=0
    local output
    output=$("$STATUS_CLI" nonexistent 99 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail for nonexistent agent"
    assert_contains "$output" "No status found" "Should indicate not found"

    cleanup_status_test
}

test_cli_help() {
    log_test "CLI shows help"

    local output
    output=$("$STATUS_CLI" --help 2>&1) || true

    assert_contains "$output" "Usage" "Should show usage"
    assert_contains "$output" "--watch" "Should document watch flag"
    assert_contains "$output" "--json" "Should document json flag"
    assert_contains "$output" "--cleanup" "Should document cleanup flag"
}

#===============================================================================
# TEST CASES: Integration
#===============================================================================

test_reinit_from_env() {
    log_test "Status reinitializes from environment variables"

    setup_status_test

    # Simulate environment set by launch-agent.sh
    export KAPSIS_STATUS_PROJECT="env-project"
    export KAPSIS_STATUS_AGENT_ID="99"
    export KAPSIS_STATUS_BRANCH="feature/from-env"
    export KAPSIS_STATUS_SANDBOX_MODE="overlay"

    # Reset and reinit from env
    _KAPSIS_STATUS_INITIALIZED=false
    unset _KAPSIS_STATUS_FILE
    status_reinit_from_env

    local status_file="$TEST_STATUS_DIR/kapsis-env-project-99.json"
    assert_file_exists "$status_file" "Status file should be created from env"

    local content
    content=$(cat "$status_file")
    assert_contains "$content" '"project": "env-project"' "Should use project from env"
    assert_contains "$content" '"agent_id": "99"' "Should use agent_id from env"
    assert_contains "$content" '"branch": "feature/from-env"' "Should use branch from env"

    # Cleanup env vars
    unset KAPSIS_STATUS_PROJECT KAPSIS_STATUS_AGENT_ID KAPSIS_STATUS_BRANCH KAPSIS_STATUS_SANDBOX_MODE
    cleanup_status_test
}

test_status_utility_functions() {
    log_test "Status utility functions work correctly"

    setup_status_test

    status_init "test-project" "1" "" "worktree" ""
    status_phase "running" 50 "Test"

    # Test status_get_file
    local file_path
    file_path=$(status_get_file)
    assert_contains "$file_path" "kapsis-test-project-1.json" "Should return correct file path"

    # Test status_get_phase
    local current_phase
    current_phase=$(status_get_phase)
    assert_equals "running" "$current_phase" "Should return current phase"

    # Test status_is_active
    if status_is_active; then
        log_info "  status_is_active returns true when active"
    else
        log_fail "status_is_active should return true"
        cleanup_status_test
        return 1
    fi

    cleanup_status_test
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Status Reporting"

    # Library tests
    run_test test_status_init_creates_file
    run_test test_status_init_sets_fields
    run_test test_status_phase_updates
    run_test test_status_phase_progression
    run_test test_status_complete_success
    run_test test_status_complete_failure
    run_test test_status_timestamps
    run_test test_status_json_escaping
    run_test test_status_atomic_write
    run_test test_status_multiple_agents
    run_test test_status_disabled

    # CLI tests
    run_test test_cli_list_empty
    run_test test_cli_list_agents
    run_test test_cli_specific_agent
    run_test test_cli_json_output
    run_test test_cli_specific_agent_json
    run_test test_cli_nonexistent_agent
    run_test test_cli_help

    # Integration tests
    run_test test_reinit_from_env
    run_test test_status_utility_functions

    # Summary
    print_summary
}

main "$@"
