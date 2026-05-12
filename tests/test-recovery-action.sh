#!/usr/bin/env bash
#===============================================================================
# Test: kapsis-recovery-action — recovery action determination (Issue #262)
#
# Verifies that the recovery action script correctly maps error_type values
# to actions, exit codes, and step-by-step guidance for callers.
#
# These tests run without containers (--quick compatible).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

RECOVERY_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-recovery-action.sh"

# Temporary directory for synthetic status files
STATUS_TMP_DIR=""

setup_status_dir() {
    STATUS_TMP_DIR="$(mktemp -d)"
}

cleanup_status_dir() {
    [[ -n "$STATUS_TMP_DIR" && -d "$STATUS_TMP_DIR" ]] && rm -rf "$STATUS_TMP_DIR"
}

# Write a synthetic status.json file for testing
# Usage: write_status <filename> <json-content>
write_status() {
    local filename="$1"
    local json="$2"
    echo "$json" > "${STATUS_TMP_DIR}/${filename}"
}

#===============================================================================
# HELPER: build minimal complete-phase status JSON
#===============================================================================

make_status() {
    local exit_code="${1:-1}"
    local error_type="${2:-agent_failure}"
    local commit_status="${3:-}"
    local push_fallback="${4:-}"
    local worktree_path="${5:-}"
    local branch="${6:-}"

    local commit_status_json="null"
    [[ -n "$commit_status" ]] && commit_status_json="\"$commit_status\""

    local push_fallback_json="null"
    [[ -n "$push_fallback" ]] && push_fallback_json="\"$push_fallback\""

    local worktree_json="null"
    [[ -n "$worktree_path" ]] && worktree_json="\"$worktree_path\""

    local branch_json="null"
    [[ -n "$branch" ]] && branch_json="\"$branch\""

    local error_type_json="null"
    [[ -n "$error_type" ]] && error_type_json="\"$error_type\""

    cat << EOF
{
  "version": "1.0",
  "agent_id": "test-agent",
  "project": "testproject",
  "branch": ${branch_json},
  "phase": "complete",
  "progress": 100,
  "message": "Completed",
  "exit_code": ${exit_code},
  "commit_status": ${commit_status_json},
  "push_fallback_command": ${push_fallback_json},
  "worktree_path": ${worktree_json},
  "error_type": ${error_type_json},
  "push_status": null,
  "pr_url": null
}
EOF
}

#===============================================================================
# TESTS: error conditions
#===============================================================================

test_missing_status_file() {
    log_test "Missing status file returns exit 3"

    local rc=0
    "$RECOVERY_SCRIPT" --status-file "/nonexistent/kapsis-x.json" >/dev/null 2>&1 || rc=$?

    assert_exit_code 3 "$rc" "Should exit 3 when status file is missing"
}

test_missing_status_file_json_mode() {
    log_test "Missing status file in JSON mode outputs error JSON"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "/nonexistent/kapsis-x.json" 2>&1) || rc=$?

    assert_exit_code 3 "$rc" "Should exit 3 in JSON mode too"
    assert_contains "$output" "not_found" "JSON output should include error field"
}

test_agent_still_running() {
    log_test "Running agent (phase != complete) returns exit 3"

    local status_file="${STATUS_TMP_DIR}/running.json"
    cat << 'EOF' > "$status_file"
{
  "phase": "running",
  "progress": 50,
  "exit_code": null,
  "error_type": null
}
EOF

    local rc=0
    "$RECOVERY_SCRIPT" --status-file "$status_file" >/dev/null 2>&1 || rc=$?

    assert_exit_code 3 "$rc" "Should exit 3 while agent is running"
}

test_missing_project_arg() {
    log_test "Missing project/agent-id argument returns exit 3"

    local rc=0
    "$RECOVERY_SCRIPT" 2>/dev/null || rc=$?

    assert_exit_code 3 "$rc" "Should exit 3 with no arguments"
}

#===============================================================================
# TESTS: success case
#===============================================================================

test_successful_agent_exit_0() {
    log_test "Successful agent (exit_code=0) returns exit 0, action 'none'"

    local status_file="${STATUS_TMP_DIR}/success.json"
    make_status 0 "" "success" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0 for successful agent"
    assert_contains "$output" "successfully" "Should mention success"
}

test_successful_agent_json_mode() {
    log_test "Successful agent JSON output has action 'none'"

    local status_file="${STATUS_TMP_DIR}/success.json"
    make_status 0 "" "success" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0"
    assert_contains "$output" '"action"' "JSON should have action field"
    assert_contains "$output" '"none"' "Action should be none"
}

#===============================================================================
# TESTS: agent_failure → retry (exit 0)
#===============================================================================

test_agent_failure_action_retry() {
    log_test "agent_failure maps to action 'retry', exits 0"

    local status_file="${STATUS_TMP_DIR}/agent_failure.json"
    make_status 1 "agent_failure" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "agent_failure should exit 0 (auto-retry safe)"
    assert_contains "$output" "retry" "Should show retry action"
}

