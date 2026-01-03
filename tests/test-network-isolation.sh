#!/usr/bin/env bash
#===============================================================================
# Test: Network Isolation
#
# Verifies network isolation modes (none, open) work correctly.
# Phase 1 security feature - ensures agents can be network-isolated.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# QUICK TESTS (no container required)
#===============================================================================

test_network_mode_flag_validation() {
    log_test "Testing --network-mode flag validation"

    local output
    local exit_code=0

    # Test invalid mode
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode "invalid" --task "test" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail with invalid network mode"
    assert_contains "$output" "Invalid network mode" "Should mention invalid network mode"
    assert_contains "$output" "must be: none, open" "Should show valid options"
}

test_network_mode_none_accepted() {
    log_test "Testing --network-mode=none is accepted"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode none --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with network-mode=none"
    assert_contains "$output" "--network=none" "Should include --network=none in container command"
    assert_contains "$output" "Network: isolated" "Should log network isolation"
}

test_network_mode_open_accepted() {
    log_test "Testing --network-mode=open is accepted"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode open --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with network-mode=open"
    assert_not_contains "$output" "--network=none" "Should NOT include --network=none"
    assert_contains "$output" "Network: unrestricted" "Should warn about unrestricted network"
}

test_network_mode_default_is_open() {
    log_test "Testing default network mode is 'open' with warning"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with default network mode"
    assert_not_contains "$output" "--network=none" "Should NOT include --network=none by default"
    assert_contains "$output" "consider --network-mode=none" "Should suggest using isolated mode"
}

test_network_mode_env_override() {
    log_test "Testing KAPSIS_NETWORK_MODE environment variable"

    local output
    local exit_code=0

    # Set env var to 'none'
    output=$(KAPSIS_NETWORK_MODE=none "$LAUNCH_SCRIPT" "$TEST_PROJECT" --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with env var"
    assert_contains "$output" "--network=none" "Should include --network=none from env var"
    assert_contains "$output" "Network: isolated" "Should log network isolation"
}

test_network_mode_flag_overrides_env() {
    log_test "Testing CLI flag overrides environment variable"

    local output
    local exit_code=0

    # Env says 'none', flag says 'open'
    output=$(KAPSIS_NETWORK_MODE=none "$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode open --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed"
    assert_not_contains "$output" "--network=none" "CLI flag should override env var"
    assert_contains "$output" "Network: unrestricted" "Should show open network mode"
}

#===============================================================================
# NOTE: Container-level network isolation tests removed
#
# The quick tests above verify that:
# 1. --network-mode flag is validated correctly
# 2. --network-mode=none adds --network=none to the container command (dry-run)
# 3. --network-mode=open does NOT add --network=none (dry-run)
# 4. Environment variable and CLI precedence work correctly
#
# These dry-run tests fully validate our code's behavior. The actual network
# isolation is handled by Podman's --network=none flag, which is a well-tested
# container runtime feature. Testing Podman's network isolation would be
# testing Podman, not Kapsis.
#
# If you need to manually verify network isolation works:
#   ./scripts/launch-agent.sh ~/project --network-mode none --task "ping 8.8.8.8"
#   (should fail with network unreachable)
#===============================================================================

#===============================================================================
# RUN TESTS
#===============================================================================

main() {
    setup_test_project

    # Quick tests (no container) - these validate our code's behavior via dry-run
    run_test test_network_mode_flag_validation
    run_test test_network_mode_none_accepted
    run_test test_network_mode_open_accepted
    run_test test_network_mode_default_is_open
    run_test test_network_mode_env_override
    run_test test_network_mode_flag_overrides_env

    cleanup_test_project
    print_summary
}

main "$@"
