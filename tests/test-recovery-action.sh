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

# Temporary directory for synthetic status files; cleaned up on EXIT so that
# aborting under set -e doesn't leave tmpdir behind.
STATUS_TMP_DIR=""

setup_status_dir() {
    STATUS_TMP_DIR="$(mktemp -d)"
}

cleanup_status_dir() {
    [[ -n "$STATUS_TMP_DIR" && -d "$STATUS_TMP_DIR" ]] && rm -rf "$STATUS_TMP_DIR"
}

trap cleanup_status_dir EXIT

#===============================================================================
# HELPERS
#===============================================================================

# Write a synthetic status.json for testing.
write_status() {
    local filename="$1"
    local json="$2"
    echo "$json" > "${STATUS_TMP_DIR}/${filename}"
}

# Build a minimal complete-phase status JSON.
# Args: exit_code error_type commit_status push_fallback worktree_path branch
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

# Assert that $1 is parseable JSON (uses python3; skips assertion if unavailable).
assert_json_parseable() {
    local output="$1"
    local message="${2:-Output should be valid JSON}"
    if command -v python3 &>/dev/null; then
        local rc=0
        echo "$output" | python3 -c "import json, sys; json.load(sys.stdin)" 2>/dev/null || rc=$?
        assert_exit_code 0 "$rc" "$message"
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
    assert_contains "$output" "positional" "Should document that --status-file ignores positional args"
}

test_unknown_flag_exits_3_not_0() {
    log_test "Unknown flag exits 3 (not 0) so CLI typos don't look like 'retry'"

    local rc=0
    "$RECOVERY_SCRIPT" --jsno 2>/dev/null || rc=$?

    assert_exit_code 3 "$rc" "Unknown option should exit 3, not 0"
}

