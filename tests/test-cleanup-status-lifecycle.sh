#!/usr/bin/env bash
#===============================================================================
# Test: Status file lifecycle (clean_status TTL + zombie sweep) — Issue #430
#
# Regression for a lifecycle mismatch: clean_status() used to delete every
# "complete" status.json unconditionally on the next cleanup run, while
# clean_conversations() keeps the matching conversations/<id>/ dir for
# KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS (default 7 days). A conversation dir
# could then outlive its own status.json and appear "orphaned" to the
# dashboard. The fix makes clean_status() share the exact same TTL constant
# for the complete-phase retention (KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS is
# declared `readonly` in scripts/lib/constants.sh — fixed at 7 days, not
# independently overridable — so this test ages fixtures well past that
# fixed value rather than trying to tune it), and adds a slower (default 6h,
# genuinely overridable via env — not constants.sh) sweep that reaps
# non-terminal status.json files stuck past KAPSIS_DEFAULT_STATUS_STALE_HOURS
# — a zombie the liveness monitor never caught (or a status file left behind
# by a killed/crashed launcher).
#
# Coverage:
#   1. Fresh complete status.json survives clean_status
#   2. Complete status.json older than the (fixed 7-day) TTL is removed
#   3. Fresh non-terminal status.json survives (protects live agents)
#   4. Non-terminal status.json older than the stale-hours threshold is
#      removed (zombie reap), with a log_warn
#   5. CLEAN_ALL=true bypasses both age checks
#
# Category: cleanup (no container required)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

print_test_header "Status File Lifecycle (TTL + zombie sweep)"

# NOTE: KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS is `readonly` (constants.sh) —
# fixed at 7 days, not settable per-invocation. Only stale_hours (a plain
# bash default in kapsis-cleanup.sh, not constants.sh) is genuinely
# overridable, so only it is parametrized here.
_run_clean_status() {
    local status_root="$1"
    local dry_run="${2:-false}"
    local clean_all="${3:-false}"
    local stale_hours="${4:-6}"
    run_cleanup_snippet '
        STATUS_DIR="'"$status_root"'"
        CLEAN_ALL="'"$clean_all"'"
        DRY_RUN="'"$dry_run"'"
        PROJECT_FILTER=""
        KAPSIS_DEFAULT_STATUS_STALE_HOURS="'"$stale_hours"'"
        TOTAL_SIZE_FREED=0
        ITEMS_CLEANED=0
        clean_status
    '
}

# Age a path well past a given threshold (BSD/GNU touch portable), in days.
_age_days() {
    local path="$1" days="$2"
    touch -d "${days} days ago" "$path" 2>/dev/null \
        || touch -t "$(date -v-"${days}"d +%Y%m%d0000 2>/dev/null || date -d "${days} days ago" +%Y%m%d0000)" "$path"
}

# Age a path well past a given threshold, in hours (approximated via minutes
# for portability — days-based touch above doesn't have hour granularity).
_age_hours() {
    local path="$1" hours="$2"
    local mins=$((hours * 60))
    touch -d "${mins} minutes ago" "$path" 2>/dev/null \
        || touch -t "$(date -v-"${mins}"M +%Y%m%d%H%M 2>/dev/null || date -d "${mins} minutes ago" +%Y%m%d%H%M)" "$path"
}

_write_status() {
    local path="$1" phase="$2"
    printf '{"phase": "%s", "progress": 50, "message": "test"}\n' "$phase" > "$path"
}

#-------------------------------------------------------------------------------
# 1. Fresh complete status.json survives.
#-------------------------------------------------------------------------------
test_fresh_complete_survives() {
    local status_root
    status_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-fresh-complete.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$status_root'" RETURN

    _write_status "$status_root/kapsis-proj-1.json" "complete"

    _run_clean_status "$status_root" "false" "false" "6" >/dev/null

    assert_file_exists "$status_root/kapsis-proj-1.json" \
        "Fresh complete status.json (within TTL) must survive clean_status"
}

#-------------------------------------------------------------------------------
# 2. Complete status.json older than the TTL is removed.
#-------------------------------------------------------------------------------
test_expired_complete_removed() {
    local status_root
    status_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-expired-complete.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$status_root'" RETURN

    _write_status "$status_root/kapsis-proj-2.json" "complete"
    _age_days "$status_root/kapsis-proj-2.json" 60   # well past the fixed 7-day TTL

    _run_clean_status "$status_root" "false" "false" "6" >/dev/null

    assert_file_not_exists "$status_root/kapsis-proj-2.json" \
        "Complete status.json older than KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS should be removed"
}

#-------------------------------------------------------------------------------
# 3. Fresh non-terminal status.json survives (protects live agents).
#-------------------------------------------------------------------------------
test_fresh_nonterminal_survives() {
    local status_root
    status_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-fresh-running.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$status_root'" RETURN

    _write_status "$status_root/kapsis-proj-3.json" "running"

    _run_clean_status "$status_root" "false" "false" "6" >/dev/null

    assert_file_exists "$status_root/kapsis-proj-3.json" \
        "Fresh non-terminal status.json (younger than stale threshold) must never be reaped"
}

#-------------------------------------------------------------------------------
# 4. Non-terminal status.json older than the stale threshold is reaped
#    (zombie), with a log_warn.
#-------------------------------------------------------------------------------
test_stale_nonterminal_reaped_with_warning() {
    local status_root
    status_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-zombie.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$status_root'" RETURN

    _write_status "$status_root/kapsis-proj-4.json" "running"
    _age_hours "$status_root/kapsis-proj-4.json" 10   # past the 6h default stale threshold

    local output
    output=$(_run_clean_status "$status_root" "false" "false" "6")

    assert_file_not_exists "$status_root/kapsis-proj-4.json" \
        "Non-terminal status.json older than KAPSIS_DEFAULT_STATUS_STALE_HOURS should be reaped as a zombie"
    assert_contains "$output" "WARN" \
        "Zombie reap must log a warning"
    assert_contains "$output" "kapsis-proj-4.json" \
        "Zombie reap warning must name the reaped file"
}

#-------------------------------------------------------------------------------
# 5. CLEAN_ALL=true bypasses both age checks.
#-------------------------------------------------------------------------------
test_clean_all_bypasses_age_checks() {
    local status_root
    status_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-clean-all.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$status_root'" RETURN

    _write_status "$status_root/kapsis-proj-5a.json" "complete"
    _write_status "$status_root/kapsis-proj-5b.json" "running"

    _run_clean_status "$status_root" "false" "true" "6" >/dev/null

    assert_file_not_exists "$status_root/kapsis-proj-5a.json" \
        "CLEAN_ALL=true should remove a fresh complete status.json regardless of TTL"
    assert_file_not_exists "$status_root/kapsis-proj-5b.json" \
        "CLEAN_ALL=true should remove a fresh non-terminal status.json regardless of stale threshold"
}

#===============================================================================
# Runner
#===============================================================================

run_test test_fresh_complete_survives
run_test test_expired_complete_removed
run_test test_fresh_nonterminal_survives
run_test test_stale_nonterminal_reaped_with_warning
run_test test_clean_all_bypasses_age_checks

print_summary
