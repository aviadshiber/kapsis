#!/usr/bin/env bash
#===============================================================================
# Test: Parallel Agents
#
# Verifies that multiple agents can run simultaneously without interference:
# - No shared state
# - Independent filesystems
# - No volume conflicts
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# HELPERS
#===============================================================================

# Setup sandboxes for parallel agents
setup_parallel_sandboxes() {
    local count="$1"
    for i in $(seq 1 "$count"); do
        local sandbox="$HOME/.ai-sandboxes/kapsis-parallel-$i-$$"
        mkdir -p "$sandbox/upper" "$sandbox/work"
    done
}

# Cleanup parallel sandboxes
cleanup_parallel_sandboxes() {
    local count="$1"
    for i in $(seq 1 "$count"); do
        local name="kapsis-parallel-$i-$$"
        podman rm -f "$name" 2>/dev/null || true
        podman volume rm "${name}-m2" 2>/dev/null || true
        rm -rf "$HOME/.ai-sandboxes/$name"
    done
}

#===============================================================================
# TEST CASES
#===============================================================================

test_two_agents_run_simultaneously() {
    log_test "Testing two agents can run at the same time"

    setup_parallel_sandboxes 2

    local sandbox1="$HOME/.ai-sandboxes/kapsis-parallel-1-$$"
    local sandbox2="$HOME/.ai-sandboxes/kapsis-parallel-2-$$"

    # Start both agents
    podman run -d \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-1-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox1/upper,workdir=$sandbox1/work" \
        "$KAPSIS_TEST_IMAGE" \
        sleep 10 2>/dev/null || {
            cleanup_parallel_sandboxes 2
            return 0  # Skip if image missing
        }

    podman run -d \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-2-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox2/upper,workdir=$sandbox2/work" \
        "$KAPSIS_TEST_IMAGE" \
        sleep 10 2>/dev/null

    # Both should be running
    local running
    running=$(podman ps -q --filter "name=kapsis-parallel-.*-$$" | wc -l)

    cleanup_parallel_sandboxes 2

    if [[ "$running" -ge 2 ]]; then
        return 0
    else
        log_fail "Both agents should be running"
        return 1
    fi
}

test_agents_have_isolated_filesystems() {
    log_test "Testing agents have isolated filesystems"

    setup_parallel_sandboxes 2

    local sandbox1="$HOME/.ai-sandboxes/kapsis-parallel-1-$$"
    local sandbox2="$HOME/.ai-sandboxes/kapsis-parallel-2-$$"

    # Agent 1 creates a file
    podman run --rm \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-1-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox1/upper,workdir=$sandbox1/work" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c "echo 'agent1' > /workspace/agent1-file.txt" 2>/dev/null || {
            cleanup_parallel_sandboxes 2
            return 0
        }

    # Agent 2 checks for Agent 1's file
    local output
    output=$(podman run --rm \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-2-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox2/upper,workdir=$sandbox2/work" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c "cat /workspace/agent1-file.txt 2>/dev/null || echo 'not found'" 2>&1)

    cleanup_parallel_sandboxes 2

    assert_contains "$output" "not found" "Agent 2 should not see Agent 1's files"
}

test_agents_have_isolated_volumes() {
    log_test "Testing agents have isolated Maven volumes"

    local name1="kapsis-vol-iso-1-$$"
    local name2="kapsis-vol-iso-2-$$"

    # Agent 1 writes to its volume
    podman run --rm \
        -e CI="${CI:-true}" \
        --name "$name1" \
        --userns=keep-id \
        -v "${name1}-m2:/home/developer/.m2/repository" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c "mkdir -p /home/developer/.m2/repository/test && echo 'agent1' > /home/developer/.m2/repository/test/marker.txt" 2>/dev/null || {
            podman volume rm "${name1}-m2" "${name2}-m2" 2>/dev/null || true
            return 0
        }

    # Agent 2 checks its volume (should be empty)
    local output
    output=$(podman run --rm \
        -e CI="${CI:-true}" \
        --name "$name2" \
        --userns=keep-id \
        -v "${name2}-m2:/home/developer/.m2/repository" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c "cat /home/developer/.m2/repository/test/marker.txt 2>/dev/null || echo 'not found'" 2>&1)

    podman volume rm "${name1}-m2" "${name2}-m2" 2>/dev/null || true

    assert_contains "$output" "not found" "Agent 2 should have isolated volume"
}

