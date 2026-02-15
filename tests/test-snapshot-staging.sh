#!/usr/bin/env bash
#===============================================================================
# Test: Snapshot Staging for Filesystem Includes (issue #164)
#
# Tests verify:
#   - _snapshot_file() creates a byte-identical copy
#   - _snapshot_file() preserves file permissions
#   - _snapshot_file() lazily initializes SNAPSHOT_DIR
#   - _snapshot_file() falls back to original path on failure
#   - _snapshot_file() handles nested relative paths
#   - _snapshot_file() respects DRY_RUN mode
#   - Snapshot directory cleanup removes all snapshots
#
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source logging (needed by _snapshot_file)
source "$KAPSIS_ROOT/scripts/lib/logging.sh"

# Test directory
TEST_TEMP_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_snapshot_tests() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-snapshot-test.XXXXXX")
    log_info "Test temp directory: $TEST_TEMP_DIR"

    # Override HOME for tests to avoid polluting real ~/.kapsis/
    export ORIGINAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/fake-home"
    mkdir -p "$HOME/.kapsis"

    # Set required globals that _snapshot_file depends on
    export AGENT_ID="test-snapshot-$$"
    export DRY_RUN=false
    export SNAPSHOT_DIR=""
}

cleanup_snapshot_tests() {
    export HOME="$ORIGINAL_HOME"
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Reset SNAPSHOT_DIR between tests to ensure lazy-init is tested properly
reset_snapshot_state() {
    if [[ -n "${SNAPSHOT_DIR:-}" && -d "$SNAPSHOT_DIR" ]]; then
        rm -rf "$SNAPSHOT_DIR"
    fi
    SNAPSHOT_DIR=""
    DRY_RUN=false
}

#-------------------------------------------------------------------------------
# Inline _snapshot_file for testing (extracted from launch-agent.sh)
# This avoids sourcing the full launch-agent.sh which has many side effects
#-------------------------------------------------------------------------------
_snapshot_file() {
    local host_path="$1"
    local relative_name="$2"

    if [[ -z "$SNAPSHOT_DIR" ]]; then
        SNAPSHOT_DIR="${HOME}/.kapsis/snapshots/${AGENT_ID}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_debug "[DRY-RUN] Would create snapshot dir: $SNAPSHOT_DIR"
            echo "$host_path"
            return 0
        fi
        mkdir -p "$SNAPSHOT_DIR"
        log_debug "Created snapshot directory: $SNAPSHOT_DIR"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "$host_path"
        return 0
    fi

    local snapshot_path="${SNAPSHOT_DIR}/${relative_name}"
    mkdir -p "$(dirname "$snapshot_path")" 2>/dev/null || true

    if cp -p "$host_path" "$snapshot_path" 2>/dev/null; then
        echo "$snapshot_path"
    else
        log_warn "Snapshot failed for ${host_path}, falling back to live mount"
        echo "$host_path"
    fi
}

#===============================================================================
# TESTS
#===============================================================================

test_snapshot_file_creates_copy() {
    log_test "_snapshot_file: creates byte-identical copy"
    reset_snapshot_state

    local src="$TEST_TEMP_DIR/source/config.json"
    mkdir -p "$(dirname "$src")"
    echo '{"mcpServers": {"context7": {"command": "npx"}}}' > "$src"

    local result
    result=$(_snapshot_file "$src" "config.json")

    assert_file_exists "$result" "Snapshot file should exist"
    assert_not_equals "$src" "$result" "Snapshot path should differ from source"

    if cmp -s "$src" "$result"; then
        log_pass "Snapshot is byte-identical to source"
    else
        log_fail "Snapshot content differs from source"
    fi
}

test_snapshot_file_preserves_permissions() {
    log_test "_snapshot_file: preserves file permissions"
    reset_snapshot_state

    local src="$TEST_TEMP_DIR/source/secret.key"
    mkdir -p "$(dirname "$src")"
    echo "secret-key-data" > "$src"
    chmod 600 "$src"

    local result
    result=$(_snapshot_file "$src" "secret.key")

    assert_file_exists "$result" "Snapshot should exist"

    # Compare permissions (portable octal comparison)
    local src_perms dst_perms
    if [[ "$(uname)" == "Darwin" ]]; then
        src_perms=$(stat -f '%Lp' "$src")
        dst_perms=$(stat -f '%Lp' "$result")
    else
        src_perms=$(stat -c '%a' "$src")
        dst_perms=$(stat -c '%a' "$result")
    fi
    assert_equals "$src_perms" "$dst_perms" "Permissions should be preserved"
}

test_snapshot_file_lazy_init() {
    log_test "_snapshot_file: lazily initializes SNAPSHOT_DIR"
    reset_snapshot_state

    assert_equals "" "$SNAPSHOT_DIR" "SNAPSHOT_DIR should be empty before first call"

    local src="$TEST_TEMP_DIR/source/init.txt"
    mkdir -p "$(dirname "$src")"
    echo "init test" > "$src"

    _snapshot_file "$src" "init.txt" > /dev/null

    assert_not_equals "" "$SNAPSHOT_DIR" "SNAPSHOT_DIR should be set after first call"
    assert_dir_exists "$SNAPSHOT_DIR" "SNAPSHOT_DIR should exist"
    assert_contains "$SNAPSHOT_DIR" ".kapsis/snapshots/" "SNAPSHOT_DIR should be under .kapsis/snapshots/"
}

test_snapshot_file_fallback_on_failure() {
    log_test "_snapshot_file: falls back to original path when cp fails"
    reset_snapshot_state

    local src="$TEST_TEMP_DIR/source/noperm.txt"
    mkdir -p "$(dirname "$src")"
    echo "no permission" > "$src"

    # Make source unreadable to force cp failure
    chmod 000 "$src"

    local result
    result=$(_snapshot_file "$src" "noperm.txt")

    # Should fall back to original path
    assert_equals "$src" "$result" "Should return original path on copy failure"

    # Restore permissions for cleanup
    chmod 644 "$src"
}

test_snapshot_file_nested_path() {
    log_test "_snapshot_file: handles nested relative paths"
    reset_snapshot_state

    local src="$TEST_TEMP_DIR/source/nested/deep/settings.json"
    mkdir -p "$(dirname "$src")"
    echo '{"nested": true}' > "$src"

    local result
    result=$(_snapshot_file "$src" ".claude/settings.json")

    assert_file_exists "$result" "Snapshot should exist at nested path"
    assert_contains "$result" ".claude/settings.json" "Path should contain nested structure"

    if cmp -s "$src" "$result"; then
        log_pass "Nested snapshot content matches source"
    else
        log_fail "Nested snapshot content differs"
    fi
}

test_snapshot_file_dry_run() {
    log_test "_snapshot_file: returns original path in DRY_RUN mode"
    reset_snapshot_state
    DRY_RUN=true

    local src="$TEST_TEMP_DIR/source/dryrun.txt"
    mkdir -p "$(dirname "$src")"
    echo "dry run test" > "$src"

    local result
    result=$(_snapshot_file "$src" "dryrun.txt")

    assert_equals "$src" "$result" "Should return original path in dry-run mode"

    # SNAPSHOT_DIR should remain empty in dry-run (no directory created)
    assert_equals "" "$SNAPSHOT_DIR" "SNAPSHOT_DIR should remain empty in dry-run"

    DRY_RUN=false
}

test_snapshot_dir_cleanup() {
    log_test "Snapshot directory cleanup removes all snapshots"
    reset_snapshot_state

    # Create several snapshots
    local src1="$TEST_TEMP_DIR/source/file1.txt"
    local src2="$TEST_TEMP_DIR/source/file2.json"
    mkdir -p "$(dirname "$src1")"
    echo "file1" > "$src1"
    echo '{"file": 2}' > "$src2"

    _snapshot_file "$src1" "file1.txt" > /dev/null
    _snapshot_file "$src2" "file2.json" > /dev/null

    assert_dir_exists "$SNAPSHOT_DIR" "Snapshot dir should exist"

    # Cleanup (same pattern as _cleanup_with_completion in launch-agent.sh)
    [[ -n "${SNAPSHOT_DIR:-}" && -d "$SNAPSHOT_DIR" ]] && rm -rf "$SNAPSHOT_DIR"

    assert_dir_not_exists "$SNAPSHOT_DIR" "Snapshot dir should be removed after cleanup"
}

test_snapshot_file_parallel_agent_isolation() {
    log_test "_snapshot_file: uses AGENT_ID for isolation between parallel agents"
    reset_snapshot_state

    local src="$TEST_TEMP_DIR/source/parallel.txt"
    mkdir -p "$(dirname "$src")"
    echo "parallel test" > "$src"

    AGENT_ID="agent-alpha"
    _snapshot_file "$src" "parallel.txt" > /dev/null
    local dir_alpha="$SNAPSHOT_DIR"

    reset_snapshot_state
    AGENT_ID="agent-beta"
    _snapshot_file "$src" "parallel.txt" > /dev/null
    local dir_beta="$SNAPSHOT_DIR"

    assert_not_equals "$dir_alpha" "$dir_beta" "Different agents should have different snapshot dirs"
    assert_contains "$dir_alpha" "agent-alpha" "Alpha dir should contain agent ID"
    assert_contains "$dir_beta" "agent-beta" "Beta dir should contain agent ID"

    # Cleanup both
    rm -rf "$dir_alpha" "$dir_beta"
    AGENT_ID="test-snapshot-$$"
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "Snapshot Staging (issue #164)"

    # Setup
    setup_snapshot_tests

    # Ensure cleanup on exit
    trap cleanup_snapshot_tests EXIT

    # Snapshot file tests
    run_test test_snapshot_file_creates_copy
    run_test test_snapshot_file_preserves_permissions
    run_test test_snapshot_file_lazy_init
    run_test test_snapshot_file_fallback_on_failure
    run_test test_snapshot_file_nested_path
    run_test test_snapshot_file_dry_run
    run_test test_snapshot_dir_cleanup
    run_test test_snapshot_file_parallel_agent_isolation

    # Summary
    print_summary
}

main "$@"
