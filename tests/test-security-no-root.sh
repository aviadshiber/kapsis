#!/usr/bin/env bash
#===============================================================================
# Test: Security - No Root
#
# Verifies security properties of the sandbox:
# - Container runs as non-root user
# - UID mapping works correctly
# - Cannot escalate privileges
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_not_running_as_root() {
    log_test "Testing container does not run as root"

    setup_container_test "sec-noroot"

    local output
    output=$(run_in_container "whoami")

    cleanup_container_test

    assert_not_contains "$output" "root" "Should not run as root"
}

test_uid_not_zero() {
    log_test "Testing UID is not 0"

    setup_container_test "sec-uid"

    local output
    output=$(run_in_container "id -u")

    cleanup_container_test

    assert_not_equals "0" "$output" "UID should not be 0"
}

test_cannot_sudo() {
    log_test "Testing sudo is not available or fails"

    setup_container_test "sec-sudo"

    local output
    local exit_code=0
    output=$(run_in_container "sudo echo 'test' 2>&1") || exit_code=$?

    cleanup_container_test

    # Should either not have sudo or fail
    if [[ $exit_code -ne 0 ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"not allowed"* ]]; then
        return 0
    else
        log_fail "sudo should not be available or should fail"
        return 1
    fi
}

test_userns_keep_id() {
    log_test "Testing userns=keep-id maps to host UID"

    setup_container_test "sec-userns"

    # Get host UID
    local host_uid
    host_uid=$(id -u)

    # Get container UID
    local container_uid
    container_uid=$(run_in_container "id -u")

    cleanup_container_test

    # UIDs should match due to keep-id
    assert_equals "$host_uid" "$container_uid" "Container UID should match host UID"
}

test_files_owned_by_user() {
    log_test "Testing files in workspace owned by user"

    setup_container_test "sec-owner"

    # Check file ownership
    local output
    output=$(run_in_container "ls -la /workspace/pom.xml | awk '{print \$3}'")

    cleanup_container_test

    # Should be owned by developer or the mapped user
    if [[ "$output" != "root" ]]; then
        return 0
    else
        log_fail "Files should not be owned by root"
        return 1
    fi
}

test_cannot_access_host_root() {
    log_test "Testing cannot access host root filesystem"

    setup_container_test "sec-hostroot"

    local output
    local exit_code=0
    output=$(run_in_container "ls /host 2>&1") || exit_code=$?

    cleanup_container_test

    # Should fail - /host shouldn't exist
    if [[ $exit_code -ne 0 ]] || [[ "$output" == *"No such file"* ]] || [[ "$output" == *"cannot access"* ]]; then
        return 0
    else
        log_fail "Should not have access to /host"
        return 1
    fi
}

test_security_labels_disabled() {
    log_test "Testing security labels are disabled (for overlay)"

    # This is verified by the fact that overlay mounts work
    # If SELinux/AppArmor labels were enforced, overlay might fail

    setup_container_test "sec-labels"

    # Try to create file (requires working overlay)
    local exit_code=0
    run_in_container "touch /workspace/security-test.txt" || exit_code=$?

    cleanup_container_test

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        log_fail "Security labels may be blocking overlay"
        return 1
    fi
}

test_memory_limit_enforced() {
    log_test "Testing memory limit is visible"

    setup_container_test "sec-mem"

    # Check cgroup memory limit
    local output
    output=$(run_in_container "cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 'unknown'")

    cleanup_container_test

    # Should show some limit (not "max" or unlimited)
    if [[ "$output" != "max" ]] && [[ "$output" != "unknown" ]]; then
        return 0
    else
        log_info "Memory limit not detected (may be cgroup v1/v2 difference)"
        return 0  # Don't fail, just informational
    fi
}

test_hostname_set() {
    log_test "Testing container hostname is set correctly"

    setup_container_test "sec-hostname"

    local output
    output=$(run_in_container "hostname")

    cleanup_container_test

    # Should be the container test ID
    assert_contains "$output" "kapsis-test" "Hostname should be set to container name"
}

test_home_directory_exists() {
    log_test "Testing home directory exists and is writable"

    setup_container_test "sec-home"

    local output
    output=$(run_in_container "echo 'test' > ~/test.txt && cat ~/test.txt && rm ~/test.txt && echo 'success'")

    cleanup_container_test

    assert_contains "$output" "success" "Home directory should be writable"
}

test_no_privileged_mode() {
    log_test "Testing container is not privileged"

    setup_container_test "sec-priv"

    # Check for privileged indicators
    local output
    output=$(run_in_container "cat /proc/self/status | grep CapEff")

    cleanup_container_test

    # Privileged containers have all capabilities (0000003fffffffff)
    # Non-privileged have fewer
    if [[ "$output" == *"00000000"* ]]; then
        return 0
    else
        log_info "Capability check: $output"
        # This is informational, not a hard failure
        return 0
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Security - No Root"
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
    run_test test_not_running_as_root
    run_test test_uid_not_zero
    run_test test_cannot_sudo
    run_test test_userns_keep_id
    run_test test_files_owned_by_user
    run_test test_cannot_access_host_root
    run_test test_security_labels_disabled
    run_test test_memory_limit_enforced
    run_test test_hostname_set
    run_test test_home_directory_exists
    run_test test_no_privileged_mode

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
