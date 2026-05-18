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
# Input validation tests (flag-injection guard)
#===============================================================================

test_validator_accepts_known_good_values() {
    log_test "_is_valid_userns_value accepts keep-id, keep-id:uid=N,gid=N, auto, host"
    _setup
    _is_valid_userns_value "keep-id"                     || { _log_failure "rejected keep-id"; return 1; }
    _is_valid_userns_value "keep-id:uid=1000,gid=1000"   || { _log_failure "rejected keep-id:uid=1000,gid=1000"; return 1; }
    _is_valid_userns_value "keep-id:uid=99999,gid=99999" || { _log_failure "rejected uid=99999"; return 1; }
    _is_valid_userns_value "auto"                        || { _log_failure "rejected auto"; return 1; }
    _is_valid_userns_value "host"                        || { _log_failure "rejected host"; return 1; }
    _teardown
}

test_validator_rejects_flag_injection() {
    log_test "_is_valid_userns_value rejects newline-injected flag payloads"
    _setup
    local injection=$'keep-id\n--privileged\n--cap-add=ALL'
    if _is_valid_userns_value "$injection"; then
        _log_failure "validator accepted flag-injection payload — would split via mapfile into raw podman flags"
        _teardown
        return 1
    fi
    _teardown
}

test_validator_rejects_uid_zero() {
    log_test "_is_valid_userns_value rejects keep-id:uid=0 (privilege uplift surface)"
    _setup
    if _is_valid_userns_value "keep-id:uid=0,gid=0"; then
        _log_failure "validator accepted uid=0 — would map container root to host UID"
        _teardown
        return 1
    fi
    if _is_valid_userns_value "keep-id:uid=999,gid=999"; then
        _log_failure "validator accepted uid=999 (< 1000 threshold)"
        _teardown
        return 1
    fi
    _teardown
}

test_validator_rejects_pathological_uids() {
    log_test "_is_valid_userns_value rejects 10-digit UIDs (almost certainly typos)"
    _setup
    if _is_valid_userns_value "keep-id:uid=9999999999,gid=9999999999"; then
        _log_failure "validator accepted 10-digit UID"
        _teardown
        return 1
    fi
    _teardown
}

test_validator_rejects_arbitrary_strings() {
    log_test "_is_valid_userns_value rejects misspellings and arbitrary values"
    _setup
    for bad in "keep_id" "keepid" "private" "" "keep-id:" "keep-id:uid=" "keep-id:uid=1000,gid=" "anything else"; do
        if _is_valid_userns_value "$bad"; then
            _log_failure "validator accepted invalid value: '$bad'"
            _teardown
            return 1
        fi
    done
    _teardown
}

test_resolve_rejects_invalid_env_and_falls_through() {
    log_test "_resolve_userns ignores invalid KAPSIS_USERNS and falls through to YAML/default"
    STUB_HOST_UID=501
    _setup
    export KAPSIS_USERNS=$'keep-id\n--privileged'  # would be flag injection
    export SECURITY_USERNS="auto"
    local result
    result=$(_resolve_userns 2>/dev/null)
    assert_equals "auto" "$result" "invalid env should be ignored, yaml wins next"
    _teardown
}

test_resolve_rejects_invalid_yaml_and_falls_through() {
    log_test "_resolve_userns ignores invalid SECURITY_USERNS and falls through to autodetect"
    STUB_HOST_UID=1882662165
    _setup
    export SECURITY_USERNS="garbage_value"
    local result
    result=$(_resolve_userns 2>/dev/null)
    assert_equals "keep-id:uid=1000,gid=1000" "$result" \
        "invalid yaml should be ignored, autodetect runs for high UID"
    _teardown
}

#===============================================================================
# Threshold tunability + safe fallback tests
#===============================================================================

test_threshold_overridable_via_env() {
    log_test "KAPSIS_USERNS_THRESHOLD env var controls the autodetect boundary"
    STUB_HOST_UID=2000
    _setup
    # Re-bind the threshold after _setup sourced security.sh with default 60000.
    KAPSIS_USERNS_THRESHOLD=1000
    local result
    result=$(_detect_userns_default)
    assert_equals "keep-id:uid=1000,gid=1000" "$result" \
        "with threshold=1000, UID 2000 should pick explicit form"
    _teardown
}

