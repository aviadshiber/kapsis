#!/usr/bin/env bash
#===============================================================================
# Test: --userns resolution chain (kapsis#361)
#
# Covers the three-tier precedence introduced to fix the keep-id degenerate
# mapping bug on hosts with domain UIDs (>1B):
#
#   1. KAPSIS_USERNS env var          (highest precedence; debug override)
#   2. SECURITY_USERNS from YAML      (set by launch-agent.sh's parse path)
#   3. detect_userns_default()        (autodetect from host UID)
#
# All tests are QUICK (no container, no real Podman VM needed). They stub
# the `id` builtin to simulate different host UIDs and source security.sh
# directly to call _resolve_userns / _detect_userns_default.
#
# Category: validation
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

SECURITY_SCRIPT="$KAPSIS_ROOT/scripts/lib/security.sh"

#===============================================================================
# Shared stub infrastructure
#===============================================================================

# _setup: source security.sh with a clean env and define an `id` stub the
# tests can configure via STUB_HOST_UID.  Must be called at the top of every
# test function so the stub doesn't leak into siblings.
_setup() {
    # Clear any inherited values so each test sees a clean slate.
    unset KAPSIS_USERNS
    unset SECURITY_USERNS

    STUB_HOST_UID="${STUB_HOST_UID:-1000}"

    # Override the `id` external — `id -u` is what _detect_userns_default
    # uses to decide the threshold.  Bash function definitions shadow the
    # external binary for the current shell.
    id() {
        case "${1:-}" in
            -u) echo "$STUB_HOST_UID" ;;
            *)  echo "uid=${STUB_HOST_UID}(stub) gid=${STUB_HOST_UID}(stub)" ;;
        esac
    }
    export -f id

    # shellcheck source=scripts/lib/security.sh
    source "$SECURITY_SCRIPT"
}

_teardown() {
    unset -f id 2>/dev/null || true
    unset KAPSIS_USERNS SECURITY_USERNS STUB_HOST_UID
}

#===============================================================================
# detect_userns_default tests
#===============================================================================

test_detect_default_low_uid_returns_plain_keep_id() {
    log_test "detect_userns_default returns 'keep-id' for low host UID (501)"
    STUB_HOST_UID=501
    _setup
    local result
    result=$(_detect_userns_default)
    assert_equals "keep-id" "$result" "low host UID should use plain keep-id"
    _teardown
}

test_detect_default_root_uid_returns_plain_keep_id() {
    log_test "detect_userns_default returns 'keep-id' for UID 0"
    STUB_HOST_UID=0
    _setup
    local result
    result=$(_detect_userns_default)
    assert_equals "keep-id" "$result" "root UID is well under threshold"
    _teardown
}

test_detect_default_at_threshold_returns_plain_keep_id() {
    log_test "detect_userns_default at exactly 60000 stays on plain keep-id"
    STUB_HOST_UID=60000
    _setup
    local result
    result=$(_detect_userns_default)
    assert_equals "keep-id" "$result" "UID == threshold is inclusive lower"
    _teardown
}

test_detect_default_just_above_threshold_returns_explicit_form() {
    log_test "detect_userns_default at 60001 switches to keep-id:uid=1000,gid=1000"
    STUB_HOST_UID=60001
    _setup
    local result
    result=$(_detect_userns_default)
    assert_equals "keep-id:uid=1000,gid=1000" "$result" \
        "UID above threshold needs explicit uid/gid override"
    _teardown
}

test_detect_default_domain_uid_returns_explicit_form() {
    log_test "detect_userns_default on AD domain UID (1.88B) returns explicit form"
    STUB_HOST_UID=1882662165
    _setup
    local result
    result=$(_detect_userns_default)
    assert_equals "keep-id:uid=1000,gid=1000" "$result" \
        "domain UID is the motivating case for #361 — must use explicit form"
    _teardown
}

#===============================================================================
# _resolve_userns precedence tests
#===============================================================================

test_resolve_env_var_wins_over_yaml_and_default() {
    log_test "KAPSIS_USERNS env var beats SECURITY_USERNS yaml + autodetect"
    STUB_HOST_UID=1882662165
    _setup
    export KAPSIS_USERNS="auto"
    export SECURITY_USERNS="keep-id"
    local result
    result=$(_resolve_userns)
    assert_equals "auto" "$result" "env var has highest precedence"
    _teardown
}

test_resolve_yaml_wins_over_default() {
    log_test "SECURITY_USERNS yaml beats autodetected default"
    STUB_HOST_UID=1882662165
    _setup
    export SECURITY_USERNS="host"
    local result
    result=$(_resolve_userns)
    assert_equals "host" "$result" "yaml setting wins when env is unset"
    _teardown
}

test_resolve_falls_back_to_autodetect_when_unset() {
    log_test "_resolve_userns falls through to autodetect when env+yaml both unset"
    STUB_HOST_UID=1882662165
    _setup
    local result
    result=$(_resolve_userns)
    assert_equals "keep-id:uid=1000,gid=1000" "$result" \
        "no env, no yaml — should call _detect_userns_default"
    _teardown
}

test_resolve_falls_back_to_autodetect_for_low_uid_when_unset() {
    log_test "_resolve_userns autodetect returns plain keep-id for low host UID"
    STUB_HOST_UID=501
    _setup
    local result
    result=$(_resolve_userns)
    assert_equals "keep-id" "$result" "low UID + no overrides = plain keep-id"
    _teardown
}

#===============================================================================
# Regression guard
#===============================================================================
# Full generate_process_isolation_args integration is not covered here: it
# pulls in SECURITY_DEFAULTS[] which requires the standard profile to be
# bootstrapped, which interacts with launch-agent.sh's environment in ways
# that are hard to stub without a real container. The _resolve_userns +
# _detect_userns_default coverage above is sufficient to guarantee that
# generate_process_isolation_args's `--userns=$(_resolve_userns)` line emits
# the correct value — the function just substitutes our resolver's output.

#===============================================================================
# Main
#===============================================================================

run_test test_detect_default_low_uid_returns_plain_keep_id
run_test test_detect_default_root_uid_returns_plain_keep_id
run_test test_detect_default_at_threshold_returns_plain_keep_id
run_test test_detect_default_just_above_threshold_returns_explicit_form
run_test test_detect_default_domain_uid_returns_explicit_form
run_test test_resolve_env_var_wins_over_yaml_and_default
run_test test_resolve_yaml_wins_over_default
run_test test_resolve_falls_back_to_autodetect_when_unset
run_test test_resolve_falls_back_to_autodetect_for_low_uid_when_unset

print_summary