test_agent_failure_json_output() {
    log_test "agent_failure JSON output contains correct fields"

    local status_file="${STATUS_TMP_DIR}/agent_failure.json"
    make_status 1 "agent_failure" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0"
    assert_contains "$output" '"action": "retry"' "JSON action should be retry"
    assert_contains "$output" '"error_type": "agent_failure"' "JSON should have error_type"
    assert_contains "$output" '"next_steps"' "JSON should have next_steps"
}

#===============================================================================
# TESTS: push_failure → retry_push (exit 0)
#===============================================================================

test_push_failure_action_retry_push() {
    log_test "push_failure maps to action 'retry_push', exits 0"

    local status_file="${STATUS_TMP_DIR}/push_failure.json"
    make_status 2 "push_failure" "success" \
        "cd /worktrees/test && git push -u origin feature/fix" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "push_failure should exit 0 (auto-retry safe)"
    assert_contains "$output" "retry_push" "Should show retry_push action"
    assert_contains "$output" "git push" "Should include push fallback command in steps"
}

test_push_failure_json_includes_fallback() {
    log_test "push_failure JSON output includes push_fallback_command"

    local fallback="cd /worktrees/myproject && git push -u origin feature/bugfix"
    local status_file="${STATUS_TMP_DIR}/push_failure.json"
    make_status 2 "push_failure" "success" "$fallback" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0"
    assert_contains "$output" '"action": "retry_push"' "JSON action should be retry_push"
    assert_contains "$output" "push_fallback_command" "JSON should expose push_fallback_command"
}

#===============================================================================
# TESTS: mount_failure → restart_and_retry (exit 2)
#===============================================================================

test_mount_failure_action_restart() {
    log_test "mount_failure maps to 'restart_and_retry', exits 2"

    local status_file="${STATUS_TMP_DIR}/mount_failure.json"
    make_status 4 "mount_failure" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 2 "$rc" "mount_failure should exit 2 (restart needed)"
    assert_contains "$output" "restart_and_retry" "Should show restart action"
    assert_contains "$output" "podman machine stop" "Should include stop step"
    assert_contains "$output" "podman machine start" "Should include start step"
}

test_mount_failure_json_action() {
    log_test "mount_failure JSON has action restart_and_retry"

    local status_file="${STATUS_TMP_DIR}/mount_failure.json"
    make_status 4 "mount_failure" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 2 "$rc" "Should exit 2"
    assert_contains "$output" '"action": "restart_and_retry"' "JSON action should be restart_and_retry"
}

#===============================================================================
# TESTS: commit_failure → notify_human (exit 1)
#===============================================================================

test_commit_failure_action_notify() {
    log_test "commit_failure maps to 'notify_human', exits 1"

    local status_file="${STATUS_TMP_DIR}/commit_failure.json"
    make_status 6 "commit_failure" "failed" "" "/worktrees/myproject" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 1 "$rc" "commit_failure should exit 1 (notify human)"
    assert_contains "$output" "notify_human" "Should show notify_human action"
    assert_contains "$output" "git status" "Should include recovery commands"
    assert_contains "$output" "git commit" "Should include commit step"
}

test_commit_failure_worktree_in_steps() {
    log_test "commit_failure steps include the preserved worktree path"

    local worktree="/worktrees/testproject-abc123"
    local status_file="${STATUS_TMP_DIR}/commit_failure.json"
    make_status 6 "commit_failure" "failed" "" "$worktree" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 1 "$rc" "Should exit 1"
    assert_contains "$output" "$worktree" "Steps should include worktree path"
}

#===============================================================================
# TESTS: agent_partial → notify_human (exit 1)
#===============================================================================

test_agent_partial_action_notify() {
    log_test "agent_partial maps to 'notify_human', exits 1"

    local status_file="${STATUS_TMP_DIR}/agent_partial.json"
    make_status 1 "agent_partial" "success" "" "" "feature/my-fix" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 1 "$rc" "agent_partial should exit 1"
    assert_contains "$output" "notify_human" "Should show notify_human"
    assert_contains "$output" "feature/my-fix" "Should include branch name in steps"
}

#===============================================================================
# TESTS: uncommitted_work → notify_human (exit 1)
#===============================================================================

test_uncommitted_work_action_notify() {
    log_test "uncommitted_work maps to 'notify_human', exits 1"

    local status_file="${STATUS_TMP_DIR}/uncommitted.json"
    make_status 3 "uncommitted_work" "uncommitted" "" "/worktrees/testproject" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 1 "$rc" "uncommitted_work should exit 1"
    assert_contains "$output" "notify_human" "Should show notify_human"
    assert_contains "$output" "git add" "Should include add step"
}

#===============================================================================
# TESTS: hung_after_completion — depends on commit_status
#===============================================================================

test_hung_after_completion_committed_notify_human() {
    log_test "hung_after_completion + commit=success → notify_human (work done, exit 1)"

    local status_file="${STATUS_TMP_DIR}/hung_committed.json"
    make_status 5 "hung_after_completion" "success" "" "" "feature/complete" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 1 "$rc" "Should exit 1 (work committed, no retry)"
    assert_contains "$output" "notify_human" "Should show notify_human"
    assert_contains "$output" "feature/complete" "Should include branch in review step"
}