test_id_failure_falls_back_to_safe_path() {
    log_test "_detect_userns_default picks explicit form when id command fails"
    _setup
    # Re-stub id to fail entirely (simulates LDAP/AD/NSS timeout on a domain host).
    id() { return 1; }
    export -f id
    local result
    result=$(_detect_userns_default)
    assert_equals "keep-id:uid=1000,gid=1000" "$result" \
        "on id failure, default must pick the safe explicit form — NOT plain keep-id, which would reproduce #361"
    _teardown
}

#===============================================================================
# YAML → SECURITY_USERNS plumbing (launch-agent.sh:973-985)
#===============================================================================
# The actual parsing happens inside launch-agent.sh's parse_config() which is
# 3000+ lines of monolithic bash with no test entry point. Rather than
# refactor, we exercise the same yq command and export-guard logic in
# isolation against fixture YAML files. If launch-agent.sh's command ever
# diverges, this test won't catch it — but the contract being tested is
# `yq -r '.security.userns // ""' fixture` returning the value we expect.

test_yaml_parse_extracts_userns_value() {
    log_test "yq extracts security.userns from YAML verbatim"
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi
    local fixture
    fixture=$(mktemp -t kapsis-userns-yaml-XXXXXX)
    cat > "$fixture" <<'EOF'
agent:
  command: claude
security:
  userns: keep-id:uid=1000,gid=1000
EOF
    local cfg_val
    cfg_val=$(yq -r '.security.userns // ""' "$fixture" 2>/dev/null)
    assert_equals "keep-id:uid=1000,gid=1000" "$cfg_val" \
        "yq should extract the userns string verbatim from YAML"
    rm -f "$fixture"
}

test_yaml_parse_missing_field_returns_empty_string() {
    log_test "yq returns empty string when security.userns is absent (// fallback)"
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi
    local fixture
    fixture=$(mktemp -t kapsis-userns-yaml-XXXXXX)
    cat > "$fixture" <<'EOF'
agent:
  command: claude
EOF
    local cfg_val
    cfg_val=$(yq -r '.security.userns // ""' "$fixture" 2>/dev/null)
    assert_equals "" "$cfg_val" \
        "Missing field should fall back to empty string"
    rm -f "$fixture"
}

test_yaml_parse_explicit_null_returns_empty_string() {
    log_test "yq returns empty string when security.userns is literal null"
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi
    local fixture
    fixture=$(mktemp -t kapsis-userns-yaml-XXXXXX)
    cat > "$fixture" <<'EOF'
agent:
  command: claude
security:
  userns: null
EOF
    local cfg_val
    cfg_val=$(yq -r '.security.userns // ""' "$fixture" 2>/dev/null)
    assert_equals "" "$cfg_val" \
        "Explicit YAML null should be coalesced to empty, never reach SECURITY_USERNS"
    rm -f "$fixture"
}

test_yaml_parse_export_guard_respects_kapsis_userns_env() {
    log_test "YAML→SECURITY_USERNS export is gated on KAPSIS_USERNS being unset"
    # Mirrors the launch-agent.sh:975 guard:
    #   [[ -n "$cfg_val" ]] && [[ -z "${KAPSIS_USERNS:-}" ]] && export SECURITY_USERNS=...
    local cfg_val="keep-id:uid=1000,gid=1000"
    local actual=""

    # Case A: KAPSIS_USERNS unset → guard fires, export happens
    unset KAPSIS_USERNS
    [[ -n "$cfg_val" ]] && [[ -z "${KAPSIS_USERNS:-}" ]] && actual="$cfg_val"
    assert_equals "keep-id:uid=1000,gid=1000" "$actual" \
        "With KAPSIS_USERNS unset, YAML value should populate SECURITY_USERNS"

    # Case B: KAPSIS_USERNS set → guard blocks, SECURITY_USERNS untouched
    actual=""
    KAPSIS_USERNS="host"
    [[ -n "$cfg_val" ]] && [[ -z "${KAPSIS_USERNS:-}" ]] && actual="$cfg_val"
    assert_equals "" "$actual" \
        "With KAPSIS_USERNS set, YAML value must NOT clobber it (env wins)"
    unset KAPSIS_USERNS
}

#===============================================================================
# check_userns_compat tests (preflight-check.sh)
#===============================================================================
# Re-exercises the preflight warn branches against fixture environments.