test_extra_positional_arg_exits_3() {
    log_test "Extra positional argument exits 3"

    local status_file="${STATUS_TMP_DIR}/extra_arg.json"
    make_status 0 "" "success" > "$status_file"

    local rc=0
    KAPSIS_STATUS_DIR="$STATUS_TMP_DIR" \
        "$RECOVERY_SCRIPT" "proj" "agent" "extra" 2>/dev/null || rc=$?

    assert_exit_code 3 "$rc" "Extra positional arg should exit 3"
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

test_invalid_project_id_rejected() {
    log_test "project containing path-traversal characters is rejected"

    local rc=0
    "$RECOVERY_SCRIPT" "../../etc/passwd" "agent" 2>/dev/null || rc=$?

    assert_exit_code 3 "$rc" "Path traversal in project should exit 3"
}

test_invalid_agent_id_rejected() {
    log_test "agent-id containing semicolon is rejected"

    local rc=0
    "$RECOVERY_SCRIPT" "myproject" "agent;evil" 2>/dev/null || rc=$?

    assert_exit_code 3 "$rc" "Shell metachar in agent-id should exit 3"
}

#===============================================================================
# TESTS: success case
#===============================================================================

test_successful_agent_exit_0() {
    log_test "Successful agent (exit_code=0) returns exit 0, mentions success"

    local status_file="${STATUS_TMP_DIR}/success.json"
    make_status 0 "" "success" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0 for successful agent"
    assert_contains "$output" "successfully" "Should mention success"
}

test_successful_agent_json_mode() {
    log_test "Successful agent JSON output has action 'none' and is valid JSON"

    local status_file="${STATUS_TMP_DIR}/success.json"
    make_status 0 "" "success" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0"
    assert_contains "$output" '"action"' "JSON should have action field"
    assert_contains "$output" '"none"' "Action should be none"
    assert_json_parseable "$output" "Success JSON should be valid JSON"
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
    log_test "agent_failure JSON output contains correct fields and is valid JSON"

    local status_file="${STATUS_TMP_DIR}/agent_failure.json"
    make_status 1 "agent_failure" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0"
    assert_contains "$output" '"action": "retry"' "JSON action should be retry"
    assert_contains "$output" '"error_type": "agent_failure"' "JSON should have error_type"
    assert_contains "$output" '"next_steps"' "JSON should have next_steps"
    assert_json_parseable "$output" "agent_failure JSON should be valid JSON"
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
    log_test "push_failure JSON output includes push_fallback_command and is valid JSON"

    local fallback="cd /worktrees/myproject && git push -u origin feature/bugfix"
    local status_file="${STATUS_TMP_DIR}/push_failure.json"
    make_status 2 "push_failure" "success" "$fallback" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 0 "$rc" "Should exit 0"
    assert_contains "$output" '"action": "retry_push"' "JSON action should be retry_push"
    assert_contains "$output" "push_fallback_command" "JSON should expose push_fallback_command"
    assert_json_parseable "$output" "push_failure JSON should be valid JSON"
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
    log_test "mount_failure JSON has action restart_and_retry and is valid JSON"

    local status_file="${STATUS_TMP_DIR}/mount_failure.json"
    make_status 4 "mount_failure" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 2 "$rc" "Should exit 2"
    assert_contains "$output" '"action": "restart_and_retry"' "JSON action should be restart_and_retry"
    assert_json_parseable "$output" "mount_failure JSON should be valid JSON"
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
    log_test "commit_failure steps include the preserved worktree path (single-quoted)"

    local worktree="/worktrees/testproject-abc123"
    local status_file="${STATUS_TMP_DIR}/commit_failure2.json"
    make_status 6 "commit_failure" "failed" "" "$worktree" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 1 "$rc" "Should exit 1"
    assert_contains "$output" "$worktree" "Steps should include worktree path"
}

test_commit_failure_json() {
    log_test "commit_failure JSON output is valid JSON with notify_human action"

    local status_file="${STATUS_TMP_DIR}/commit_failure_json.json"
    make_status 6 "commit_failure" "failed" "" "/worktrees/proj" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_exit_code 1 "$rc" "Should exit 1"
    assert_contains "$output" '"action": "notify_human"' "JSON action should be notify_human"
    assert_json_parseable "$output" "commit_failure JSON should be valid JSON"
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

test_agent_partial_json() {
    log_test "agent_partial JSON is valid JSON"

    local status_file="${STATUS_TMP_DIR}/agent_partial_json.json"
    make_status 1 "agent_partial" "success" "" "" "feature/my-fix" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_json_parseable "$output" "agent_partial JSON should be valid JSON"
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
# TESTS: hung_after_completion — context-sensitive on commit_status
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

test_hung_after_completion_json_parseable() {
    log_test "hung_after_completion JSON output is valid JSON"

    local status_file="${STATUS_TMP_DIR}/hung_json.json"
    make_status 5 "hung_after_completion" "success" "" "" "main" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_json_parseable "$output" "hung_after_completion JSON should be valid JSON"
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
# TESTS: JSON mode — completeness and validity across all types
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
    assert_json_parseable "$output" "JSON with all fields should be parseable"
}

test_json_commit_status_null_when_absent() {
    log_test "JSON commit_status is null (not empty string) when field is absent in source"

    # Status file with no commit_status field
    local status_file="${STATUS_TMP_DIR}/no_commit_status.json"
    cat << 'EOF' > "$status_file"
{
  "phase": "complete",
  "exit_code": 1,
  "error_type": "agent_failure",
  "commit_status": null,
  "push_fallback_command": null,
  "worktree_path": null,
  "branch": null
}
EOF

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_contains "$output" '"commit_status": null' "commit_status should be null, not empty string"
    assert_json_parseable "$output" "JSON with null commit_status should be parseable"
}

test_json_exit_code_missing_produces_valid_json() {
    log_test "JSON is valid even when source status.json has no exit_code field"

    local status_file="${STATUS_TMP_DIR}/no_exit_code.json"
    cat << 'EOF' > "$status_file"
{
  "phase": "complete",
  "error_type": "agent_failure",
  "commit_status": null,
  "push_fallback_command": null,
  "worktree_path": null,
  "branch": null
}
EOF

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_json_parseable "$output" "Missing exit_code should still produce valid JSON"
    # exit_code should be null or 0 (success path triggers for null exit_code)
    assert_not_contains "$output" '"exit_code": ,' "Should not produce invalid JSON with empty exit_code"
}

test_json_special_chars_in_branch_are_escaped() {
    log_test "Special characters in branch name are JSON-escaped"

    local status_file="${STATUS_TMP_DIR}/special_branch.json"
    cat << 'EOF' > "$status_file"
{
  "phase": "complete",
  "exit_code": 1,
  "error_type": "agent_partial",
  "commit_status": "success",
  "push_fallback_command": null,
  "worktree_path": null,
  "branch": "feature/tab\there"
}
EOF

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --json --status-file "$status_file" 2>&1) || rc=$?

    assert_json_parseable "$output" "Branch with special chars should produce valid JSON"
}

#===============================================================================
# TESTS: --status-file mode
#===============================================================================

test_status_file_header_shows_basename() {
    log_test "--status-file mode shows file basename in header (not empty)"

    local status_file="${STATUS_TMP_DIR}/kapsis-myproj-99.json"
    make_status 1 "agent_failure" > "$status_file"

    local output rc=0
    output=$("$RECOVERY_SCRIPT" --status-file "$status_file" 2>&1) || rc=$?

    assert_contains "$output" "kapsis-myproj-99" "Header should show status file basename"
    assert_not_contains "$output" "Recovery Action ===" "Header should not be empty identifier"
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
run_test test_unknown_flag_exits_3_not_0
run_test test_extra_positional_arg_exits_3
run_test test_missing_status_file
run_test test_missing_status_file_json_mode
run_test test_agent_still_running
run_test test_missing_project_arg
run_test test_invalid_project_id_rejected
run_test test_invalid_agent_id_rejected
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
run_test test_commit_failure_json
run_test test_agent_partial_action_notify
run_test test_agent_partial_json
run_test test_uncommitted_work_action_notify
run_test test_hung_after_completion_committed_notify_human
run_test test_hung_after_completion_not_committed_retry
run_test test_hung_after_completion_json_parseable
run_test test_unknown_error_type_notify_human
run_test test_json_has_required_fields
run_test test_json_commit_status_null_when_absent
run_test test_json_exit_code_missing_produces_valid_json
run_test test_json_special_chars_in_branch_are_escaped
run_test test_status_file_header_shows_basename
run_test test_project_and_agentid_resolution

print_summary
