#!/usr/bin/env bash
#===============================================================================
# Test: Snapshot directory cleanup (Issue #389)
#
# Verifies the TTL-based cleanup of ~/.kapsis/snapshots/ added to fix the
# unbounded growth that caused a Slack-bot outage (109 GB / 852 dirs / 87 days
# filled disk to 98%).
#
# Coverage:
#   1. Constants declared (KAPSIS_DEFAULT_SNAPSHOTS_TTL_DAYS,
#      KAPSIS_DEFAULT_DIR_WARN_SIZE_GB)
#   2. CLI flags parsed (--snapshots, --snapshots-older-than)
#   3. Dispatcher invokes clean_snapshots in default and selective modes
#   4. Stale snapshot dirs (mtime past TTL) get removed
#   5. Fresh snapshot dirs (mtime within TTL) are preserved
#   6. --dry-run lists stale dirs without deleting
#   7. --all ignores TTL and removes everything
#   8. --snapshots-older-than overrides default TTL
#   9. Symlinked top-level snapshots/ dir is refused
#  10. Disk-pressure warning fires when threshold exceeded
#  11. .disk-usage-cache is written after cleanup
#
# Category: validation (no container required)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
CONSTANTS_SCRIPT="$KAPSIS_ROOT/scripts/lib/constants.sh"

# The framework's assert_file_{exists,not_exists} use [[ -f ]] and reject
# directories. Snapshot entries are directories, so we need our own helpers.
assert_dir_exists() {
    local path="$1"
    local message="${2:-Directory should exist}"
    if [[ -d "$path" ]]; then
        return 0
    fi
    _log_failure "$message" "Missing directory: $path"
    return 1
}

assert_dir_not_exists() {
    local path="$1"
    local message="${2:-Directory should not exist}"
    if [[ ! -d "$path" ]]; then
        return 0
    fi
    _log_failure "$message" "Directory exists but shouldn't: $path"
    return 1
}

#===============================================================================
# Static-content assertions
#===============================================================================

test_snapshots_ttl_constant_declared() {
    local content
    content=$(cat "$CONSTANTS_SCRIPT")
    assert_contains "$content" "KAPSIS_DEFAULT_SNAPSHOTS_TTL_DAYS=14" \
        "constants.sh should declare KAPSIS_DEFAULT_SNAPSHOTS_TTL_DAYS=14"
}

test_dir_warn_size_constant_declared() {
    local content
    content=$(cat "$CONSTANTS_SCRIPT")
    assert_contains "$content" "KAPSIS_DEFAULT_DIR_WARN_SIZE_GB=50" \
        "constants.sh should declare KAPSIS_DEFAULT_DIR_WARN_SIZE_GB=50"
}

test_clean_snapshots_variable_declared() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "CLEAN_SNAPSHOTS=false" \
        "kapsis-cleanup.sh should initialize CLEAN_SNAPSHOTS=false"
}

test_snapshots_dir_variable_declared() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "SNAPSHOTS_DIR=" \
        "kapsis-cleanup.sh should declare SNAPSHOTS_DIR"
}

test_snapshots_flag_sets_explicit_action() {
    # Extract the --snapshots) case branch only (not --snapshots-older-than)
    local branch
    branch=$(awk '
        /^            --snapshots\)/ {capture=1; next}
        capture && /;;/ {capture=0; next}
        capture {print}
    ' "$CLEANUP_SCRIPT")
    assert_contains "$branch" "CLEAN_SNAPSHOTS=true" \
        "--snapshots branch should set CLEAN_SNAPSHOTS=true"
    assert_contains "$branch" "explicit_action_requested=true" \
        "--snapshots branch should set explicit_action_requested=true"
}

test_snapshots_older_than_flag_validates_integer() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "snapshots-older-than requires a non-negative integer" \
        "--snapshots-older-than should reject non-integer arguments"
}

test_default_block_includes_clean_snapshots() {
    # The default-cleanup block should call clean_snapshots after clean_conversations
    local block
    block=$(awk '/explicit_action_requested.*!= "true"/,/^    fi$/' "$CLEANUP_SCRIPT")
    assert_contains "$block" "clean_snapshots" \
        "Default cleanup block should invoke clean_snapshots"
}

test_disk_pressure_function_exists() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "check_disk_pressure()" \
        "kapsis-cleanup.sh should define check_disk_pressure()"
}

test_disk_pressure_called_after_summary() {
    # check_disk_pressure must be invoked after print_summary in main()
    local tail
    tail=$(awk '/^    print_summary$/,/^}$/' "$CLEANUP_SCRIPT")
    assert_contains "$tail" "check_disk_pressure" \
        "main() should call check_disk_pressure after print_summary"
}

test_usage_help_documents_snapshots() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "--snapshots         Clean per-agent snapshot dirs" \
        "usage() should document --snapshots flag"
    assert_contains "$content" "--snapshots-older-than <days>" \
        "usage() should document --snapshots-older-than flag"
}

#===============================================================================
# Functional tests — exercise clean_snapshots() against fake snapshot dirs
#===============================================================================

