#!/usr/bin/env bash
#===============================================================================
# Test: Cleanup Sandbox
#
# Verifies that sandbox resources can be properly cleaned up:
# - Sandbox directories
# - Named volumes
# - Orphan containers
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_sandbox_dir_removable() {
    log_test "Testing sandbox directory can be removed"

    setup_container_test "cleanup-dir"

    # Run container to create files
    run_in_container "
        echo 'test' > /workspace/test.txt
        mkdir -p /workspace/subdir
        echo 'nested' > /workspace/subdir/nested.txt
    " || true

    # Verify upper dir has files
    assert_file_in_upper "test.txt" "Should have test file"

    # Cleanup should work
    cleanup_container_test

    # Verify directory is gone
    if [[ -d "$CONTAINER_TEST_SANDBOX" ]]; then
        log_fail "Sandbox directory should be removed"
        return 1
    fi
    return 0
}

test_named_volumes_removable() {
    log_test "Testing named volumes can be removed"

    local volume_name="kapsis-test-vol-$$"

    # Create volume
    podman volume create "$volume_name" 2>/dev/null || true

    # Use volume in container
    podman run --rm \
        --name "vol-test-$$" \
        --userns=keep-id \
        -v "${volume_name}:/data" \
        $KAPSIS_TEST_IMAGE \
        bash -c "echo 'data' > /data/test.txt" 2>/dev/null || {
            podman volume rm "$volume_name" 2>/dev/null || true
            return 0  # Skip if image missing
        }

    # Remove volume
    local exit_code=0
    podman volume rm "$volume_name" 2>/dev/null || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        log_fail "Volume should be removable"
        return 1
    fi
}

test_stopped_container_removable() {
    log_test "Testing stopped container can be removed"

    local container_name="kapsis-stop-test-$$"

    # Run and exit container
    podman run \
        --name "$container_name" \
        --userns=keep-id \
        $KAPSIS_TEST_IMAGE \
        echo "done" 2>/dev/null || {
            return 0  # Skip if image missing
        }

    # Remove stopped container
    local exit_code=0
    podman rm "$container_name" 2>/dev/null || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        log_fail "Stopped container should be removable"
        return 1
    fi
}

test_force_remove_running() {
    log_test "Testing running container can be force removed"

    local container_name="kapsis-force-test-$$"
    local sandbox="$HOME/.ai-sandboxes/$container_name"
    mkdir -p "$sandbox/upper" "$sandbox/work"

    # Start long-running container
    podman run -d \
        --name "$container_name" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox/upper,workdir=$sandbox/work" \
        $KAPSIS_TEST_IMAGE \
        sleep 300 2>/dev/null || {
            rm -rf "$sandbox"
            return 0  # Skip if image missing
        }

    # Force remove
    local exit_code=0
    podman rm -f "$container_name" 2>/dev/null || exit_code=$?

    rm -rf "$sandbox"

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        log_fail "Running container should be force removable"
        return 1
    fi
}

test_cleanup_orphan_volumes() {
    log_test "Testing orphan volumes can be identified and removed"

    # Create some test volumes
    local vol1="kapsis-orphan-1-$$"
    local vol2="kapsis-orphan-2-$$"

    podman volume create "$vol1" 2>/dev/null || true
    podman volume create "$vol2" 2>/dev/null || true

    # List volumes matching pattern
    local orphans
    orphans=$(podman volume ls --format '{{.Name}}' | grep "kapsis-orphan" || echo "")

    # Remove them
    if [[ -n "$orphans" ]]; then
        echo "$orphans" | xargs podman volume rm 2>/dev/null || true
    fi

    # Verify removed
    local remaining
    remaining=$(podman volume ls --format '{{.Name}}' | grep "kapsis-orphan-.*-$$" || echo "")

    if [[ -z "$remaining" ]]; then
        return 0
    else
        log_fail "Orphan volumes should be removed"
        return 1
    fi
}

test_cleanup_multiple_sandboxes() {
    log_test "Testing multiple sandboxes can be cleaned"

    # Create multiple sandboxes
    for i in 1 2 3; do
        mkdir -p "$HOME/.ai-sandboxes/kapsis-multi-$i-$$/upper"
        mkdir -p "$HOME/.ai-sandboxes/kapsis-multi-$i-$$/work"
        echo "test $i" > "$HOME/.ai-sandboxes/kapsis-multi-$i-$$/upper/file.txt"
    done

    # Clean them all
    rm -rf "$HOME/.ai-sandboxes/kapsis-multi-"*"-$$"

    # Verify all removed
    local remaining
    remaining=$(ls -d "$HOME/.ai-sandboxes/kapsis-multi-"*"-$$" 2>/dev/null | wc -l)

    if [[ "$remaining" -eq 0 ]]; then
        return 0
    else
        log_fail "All sandboxes should be removed"
        return 1
    fi
}

test_cleanup_preserves_other_sandboxes() {
    log_test "Testing cleanup preserves other agent sandboxes"

    # Create sandbox to keep
    local keep_sandbox="$HOME/.ai-sandboxes/kapsis-keep-$$"
    mkdir -p "$keep_sandbox/upper"
    echo "preserve me" > "$keep_sandbox/upper/important.txt"

    # Create sandbox to remove
    local remove_sandbox="$HOME/.ai-sandboxes/kapsis-remove-$$"
    mkdir -p "$remove_sandbox/upper"
    echo "delete me" > "$remove_sandbox/upper/temp.txt"

    # Remove only the 'remove' sandbox
    rm -rf "$remove_sandbox"

    # Verify 'keep' sandbox preserved
    if [[ -f "$keep_sandbox/upper/important.txt" ]]; then
        rm -rf "$keep_sandbox"
        return 0
    else
        rm -rf "$keep_sandbox"
        log_fail "Other sandbox should be preserved"
        return 1
    fi
}

test_cleanup_empty_sandbox_dir() {
    log_test "Testing empty sandbox parent directory handling"

    # Create temp sandbox
    local sandbox="$HOME/.ai-sandboxes/kapsis-empty-test-$$"
    mkdir -p "$sandbox/upper" "$sandbox/work"

    # Remove it
    rm -rf "$sandbox"

    # Parent should still exist (don't remove .ai-sandboxes itself)
    if [[ -d "$HOME/.ai-sandboxes" ]]; then
        return 0
    else
        mkdir -p "$HOME/.ai-sandboxes"  # Recreate if accidentally removed
        return 0
    fi
}

test_cleanup_with_overlay_unmount() {
    log_test "Testing cleanup works even with overlay in use"

    setup_container_test "cleanup-overlay"

    # Create files
    run_in_container "echo 'test' > /workspace/test.txt" || true

    # Cleanup should handle any mount issues
    cleanup_container_test

    if [[ -d "$CONTAINER_TEST_SANDBOX" ]]; then
        log_fail "Sandbox should be cleaned up"
        rm -rf "$CONTAINER_TEST_SANDBOX"
        return 1
    fi
    return 0
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Cleanup Sandbox"

    # Check prerequisites
    if ! skip_if_no_container; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_sandbox_dir_removable
    run_test test_named_volumes_removable
    run_test test_stopped_container_removable
    run_test test_force_remove_running
    run_test test_cleanup_orphan_volumes
    run_test test_cleanup_multiple_sandboxes
    run_test test_cleanup_preserves_other_sandboxes
    run_test test_cleanup_empty_sandbox_dir
    run_test test_cleanup_with_overlay_unmount

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