test_hung_after_completion_not_committed_retry() {
    log_test "hung_after_completion + no commit → retry (exit 0)"

    local status_file="${STATUS_TMP_DIR}/hung_uncommitted.json"
    make_status 5 "hung_after_completion" "uncommitted" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0 (no work committed, retry safe)"
    assert_contains "$output" "retry" "Should show retry action"
}

#===============================================================================
# TESTS: unknown error_type → notify_human (exit 1)
#===============================================================================

test_unknown_error_type_notify_human() {
    log_test "Unknown error_type defaults to notify_human, exits 1"

    local status_file="${STATUS_TMP_DIR}/unknown.json"
    make_status 1 "some_future_error_type" > "$status_file"

    local rc=0
    "$RECOVERY_SCRIPT" --status-file "$status_file" >/dev/null 2>&1 || rc=$?

    assert_exit_code 1 "$rc" "Unknown error_type should exit 1 (notify_human)"
}

#===============================================================================
# TESTS: --json mode completeness
#===============================================================================

test_json_has_required_fields() {
    log_test "JSON output has all required fields"

    local status_file="${STATUS_TMP_DIR}/json_fields.json"
    make_status 1 "agent_failure" "no_changes" "" "/worktrees/proj" "main" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_contains "$output" '"action"' "Should have action field"
    assert_contains "$output" '"error_type"' "Should have error_type field"
    assert_contains "$output" '"description"' "Should have description field"
    assert_contains "$output" '"exit_code"' "Should have exit_code field"
    assert_contains "$output" '"commit_status"' "Should have commit_status field"
    assert_contains "$output" '"next_steps"' "Should have next_steps field"
}

test_json_valid_structure() {
    log_test "JSON output is parseable (no syntax errors)"

    local status_file="${STATUS_TMP_DIR}/json_valid.json"
    make_status 2 "push_failure" "success" \
        "cd /worktrees/proj && git push -u origin fix/thing" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    # Validate JSON is parseable with python3 (available everywhere, no jq dep)
    if command -v python3 &>/dev/null; then
        local parse_rc=0
        echo "$output" | python3 -c "import json, sys; json.load(sys.stdin)" 2>/dev/null || parse_rc=$?
        assert_exit_code 0 "$parse_rc" "JSON output should be valid JSON"
    else
        # Minimal structural check without python3
        assert_contains "$output" "{" "JSON should start with {"
        assert_contains "$output" "}" "JSON should end with }"
        assert_contains "$output" '"action"' "JSON should have action key"
    fi
}

#===============================================================================
# TESTS: script properties
#===============================================================================

test_script_is_executable() {
    log_test "kapsis-recovery-action.sh is executable"
    assert_true "[[ -x '$RECOVERY_SCRIPT' ]]" "Script should be executable"
}

test_help_flag_exits_0() {
    log_test "--help flag exits 0 and shows usage"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --help 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "--help should exit 0"
    assert_contains "$output" "Usage" "Should show usage"
    assert_contains "$output" "--status-file" "Should document --status-file option"
    assert_contains "$output" "--json" "Should document --json option"
}

test_project_and_agentid_resolution() {
    log_test "project + agent-id arguments resolve to correct status file path"

    local project="myproj"
    local agent_id="42"
    local expected_file="${STATUS_TMP_DIR}/kapsis-${project}-${agent_id}.json"

    make_status 0 "" "success" > "$expected_file"

    local output rc=0
    output=$(KAPSIS_STATUS_DIR="$STATUS_TMP_DIR" \
        "$RECOVERY_SCRIPT" "$project" "$agent_id" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should resolve and find the status file"
    assert_contains "$output" "successfully" "Should show success message"
}

#===============================================================================
# MAIN
#===============================================================================

print_test_header "kapsis-recovery-action (Issue #262)"

setup_status_dir

run_test test_script_is_executable
run_test test_help_flag_exits_0
run_test test_missing_status_file
run_test test_missing_status_file_json_mode
run_test test_agent_still_running
run_test test_missing_project_arg
run_test test_successful_agent_exit_0
run_test test_successful_agent_json_mode
run_test test_agent_failure_action_retry
run_test test_agent_failure_json_output
run_test test_push_failure_action_retry_push
run_test test_push_failure_json_includes_fallback
run_test test_mount_failure_action_restart
run_test test_mount_failure_json_action
run_test test_commit_failure_action_notify
run_test test_commit_failure_worktree_in_steps
run_test test_agent_partial_action_notify
run_test test_uncommitted_work_action_notify
run_test test_hung_after_completion_committed_notify_human
run_test test_hung_after_completion_not_committed_retry
run_test test_unknown_error_type_notify_human
run_test test_json_has_required_fields
run_test test_json_valid_structure
run_test test_project_and_agentid_resolution

cleanup_status_dir

print_summary