# Create a stale (past TTL) and fresh (within TTL) snapshot dir under $1.
_seed_snapshots() {
    local base="$1"
    mkdir -p "$base/agent-stale" "$base/agent-fresh"
    # Drop some bytes so get_dir_size has something to measure.
    echo "stale content" > "$base/agent-stale/marker"
    echo "fresh content" > "$base/agent-fresh/marker"
    # Age the stale dir 30 days back (well past 14-day TTL).
    # touch -d works on both macOS BSD touch and GNU touch.
    touch -d "30 days ago" "$base/agent-stale" 2>/dev/null \
        || touch -t "$(date -v-30d +%Y%m%d0000 2>/dev/null || date -d '30 days ago' +%Y%m%d0000)" "$base/agent-stale"
}

# Run a snippet of the cleanup script after pre-sourcing its lib dependencies.
# Feeding the script body via /dev/stdin makes its $SCRIPT_DIR resolve to /dev,
# which prevents the script's own `if [[ -f $SCRIPT_DIR/lib/compat.sh ]]` block
# from loading helpers like get_dir_mtime. We load them explicitly first.
_run_cleanup_snippet() {
    local snippet="$1"
    bash -c '
        set -e
        # shellcheck source=/dev/null
        source "'"$KAPSIS_ROOT"'/scripts/lib/compat.sh"
        # shellcheck source=/dev/null
        source "'"$KAPSIS_ROOT"'/scripts/lib/logging.sh"
        # shellcheck source=/dev/null
        source "'"$KAPSIS_ROOT"'/scripts/lib/constants.sh"
        script_body=$(sed "s|^main \"\\\$@\"$|# main suppressed|" "'"$CLEANUP_SCRIPT"'")
        # shellcheck disable=SC1090
        source /dev/stdin <<< "$script_body"
        '"$snippet"'
    ' 2>&1
}

_run_clean_snapshots() {
    local snap_dir="$1"
    local ttl_override="${2:-}"
    local clean_all="${3:-false}"
    local dry_run="${4:-false}"
    _run_cleanup_snippet '
        SNAPSHOTS_DIR="'"$snap_dir"'"
        SNAPSHOTS_TTL_OVERRIDE="'"$ttl_override"'"
        CLEAN_ALL="'"$clean_all"'"
        DRY_RUN="'"$dry_run"'"
        PROJECT_FILTER=""
        AGENT_FILTER=""
        TOTAL_SIZE_FREED=0
        ITEMS_CLEANED=0
        clean_snapshots
    '
}

_run_check_disk_pressure() {
    local kapsis_dir="$1"
    local threshold_gb="$2"
    local dry_run="${3:-false}"
    _run_cleanup_snippet '
        KAPSIS_DIR="'"$kapsis_dir"'"
        KAPSIS_DIR_WARN_SIZE_GB="'"$threshold_gb"'"
        DRY_RUN="'"$dry_run"'"
        check_disk_pressure
    '
}

test_stale_snapshot_removed_default_ttl() {
    local snap_dir
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-stale.XXXXXX")
    _seed_snapshots "$snap_dir"

    _run_clean_snapshots "$snap_dir" "" "false" "false" >/dev/null

    assert_dir_not_exists "$snap_dir/agent-stale" \
        "Stale snapshot dir (30d old) should be removed under default 14-day TTL"
    assert_dir_exists "$snap_dir/agent-fresh" \
        "Fresh snapshot dir should be preserved"

    rm -rf "$snap_dir"
}

test_dry_run_preserves_all_snapshots() {
    local snap_dir
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-dryrun.XXXXXX")
    _seed_snapshots "$snap_dir"

    _run_clean_snapshots "$snap_dir" "" "false" "true" >/dev/null

    assert_dir_exists "$snap_dir/agent-stale" \
        "Dry-run must not delete stale snapshot"
    assert_dir_exists "$snap_dir/agent-fresh" \
        "Dry-run must not delete fresh snapshot"

    rm -rf "$snap_dir"
}

test_all_removes_fresh_and_stale() {
    local snap_dir
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-all.XXXXXX")
    _seed_snapshots "$snap_dir"

    _run_clean_snapshots "$snap_dir" "" "true" "false" >/dev/null

    assert_dir_not_exists "$snap_dir/agent-stale" \
        "--all should remove stale snapshot"
    assert_dir_not_exists "$snap_dir/agent-fresh" \
        "--all should remove fresh snapshot regardless of TTL"

    rm -rf "$snap_dir"
}

test_older_than_override_shrinks_ttl() {
    local snap_dir
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-override.XXXXXX")
    mkdir -p "$snap_dir/agent-3day"
    echo "x" > "$snap_dir/agent-3day/marker"
    touch -d "3 days ago" "$snap_dir/agent-3day" 2>/dev/null \
        || touch -t "$(date -v-3d +%Y%m%d0000 2>/dev/null || date -d '3 days ago' +%Y%m%d0000)" "$snap_dir/agent-3day"

    _run_clean_snapshots "$snap_dir" "1" "false" "false" >/dev/null

    assert_dir_not_exists "$snap_dir/agent-3day" \
        "--snapshots-older-than 1 should remove 3-day-old snapshot"

    rm -rf "$snap_dir"
}

