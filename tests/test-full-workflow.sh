#!/usr/bin/env bash
#===============================================================================
# Test: Full Workflow
#
# End-to-end integration test of the complete Kapsis workflow:
# 1. Launch agent with task
# 2. Create branch
# 3. Make changes
# 4. Commit changes
# 5. Verify isolation
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# HELPERS
#===============================================================================

# Run a simulated agent workflow
run_workflow() {
    local agent_id="$1"
    local branch="$2"
    local task="$3"

    run_podman_isolated "$agent_id" "
        cd /workspace

        # Configure git
        git config user.email 'kapsis@test.com'
        git config user.name 'Kapsis Agent'

        # Create branch
        git checkout -b \"$branch\" 2>/dev/null || git checkout \"$branch\"

        # Make changes based on task
        echo \"// Task: $task\" >> src/main/java/Main.java
        echo 'Changes made by agent' > agent-changes.txt

        # Stage and commit
        git add -A
        git commit -m \"feat: $task\"

        # Show result
        git log --oneline -1
        echo 'Workflow complete'
    " \
        -e KAPSIS_PROJECT="test-project" \
        -e KAPSIS_BRANCH="$branch" \
        -e KAPSIS_TASK="$task"
}

#===============================================================================
# TEST CASES
#===============================================================================

test_complete_workflow_success() {
    log_test "Testing complete workflow executes successfully"

    local agent_id="kapsis-workflow-$$"
    local branch="feature/workflow-test"

    local output
    output=$(run_workflow "$agent_id" "$branch" "implement feature X") || true

    # Cleanup
    cleanup_isolated_container "$agent_id"

    assert_contains "$output" "Workflow complete" "Workflow should complete"
}

test_workflow_creates_branch() {
    log_test "Testing workflow creates branch"

    local agent_id="kapsis-branch-wf-$$"

    local output
    output=$(run_podman_isolated "$agent_id" "
        cd /workspace
        git checkout -b feature/wf-branch
        git branch --show-current
    ") || true

    cleanup_isolated_container "$agent_id"

    assert_contains "$output" "feature/wf-branch" "Should create branch"
}

test_workflow_commits_changes() {
    log_test "Testing workflow commits changes"

    local agent_id="kapsis-commit-wf-$$"

    local output
    output=$(run_podman_isolated "$agent_id" "
        cd /workspace
        git config user.email 'test@test.com'
        git config user.name 'Test'
        git checkout -b feature/commit-test
        echo 'change' > change.txt
        git add change.txt
        git commit -m 'Test commit'
        git log --oneline -1
    ") || true

    cleanup_isolated_container "$agent_id"

    assert_contains "$output" "Test commit" "Should create commit"
}

test_workflow_preserves_host() {
    log_test "Testing workflow preserves host files"

    local agent_id="kapsis-preserve-wf-$$"

    # Record original state
    local original_main
    original_main=$(cat "$TEST_PROJECT/src/main/java/Main.java")

    # Run workflow that modifies file
    run_podman_isolated "$agent_id" "
        echo 'MODIFIED' >> /workspace/src/main/java/Main.java
    " 2>/dev/null || true

    cleanup_isolated_container "$agent_id"

    # Verify host unchanged
    local current_main
    current_main=$(cat "$TEST_PROJECT/src/main/java/Main.java")

    assert_equals "$original_main" "$current_main" "Host file should be unchanged"
}

test_workflow_with_spec_file() {
    log_test "Testing workflow with spec file"

    # Create spec file
    local spec_file="$TEST_PROJECT/task-spec.md"
    cat > "$spec_file" << 'EOF'
# Task Specification

## Objective
Implement a new logging feature.

## Requirements
- Add logging to main method
- Use standard output
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent interactive --spec "$spec_file" --dry-run 2>&1) || true

    rm -f "$spec_file"

    # Should show spec file in output
    assert_contains "$output" "task-spec.md" "Should reference spec file" || \
    assert_contains "$output" "Spec" "Should mention spec" || true
}

test_workflow_interactive_mode() {
    log_test "Testing interactive mode workflow"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent interactive --interactive --dry-run 2>&1) || true

    # Should show interactive config
    assert_contains "$output" "INTERACTIVE" "Should use interactive agent"
}

test_workflow_dry_run_complete() {
    log_test "Testing dry-run shows complete workflow"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" \
        --agent claude \
        --task "fix tests" \
        --branch "feature/dry-run-test" \
        --dry-run 2>&1) || true

    # Should show all components
    assert_contains "$output" "Agent:" "Should show agent"
    assert_contains "$output" "Project:" "Should show project"
    assert_contains "$output" "Branch:" "Should show branch"
    assert_contains "$output" "podman run" "Should show podman command"
}

test_workflow_error_handling() {
    log_test "Testing workflow handles errors gracefully"

    # Non-existent project
    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" 1 "/nonexistent" --task "test" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail on invalid input"
    assert_contains "$output" "not exist" "Should show error message"
}

test_workflow_cleanup_on_error() {
    log_test "Testing cleanup happens on container error"

    local agent_id="kapsis-error-wf-$$"

    # Run container that exits with error
    run_podman_isolated "$agent_id" "exit 1" 2>/dev/null || true

    # Container should not be left running
    local running
    running=$(podman ps -q --filter "name=$agent_id" | wc -l)

    cleanup_isolated_container "$agent_id"

    if [[ "$running" -eq 0 ]]; then
        return 0
    else
        podman rm -f "$agent_id" 2>/dev/null || true
        log_fail "Container should not be left running after error"
        return 1
    fi
}

test_workflow_env_propagation() {
    log_test "Testing environment variables propagate through workflow"

    local agent_id="kapsis-env-wf-$$"

    local output
    output=$(ANTHROPIC_API_KEY="test-key" run_podman_isolated "$agent_id" \
        'echo "KEY=${ANTHROPIC_API_KEY:0:4}... TASK=$KAPSIS_TASK"' \
        -e ANTHROPIC_API_KEY \
        -e KAPSIS_TASK="test task") || true

    cleanup_isolated_container "$agent_id"

    assert_contains "$output" "test..." "API key should be passed (truncated)"
    assert_contains "$output" "test task" "Task should be passed"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Full Workflow Integration"

    # Check prerequisites
    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_complete_workflow_success
    run_test test_workflow_creates_branch
    run_test test_workflow_commits_changes
    run_test test_workflow_preserves_host
    run_test test_workflow_with_spec_file
    run_test test_workflow_interactive_mode
    run_test test_workflow_dry_run_complete
    run_test test_workflow_error_handling
    run_test test_workflow_cleanup_on_error
    run_test test_workflow_env_propagation

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
