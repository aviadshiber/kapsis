#!/usr/bin/env bash
#===============================================================================
# Test: DNS Failure Threshold Check (Issue #216)
#
# Verifies check_dns_failure_threshold() correctly gates container launch
# when DNS resolution failures exceed configured limits.
#
# All tests run without containers (quick tests only).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

DNS_PIN_LIB="$KAPSIS_ROOT/scripts/lib/dns-pin.sh"

#-------------------------------------------------------------------------------
# Helper: source dns-pin.sh once
#-------------------------------------------------------------------------------
_source_dns_pin() {
    # Reset load guard so we can re-source in test isolation
    unset _KAPSIS_DNS_PIN_LOADED 2>/dev/null || true
    source "$DNS_PIN_LIB"
}

#===============================================================================
# LIBRARY VALIDATION
#===============================================================================

test_threshold_function_exists() {
    log_test "check_dns_failure_threshold function exists in dns-pin.sh"

    _source_dns_pin
    if declare -F check_dns_failure_threshold >/dev/null; then
        log_pass "check_dns_failure_threshold is defined"
    else
        log_fail "check_dns_failure_threshold not found in dns-pin.sh"
        _ASSERTION_FAILED=true
    fi
}

test_counts_file_var_exists() {
    log_test "KAPSIS_DNS_COUNTS_FILE variable is declared in dns-pin.sh"

    _source_dns_pin
    # The variable should exist (even if empty)
    if [[ -v KAPSIS_DNS_COUNTS_FILE ]]; then
        log_pass "KAPSIS_DNS_COUNTS_FILE is declared"
    else
        log_fail "KAPSIS_DNS_COUNTS_FILE not declared in dns-pin.sh"
        _ASSERTION_FAILED=true
    fi
}

#===============================================================================
# THRESHOLD LOGIC — RATE-BASED
#===============================================================================

test_no_failures_always_passes() {
    log_test "Zero failures always passes regardless of threshold"

    _source_dns_pin
    assert_command_succeeds \
        "check_dns_failure_threshold 10 0 -1 0.5" \
        "0 failures with 10 resolved should pass"
}

test_rate_below_threshold_passes() {
    log_test "Failure rate below threshold passes (3/10 = 30% < 50%)"

    _source_dns_pin
    assert_command_succeeds \
        "check_dns_failure_threshold 7 3 -1 0.5" \
        "30% failure rate should pass when threshold is 50%"
}

test_rate_at_threshold_passes() {
    log_test "Failure rate exactly at threshold passes (5/10 = 50% not > 50%)"

    _source_dns_pin
    assert_command_succeeds \
        "check_dns_failure_threshold 5 5 -1 0.5" \
        "50% failure rate should pass when threshold is 50% (boundary: strictly greater)"
}

test_rate_exceeds_threshold_fails() {
    log_test "Failure rate above threshold aborts (6/10 = 60% > 50%)"

    _source_dns_pin
    assert_command_fails \
        "check_dns_failure_threshold 4 6 -1 0.5" \
        "60% failure rate should fail when threshold is 50%"
}

test_issue_216_scenario() {
    log_test "Issue #216 scenario: 33/52 domains failed (63%) > 50% threshold"

    _source_dns_pin
    assert_command_fails \
        "check_dns_failure_threshold 19 33 -1 0.5" \
        "63% failure rate should fail (the exact issue #216 case)"
}

test_rate_disabled_skips_check() {
    log_test "Rate check disabled with -1 skips rate evaluation"

    _source_dns_pin
    # 40/50 = 80% failures, but rate check is disabled
    assert_command_succeeds \
        "check_dns_failure_threshold 10 40 -1 -1" \
        "Rate check disabled (-1) should pass even with 80% failure rate"
}

test_strict_threshold_zero() {
    log_test "max_failure_rate=0.0 fails on any single failure"

    _source_dns_pin
    assert_command_fails \
        "check_dns_failure_threshold 9 1 -1 0.0" \
        "Any failure should abort when max_failure_rate=0.0"
}

test_permissive_threshold_one() {
    log_test "max_failure_rate=1.0 allows all domains to fail"

    _source_dns_pin
    # 10/10 = 100%, threshold is 100%; strictly greater comparison means equal passes
    assert_command_succeeds \
        "check_dns_failure_threshold 0 10 -1 1.0" \
        "All failures should pass when max_failure_rate=1.0"
}