test_symlinked_top_dir_refused() {
    local snap_dir target_dir
    target_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-target.XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-symlink.XXXXXX")
    # Replace snap_dir with a symlink to target_dir
    rm -rf "$snap_dir"
    ln -s "$target_dir" "$snap_dir"
    mkdir -p "$target_dir/agent-victim"
    touch -d "60 days ago" "$target_dir/agent-victim" 2>/dev/null || true

    local output
    output=$(_run_clean_snapshots "$snap_dir" "" "false" "false")

    assert_contains "$output" "symlink" \
        "Symlinked snapshots dir should be refused with a warning"
    assert_dir_exists "$target_dir/agent-victim" \
        "Victim dir behind symlink must not be deleted"

    rm -rf "$target_dir" "$snap_dir"
}

test_disk_pressure_writes_cache() {
    local fake_kapsis
    fake_kapsis=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-pressure.XXXXXX")
    echo "x" > "$fake_kapsis/marker"

    # 1 GB threshold — won't trigger the warning on a tiny tmpdir but the
    # function still measures size and writes the cache file.
    _run_check_disk_pressure "$fake_kapsis" "1" "false" >/dev/null

    assert_file_exists "$fake_kapsis/.disk-usage-cache" \
        "check_disk_pressure should write .disk-usage-cache when threshold > 0"

    local cache_content
    cache_content=$(cat "$fake_kapsis/.disk-usage-cache")
    assert_contains "$cache_content" '"bytes":' \
        ".disk-usage-cache should contain bytes field"
    assert_contains "$cache_content" '"at":' \
        ".disk-usage-cache should contain at (timestamp) field"

    rm -rf "$fake_kapsis"
}

test_disk_pressure_zero_threshold_disables() {
    local fake_kapsis
    fake_kapsis=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-disabled.XXXXXX")
    echo "x" > "$fake_kapsis/marker"

    _run_check_disk_pressure "$fake_kapsis" "0" "false" >/dev/null

    assert_file_not_exists "$fake_kapsis/.disk-usage-cache" \
        "Threshold of 0 GB should disable the check entirely (no cache write, no warning)"

    rm -rf "$fake_kapsis"
}

test_disk_pressure_skips_cache_in_dry_run() {
    local fake_kapsis
    fake_kapsis=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-dryrun-cache.XXXXXX")
    echo "x" > "$fake_kapsis/marker"

    _run_check_disk_pressure "$fake_kapsis" "1" "true" >/dev/null

    assert_file_not_exists "$fake_kapsis/.disk-usage-cache" \
        "Dry-run must not write .disk-usage-cache"

    rm -rf "$fake_kapsis"
}

# Regression for PR #393 review: a non-numeric KAPSIS_DIR_WARN_SIZE_GB (e.g.
# "50g") must NOT crash the script via the arithmetic on the next line.
# Cleanup work is already done by the time check_disk_pressure runs, so a
# silent non-zero exit would let callers (slack-bot dispatch, cron wrappers)
# think cleanup failed.
test_disk_pressure_rejects_non_numeric_threshold() {
    local fake_kapsis
    fake_kapsis=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-389-nonnumeric.XXXXXX")
    echo "x" > "$fake_kapsis/marker"

    local exit_code=0
    _run_check_disk_pressure "$fake_kapsis" "50g" "false" >/dev/null 2>&1 || exit_code=$?

    [[ "$exit_code" -eq 0 ]] || {
        _log_failure "Non-numeric KAPSIS_DIR_WARN_SIZE_GB should not crash" \
            "Got exit code: $exit_code"
        return 1
    }
    assert_file_not_exists "$fake_kapsis/.disk-usage-cache" \
        "Non-numeric threshold should short-circuit before cache write"

    rm -rf "$fake_kapsis"
}

#===============================================================================
# Runner
#===============================================================================

run_test test_snapshots_ttl_constant_declared
run_test test_dir_warn_size_constant_declared
run_test test_clean_snapshots_variable_declared
run_test test_snapshots_dir_variable_declared
run_test test_snapshots_flag_sets_explicit_action
run_test test_snapshots_older_than_flag_validates_integer
run_test test_default_block_includes_clean_snapshots
run_test test_disk_pressure_function_exists
run_test test_disk_pressure_called_after_summary
run_test test_usage_help_documents_snapshots

run_test test_stale_snapshot_removed_default_ttl
run_test test_dry_run_preserves_all_snapshots
run_test test_all_removes_fresh_and_stale
run_test test_older_than_override_shrinks_ttl
run_test test_symlinked_top_dir_refused
run_test test_disk_pressure_writes_cache
run_test test_disk_pressure_zero_threshold_disables
run_test test_disk_pressure_skips_cache_in_dry_run
run_test test_disk_pressure_rejects_non_numeric_threshold

print_summary