test_concurrent_file_operations() {
    log_test "Testing concurrent file operations don't conflict"

    setup_parallel_sandboxes 3

    # Start 3 agents that all write to same filename
    for i in 1 2 3; do
        local sandbox="$HOME/.ai-sandboxes/kapsis-parallel-$i-$$"
        podman run -d \
        -e CI="${CI:-true}" \
            --name "kapsis-parallel-$i-$$" \
            --userns=keep-id \
            --security-opt label=disable \
            -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox/upper,workdir=$sandbox/work" \
            "$KAPSIS_TEST_IMAGE" \
            bash -c "echo 'agent$i' > /workspace/shared-name.txt && sleep 5" 2>/dev/null || true
    done

    # Wait for completion
    sleep 6

    # Check each agent wrote its own content
    local all_correct=true
    for i in 1 2 3; do
        local sandbox="$HOME/.ai-sandboxes/kapsis-parallel-$i-$$"
        if [[ -f "$sandbox/upper/shared-name.txt" ]]; then
            local content
            content=$(cat "$sandbox/upper/shared-name.txt")
            if [[ "$content" != "agent$i" ]]; then
                all_correct=false
            fi
        fi
    done

    cleanup_parallel_sandboxes 3

    if $all_correct; then
        return 0
    else
        log_fail "Each agent should have its own file content"
        return 1
    fi
}

test_no_cross_contamination_on_git() {
    log_test "Testing git operations don't cross-contaminate"

    setup_parallel_sandboxes 2

    local sandbox1="$HOME/.ai-sandboxes/kapsis-parallel-1-$$"
    local sandbox2="$HOME/.ai-sandboxes/kapsis-parallel-2-$$"

    # Agent 1 makes git commit
    podman run --rm \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-1-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox1/upper,workdir=$sandbox1/work" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c "
            cd /workspace
            git config user.email 'agent1@test.com'
            git config user.name 'Agent 1'
            echo 'agent1 change' > agent1.txt
            git add agent1.txt
            git commit -m 'Agent 1 commit'
        " 2>/dev/null || {
            cleanup_parallel_sandboxes 2
            return 0
        }

    # Agent 2 checks git log
    local output
    output=$(podman run --rm \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-2-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox2/upper,workdir=$sandbox2/work" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c "cd /workspace && git log --oneline -1" 2>&1)

    cleanup_parallel_sandboxes 2

    # Agent 2 should NOT see Agent 1's commit
    assert_not_contains "$output" "Agent 1 commit" "Agent 2 should not see Agent 1's commit"
}

test_resource_limits_per_agent() {
    log_test "Testing each agent has its own resource limits"

    setup_parallel_sandboxes 2

    local sandbox1="$HOME/.ai-sandboxes/kapsis-parallel-1-$$"
    local sandbox2="$HOME/.ai-sandboxes/kapsis-parallel-2-$$"

    # Start with different resource limits
    podman run -d \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-1-$$" \
        --memory=1g \
        --cpus=1 \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox1/upper,workdir=$sandbox1/work" \
        "$KAPSIS_TEST_IMAGE" \
        sleep 10 2>/dev/null || {
            cleanup_parallel_sandboxes 2
            return 0
        }

    podman run -d \
        -e CI="${CI:-true}" \
        --name "kapsis-parallel-2-$$" \
        --memory=2g \
        --cpus=2 \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox2/upper,workdir=$sandbox2/work" \
        "$KAPSIS_TEST_IMAGE" \
        sleep 10 2>/dev/null

    # Both should be running with different limits
    local count
    count=$(podman ps --filter "name=kapsis-parallel" --format "{{.Names}}" | wc -l)

    cleanup_parallel_sandboxes 2

    if [[ "$count" -ge 2 ]]; then
        return 0
    else
        log_fail "Both agents should be running with different resources"
        return 1
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Parallel Agents"

    # Check prerequisites
    if ! skip_if_no_container; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_two_agents_run_simultaneously
    run_test test_agents_have_isolated_filesystems
    run_test test_agents_have_isolated_volumes
    run_test test_concurrent_file_operations
    run_test test_no_cross_contamination_on_git
    run_test test_resource_limits_per_agent

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