#===============================================================================
# THRESHOLD LOGIC — ABSOLUTE COUNT
#===============================================================================

test_absolute_below_limit_passes() {
    log_test "Absolute failures below max_failures passes"

    _source_dns_pin
    assert_command_succeeds \
        "check_dns_failure_threshold 45 4 5 -1" \
        "4 failures with max_failures=5 should pass"
}

test_absolute_at_limit_passes() {
    log_test "Absolute failures at max_failures passes (boundary: strictly greater)"

    _source_dns_pin
    assert_command_succeeds \
        "check_dns_failure_threshold 45 5 5 -1" \
        "5 failures with max_failures=5 should pass"
}

test_absolute_exceeds_limit_fails() {
    log_test "Absolute failures exceeding max_failures aborts"

    _source_dns_pin
    assert_command_fails \
        "check_dns_failure_threshold 44 6 5 -1" \
        "6 failures with max_failures=5 should fail"
}

test_absolute_disabled_skips_check() {
    log_test "Absolute count check disabled with -1"

    _source_dns_pin
    assert_command_succeeds \
        "check_dns_failure_threshold 0 100 -1 -1" \
        "max_failures=-1 should skip count check entirely"
}

#===============================================================================
# COMBINED THRESHOLDS
#===============================================================================

test_both_thresholds_rate_triggers() {
    log_test "Both thresholds set — rate threshold triggers"

    _source_dns_pin
    # 6/10 = 60% > 50%, absolute 6 <= 10
    assert_command_fails \
        "check_dns_failure_threshold 4 6 10 0.5" \
        "Rate threshold (60% > 50%) should trigger even when absolute is fine"
}

test_both_thresholds_absolute_triggers() {
    log_test "Both thresholds set — absolute count triggers first"

    _source_dns_pin
    # 3/100 = 3% (fine on rate), but 3 > 2 on absolute
    assert_command_fails \
        "check_dns_failure_threshold 97 3 2 0.5" \
        "Absolute threshold (3 > 2) should trigger even when rate is fine"
}

#===============================================================================
# GLOBALS POPULATED BY resolve_allowlist_domains
#===============================================================================

test_counts_file_written_after_resolution() {
    log_test "KAPSIS_DNS_COUNTS_FILE is written by resolve_allowlist_domains"

    _source_dns_pin

    # Feed a mix: one IP passthrough (resolved), one unresolvable domain (failed)
    local counts_file
    counts_file=$(mktemp)

    local _resolved _failed
    KAPSIS_DNS_COUNTS_FILE="$counts_file" \
        resolve_allowlist_domains \
            "1.2.3.4,this-domain-should-not-exist-xyz-kapsis-test.invalid" \
            1 dynamic >/dev/null 2>&1 || true

    read -r _resolved _failed < "$counts_file" || true
    rm -f "$counts_file"

    if [[ "$_resolved" -eq 1 ]] && [[ "$_failed" -eq 1 ]]; then
        log_pass "Counts file written correctly: resolved=$_resolved failed=$_failed"
    else
        log_fail "Expected resolved=1 failed=1, got resolved=$_resolved failed=$_failed"
        _ASSERTION_FAILED=true
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "DNS Failure Threshold Tests (Issue #216)"

    run_test test_threshold_function_exists
    run_test test_counts_file_var_exists

    run_test test_no_failures_always_passes
    run_test test_rate_below_threshold_passes
    run_test test_rate_at_threshold_passes
    run_test test_rate_exceeds_threshold_fails
    run_test test_issue_216_scenario
    run_test test_rate_disabled_skips_check
    run_test test_strict_threshold_zero
    run_test test_permissive_threshold_one

    run_test test_absolute_below_limit_passes
    run_test test_absolute_at_limit_passes
    run_test test_absolute_exceeds_limit_fails
    run_test test_absolute_disabled_skips_check

    run_test test_both_thresholds_rate_triggers
    run_test test_both_thresholds_absolute_triggers

    run_test test_counts_file_written_after_resolution

    print_summary
}

main "$@"
