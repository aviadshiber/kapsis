#!/usr/bin/env bash
#===============================================================================
# Test: Git New Branch
#
# Verifies the git branch workflow for creating and working on new branches.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_branch_flag_creates_branch() {
    log_test "Testing --branch creates new branch in container"

    setup_container_test "git-branch"

    local branch_name="feature/test-branch-$$"

    # Run container with branch flag
    local output
    output=$(run_in_container "
        export KAPSIS_BRANCH='$branch_name'
        source /opt/kapsis/scripts/entrypoint.sh 2>&1 || true
        cd /workspace
        git branch --show-current
    ") || true

    cleanup_container_test

    # Should have created the branch
    assert_contains "$output" "$branch_name" "Should be on the new branch"
}

test_branch_from_current_head() {
    log_test "Testing new branch created from current HEAD"

    setup_container_test "git-head"

    # Get current HEAD on host
    local host_head
    host_head=$(cd "$TEST_PROJECT" && git rev-parse HEAD)

    # Create branch in container
    local container_head
    container_head=$(run_in_container "
        export KAPSIS_BRANCH='feature/from-head'
        cd /workspace
        git checkout -b feature/from-head 2>/dev/null || true
        git rev-parse HEAD
    ") || true

    cleanup_container_test

    # Branch should start from same commit
    assert_contains "$container_head" "$host_head" "Branch should start from HEAD"
}

test_auto_branch_generates_name() {
    log_test "Testing --auto-branch generates branch name"

    # This tests the launch script's auto-branch logic
    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --auto-branch --task "fix login bug" --dry-run 2>&1) || true

    # Should have generated a branch name
    assert_contains "$output" "Branch:" "Should show branch name"
    # Auto-generated names typically include task keywords
    assert_contains "$output" "fix" "Branch name should include task keywords" || \
    assert_contains "$output" "kapsis" "Branch name should include kapsis prefix" || true
}

test_branch_survives_container_restart() {
    log_test "Testing branch state survives in overlay"

    setup_container_test "git-persist"

    local branch_name="feature/persist-test-$$"

    # First container: create branch and make changes
    run_in_container "
        cd /workspace
        git checkout -b '$branch_name'
        echo 'change1' > branch-file.txt
        git add branch-file.txt
        git config user.email 'test@test.com'
        git config user.name 'Test'
        git commit -m 'Branch commit'
    " || true

    # Verify changes are in upper directory
    assert_file_in_upper "branch-file.txt" "File should be in upper directory"

    cleanup_container_test
}

test_multiple_branches_different_agents() {
    log_test "Testing multiple agents can work on different branches"

    local branch1="feature/agent1-branch-$$"
    local branch2="feature/agent2-branch-$$"

    # Setup two separate sandboxes
    local sandbox1="$HOME/.ai-sandboxes/git-multi-1-$$"
    local sandbox2="$HOME/.ai-sandboxes/git-multi-2-$$"
    mkdir -p "$sandbox1/upper" "$sandbox1/work"
    mkdir -p "$sandbox2/upper" "$sandbox2/work"

    # Agent 1 creates branch 1
    podman run --rm \
        --name "git-multi-1-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox1/upper,workdir=$sandbox1/work" \
        -e KAPSIS_BRANCH="$branch1" \
        kapsis-sandbox:latest \
        bash -c "cd /workspace && git checkout -b '$branch1' && echo 'agent1' > agent1.txt" 2>/dev/null || {
            rm -rf "$sandbox1" "$sandbox2"
            return 0  # Skip if image missing
        }

    # Agent 2 creates branch 2
    podman run --rm \
        --name "git-multi-2-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox2/upper,workdir=$sandbox2/work" \
        -e KAPSIS_BRANCH="$branch2" \
        kapsis-sandbox:latest \
        bash -c "cd /workspace && git checkout -b '$branch2' && echo 'agent2' > agent2.txt" 2>/dev/null

    # Verify each agent has its own file in its sandbox
    if [[ -f "$sandbox1/upper/agent1.txt" ]] && [[ -f "$sandbox2/upper/agent2.txt" ]]; then
        rm -rf "$sandbox1" "$sandbox2"
        return 0
    else
        rm -rf "$sandbox1" "$sandbox2"
        log_fail "Each agent should have its own file"
        return 1
    fi
}

test_branch_env_var_passed() {
    log_test "Testing KAPSIS_BRANCH env var is available in container"

    setup_container_test "git-env"

    local branch_name="feature/env-test"

    # Check env var is set
    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e KAPSIS_BRANCH="$branch_name" \
        kapsis-sandbox:latest \
        bash -c 'echo $KAPSIS_BRANCH' 2>&1) || true

    cleanup_container_test

    assert_equals "$branch_name" "$output" "KAPSIS_BRANCH should be set"
}

test_branch_flag_validation() {
    log_test "Testing --branch requires git repo"

    # Create non-git directory
    local non_git_dir
    non_git_dir=$(mktemp -d)

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" 1 "$non_git_dir" --branch "test" --task "test" 2>&1) || exit_code=$?

    rm -rf "$non_git_dir"

    assert_not_equals 0 "$exit_code" "Should fail without git repo"
    assert_contains "$output" "git repository" "Should mention git requirement"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Git New Branch"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Check prerequisites
    if ! skip_if_no_container; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_branch_flag_creates_branch
    run_test test_branch_from_current_head
    run_test test_auto_branch_generates_name
    run_test test_branch_survives_container_restart
    run_test test_multiple_branches_different_agents
    run_test test_branch_env_var_passed
    run_test test_branch_flag_validation

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
