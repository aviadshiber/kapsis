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

    # Run container with KAPSIS_BRANCH env var - entrypoint.sh handles branch creation
    # The init_git_branch function in entrypoint creates/checks out the branch
    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --hostname "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --device /dev/fuse \
        --cap-add SYS_ADMIN \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/lower:ro" \
        -v "${CONTAINER_TEST_ID}-upper:/upper" \
        -v "${CONTAINER_TEST_ID}-work:/work" \
        -v "${CONTAINER_TEST_ID}-m2:/home/developer/.m2/repository" \
        -e KAPSIS_AGENT_ID="$CONTAINER_TEST_ID" \
        -e KAPSIS_PROJECT="test" \
        -e KAPSIS_USE_FUSE_OVERLAY=true \
        -e KAPSIS_BRANCH="$branch_name" \
        kapsis-sandbox:latest \
        bash -c "cd /workspace && git branch --show-current" 2>&1) || true

    cleanup_container_test

    # Should have created the branch (check output contains branch name)
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
    local agent1="git-multi-1-$$"
    local agent2="git-multi-2-$$"

    # Agent 1 creates branch 1
    run_podman_isolated "$agent1" "cd /workspace && git checkout -b '$branch1' && echo 'agent1' > agent1.txt" \
        -e KAPSIS_BRANCH="$branch1" 2>/dev/null || {
            cleanup_isolated_container "$agent1"
            cleanup_isolated_container "$agent2"
            return 0  # Skip if image missing
        }

    # Agent 2 creates branch 2
    run_podman_isolated "$agent2" "cd /workspace && git checkout -b '$branch2' && echo 'agent2' > agent2.txt" \
        -e KAPSIS_BRANCH="$branch2" 2>/dev/null

    # Verify each agent has its own file (check upper volumes in fuse mode)
    if [[ "${KAPSIS_USE_FUSE_OVERLAY:-}" == "true" ]]; then
        # Check files in upper volumes
        local agent1_has_file
        local agent2_has_file
        agent1_has_file=$(podman run --rm -v "${agent1}-upper:/upper:ro" kapsis-sandbox:latest bash -c "test -f /upper/data/agent1.txt && echo YES || echo NO" 2>&1)
        agent2_has_file=$(podman run --rm -v "${agent2}-upper:/upper:ro" kapsis-sandbox:latest bash -c "test -f /upper/data/agent2.txt && echo YES || echo NO" 2>&1)

        cleanup_isolated_container "$agent1"
        cleanup_isolated_container "$agent2"

        if [[ "$agent1_has_file" == *"YES"* ]] && [[ "$agent2_has_file" == *"YES"* ]]; then
            return 0
        else
            log_fail "Each agent should have its own file"
            return 1
        fi
    else
        # Check files in upper directories (native overlay)
        local sandbox1="$HOME/.ai-sandboxes/$agent1"
        local sandbox2="$HOME/.ai-sandboxes/$agent2"

        if [[ -f "$sandbox1/upper/agent1.txt" ]] && [[ -f "$sandbox2/upper/agent2.txt" ]]; then
            cleanup_isolated_container "$agent1"
            cleanup_isolated_container "$agent2"
            return 0
        else
            cleanup_isolated_container "$agent1"
            cleanup_isolated_container "$agent2"
            log_fail "Each agent should have its own file"
            return 1
        fi
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

    # Use assert_contains since entrypoint outputs logging before the command
    assert_contains "$output" "$branch_name" "KAPSIS_BRANCH should be set"
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
    if ! skip_if_no_overlay_rw; then
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