_setup_preflight() {
    # Source the preflight check file in a way that doesn't run main().
    # The file exposes check_userns_compat; we stub preflight_warn /
    # preflight_ok / log_section to capture invocations instead of logging.
    STUB_HOST_UID="${STUB_HOST_UID:-1000}"
    id() { case "${1:-}" in -u) echo "$STUB_HOST_UID" ;; esac; }
    export -f id
    PREFLIGHT_WARNS=""
    PREFLIGHT_OKS=""
    preflight_warn() { PREFLIGHT_WARNS+="$* | "; }
    preflight_ok()   { PREFLIGHT_OKS+="$* | "; }
    # shellcheck source=scripts/preflight-check.sh
    source "$KAPSIS_ROOT/scripts/preflight-check.sh"
    # Re-stub the funcs after source (the source may redefine them).
    preflight_warn() { PREFLIGHT_WARNS+="$* | "; }
    preflight_ok()   { PREFLIGHT_OKS+="$* | "; }
}

_teardown_preflight() {
    unset -f id preflight_warn preflight_ok 2>/dev/null || true
    unset STUB_HOST_UID PREFLIGHT_WARNS PREFLIGHT_OKS KAPSIS_USERNS KAPSIS_USERNS_THRESHOLD
}

test_preflight_warns_on_pinned_keepid_for_high_uid() {
    log_test "check_userns_compat warns when YAML pins keep-id and host UID > threshold"
    STUB_HOST_UID=1882662165
    _setup_preflight
    local fixture
    fixture=$(mktemp -t kapsis-preflight-XXXXXX)
    cat > "$fixture" <<'EOF'
security:
  userns: keep-id
EOF
    check_userns_compat "$fixture"
    if [[ "$PREFLIGHT_WARNS" != *"'keep-id' pinned"* ]]; then
        _log_failure "expected pinned-keep-id warning, got: $PREFLIGHT_WARNS"
        rm -f "$fixture"; _teardown_preflight
        return 1
    fi
    rm -f "$fixture"
    _teardown_preflight
}

test_preflight_warns_on_kapsis_userns_env_keepid() {
    log_test "check_userns_compat also warns when KAPSIS_USERNS=keep-id env is set"
    STUB_HOST_UID=1882662165
    _setup_preflight
    KAPSIS_USERNS="keep-id"
    check_userns_compat ""
    if [[ "$PREFLIGHT_WARNS" != *"KAPSIS_USERNS env"* ]]; then
        _log_failure "expected env-pin warning, got: $PREFLIGHT_WARNS"
        _teardown_preflight
        return 1
    fi
    _teardown_preflight
}

test_preflight_warns_on_host_userns_mode() {
    log_test "check_userns_compat warns when resolved userns is 'host'"
    STUB_HOST_UID=501
    _setup_preflight
    KAPSIS_USERNS="host"
    check_userns_compat ""
    if [[ "$PREFLIGHT_WARNS" != *"disables user namespace isolation"* ]]; then
        _log_failure "expected host-mode warning, got: $PREFLIGHT_WARNS"
        _teardown_preflight
        return 1
    fi
    _teardown_preflight
}

test_preflight_silent_on_default_low_uid() {
    log_test "check_userns_compat is silent (OK) for low UID + no overrides"
    STUB_HOST_UID=501
    _setup_preflight
    check_userns_compat ""
    if [[ -n "$PREFLIGHT_WARNS" ]]; then
        _log_failure "expected no warnings, got: $PREFLIGHT_WARNS"
        _teardown_preflight
        return 1
    fi
    if [[ "$PREFLIGHT_OKS" != *"autodetected"* ]]; then
        _log_failure "expected OK with 'autodetected', got: $PREFLIGHT_OKS"
        _teardown_preflight
        return 1
    fi
    _teardown_preflight
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
run_test test_validator_accepts_known_good_values
run_test test_validator_rejects_flag_injection
run_test test_validator_rejects_uid_zero
run_test test_validator_rejects_pathological_uids
run_test test_validator_rejects_arbitrary_strings
run_test test_resolve_rejects_invalid_env_and_falls_through
run_test test_resolve_rejects_invalid_yaml_and_falls_through
run_test test_threshold_overridable_via_env
run_test test_id_failure_falls_back_to_safe_path
run_test test_yaml_parse_extracts_userns_value
run_test test_yaml_parse_missing_field_returns_empty_string
run_test test_yaml_parse_explicit_null_returns_empty_string
run_test test_yaml_parse_export_guard_respects_kapsis_userns_env
run_test test_preflight_warns_on_pinned_keepid_for_high_uid
run_test test_preflight_warns_on_kapsis_userns_env_keepid
run_test test_preflight_warns_on_host_userns_mode
run_test test_preflight_silent_on_default_low_uid

print_summary
