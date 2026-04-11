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
    assert_contains "$output" "must be: none, filtered, open" "Should show valid options"
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

test_network_mode_default_is_filtered() {
    log_test "Testing default network mode is 'filtered'"

    local output
    local exit_code=0

    # Unset KAPSIS_NETWORK_MODE to test actual default (CI may set it to 'open')
    output=$(unset KAPSIS_NETWORK_MODE; "$LAUNCH_SCRIPT" "$TEST_PROJECT" --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with default network mode"
    assert_not_contains "$output" "--network=none" "Should NOT include --network=none by default"
    assert_contains "$output" "Network: filtered" "Should show filtered network mode"
    assert_contains "$output" "DNS-based allowlist" "Should mention DNS-based allowlist"
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
# KAPSIS_NETWORK_MODE ENV VAR TESTS
# Verify the env var is passed to container for all modes
#===============================================================================

test_network_mode_none_passes_env_var() {
    log_test "Testing --network-mode=none passes KAPSIS_NETWORK_MODE=none to container"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode none --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed"
    assert_contains "$output" "-e KAPSIS_NETWORK_MODE=none" "Should pass KAPSIS_NETWORK_MODE=none to container"
}

test_network_mode_open_passes_env_var() {
    log_test "Testing --network-mode=open passes KAPSIS_NETWORK_MODE=open to container"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode open --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed"
    assert_contains "$output" "-e KAPSIS_NETWORK_MODE=open" "Should pass KAPSIS_NETWORK_MODE=open to container"
}

test_network_mode_filtered_passes_env_var() {
    log_test "Testing --network-mode=filtered passes KAPSIS_NETWORK_MODE=filtered to container"

    local output
    local exit_code=0

    # Unset to avoid CI overrides
    output=$(unset KAPSIS_NETWORK_MODE; "$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode filtered --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed"
    assert_contains "$output" "-e KAPSIS_NETWORK_MODE=filtered" "Should pass KAPSIS_NETWORK_MODE=filtered to container"
}

test_network_mode_default_passes_env_var() {
    log_test "Testing default network mode passes KAPSIS_NETWORK_MODE=filtered to container"

    local output
    local exit_code=0

    # Unset to test actual default
    output=$(unset KAPSIS_NETWORK_MODE; "$LAUNCH_SCRIPT" "$TEST_PROJECT" --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed"
    assert_contains "$output" "-e KAPSIS_NETWORK_MODE=filtered" "Default should pass KAPSIS_NETWORK_MODE=filtered to container"
}

#===============================================================================
# CONTAINER TESTS (require Podman)
# These verify network isolation actually works at runtime
#===============================================================================

test_network_none_blocks_network() {
    log_test "Testing --network=none blocks network access"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_test "Skipping container test in quick mode"
        return 0
    fi

    # Check if container runtime is available
    if ! command -v podman &>/dev/null; then
        log_test "Skipping - podman not available"
        return 0
    fi

    local image_name="${KAPSIS_IMAGE:-kapsis-sandbox:latest}"
    if ! podman image exists "$image_name" 2>/dev/null; then
        log_test "Skipping - container image '$image_name' not found"
        return 0
    fi

    local output
    local exit_code=0

    # Run container with --network=none and try to ping
    # Use --entrypoint="" to skip the Kapsis entrypoint and test raw network isolation
    output=$(timeout 30 podman run --rm \
        --entrypoint="" \
        --network=none \
        "$image_name" \
        bash -c "ping -c 1 -W 5 8.8.8.8 2>&1 && echo 'NETWORK_WORKS' || echo 'NETWORK_BLOCKED'" \
        2>&1) || exit_code=$?

    assert_contains "$output" "NETWORK_BLOCKED" "Network should be blocked with --network=none"
}

test_network_open_allows_network() {
    log_test "Testing default network allows network access"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_test "Skipping container test in quick mode"
        return 0
    fi

    # Check if container runtime is available
    if ! command -v podman &>/dev/null; then
        log_test "Skipping - podman not available"
        return 0
    fi

    local image_name="${KAPSIS_IMAGE:-kapsis-sandbox:latest}"
    if ! podman image exists "$image_name" 2>/dev/null; then
        log_test "Skipping - container image '$image_name' not found"
        return 0
    fi

    local output
    local exit_code=0

    # Run container with default network and try to access network
    # Test TCP connection to a reliable endpoint (DNS resolution + connection establishment)
    # Using multiple fallback endpoints for reliability
    # Use --entrypoint="" to skip the Kapsis entrypoint and test raw network connectivity
    output=$(timeout 30 podman run --rm \
        --entrypoint="" \
        "$image_name" \
        bash -c '
            # Try multiple endpoints for reliability (any success = network works)
            for host in github.com google.com cloudflare.com; do
                if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://$host" 2>/dev/null | grep -qE "^[23]"; then
                    echo "NETWORK_WORKS"
                    exit 0
                fi
            done
            echo "NETWORK_FAILED"
        ' \
        2>&1) || exit_code=$?

    assert_contains "$output" "NETWORK_WORKS" "Network should work with default network mode"
}

#===============================================================================
# RUN TESTS
#===============================================================================

main() {
    setup_test_project

    # Quick tests (no container) - validate flag handling via dry-run
    run_test test_network_mode_flag_validation
    run_test test_network_mode_none_accepted
    run_test test_network_mode_open_accepted
    run_test test_network_mode_default_is_filtered
    run_test test_network_mode_env_override
    run_test test_network_mode_flag_overrides_env

    # KAPSIS_NETWORK_MODE env var tests - verify env var is passed to container
    run_test test_network_mode_none_passes_env_var
    run_test test_network_mode_open_passes_env_var
    run_test test_network_mode_filtered_passes_env_var
    run_test test_network_mode_default_passes_env_var

    # Container tests - verify network isolation actually works
    run_test test_network_none_blocks_network
    run_test test_network_open_allows_network

    cleanup_test_project
    print_summary
}

main "$@"
