#!/usr/bin/env bash
#===============================================================================
# Test: Backend Abstraction
#
# Verifies that the backend dispatch system works correctly:
# - Default backend is podman
# - --backend flag is parsed
# - Invalid backends are rejected
# - Backend files exist and define required functions
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_backend_constants_exist() {
    log_test "Testing backend constants are defined"

    # Source constants in a subshell to avoid polluting test state
    local default_backend supported_backends
    default_backend=$(bash -c "source '$KAPSIS_ROOT/scripts/lib/constants.sh' && echo \"\$KAPSIS_DEFAULT_BACKEND\"")
    supported_backends=$(bash -c "source '$KAPSIS_ROOT/scripts/lib/constants.sh' && echo \"\$KAPSIS_SUPPORTED_BACKENDS\"")

    assert_equals "podman" "$default_backend" "Default backend should be podman"
    assert_contains "$supported_backends" "podman" "Supported backends should include podman"
    assert_contains "$supported_backends" "k8s" "Supported backends should include k8s"
}

test_k8s_constants_exist() {
    log_test "Testing K8s-specific constants are defined"

    local poll_interval default_namespace
    poll_interval=$(bash -c "source '$KAPSIS_ROOT/scripts/lib/constants.sh' && echo \"\$KAPSIS_K8S_DEFAULT_POLL_INTERVAL\"")
    default_namespace=$(bash -c "source '$KAPSIS_ROOT/scripts/lib/constants.sh' && echo \"\$KAPSIS_K8S_DEFAULT_NAMESPACE\"")

    assert_equals "10" "$poll_interval" "Default poll interval should be 10"
    assert_equals "default" "$default_namespace" "Default namespace should be 'default'"
}

test_default_backend_is_podman() {
    log_test "Testing default backend is podman in dry-run"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Dry-run should succeed"
    assert_contains "$output" "podman run" "Default should use podman"
}

test_explicit_backend_podman() {
    log_test "Testing --backend podman matches default"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --backend podman --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Dry-run with --backend podman should succeed"
    assert_contains "$output" "podman run" "Should use podman"
}

test_invalid_backend_rejected() {
    log_test "Testing invalid backend is rejected"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --backend docker --task "test" --dry-run 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Invalid backend should fail"
    assert_contains "$output" "Unsupported backend" "Should show error about unsupported backend"
}

test_backend_podman_file_exists() {
    log_test "Testing podman backend file exists"

    assert_file_exists "$KAPSIS_ROOT/scripts/backends/podman.sh" "Podman backend file should exist"
}

test_backend_k8s_file_exists() {
    log_test "Testing k8s backend file exists"

    assert_file_exists "$KAPSIS_ROOT/scripts/backends/k8s.sh" "K8s backend file should exist"
}

test_podman_backend_defines_required_functions() {
    log_test "Testing podman backend defines required functions"

    # Source backend in subshell and check for functions
    local result
    result=$(bash -c "
        source '$KAPSIS_ROOT/scripts/lib/constants.sh'
        source '$KAPSIS_ROOT/scripts/lib/logging.sh'
        init_logging 'test'
        source '$KAPSIS_ROOT/scripts/backends/podman.sh'
        for fn in backend_validate backend_build_spec backend_run backend_get_exit_code backend_cleanup backend_supports; do
            if type -t \"\$fn\" &>/dev/null; then
                echo \"\$fn:ok\"
            else
                echo \"\$fn:missing\"
            fi
        done
    " 2>/dev/null)

    assert_contains "$result" "backend_validate:ok" "backend_validate should be defined"
    assert_contains "$result" "backend_build_spec:ok" "backend_build_spec should be defined"
    assert_contains "$result" "backend_run:ok" "backend_run should be defined"
    assert_contains "$result" "backend_get_exit_code:ok" "backend_get_exit_code should be defined"
    assert_contains "$result" "backend_cleanup:ok" "backend_cleanup should be defined"
    assert_contains "$result" "backend_supports:ok" "backend_supports should be defined"
}

test_k8s_dry_run_outputs_yaml() {
    log_test "Testing --backend k8s --dry-run outputs CR YAML"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --backend k8s --task "test task" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "K8s dry-run should succeed"
    assert_contains "$output" "apiVersion: kapsis.io/v1alpha1" "Should contain CRD apiVersion"
    assert_contains "$output" "kind: AgentRequest" "Should contain kind"
    assert_not_contains "$output" "podman run" "Should NOT contain podman run"
}

test_k8s_timeout_constant_exists() {
    log_test "Testing K8s timeout constant is defined"

    local timeout
    timeout=$(bash -c "source '$KAPSIS_ROOT/scripts/lib/constants.sh' && echo \"\$KAPSIS_K8S_DEFAULT_TIMEOUT\"")

    assert_equals "7200" "$timeout" "Default timeout should be 7200"
}

test_k8s_backend_defines_required_functions() {
    log_test "Testing k8s backend defines required functions"

    local result
    result=$(bash -c "
        source '$KAPSIS_ROOT/scripts/lib/constants.sh'
        source '$KAPSIS_ROOT/scripts/lib/logging.sh'
        init_logging 'test'
        # Provide stubs for variables k8s backend expects
        DRY_RUN=true
        AGENT_ID=test
        source '$KAPSIS_ROOT/scripts/backends/k8s.sh'
        for fn in backend_validate backend_build_spec backend_run backend_get_exit_code backend_cleanup backend_supports; do
            if type -t \"\$fn\" &>/dev/null; then
                echo \"\$fn:ok\"
            else
                echo \"\$fn:missing\"
            fi
        done
    " 2>/dev/null)

    assert_contains "$result" "backend_validate:ok" "backend_validate should be defined"
    assert_contains "$result" "backend_build_spec:ok" "backend_build_spec should be defined"
    assert_contains "$result" "backend_run:ok" "backend_run should be defined"
    assert_contains "$result" "backend_get_exit_code:ok" "backend_get_exit_code should be defined"
    assert_contains "$result" "backend_cleanup:ok" "backend_cleanup should be defined"
    assert_contains "$result" "backend_supports:ok" "backend_supports should be defined"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Backend Abstraction"

    setup_test_project

    run_test test_backend_constants_exist
    run_test test_k8s_constants_exist
    run_test test_k8s_timeout_constant_exists
    run_test test_default_backend_is_podman
    run_test test_explicit_backend_podman
    run_test test_invalid_backend_rejected
    run_test test_backend_podman_file_exists
    run_test test_backend_k8s_file_exists
    run_test test_podman_backend_defines_required_functions
    run_test test_k8s_backend_defines_required_functions
    run_test test_k8s_dry_run_outputs_yaml

    cleanup_test_project

    print_summary
}

main "$@"
