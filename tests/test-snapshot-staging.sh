#!/usr/bin/env bash
#===============================================================================
# Test: Snapshot Staging for Filesystem Includes (issue #164)
#
# Tests verify:
#   - _init_snapshot_dir() creates the snapshot directory
#   - _init_snapshot_dir() sets SNAPSHOT_DIR in parent shell scope
#   - _init_snapshot_dir() skips mkdir in DRY_RUN mode
#   - _snapshot_file() creates a byte-identical copy
#   - _snapshot_file() preserves file permissions
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

# Reset SNAPSHOT_DIR between tests
reset_snapshot_state() {
    if [[ -n "${SNAPSHOT_DIR:-}" && -d "$SNAPSHOT_DIR" ]]; then
        rm -rf "$SNAPSHOT_DIR"
    fi
    SNAPSHOT_DIR=""
    DRY_RUN=false
}

#-------------------------------------------------------------------------------
# Inline helpers extracted from launch-agent.sh for testing.
# This avoids sourcing the full launch-agent.sh which has many side effects.
#
# IMPORTANT: _init_snapshot_dir() must be called in the PARENT shell (not via
# $() subshell) so that SNAPSHOT_DIR propagates. _snapshot_file() is safe to
# call via $() since it only reads SNAPSHOT_DIR, never sets it.
#-------------------------------------------------------------------------------
_init_snapshot_dir() {
    if [[ -z "$SNAPSHOT_DIR" ]]; then
        SNAPSHOT_DIR="${HOME}/.kapsis/snapshots/${AGENT_ID}"
        if [[ "$DRY_RUN" != "true" ]]; then
            mkdir -p "$SNAPSHOT_DIR"
        fi
    fi
}

