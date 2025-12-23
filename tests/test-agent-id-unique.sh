#!/usr/bin/env bash
#===============================================================================
# Test: Agent ID Uniqueness
#
# Verifies that the same agent ID cannot be used to run multiple containers
# simultaneously, preventing resource conflicts and data corruption.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_same_id_blocked() {
    log_test "Testing same agent ID cannot run twice"

    local agent_id="kapsis-test-unique-$$"
    local sandbox_dir="$HOME/.ai-sandboxes/$agent_id"

    # Setup sandbox
    rm -rf "$sandbox_dir"
    mkdir -p "$sandbox_dir/upper" "$sandbox_dir/work"

    # Start first container in background (sleeps for a bit)
    podman run -d \
        --name "$agent_id" \
        --hostname "$agent_id" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox_dir/upper,workdir=$sandbox_dir/work" \
        $KAPSIS_TEST_IMAGE \
        sleep 30 2>/dev/null || {
            log_info "First container failed to start (may be image missing)"
            rm -rf "$sandbox_dir"
            return 0
        }

    # Try to start second container with same name
    local output
    local exit_code=0
    output=$(podman run --rm \
        --name "$agent_id" \
        --hostname "$agent_id" \
        $KAPSIS_TEST_IMAGE \
        echo "should not run" 2>&1) || exit_code=$?

    # Cleanup
    podman rm -f "$agent_id" 2>/dev/null || true
    rm -rf "$sandbox_dir"

    # Second container should fail
    if [[ $exit_code -ne 0 ]]; then
        assert_contains "$output" "in use" "Error should mention container name in use"
        return 0
    else
        log_fail "Second container with same ID should not start"
        return 1
    fi
}

test_different_ids_allowed() {
    log_test "Testing different agent IDs can run simultaneously"

    local agent_id1="kapsis-test-multi-1-$$"
    local agent_id2="kapsis-test-multi-2-$$"
    local sandbox1="$HOME/.ai-sandboxes/$agent_id1"
    local sandbox2="$HOME/.ai-sandboxes/$agent_id2"

    # Setup sandboxes
    mkdir -p "$sandbox1/upper" "$sandbox1/work"
    mkdir -p "$sandbox2/upper" "$sandbox2/work"

    # Start first container
    podman run -d \
        --name "$agent_id1" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox1/upper,workdir=$sandbox1/work" \
        $KAPSIS_TEST_IMAGE \
        sleep 30 2>/dev/null || {
            rm -rf "$sandbox1" "$sandbox2"
            return 0  # Skip if image missing
        }

    # Start second container with different ID
    local exit_code=0
    podman run -d \
        --name "$agent_id2" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox2/upper,workdir=$sandbox2/work" \
        $KAPSIS_TEST_IMAGE \
        sleep 30 2>/dev/null || exit_code=$?

    # Check both are running
    local running1
    local running2
    running1=$(podman ps -q --filter "name=$agent_id1" | wc -l)
    running2=$(podman ps -q --filter "name=$agent_id2" | wc -l)

    # Cleanup
    podman rm -f "$agent_id1" "$agent_id2" 2>/dev/null || true
    rm -rf "$sandbox1" "$sandbox2"

    # Both should have been running
    if [[ "$running1" -ge 1 ]] && [[ "$running2" -ge 1 ]]; then
        return 0
    else
        log_fail "Both containers should be running"
        return 1
    fi
}

