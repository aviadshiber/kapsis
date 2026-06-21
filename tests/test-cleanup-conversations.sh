#!/usr/bin/env bash
#===============================================================================
# Test: Conversation directory cleanup symlink guard
#
# Regression for the per-entry symlink guard in clean_conversations(). The loop
# globs "$CONVERSATIONS_DIR"/*/, which yields trailing-slash paths; the original
# guard tested [[ -L "$conv_dir" ]] with the slash present, which FOLLOWS the
# link and always evaluates false — so a symlinked entry would be treated as an
# ordinary expired conversation dir and listed for removal (and rm -rf on a
# trailing-slash symlink follows the link into the target). The guard must strip
# the trailing slash: [[ -L "${conv_dir%/}" ]]. Mirrors the snapshots fix
# (clean_snapshots) verified in tests/test-cleanup-snapshots.sh.
#
# Coverage:
#   1. Stale conversation dir (mtime past TTL) gets removed (harness sanity)
#   2. Symlinked per-entry dir is skipped and its target is left untouched
#
# Each functional test registers a RETURN trap for its tmpdirs so they are
# reclaimed even when an assertion fails mid-test.
#
# Category: validation (no container required)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

print_test_header "Conversation Directory Cleanup (symlink guard)"

_run_clean_conversations() {
    local conv_root="$1"
    local dry_run="${2:-false}"
    run_cleanup_snippet '
        CONVERSATIONS_DIR="'"$conv_root"'"
        CLEAN_ALL="false"
        DRY_RUN="'"$dry_run"'"
        PROJECT_FILTER=""
        AGENT_FILTER=""
        TOTAL_SIZE_FREED=0
        ITEMS_CLEANED=0
        clean_conversations
    '
}

# Age a path well past the 7-day default TTL (BSD/GNU touch portable).
_age_past_ttl() {
    local path="$1"
    touch -d "60 days ago" "$path" 2>/dev/null \
        || touch -t "$(date -v-60d +%Y%m%d0000 2>/dev/null || date -d '60 days ago' +%Y%m%d0000)" "$path"
}

#-------------------------------------------------------------------------------
# 1. Harness sanity: a real expired conversation dir is removed.
#-------------------------------------------------------------------------------
test_stale_conversation_removed() {
    local conv_root
    conv_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-stale.XXXXXX")
    # shellcheck disable=SC2064  # expand now: tmpdir must survive local scope
    trap "rm -rf '$conv_root'" RETURN

    mkdir -p "$conv_root/agent-old"
    echo "log" > "$conv_root/agent-old/transcript.txt"
    _age_past_ttl "$conv_root/agent-old"

    _run_clean_conversations "$conv_root" "false" >/dev/null

    assert_dir_not_exists "$conv_root/agent-old" \
        "Expired conversation dir (60d old) should be removed under default 7-day TTL"
}

#-------------------------------------------------------------------------------
# 2. Regression: a symlinked entry must be skipped, not followed/removed.
#-------------------------------------------------------------------------------
test_symlinked_entry_skipped() {
    local conv_root victim_dir
    conv_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-entrylink.XXXXXX")
    victim_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-victim.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$conv_root' '$victim_dir'" RETURN

    echo "precious" > "$victim_dir/marker"
    # Age the victim past the TTL so only the symlink guard protects it.
    _age_past_ttl "$victim_dir"
    ln -s "$victim_dir" "$conv_root/agent-link"

    local output
    output=$(_run_clean_conversations "$conv_root" "false")

    assert_contains "$output" "No expired conversation directories to clean" \
        "Symlinked entry must be skipped, not counted as a cleaned conversation"
    # The real invariant: the symlink target's contents were not touched. On
    # macOS `rm -rf path/` with a trailing slash on a symlink deletes the
    # target's contents but leaves the link in place, so asserting the link
    # itself survived would pass even with the bug present — this marker check
    # is what actually catches the regression.
    assert_file_exists "$victim_dir/marker" \
        "Symlink target content must be untouched"
}

#===============================================================================
# Runner
#===============================================================================

run_test test_stale_conversation_removed
run_test test_symlinked_entry_skipped

print_summary