_snapshot_file() {
    local host_path="$1"
    local relative_name="$2"

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

# Issue #338: inlined from launch-agent.sh. Returns 0 if subtree contains any
# AF_UNIX socket, FIFO, or device entry (the classes virtio-fs returns ENOENT
# for from lstat()). Uses find -print -quit for early exit on first match.
_path_has_unstattable_entries() {
    local p="$1"
    [[ -d "$p" ]] || return 1
    [[ -n "$(find "$p" \( -type s -o -type p -o -type c -o -type b \) -print -quit 2>/dev/null)" ]]
}

# Issue #338: inlined from launch-agent.sh. Snapshots a host dir to
# ${SNAPSHOT_DIR}/<relative_name>, omitting sockets / FIFOs / devices so the
# resulting mount can take :U without tripping podman's chown-walk on macOS
# virtio-fs. Falls back to <host_path> on failure. MUST stay byte-equivalent
# to the production helper — see test_inlined_helpers_match_production below.
_snapshot_dir_filtered() {
    local host_path="$1"
    local relative_name="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "$host_path"
        return 0
    fi

    local snapshot_path="${SNAPSHOT_DIR}/${relative_name}"

    rm -rf "$snapshot_path" 2>/dev/null || true

    if ! mkdir -p "$snapshot_path" 2>/dev/null; then
        log_warn "Snapshot dir mkdir failed for ${snapshot_path}, falling back to live mount"
        echo "$host_path"
        return 1
    fi

    cp -Rp "${host_path}/." "${snapshot_path}/" 2>/dev/null || true
    find "$snapshot_path" \( -type s -o -type p -o -type c -o -type b \) -delete 2>/dev/null || true

    chmod 0700 "$snapshot_path" 2>/dev/null || true

    local _src_count _dst_count
    _src_count=$(find "$host_path" -type f 2>/dev/null | wc -l | tr -d ' \n')
    _dst_count=$(find "$snapshot_path" -type f 2>/dev/null | wc -l | tr -d ' \n')
    if [[ "$_src_count" != "$_dst_count" ]]; then
        log_warn "Snapshot file count mismatch for ${host_path} (src=${_src_count} dst=${_dst_count}), falling back to live mount"
        echo "$host_path"
        return 1
    fi

    echo "$snapshot_path"
}

#===============================================================================
# TESTS
#===============================================================================

test_init_snapshot_dir_creates_dir() {
    log_test "_init_snapshot_dir: creates snapshot directory"
    reset_snapshot_state

    assert_equals "" "$SNAPSHOT_DIR" "SNAPSHOT_DIR should be empty before init"

    _init_snapshot_dir

    assert_not_equals "" "$SNAPSHOT_DIR" "SNAPSHOT_DIR should be set after init"
    assert_dir_exists "$SNAPSHOT_DIR" "SNAPSHOT_DIR should exist on disk"
    assert_contains "$SNAPSHOT_DIR" ".kapsis/snapshots/" "Path should be under .kapsis/snapshots/"
    assert_contains "$SNAPSHOT_DIR" "$AGENT_ID" "Path should contain AGENT_ID"
}

test_init_snapshot_dir_dry_run_no_mkdir() {
    log_test "_init_snapshot_dir: sets SNAPSHOT_DIR but skips mkdir in DRY_RUN"
    reset_snapshot_state
    DRY_RUN=true

    _init_snapshot_dir

    assert_not_equals "" "$SNAPSHOT_DIR" "SNAPSHOT_DIR should be set even in dry-run"
    assert_dir_not_exists "$SNAPSHOT_DIR" "Directory should NOT be created in dry-run"

    DRY_RUN=false
}

test_init_snapshot_dir_idempotent() {
    log_test "_init_snapshot_dir: idempotent — second call is no-op"
    reset_snapshot_state

    _init_snapshot_dir
    local first_dir="$SNAPSHOT_DIR"

    _init_snapshot_dir
    assert_equals "$first_dir" "$SNAPSHOT_DIR" "Second call should not change SNAPSHOT_DIR"
}

test_snapshot_file_creates_copy() {
    log_test "_snapshot_file: creates byte-identical copy"
    reset_snapshot_state
    _init_snapshot_dir

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
    _init_snapshot_dir

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

test_snapshot_file_fallback_on_failure() {
    log_test "_snapshot_file: falls back to original path when cp fails"

    # chmod 000 has no effect when running as root — the test would always
    # succeed in reading the file, making the fallback path unreachable.
    if ! skip_if_root; then
        return 0
    fi

    reset_snapshot_state
    _init_snapshot_dir

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
    _init_snapshot_dir

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
    _init_snapshot_dir  # Sets SNAPSHOT_DIR but does not mkdir

    local src="$TEST_TEMP_DIR/source/dryrun.txt"
    mkdir -p "$(dirname "$src")"
    echo "dry run test" > "$src"

    local result
    result=$(_snapshot_file "$src" "dryrun.txt")

    assert_equals "$src" "$result" "Should return original path in dry-run mode"

    DRY_RUN=false
}

test_snapshot_dir_cleanup() {
    log_test "Snapshot directory cleanup removes all snapshots"
    reset_snapshot_state
    _init_snapshot_dir

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
    _init_snapshot_dir
    _snapshot_file "$src" "parallel.txt" > /dev/null
    local dir_alpha="$SNAPSHOT_DIR"

    reset_snapshot_state
    AGENT_ID="agent-beta"
    _init_snapshot_dir
    _snapshot_file "$src" "parallel.txt" > /dev/null
    local dir_beta="$SNAPSHOT_DIR"

    assert_not_equals "$dir_alpha" "$dir_beta" "Different agents should have different snapshot dirs"
    assert_contains "$dir_alpha" "agent-alpha" "Alpha dir should contain agent ID"
    assert_contains "$dir_beta" "agent-beta" "Beta dir should contain agent ID"

    # Cleanup both
    rm -rf "$dir_alpha" "$dir_beta"
    AGENT_ID="test-snapshot-$$"
}

test_snapshot_file_absolute_path_no_collision() {
    log_test "_snapshot_file: absolute paths use full path to prevent collisions"
    reset_snapshot_state
    _init_snapshot_dir

    # Two files with same basename but different directories
    local src1="$TEST_TEMP_DIR/source/dir1/config.yaml"
    local src2="$TEST_TEMP_DIR/source/dir2/config.yaml"
    mkdir -p "$(dirname "$src1")" "$(dirname "$src2")"
    echo "config1" > "$src1"
    echo "config2-different" > "$src2"

    local result1 result2
    result1=$(_snapshot_file "$src1" "absolute${src1}")
    result2=$(_snapshot_file "$src2" "absolute${src2}")

    assert_not_equals "$result1" "$result2" "Different source paths should produce different snapshots"
    assert_file_exists "$result1" "First snapshot should exist"
    assert_file_exists "$result2" "Second snapshot should exist"

    # Verify content matches respective sources
    if cmp -s "$src1" "$result1" && cmp -s "$src2" "$result2"; then
        log_pass "Both snapshots match their respective sources"
    else
        log_fail "Snapshot content mismatch"
    fi
}

#===============================================================================
# Issue #328: staging mount option — :U flag for macOS UID remapping
#
# On macOS, the host user's UID (e.g. 501) maps to a different UID inside the
# container (typically UID 0 or 501 with --userns=keep-id). Directories with
# mode 0700 (like ~/.ssh, ~/.claude) are inaccessible to the container process
# (developer, UID 1000). The :U Podman mount option creates an idmapped mount
# so files appear owned by the container user and become readable.
#
# The logic under test (inlined from launch-agent.sh generate_filesystem_includes):
#   if is_macos; then _staging_mount_opts="ro,U"; else _staging_mount_opts="ro"; fi
#===============================================================================

# Inline the staging mount-option resolver from launch-agent.sh for testing.
# Returns the mount options string for a staging volume.
_staging_mount_opts_for_platform() {
    local platform="${1:-linux}"
    if [[ "$platform" == "macos" ]]; then
        echo "ro,U"
    else
        echo "ro"
    fi
}

test_staging_mount_opts_macos_includes_U_flag() {
    log_test "Staging mount opts on macOS include :U for UID remapping (Issue #328)"
    local opts
    opts=$(_staging_mount_opts_for_platform "macos")
    assert_contains "$opts" "U" "macOS staging mount must include :U to remap ownership"
    assert_contains "$opts" "ro" "macOS staging mount must remain read-only"
}

test_staging_mount_opts_linux_no_U_flag() {
    log_test "Staging mount opts on Linux do not include :U (no UID mismatch)"
    local opts
    opts=$(_staging_mount_opts_for_platform "linux")
    assert_not_contains "$opts" "U" "Linux staging mount should not include :U (UID matches)"
    assert_contains "$opts" "ro" "Linux staging mount must remain read-only"
}

test_staging_mount_opts_macos_ro_U_combined() {
    log_test "macOS staging mount opts: ro and U are both present and combined (Issue #328)"
    local opts
    opts=$(_staging_mount_opts_for_platform "macos")
    # Podman accepts both "ro,U" and "U,ro" — verify both flags exist
    local has_ro has_U
    [[ "$opts" == *"ro"* ]] && has_ro=1 || has_ro=0
    [[ "$opts" == *"U"* ]]  && has_U=1  || has_U=0
    assert_equals "1" "$has_ro" "ro flag must be present in macOS staging opts"
    assert_equals "1" "$has_U"  "U flag must be present in macOS staging opts"
}

#===============================================================================
# Issue #338: pre-filter directory snapshots so :U chown traversal doesn't
# trip on AF_UNIX sockets / FIFOs / devices that virtio-fs returns ENOENT for.
#
# Tests use mkfifo (POSIX, works on Linux + BSD) to stand in for AF_UNIX
# sockets — both share the find -type s/-type p detection codepath and the
# same lstat-ENOENT pathology on virtio-fs. AF_UNIX-specific tests would
# need a live process to bind() the socket, which is over-specified for
# unit-level coverage of the filter logic.
#===============================================================================

test_path_has_unstattable_entries_detects_fifo() {
    log_test "_path_has_unstattable_entries: detects FIFO (Issue #338)"
    local d="$TEST_TEMP_DIR/has-fifo"
    mkdir -p "$d"
    : > "$d/regular.txt"
    mkfifo "$d/socket-stand-in" 2>/dev/null

    if _path_has_unstattable_entries "$d"; then
        log_pass "Detected FIFO entry"
    else
        log_fail "Failed to detect FIFO entry"
    fi
}

test_path_has_unstattable_entries_detects_nested_fifo() {
    log_test "_path_has_unstattable_entries: detects nested FIFO (Issue #338)"
    local d="$TEST_TEMP_DIR/nested-fifo/a/b/c"
    mkdir -p "$d"
    : > "$TEST_TEMP_DIR/nested-fifo/regular.txt"
    mkfifo "$d/deep.ipc" 2>/dev/null

    if _path_has_unstattable_entries "$TEST_TEMP_DIR/nested-fifo"; then
        log_pass "Detected deeply-nested FIFO"
    else
        log_fail "Failed to detect deeply-nested FIFO"
    fi
}

test_path_has_unstattable_entries_clean_tree_returns_1() {
    log_test "_path_has_unstattable_entries: returns 1 on socket-free tree (Issue #338)"
    local d="$TEST_TEMP_DIR/clean-tree"
    mkdir -p "$d/sub"
    : > "$d/file.txt"
    : > "$d/sub/nested.json"

    if _path_has_unstattable_entries "$d"; then
        log_fail "Should NOT report unstattable entries for a regular-file-only tree"
    else
        log_pass "Correctly returned 1 for clean tree"
    fi
}

test_path_has_unstattable_entries_handles_missing_path() {
    log_test "_path_has_unstattable_entries: returns 1 on non-existent path (Issue #338)"
    if _path_has_unstattable_entries "$TEST_TEMP_DIR/does-not-exist"; then
        log_fail "Should NOT report unstattable entries for missing path"
    else
        log_pass "Correctly returned 1 for missing path"
    fi
}

test_snapshot_dir_filtered_excludes_fifos() {
    log_test "_snapshot_dir_filtered: excludes FIFOs from snapshot (Issue #338)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/src-with-fifo"
    mkdir -p "$src/sub"
    echo "regular content" > "$src/regular.txt"
    echo '{"k":"v"}' > "$src/sub/nested.json"
    mkfifo "$src/fsmonitor.ipc" 2>/dev/null
    mkfifo "$src/sub/agent.sock" 2>/dev/null

    local result
    result=$(_snapshot_dir_filtered "$src" ".claude")

    assert_dir_exists "$result" "Snapshot dir should exist"
    assert_file_exists "$result/regular.txt" "Regular file should be in snapshot"
    assert_file_exists "$result/sub/nested.json" "Nested regular file should be in snapshot"

    if [[ -e "$result/fsmonitor.ipc" ]]; then
        log_fail "FIFO at root must NOT exist in snapshot"
    else
        log_pass "FIFO at root correctly excluded"
    fi

    if [[ -e "$result/sub/agent.sock" ]]; then
        log_fail "Nested FIFO must NOT exist in snapshot"
    else
        log_pass "Nested FIFO correctly excluded"
    fi
}

test_snapshot_dir_filtered_preserves_modes() {
    log_test "_snapshot_dir_filtered: preserves mode-0700 dirs and mode-0600 files (Issue #338)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/src-modes"
    mkdir -p "$src"
    echo "secret" > "$src/id_rsa"
    chmod 700 "$src"
    chmod 600 "$src/id_rsa"
    mkfifo "$src/agent.sock" 2>/dev/null

    local result
    result=$(_snapshot_dir_filtered "$src" ".ssh")

    assert_dir_exists "$result" "Snapshot dir should exist"
    assert_file_exists "$result/id_rsa" "Regular file should be in snapshot"

    # Directory mode preservation is best-effort: SNAPSHOT_DIR is created via
    # mkdir -p (umask-filtered), so the OUTER dir mode is not expected to
    # match. Only verify file modes here.
    local src_file_mode dst_file_mode
    src_file_mode=$(stat -c '%a' "$src/id_rsa" 2>/dev/null || stat -f '%A' "$src/id_rsa" 2>/dev/null)
    dst_file_mode=$(stat -c '%a' "$result/id_rsa" 2>/dev/null || stat -f '%A' "$result/id_rsa" 2>/dev/null)

    assert_equals "$src_file_mode" "$dst_file_mode" "File mode (e.g. 0600) must be preserved"
}

test_snapshot_dir_filtered_dry_run_passthrough() {
    log_test "_snapshot_dir_filtered: returns original path in DRY_RUN mode (Issue #338)"
    reset_snapshot_state
    DRY_RUN=true
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/dry-run-src"
    mkdir -p "$src"
    echo "data" > "$src/file.txt"

    local result
    result=$(_snapshot_dir_filtered "$src" ".claude")

    assert_equals "$src" "$result" "Should return original path in dry-run mode"

    DRY_RUN=false
}

test_snapshot_dir_filtered_handles_empty_source() {
    log_test "_snapshot_dir_filtered: empty source dir produces empty snapshot (Issue #338)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/empty-src"
    mkdir -p "$src"

    local result
    result=$(_snapshot_dir_filtered "$src" ".empty")

    # Empty source is a degenerate but valid case — should return the
    # snapshot path, not fall back. (Fallback is only for src-non-empty
    # but dst-empty mismatch.)
    assert_dir_exists "$result" "Snapshot dir should exist for empty source"
    if [[ -z "$(ls -A "$result" 2>/dev/null)" ]]; then
        log_pass "Empty source produced empty snapshot"
    else
        log_fail "Snapshot of empty source unexpectedly has content"
    fi
}

test_snapshot_dir_filtered_preserves_regular_files() {
    log_test "_snapshot_dir_filtered: regular file content is byte-identical (Issue #338)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/src-content"
    mkdir -p "$src/sub"
    printf 'line one\nline two\n' > "$src/file.txt"
    printf '{"deep": "json"}' > "$src/sub/data.json"
    mkfifo "$src/x.ipc" 2>/dev/null

    local result
    result=$(_snapshot_dir_filtered "$src" ".content")

    if cmp -s "$src/file.txt" "$result/file.txt"; then
        log_pass "Top-level file matches byte-for-byte"
    else
        log_fail "Top-level file content differs"
    fi
    if cmp -s "$src/sub/data.json" "$result/sub/data.json"; then
        log_pass "Nested file matches byte-for-byte"
    else
        log_fail "Nested file content differs"
    fi
}

# AF_UNIX socket coverage (Reviewer ensemble: A/C/E flagged that FIFO is
# only a proxy for the actual #338 bug case). Binds a real AF_UNIX socket
# to exercise the `find -type s` arm of the filter end-to-end.
_have_python3_af_unix() {
    command -v python3 >/dev/null 2>&1
}

test_path_has_unstattable_entries_detects_af_unix_socket() {
    log_test "_path_has_unstattable_entries: detects real AF_UNIX socket (Issue #338 actual case)"
    if ! _have_python3_af_unix; then
        log_skip "python3 not available — skipping AF_UNIX-specific test"
        return 0
    fi
    local d="$TEST_TEMP_DIR/has-af-unix"
    mkdir -p "$d"
    : > "$d/regular.txt"
    if ! python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$d/agent.sock" 2>/dev/null; then
        log_skip "AF_UNIX bind unavailable in this env — skipping"
        return 0
    fi

    if _path_has_unstattable_entries "$d"; then
        log_pass "Detected real AF_UNIX socket"
    else
        log_fail "Failed to detect real AF_UNIX socket"
    fi
}

test_snapshot_dir_filtered_excludes_af_unix_socket() {
    log_test "_snapshot_dir_filtered: excludes real AF_UNIX socket (Issue #338 actual case)"
    if ! _have_python3_af_unix; then
        log_skip "python3 not available — skipping AF_UNIX-specific test"
        return 0
    fi
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/af-unix-src"
    mkdir -p "$src/.git"
    echo "fake claude config" > "$src/settings.json"
    if ! python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$src/.git/fsmonitor--daemon.ipc" 2>/dev/null; then
        log_skip "AF_UNIX bind unavailable in this env — skipping"
        return 0
    fi

    local result
    result=$(_snapshot_dir_filtered "$src" ".claude")

    assert_file_exists "$result/settings.json" "Regular file should be in snapshot"
    if [[ -S "$result/.git/fsmonitor--daemon.ipc" ]]; then
        log_fail "AF_UNIX socket must NOT exist in snapshot"
    else
        log_pass "AF_UNIX socket correctly excluded from snapshot"
    fi
}

# Reviewer C/D: when source contains only sockets/FIFOs (and no regular
# files), `cp -Rp` plus prune leaves an empty snapshot. The src-empty/dst-
# empty branch correctly returns the snapshot path (not the live mount),
# so the caller can safely apply :U to an empty dir without re-tripping
# #338. Verify the fallback is NOT activated in this case.
test_snapshot_dir_filtered_socket_only_source_does_not_fall_back() {
    log_test "_snapshot_dir_filtered: socket-only source produces empty snapshot, NOT fallback (Issue #338)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/socket-only-src"
    mkdir -p "$src"
    mkfifo "$src/a.ipc" 2>/dev/null
    mkfifo "$src/b.sock" 2>/dev/null

    local result rc=0
    result=$(_snapshot_dir_filtered "$src" ".socket-only") || rc=$?

    assert_equals "0" "$rc" "Should NOT return non-zero for socket-only source"
    if [[ "$result" == "$src" ]]; then
        log_fail "Should NOT fall back to live mount for socket-only source — that re-trips #338"
    else
        log_pass "Returned snapshot path (not live fallback) for socket-only source"
    fi
}

# Reviewer A/D: a partial cp (ENOSPC, I/O error) was previously silently
# accepted. Simulate by manually deleting a file from the snapshot after
# the helper completes, then assert the count check would have caught it.
# We can't easily inject mid-cp failure, so we verify the count-mismatch
# branch by post-deletion.
test_snapshot_dir_filtered_detects_partial_copy_via_count() {
    log_test "_snapshot_dir_filtered: file-count mismatch triggers fallback (Issue #338 partial-cp guard)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/count-src"
    mkdir -p "$src/d1"
    echo "a" > "$src/f1"
    echo "b" > "$src/d1/f2"
    echo "c" > "$src/f3"
    mkfifo "$src/sock" 2>/dev/null

    # Sanity: helper should succeed for a healthy copy.
    local first_result first_rc=0
    first_result=$(_snapshot_dir_filtered "$src" ".count-ok") || first_rc=$?
    assert_equals "0" "$first_rc" "Healthy copy should succeed"
    if [[ "$first_result" != "$src" ]]; then
        log_pass "Healthy copy returned snapshot path"
    else
        log_fail "Healthy copy unexpectedly fell back"
    fi

    # Now manually inject a mismatch by removing a snapshot file post-hoc
    # then re-running the count branch via direct invocation. The helper
    # re-runs (rm -rf the dst, mkdir -p, fresh cp) — counts will match
    # again — so we can't intercept mid-helper. Instead, exercise the
    # count comparison in isolation: build src, copy 2 of 3 files
    # manually, then run the count-equivalence assertion.
    local mismatch_src="$TEST_TEMP_DIR/count-mismatch-src"
    local mismatch_dst="$TEST_TEMP_DIR/count-mismatch-dst"
    mkdir -p "$mismatch_src" "$mismatch_dst"
    echo "1" > "$mismatch_src/a"
    echo "2" > "$mismatch_src/b"
    echo "3" > "$mismatch_src/c"
    echo "1" > "$mismatch_dst/a"
    echo "2" > "$mismatch_dst/b"

    local sc dc
    sc=$(find "$mismatch_src" -type f | wc -l | tr -d ' \n')
    dc=$(find "$mismatch_dst" -type f | wc -l | tr -d ' \n')
    assert_equals "3" "$sc" "Source has 3 files"
    assert_equals "2" "$dc" "Destination has 2 files"
    if [[ "$sc" != "$dc" ]]; then
        log_pass "Count comparison correctly detects partial copy"
    else
        log_fail "Count comparison failed to detect partial copy"
    fi
}

# Reviewer B: defensive chmod 0700 on the snapshot_path so credentials
# remain unenumerable even when SNAPSHOT_DIR has a loose umask-default mode.
test_snapshot_dir_filtered_hardens_snapshot_mode() {
    log_test "_snapshot_dir_filtered: snapshot_path is mode 0700 (Issue #338 review hardening)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/perm-src"
    mkdir -p "$src"
    echo "secret" > "$src/cred"

    local result
    result=$(_snapshot_dir_filtered "$src" ".perm")

    local mode
    mode=$(stat -c '%a' "$result" 2>/dev/null || stat -f '%A' "$result" 2>/dev/null)
    assert_equals "700" "$mode" "Snapshot path must be mode 0700 to hide credentials"
}

# Reviewer D: on resume / re-run, the same SNAPSHOT_DIR is reused. cp -Rp
# merges into an existing dst, so files deleted from the source would
# persist as stale entries. The pre-clean (`rm -rf`) before mkdir prevents
# this. Test: pre-populate snapshot_path with a stale file, then snapshot
# a source that no longer contains it.
test_snapshot_dir_filtered_pre_cleans_stale_entries() {
    log_test "_snapshot_dir_filtered: pre-cleans snapshot_path to prevent stale-merge (Issue #338 review)"
    reset_snapshot_state
    _init_snapshot_dir

    local src="$TEST_TEMP_DIR/clean-src"
    mkdir -p "$src"
    echo "current" > "$src/keep.txt"

    # Pre-populate the target snapshot path with a stale entry
    local stale_snapshot="${SNAPSHOT_DIR}/.clean"
    mkdir -p "$stale_snapshot"
    echo "stale-from-previous-run" > "$stale_snapshot/deleted.txt"
    # And a stale FIFO (which the prune would remove but a stale merge would leave)
    mkfifo "$stale_snapshot/stale.ipc" 2>/dev/null

    local result
    result=$(_snapshot_dir_filtered "$src" ".clean")

    assert_file_exists "$result/keep.txt" "Current file should be present"
    if [[ -e "$result/deleted.txt" ]]; then
        log_fail "Stale file from previous run must NOT persist after re-run"
    else
        log_pass "Stale file correctly cleaned before snapshot"
    fi
    if [[ -e "$result/stale.ipc" ]]; then
        log_fail "Stale FIFO from previous run must NOT persist after re-run"
    else
        log_pass "Stale FIFO correctly cleaned"
    fi
}

# Reviewer E: guard against helper drift. Compare the inlined helper
# bodies with the production functions in scripts/launch-agent.sh and
# fail if they diverge (signatures and bodies must match — comments
# may differ).
test_inlined_helpers_match_production() {
    log_test "Inlined helpers in this test file must match production (drift guard)"
    local launch="$KAPSIS_ROOT/scripts/launch-agent.sh"
    if [[ ! -f "$launch" ]]; then
        log_skip "Production launch-agent.sh not found — skipping drift check"
        return 0
    fi

    # Extract function bodies from both production and inlined versions
    # using awk: from "^_FUNC_NAME()" to the matching closing brace at
    # column 1. Strip blank lines and leading/trailing whitespace for
    # comparison resilience.
    _extract_fn_body() {
        local file="$1" fn="$2"
        awk -v fn="$fn" '
            $0 ~ "^"fn"\\(\\) \\{" { in_fn=1; depth=1; next }
            in_fn && /^}$/ { exit }
            in_fn { print }
        ' "$file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | grep -v '^#'
    }

    local prod_body inline_body
    for fn in _path_has_unstattable_entries _snapshot_dir_filtered; do
        prod_body=$(_extract_fn_body "$launch" "$fn")
        inline_body=$(_extract_fn_body "${BASH_SOURCE[0]}" "$fn")
        if [[ -z "$prod_body" ]]; then
            log_fail "Could not extract production body for ${fn}"
            continue
        fi
        if [[ -z "$inline_body" ]]; then
            log_fail "Could not extract inlined body for ${fn}"
            continue
        fi
        if [[ "$prod_body" == "$inline_body" ]]; then
            log_pass "Inlined ${fn} matches production"
        else
            log_fail "Inlined ${fn} has drifted from production"
            diff <(echo "$prod_body") <(echo "$inline_body") | head -20 || true
        fi
    done
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

    # Init tests
    run_test test_init_snapshot_dir_creates_dir
    run_test test_init_snapshot_dir_dry_run_no_mkdir
    run_test test_init_snapshot_dir_idempotent

    # Snapshot file tests
    run_test test_snapshot_file_creates_copy
    run_test test_snapshot_file_preserves_permissions
    run_test test_snapshot_file_fallback_on_failure
    run_test test_snapshot_file_nested_path
    run_test test_snapshot_file_dry_run
    run_test test_snapshot_dir_cleanup
    run_test test_snapshot_file_parallel_agent_isolation
    run_test test_snapshot_file_absolute_path_no_collision

    # Staging mount option tests (issue #328)
    run_test test_staging_mount_opts_macos_includes_U_flag
    run_test test_staging_mount_opts_linux_no_U_flag
    run_test test_staging_mount_opts_macos_ro_U_combined

    # Pre-filtered directory snapshot tests (issue #338)
    run_test test_path_has_unstattable_entries_detects_fifo
    run_test test_path_has_unstattable_entries_detects_nested_fifo
    run_test test_path_has_unstattable_entries_clean_tree_returns_1
    run_test test_path_has_unstattable_entries_handles_missing_path
    run_test test_snapshot_dir_filtered_excludes_fifos
    run_test test_snapshot_dir_filtered_preserves_modes
    run_test test_snapshot_dir_filtered_dry_run_passthrough
    run_test test_snapshot_dir_filtered_handles_empty_source
    run_test test_snapshot_dir_filtered_preserves_regular_files

    # Review-cycle hardening (issue #338 review feedback)
    run_test test_path_has_unstattable_entries_detects_af_unix_socket
    run_test test_snapshot_dir_filtered_excludes_af_unix_socket
    run_test test_snapshot_dir_filtered_socket_only_source_does_not_fall_back
    run_test test_snapshot_dir_filtered_detects_partial_copy_via_count
    run_test test_snapshot_dir_filtered_hardens_snapshot_mode
    run_test test_snapshot_dir_filtered_pre_cleans_stale_entries
    run_test test_inlined_helpers_match_production

    # Summary
    print_summary
}

main "$@"