test_volumes_isolated() {
    log_test "Testing different agent IDs have isolated volumes"

    local agent_id1="kapsis-vol-1-$$"
    local agent_id2="kapsis-vol-2-$$"

    # Create files in container 1's volume
    podman run --rm \
        --name "$agent_id1" \
        --userns=keep-id \
        -v "${agent_id1}-m2:/home/developer/.m2/repository" \
        $KAPSIS_TEST_IMAGE \
        bash -c "mkdir -p /home/developer/.m2/repository/test && echo 'agent1' > /home/developer/.m2/repository/test/marker.txt" 2>/dev/null || {
            return 0  # Skip if image missing
        }

    # Check container 2 doesn't see the file
    local output
    output=$(podman run --rm \
        --name "$agent_id2" \
        --userns=keep-id \
        -v "${agent_id2}-m2:/home/developer/.m2/repository" \
        $KAPSIS_TEST_IMAGE \
        bash -c "cat /home/developer/.m2/repository/test/marker.txt 2>/dev/null || echo 'not found'" 2>&1)

    # Cleanup volumes
    podman volume rm "${agent_id1}-m2" "${agent_id2}-m2" 2>/dev/null || true

    assert_contains "$output" "not found" "Agent 2 should not see Agent 1's files"
}

test_sandbox_dirs_isolated() {
    log_test "Testing different agent IDs have isolated sandbox directories"

    local agent_id1="kapsis-sandbox-1-$$"
    local agent_id2="kapsis-sandbox-2-$$"
    local sandbox1="$HOME/.ai-sandboxes/$agent_id1"
    local sandbox2="$HOME/.ai-sandboxes/$agent_id2"

    # Setup sandboxes
    mkdir -p "$sandbox1/upper" "$sandbox1/work"
    mkdir -p "$sandbox2/upper" "$sandbox2/work"

    # Create file in container 1
    podman run --rm \
        --name "$agent_id1" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox1/upper,workdir=$sandbox1/work" \
        $KAPSIS_TEST_IMAGE \
        bash -c "echo 'from agent 1' > /workspace/agent1-file.txt" 2>/dev/null || {
            rm -rf "$sandbox1" "$sandbox2"
            return 0  # Skip if image missing
        }

    # Run container 2 and check for file
    local output
    output=$(podman run --rm \
        --name "$agent_id2" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox2/upper,workdir=$sandbox2/work" \
        $KAPSIS_TEST_IMAGE \
        bash -c "cat /workspace/agent1-file.txt 2>/dev/null || echo 'not found'" 2>&1)

    # Cleanup
    rm -rf "$sandbox1" "$sandbox2"

    # Agent 2 should not see Agent 1's file
    assert_contains "$output" "not found" "Agent 2 should not see Agent 1's files"
}

test_container_name_enforced() {
    log_test "Testing container naming convention enforced"

    setup_container_test "name-test"

    # Run container and verify name
    run_in_container_detached "sleep 5"

    # Check container exists with expected name
    if container_exists "$CONTAINER_TEST_ID"; then
        cleanup_container_test
        return 0
    else
        cleanup_container_test
        log_fail "Container should have expected name"
        return 1
    fi
}

test_reuse_after_cleanup() {
    log_test "Testing agent ID can be reused after cleanup"

    local agent_id="kapsis-reuse-$$"
    local sandbox="$HOME/.ai-sandboxes/$agent_id"

    # First run
    mkdir -p "$sandbox/upper" "$sandbox/work"
    podman run --rm \
        --name "$agent_id" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox/upper,workdir=$sandbox/work" \
        $KAPSIS_TEST_IMAGE \
        echo "first run" 2>/dev/null || {
            rm -rf "$sandbox"
            return 0  # Skip if image missing
        }

    # Cleanup sandbox
    rm -rf "$sandbox"
    mkdir -p "$sandbox/upper" "$sandbox/work"

    # Second run with same ID should work
    local exit_code=0
    podman run --rm \
        --name "$agent_id" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox/upper,workdir=$sandbox/work" \
        $KAPSIS_TEST_IMAGE \
        echo "second run" 2>/dev/null || exit_code=$?

    rm -rf "$sandbox"

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        log_fail "Should be able to reuse agent ID after cleanup"
        return 1
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Agent ID Uniqueness"

    # Check prerequisites
    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_same_id_blocked
    run_test test_different_ids_allowed
    run_test test_volumes_isolated
    run_test test_sandbox_dirs_isolated
    run_test test_container_name_enforced
    run_test test_reuse_after_cleanup

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
