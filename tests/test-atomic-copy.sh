#!/usr/bin/env bash
#===============================================================================
# Test: Atomic Copy Library (atomic-copy.sh)
#
# Unit tests for scripts/lib/atomic-copy.sh - race-condition-safe copying.
#
# Tests verify:
#   - atomic_copy_file() copies files with correct content
#   - atomic_copy_file() validates size after copy
#   - atomic_copy_file() validates JSON for .json files
#   - atomic_copy_file() handles missing source gracefully
#   - atomic_copy_file() creates destination directories
#   - atomic_copy_dir() copies directories correctly
#   - atomic_copy_dir() validates file count after copy
#   - No leftover temp files on success or failure
#
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/atomic-copy.sh"

# Test directory for file operations
TEST_TEMP_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_atomic_copy_tests() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-atomic-copy-test.XXXXXX")
    log_info "Test temp directory: $TEST_TEMP_DIR"
}

cleanup_atomic_copy_tests() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

#===============================================================================
# atomic_copy_file() TESTS
#===============================================================================

test_atomic_copy_file_basic() {
    log_test "atomic_copy_file: copies file with correct content"

    local src="$TEST_TEMP_DIR/src/basic.txt"
    local dst="$TEST_TEMP_DIR/dst/basic.txt"

    mkdir -p "$(dirname "$src")"
    echo "Hello, World!" > "$src"

    atomic_copy_file "$src" "$dst"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 on success"
    assert_file_exists "$dst" "Destination file should exist"

    local content
    content=$(cat "$dst")
    assert_equals "Hello, World!" "$content" "Content should match source"
}

test_atomic_copy_file_preserves_content() {
    log_test "atomic_copy_file: preserves binary-identical content"

    local src="$TEST_TEMP_DIR/src/preserve.bin"
    local dst="$TEST_TEMP_DIR/dst/preserve.bin"

    mkdir -p "$(dirname "$src")"
    # Create a file with specific byte content
    printf 'line1\nline2\ttab\nline3' > "$src"

    atomic_copy_file "$src" "$dst"

    # Compare byte-for-byte
    if cmp -s "$src" "$dst"; then
        log_pass "Files are binary-identical"
    else
        log_fail "Files differ"
    fi
}

test_atomic_copy_file_size_validation() {
    log_test "atomic_copy_file: destination size matches source"

    local src="$TEST_TEMP_DIR/src/sized.txt"
    local dst="$TEST_TEMP_DIR/dst/sized.txt"

    mkdir -p "$(dirname "$src")"
    # Create a file with known size
    dd if=/dev/zero bs=1024 count=10 of="$src" 2>/dev/null

    atomic_copy_file "$src" "$dst"

    local src_size dst_size
    src_size=$(get_file_size "$src")
    dst_size=$(get_file_size "$dst")
    assert_equals "$src_size" "$dst_size" "Destination size should match source"
}

test_atomic_copy_file_json_validation() {
    log_test "atomic_copy_file: validates JSON for .json files"

    local src="$TEST_TEMP_DIR/src/config.json"
    local dst="$TEST_TEMP_DIR/dst/config.json"

    mkdir -p "$(dirname "$src")"
    echo '{"mcpServers": {"context7": {"command": "npx"}}}' > "$src"

    atomic_copy_file "$src" "$dst"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should succeed for valid JSON"

    # Verify jq can parse the destination
    if command -v jq &>/dev/null; then
        if jq empty "$dst" 2>/dev/null; then
            log_pass "Destination is valid JSON"
        else
            log_fail "Destination is not valid JSON"
        fi
    else
        log_info "jq not available, skipping JSON parse check"
    fi
}

test_atomic_copy_file_creates_parent_dirs() {
    log_test "atomic_copy_file: creates parent directories if needed"

    local src="$TEST_TEMP_DIR/src/nested.txt"
    local dst="$TEST_TEMP_DIR/dst/deep/nested/path/file.txt"

    mkdir -p "$(dirname "$src")"
    echo "nested content" > "$src"

    atomic_copy_file "$src" "$dst"

    assert_file_exists "$dst" "File should exist in nested directory"
    assert_dir_exists "$(dirname "$dst")" "Parent directories should be created"
}

test_atomic_copy_file_missing_source() {
    log_test "atomic_copy_file: returns 1 for missing source"

    local dst="$TEST_TEMP_DIR/dst/missing.txt"

    atomic_copy_file "/nonexistent/file.txt" "$dst" || true
    local exit_code=$?

    # The || true above captures the exit code indirectly; re-run properly
    if atomic_copy_file "/nonexistent/file.txt" "$dst" 2>/dev/null; then
        log_fail "Should return non-zero for missing source"
    else
        log_pass "Returns non-zero for missing source"
    fi
}

test_atomic_copy_file_empty_file() {
    log_test "atomic_copy_file: handles empty files"

    local src="$TEST_TEMP_DIR/src/empty.txt"
    local dst="$TEST_TEMP_DIR/dst/empty.txt"

    mkdir -p "$(dirname "$src")"
    touch "$src"

    atomic_copy_file "$src" "$dst"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should succeed for empty file"
    assert_file_exists "$dst" "Empty file should be created"

    local dst_size
    dst_size=$(get_file_size "$dst")
    assert_equals "0" "$dst_size" "Empty file should have size 0"
}

test_atomic_copy_file_large_file() {
    log_test "atomic_copy_file: handles 100KB file"

    local src="$TEST_TEMP_DIR/src/large.dat"
    local dst="$TEST_TEMP_DIR/dst/large.dat"

    mkdir -p "$(dirname "$src")"
    dd if=/dev/urandom bs=1024 count=100 of="$src" 2>/dev/null

    atomic_copy_file "$src" "$dst"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should succeed for large file"

    local src_size dst_size
    src_size=$(get_file_size "$src")
    dst_size=$(get_file_size "$dst")
    assert_equals "$src_size" "$dst_size" "Large file size should match"
}

test_atomic_copy_file_no_temp_files_on_success() {
    log_test "atomic_copy_file: no temp files left after success"

    local src="$TEST_TEMP_DIR/src/clean.txt"
    local dst_dir="$TEST_TEMP_DIR/dst/clean_dir"
    local dst="$dst_dir/clean.txt"

    mkdir -p "$(dirname "$src")" "$dst_dir"
    echo "clean test" > "$src"

    atomic_copy_file "$src" "$dst"

    # Check for leftover .atomic-copy-* temp files
    local temp_count
    temp_count=$(find "$dst_dir" -name ".atomic-copy-*" 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$temp_count" "No .atomic-copy-* temp files should remain"
}

test_atomic_copy_file_overwrites_existing() {
    log_test "atomic_copy_file: overwrites existing destination"

    local src="$TEST_TEMP_DIR/src/overwrite.txt"
    local dst="$TEST_TEMP_DIR/dst/overwrite.txt"

    mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
    echo "old content" > "$dst"
    echo "new content" > "$src"

    atomic_copy_file "$src" "$dst"

    local content
    content=$(cat "$dst")
    assert_equals "new content" "$content" "Should overwrite with new content"
}

test_atomic_copy_file_spaces_in_path() {
    log_test "atomic_copy_file: handles spaces in file path"

    local src="$TEST_TEMP_DIR/src dir/my file.txt"
    local dst="$TEST_TEMP_DIR/dst dir/my file.txt"

    mkdir -p "$(dirname "$src")"
    echo "spaced content" > "$src"

    atomic_copy_file "$src" "$dst"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should handle spaces in path"
    assert_file_exists "$dst" "File with spaces should exist"
}

test_atomic_copy_file_writable() {
    log_test "atomic_copy_file: destination is user-writable"

    local src="$TEST_TEMP_DIR/src/writable.txt"
    local dst="$TEST_TEMP_DIR/dst/writable.txt"

    mkdir -p "$(dirname "$src")"
    echo "writable test" > "$src"

    atomic_copy_file "$src" "$dst"

    if [[ -w "$dst" ]]; then
        log_pass "Destination file is writable"
    else
        log_fail "Destination file should be writable"
    fi
}

#===============================================================================
# atomic_copy_dir() TESTS
#===============================================================================

test_atomic_copy_dir_basic() {
    log_test "atomic_copy_dir: copies directory with all files"

    local src="$TEST_TEMP_DIR/src/mydir"
    local dst="$TEST_TEMP_DIR/dst/mydir"

    mkdir -p "$src"
    echo "file1" > "$src/a.txt"
    echo "file2" > "$src/b.txt"
    echo "file3" > "$src/c.txt"

    atomic_copy_dir "$src" "$dst"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 on success"
    assert_file_exists "$dst/a.txt" "a.txt should be copied"
    assert_file_exists "$dst/b.txt" "b.txt should be copied"
    assert_file_exists "$dst/c.txt" "c.txt should be copied"

    local content
    content=$(cat "$dst/a.txt")
    assert_equals "file1" "$content" "Content should match source"
}

test_atomic_copy_dir_preserves_structure() {
    log_test "atomic_copy_dir: preserves nested directory structure"

    local src="$TEST_TEMP_DIR/src/nested_dir"
    local dst="$TEST_TEMP_DIR/dst/nested_dir"

    mkdir -p "$src/sub1/sub2"
    echo "root" > "$src/root.txt"
    echo "sub1" > "$src/sub1/sub1.txt"
    echo "sub2" > "$src/sub1/sub2/sub2.txt"

    atomic_copy_dir "$src" "$dst"

    assert_file_exists "$dst/root.txt" "root.txt should exist"
    assert_file_exists "$dst/sub1/sub1.txt" "sub1/sub1.txt should exist"
    assert_file_exists "$dst/sub1/sub2/sub2.txt" "sub1/sub2/sub2.txt should exist"

    local content
    content=$(cat "$dst/sub1/sub2/sub2.txt")
    assert_equals "sub2" "$content" "Nested content should match"
}

test_atomic_copy_dir_missing_source() {
    log_test "atomic_copy_dir: returns 1 for missing source"

    local dst="$TEST_TEMP_DIR/dst/missing_dir"

    if atomic_copy_dir "/nonexistent/dir" "$dst" 2>/dev/null; then
        log_fail "Should return non-zero for missing source"
    else
        log_pass "Returns non-zero for missing source"
    fi
}

test_atomic_copy_dir_no_temp_dirs_on_success() {
    log_test "atomic_copy_dir: no temp dirs left after success"

    local src="$TEST_TEMP_DIR/src/clean_dir"
    local parent_dir="$TEST_TEMP_DIR/dst"
    local dst="$parent_dir/clean_dir"

    mkdir -p "$src" "$parent_dir"
    echo "test" > "$src/test.txt"

    atomic_copy_dir "$src" "$dst"

    # Check for leftover .atomic-copy-dir-* temp directories
    local temp_count
    temp_count=$(find "$parent_dir" -maxdepth 1 -name ".atomic-copy-dir-*" 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$temp_count" "No .atomic-copy-dir-* temp dirs should remain"
}

test_atomic_copy_dir_writable() {
    log_test "atomic_copy_dir: destination files are user-writable"

    local src="$TEST_TEMP_DIR/src/writable_dir"
    local dst="$TEST_TEMP_DIR/dst/writable_dir"

    mkdir -p "$src"
    echo "test" > "$src/file.txt"

    atomic_copy_dir "$src" "$dst"

    if [[ -w "$dst/file.txt" ]]; then
        log_pass "Files in destination directory are writable"
    else
        log_fail "Files in destination directory should be writable"
    fi
}

#===============================================================================
# PERMISSION PRESERVATION TESTS (Issue #159)
#===============================================================================

test_atomic_copy_file_preserves_permissions() {
    log_test "atomic_copy_file: preserves original file permissions"

    local src="$TEST_TEMP_DIR/src/restricted.txt"
    local dst="$TEST_TEMP_DIR/dst/restricted.txt"

    mkdir -p "$(dirname "$src")"
    echo "secret content" > "$src"
    chmod 600 "$src"

    atomic_copy_file "$src" "$dst"

    local dst_mode
    dst_mode=$(get_file_mode "$dst")

    assert_equals "600" "$dst_mode" "Destination should preserve mode 600"
}

test_atomic_copy_file_readonly_gets_write() {
    log_test "atomic_copy_file: read-only source becomes writable"

    local src="$TEST_TEMP_DIR/src/readonly.txt"
    local dst="$TEST_TEMP_DIR/dst/readonly.txt"

    mkdir -p "$(dirname "$src")"
    echo "read-only content" > "$src"
    chmod 400 "$src"

    atomic_copy_file "$src" "$dst"

    if [[ -w "$dst" ]]; then
        log_pass "Read-only source file is writable at destination"
    else
        log_fail "Destination should be user-writable"
    fi
}

test_atomic_copy_dir_preserves_file_permissions() {
    log_test "atomic_copy_dir: preserves file permissions in directory"

    local src="$TEST_TEMP_DIR/src/ssh_dir"
    local dst="$TEST_TEMP_DIR/dst/ssh_dir"

    mkdir -p "$src"
    echo "private key" > "$src/id_rsa"
    echo "public key" > "$src/id_rsa.pub"
    echo "config" > "$src/config"
    chmod 600 "$src/id_rsa"
    chmod 644 "$src/id_rsa.pub"
    chmod 600 "$src/config"

    atomic_copy_dir "$src" "$dst"

    local mode_key mode_pub mode_config
    mode_key=$(get_file_mode "$dst/id_rsa")
    mode_pub=$(get_file_mode "$dst/id_rsa.pub")
    mode_config=$(get_file_mode "$dst/config")

    assert_equals "600" "$mode_key" "id_rsa should keep mode 600"
    assert_equals "644" "$mode_pub" "id_rsa.pub should keep mode 644"
    assert_equals "600" "$mode_config" "config should keep mode 600"
}

test_atomic_copy_dir_directories_writable() {
    log_test "atomic_copy_dir: directories are user-writable after copy"

    local src="$TEST_TEMP_DIR/src/dir_perms"
    local dst="$TEST_TEMP_DIR/dst/dir_perms"

    mkdir -p "$src/subdir"
    echo "test" > "$src/subdir/file.txt"

    atomic_copy_dir "$src" "$dst"

    if [[ -w "$dst" ]]; then
        log_pass "Top-level directory is writable"
    else
        log_fail "Top-level directory should be writable"
    fi

    if [[ -w "$dst/subdir" ]]; then
        log_pass "Subdirectory is writable"
    else
        log_fail "Subdirectory should be writable"
    fi
}

#===============================================================================
# ROLLBACK TESTS (issue #164)
#===============================================================================

test_atomic_copy_file_rollback_removes_corrupt_dst() {
    log_test "atomic_copy_file: removes destination when source disappears mid-copy"

    local src="$TEST_TEMP_DIR/src/rollback.txt"
    local dst="$TEST_TEMP_DIR/dst/rollback.txt"

    mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
    echo "original content" > "$src"

    # First copy succeeds
    atomic_copy_file "$src" "$dst"
    assert_file_exists "$dst" "File should exist after successful copy"

    # Remove source to force validation failure on next copy attempt
    # (source not found returns 1 and dst should not retain stale data
    #  from a previous copy — but this tests the source-not-found path)
    rm -f "$src"

    # Attempt copy with missing source — should fail and not leave stale dst
    if atomic_copy_file "$src" "$dst" 2>/dev/null; then
        log_fail "Should fail when source is missing"
    else
        log_pass "Correctly fails when source is missing"
    fi
}

test_atomic_copy_file_rollback_validation_detects_mismatch() {
    log_test "atomic_copy_file: _atomic_validate_file detects size mismatch"

    local src="$TEST_TEMP_DIR/src/validate.json"
    local dst="$TEST_TEMP_DIR/dst/validate.json"

    mkdir -p "$(dirname "$src")" "$(dirname "$dst")"

    # Create source with known content
    echo '{"key": "value", "data": "important"}' > "$src"

    # Place truncated content at destination (simulates torn read result)
    echo '{"key":' > "$dst"

    # Validation should detect the size mismatch
    if _atomic_validate_file "$src" "$dst"; then
        log_fail "Validation should detect size mismatch between source and corrupt destination"
    else
        log_pass "Validation correctly detects size mismatch"
    fi

    # Also verify JSON validation catches invalid JSON of matching size
    # Create src and dst with same byte count but dst has invalid JSON
    echo '{"ok": true}' > "$src"
    local src_size
    src_size=$(wc -c < "$src" | tr -d ' ')
    # Create dst with same size but invalid JSON
    printf '%*s' "$src_size" "" | tr ' ' 'x' > "$dst"

    if command -v jq &>/dev/null; then
        if _atomic_validate_file "$src" "$dst"; then
            log_fail "Validation should catch invalid JSON even with matching size"
        else
            log_pass "Validation catches invalid JSON with matching size"
        fi
    else
        log_info "jq not available, skipping JSON validation check"
    fi
}

test_atomic_copy_file_rollback_removes_dst_on_validation_failure() {
    log_test "atomic_copy_file: removes destination on validation failure (issue #164)"

    local src="$TEST_TEMP_DIR/src/rollback-val.txt"
    local dst="$TEST_TEMP_DIR/dst/rollback-val.txt"

    mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
    echo "content for validation rollback test" > "$src"

    # Override _atomic_validate_file to always fail (simulates torn read / size mismatch)
    _atomic_validate_file() { return 1; }

    # Copy should succeed (cp + mv) but validation should fail → rollback
    atomic_copy_file "$src" "$dst" 2>/dev/null
    local rc=$?

    assert_not_equals "0" "$rc" "Should return non-zero when validation fails"

    # Key assertion: dst must NOT exist (issue #164 rollback removes corrupt file)
    assert_file_not_exists "$dst" "Corrupt destination should be removed after validation failure"

    # Restore original _atomic_validate_file by re-sourcing
    unset _KAPSIS_ATOMIC_COPY_LOADED
    source "$KAPSIS_ROOT/scripts/lib/atomic-copy.sh"
}

#===============================================================================
# RO-PARENT FALLBACK TESTS (Issue #328)
#
# When dirname($dst) is read-only, the original mktemp-in-parent strategy
# fails twice (mktemp fail → fallback cp to same RO parent also fails).
# These tests cover the scratch-dir fallback that lets atomic_copy_dir
# succeed when $dst itself is writable but its parent isn't.
#
# We simulate RO parent by overriding `mktemp` to fail for the specific
# pattern the library uses (a path prefix containing the destination's
# parent). This works regardless of test-runner uid (root bypasses
# chmod 555, so chmod-based simulation isn't portable across CI envs).
#===============================================================================

# Reset the library state after a test that overrode internals.
# Review finding #6: also unset cp so failed-assertion early-exit doesn't
# leak mocks into subsequent tests.
_reset_atomic_copy_lib() {
    unset -f mktemp 2>/dev/null || true
    unset -f cp 2>/dev/null || true
    unset _KAPSIS_ATOMIC_COPY_LOADED
    # shellcheck disable=SC1091
    source "$KAPSIS_ROOT/scripts/lib/atomic-copy.sh"
}

test_atomic_copy_dir_ro_parent_writable_dst() {
    log_test "atomic_copy_dir: succeeds via scratch fallback when mktemp-in-parent fails but dst is writable"

    local src="$TEST_TEMP_DIR/src/ro_parent_src"
    local parent="$TEST_TEMP_DIR/dst/ro_parent_case"
    local dst="$parent/payload"

    mkdir -p "$src" "$dst"
    echo "alpha" > "$src/a.txt"
    echo "beta" > "$src/b.txt"

    # Simulate "dirname(dst) is read-only" by making mktemp fail for any
    # path under $parent, while still letting it succeed for the scratch dir.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local args=("$@")
        for a in "${args[@]}"; do
            if [[ "$a" == "$parent/"* ]]; then
                echo "mktemp: failed to create directory via template '$a': Read-only file system" >&2
                return 1
            fi
        done
        command mktemp "$@"
    }

    KAPSIS_SCRATCH_DIR="$TEST_TEMP_DIR/scratch" atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib

    assert_equals "0" "$rc" "Scratch-dir fallback should succeed when dst itself is writable"
    assert_file_exists "$dst/a.txt" "a.txt should reach dst via scratch path"
    assert_file_exists "$dst/b.txt" "b.txt should reach dst via scratch path"
}

test_atomic_copy_dir_ro_parent_ro_dst() {
    log_test "atomic_copy_dir: fails cleanly with surfaced error when both parent and dst are RO"

    local src="$TEST_TEMP_DIR/src/double_ro_src"
    local parent="$TEST_TEMP_DIR/dst/double_ro_case"
    local dst="$parent/payload"

    mkdir -p "$src" "$dst"
    echo "stuff" > "$src/x.txt"

    # Simulate both parent AND dst RO: mktemp fails everywhere except
    # scratch; cp into dst will then fail.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local args=("$@")
        for a in "${args[@]}"; do
            if [[ "$a" == "$parent/"* ]] || [[ "$a" == "$dst/"* ]]; then
                echo "mktemp: failed to create '$a': Read-only file system" >&2
                return 1
            fi
        done
        command mktemp "$@"
    }
    # And block writes into dst by overriding cp to fail for that path
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    cp() {
        local last="${*: -1}"
        if [[ "$last" == "$dst/"* ]] || [[ "$last" == "$dst/" ]]; then
            echo "cp: cannot create '$last': Read-only file system" >&2
            return 1
        fi
        command cp "$@"
    }

    local stderr_capture
    stderr_capture=$(KAPSIS_SCRATCH_DIR="$TEST_TEMP_DIR/scratch" atomic_copy_dir "$src" "$dst" 2>&1) || true

    _reset_atomic_copy_lib
    unset -f cp 2>/dev/null || true

    assert_contains "$stderr_capture" "mktemp failed" "stderr should surface the mktemp failure"
}

test_atomic_copy_dir_surfaces_mktemp_stderr() {
    log_test "atomic_copy_dir: mktemp stderr is surfaced in warning, not swallowed (Issue #328)"

    local src="$TEST_TEMP_DIR/src/stderr_src"
    local parent="$TEST_TEMP_DIR/dst/stderr_case"
    local dst="$parent/payload"

    mkdir -p "$src" "$parent"
    echo "diag" > "$src/x.txt"

    local marker="UNIQUE_MKTEMP_DIAG_98765"
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local args=("$@")
        for a in "${args[@]}"; do
            if [[ "$a" == "$parent/"* ]]; then
                echo "mktemp: $marker" >&2
                return 1
            fi
        done
        command mktemp "$@"
    }

    local stderr_capture
    stderr_capture=$(KAPSIS_SCRATCH_DIR="$TEST_TEMP_DIR/scratch" atomic_copy_dir "$src" "$dst" 2>&1) || true

    _reset_atomic_copy_lib

    assert_contains "$stderr_capture" "$marker" "Warning should include the underlying mktemp stderr text"
}

test_atomic_copy_file_surfaces_cp_stderr() {
    log_test "atomic_copy_file: cp/mktemp stderr is surfaced when copy fails (Issue #328)"

    local src="$TEST_TEMP_DIR/src/cp_err_src.txt"
    local dst_parent="$TEST_TEMP_DIR/dst/cp_err_parent"
    local dst="$dst_parent/file.txt"

    mkdir -p "$(dirname "$src")" "$dst_parent"
    echo "diag" > "$src"

    local marker="UNIQUE_FILE_CP_DIAG_54321"
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local args=("$@")
        for a in "${args[@]}"; do
            if [[ "$a" == "$dst_parent/"* ]]; then
                echo "mktemp: $marker" >&2
                return 1
            fi
        done
        command mktemp "$@"
    }
    # Also fail the fallback cp so we exercise the surfaced-error path
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    cp() {
        local last="${*: -1}"
        if [[ "$last" == "$dst" ]]; then
            echo "cp: cannot create '$dst': Read-only file system" >&2
            return 1
        fi
        command cp "$@"
    }

    local stderr_capture
    stderr_capture=$(atomic_copy_file "$src" "$dst" 2>&1) || true

    _reset_atomic_copy_lib
    unset -f cp 2>/dev/null || true

    if [[ "$stderr_capture" == *"$marker"* ]] || [[ "$stderr_capture" == *"fallback cp failed"* ]]; then
        log_pass "Warning surfaces underlying failure"
    else
        log_fail "Warning should surface mktemp/cp failure; got: $stderr_capture"
    fi
}

#===============================================================================
# ENSEMBLE REVIEW FOLLOW-UP TESTS (Issue #328, post-review hardening)
#===============================================================================

test_atomic_copy_dir_scratch_resets_prepopulated_dst() {
    log_test "atomic_copy_dir: scratch path clears stale files in pre-populated dst (review finding #2)"

    local src="$TEST_TEMP_DIR/src/scratch_repop_src"
    local parent="$TEST_TEMP_DIR/dst/scratch_repop_case"
    local dst="$parent/payload"

    mkdir -p "$src" "$dst"
    echo "fresh" > "$src/keep.txt"
    # Stale file that should NOT survive the copy
    echo "stale" > "$dst/stale.txt"

    # Force the primary mktemp to fail so scratch path is exercised
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local args=("$@")
        for a in "${args[@]}"; do
            if [[ "$a" == "$parent/"* ]]; then
                echo "mktemp: simulated RO parent" >&2
                return 1
            fi
        done
        command mktemp "$@"
    }

    KAPSIS_SCRATCH_DIR="$TEST_TEMP_DIR/scratch_repop" atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib

    assert_equals "0" "$rc" "Scratch path should succeed when dst was pre-populated with stale files"
    assert_file_exists "$dst/keep.txt" "Fresh src file should reach dst"
    assert_file_not_exists "$dst/stale.txt" "Stale file in dst should be cleared by scratch path"
}

test_atomic_copy_dir_last_resort_returns_success_when_cp_works() {
    log_test "atomic_copy_dir: last-resort direct cp returns 0 when files copy successfully (review finding #1)"

    local src="$TEST_TEMP_DIR/src/last_resort_src"
    local parent="$TEST_TEMP_DIR/dst/last_resort_case"
    local dst="$parent/payload"

    mkdir -p "$src" "$dst"
    echo "alpha" > "$src/a.txt"
    echo "beta" > "$src/b.txt"

    # Mock mktemp to fail for the primary path AND for any scratch path —
    # both must fail to reach the "last resort direct cp" branch.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        # All mktemp calls fail; library falls through to direct cp -rp.
        echo "mktemp: simulated failure" >&2
        return 1
    }

    # Scratch dir is irrelevant because mktemp -d will fail there too.
    KAPSIS_SCRATCH_DIR="$TEST_TEMP_DIR/last_resort_scratch" atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib

    assert_equals "0" "$rc" "Last-resort cp should return 0 when files were copied successfully"
    assert_file_exists "$dst/a.txt" "Last-resort path should copy src files"
    assert_file_exists "$dst/b.txt" "Last-resort path should copy src files"
}

test_atomic_copy_dir_mktemp_stderr_does_not_corrupt_path_on_success() {
    log_test "atomic_copy_dir: success-time stderr from mktemp does not poison captured path (review finding #4)"

    local src="$TEST_TEMP_DIR/src/stderr_success_src"
    local dst="$TEST_TEMP_DIR/dst/stderr_success_payload"

    mkdir -p "$src"
    echo "ok" > "$src/keep.txt"

    # Simulate a wrapper/glibc/locale warning printed to stderr on success.
    # If the implementation conflates stdout+stderr, tmp_dir gets the
    # garbage prefix and the function silently falls back to scratch.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local stdout_capture
        stdout_capture=$(command mktemp "$@") || return $?
        echo "WARN: simulated locale advisory" >&2
        echo "$stdout_capture"
    }

    atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib

    assert_equals "0" "$rc" "Should succeed despite stderr noise during mktemp"
    assert_file_exists "$dst/keep.txt" "File should land via primary atomic path (not scratch fallback)"

    # And no leftover .atomic-copy-dir-* in the dst parent (would indicate
    # we took the primary path then orphaned the temp dir).
    local leftovers
    leftovers=$(find "$(dirname "$dst")" -maxdepth 1 -name ".atomic-copy-dir-*" 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$leftovers" "No orphaned temp dir from a confused fallback"
}

#===============================================================================
# Issue #328 root-cause follow-up: tolerate benign cp stderr from
# virtio-fs (sockets/FIFOs readdir-visible but stat-invisible).
#
# Helper unit tests are split into focused functions so a failure in one
# scenario does not mask failures in subsequent ones.
#===============================================================================

# Shared cp override builder for benign-stat scenarios. Simulates a
# virtio-fs source that emits "cannot stat" lines for fake socket
# entries when read by cp, but otherwise copies regular files. The mock
# only fires when SOURCE (second-to-last argv after `-rp $src/.`) starts
# with $BENIGN_STAT_SRC_PREFIX — so scratch-path's second cp
# ($tmp_dir/. → $dst/) is unaffected, as expected for a local-FS copy
# with no host-side sockets.
#
# Caller exports before invoking _install_benign_stat_cp_mock:
#   BENIGN_STAT_NAMES       — space-separated fake socket basenames
#   BENIGN_STAT_SRC_PREFIX  — prefix of the source argv to trigger on
#   EXTRA_STDERR            — (optional) extra real-error line(s)
#
# Detection of the recursive form looks for `-rp` anywhere in argv (not
# just $1), so a future refactor that moves the flag does not silently
# turn the mock into a no-op.

# shellcheck disable=SC2317  # invoked indirectly via shell override
_install_benign_stat_cp_mock() {
    cp() {
        local args=("$@")
        local n=${#args[@]}
        local last=${args[n-1]}
        local src_arg=""
        [[ $n -ge 2 ]] && src_arg=${args[n-2]}
        local has_rp=0
        local a
        for a in "$@"; do
            [[ "$a" == "-rp" ]] && has_rp=1 && break
        done
        local should_fire=0
        if [[ $has_rp -eq 1 ]]; then
            if [[ -z "${BENIGN_STAT_SRC_PREFIX:-}" ]] \
                || [[ "$src_arg" == "${BENIGN_STAT_SRC_PREFIX}"* ]]; then
                should_fire=1
            fi
        fi
        if [[ $should_fire -eq 1 ]]; then
            command cp "$@"
            local name
            for name in $BENIGN_STAT_NAMES; do
                echo "cp: cannot stat '$last/$name': No such file or directory" >&2
            done
            if [[ -n "${EXTRA_STDERR:-}" ]]; then
                printf '%s\n' "$EXTRA_STDERR" >&2
            fi
            return 1
        fi
        command cp "$@"
    }
}

test_atomic_cp_stderr_empty_is_not_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: empty stderr → not benign"
    if _atomic_cp_stderr_is_benign_only ""; then
        echo "  FAIL: empty stderr should NOT be treated as benign (no signal to whitelist)"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_whitespace_only_is_not_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: newline-only stderr → not benign (review finding)"
    # All-whitespace stderr previously bypassed the empty-string guard and
    # was classified benign — covered here so a regression reintroduces it.
    if _atomic_cp_stderr_is_benign_only $'\n\n'; then
        echo "  FAIL: stderr of '\\n\\n' must NOT be treated as benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_single_benign_line() {
    log_test "_atomic_cp_stderr_is_benign_only: single 'cannot stat ENOENT' line → benign"
    local line=$'cp: cannot stat \'/x/foo.ipc\': No such file or directory'
    if ! _atomic_cp_stderr_is_benign_only "$line"; then
        echo "  FAIL: single benign line should be classified benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_multiple_benign_lines() {
    log_test "_atomic_cp_stderr_is_benign_only: multiple benign lines (with blank in middle) → benign"
    local many=$'cp: cannot stat \'/x/a.ipc\': No such file or directory\n\ncp: cannot stat \'/x/b.ipc\': No such file or directory'
    if ! _atomic_cp_stderr_is_benign_only "$many"; then
        echo "  FAIL: multiple benign lines should be classified benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_mixed_benign_and_real_is_not_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: benign + Permission denied → not benign"
    local mixed=$'cp: cannot stat \'/x/a.ipc\': No such file or directory\ncp: cannot create regular file \'/x/y\': Permission denied'
    if _atomic_cp_stderr_is_benign_only "$mixed"; then
        echo "  FAIL: mixed benign+real stderr must NOT be benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_unrelated_failure_is_not_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: unrelated cp error → not benign"
    local real_err=$'cp: cannot create directory \'/x\': Read-only file system'
    if _atomic_cp_stderr_is_benign_only "$real_err"; then
        echo "  FAIL: unrelated cp error must NOT be benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_different_enoent_verb_is_not_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: 'cannot open ENOENT' → not benign (only 'cannot stat' qualifies)"
    local enoent_other=$'cp: cannot open \'/x/a\': No such file or directory'
    if _atomic_cp_stderr_is_benign_only "$enoent_other"; then
        echo "  FAIL: only 'cannot stat ... ENOENT' should be benign, not 'cannot open ... ENOENT'"
        return 1
    fi
    return 0
}

# ----- Issue #335 follow-up: ENOTSUPP + preserving-permissions classifier -----

test_atomic_cp_stderr_stat_enotsupp_is_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: 'cannot stat ENOTSUPP' → benign (Issue #335 A)"
    local line=$'cp: cannot stat \'/kapsis-staging/.claude/./.git/fsmonitor--daemon.ipc\': Operation not supported'
    if ! _atomic_cp_stderr_is_benign_only "$line"; then
        echo "  FAIL: 'cannot stat ... Operation not supported' must be classified benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_preserve_perms_eacces_is_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: 'preserving permissions ... Permission denied' → benign (Issue #335 B, EACCES)"
    local line=$'cp: preserving permissions for \'/home/developer/.atomic-copy-dir-1Ac6gY/.\': Permission denied'
    if ! _atomic_cp_stderr_is_benign_only "$line"; then
        echo "  FAIL: 'preserving permissions ... Permission denied' must be classified benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_preserve_perms_eperm_is_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: 'preserving permissions ... Operation not permitted' → benign (Issue #335 B, EPERM)"
    local line=$'cp: preserving permissions for \'/x/.\': Operation not permitted'
    if ! _atomic_cp_stderr_is_benign_only "$line"; then
        echo "  FAIL: 'preserving permissions ... Operation not permitted' must be classified benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_preserve_perms_enoent_is_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: 'preserving permissions ... No such file or directory' → benign (e2e-discovered: cp tries fchmod on a dst that was never created because src is a socket)"
    local line=$'cp: preserving permissions for \'/tmp/probe/./fsmonitor--daemon.ipc\': No such file or directory'
    if ! _atomic_cp_stderr_is_benign_only "$line"; then
        echo "  FAIL: 'preserving permissions ... ENOENT' must be classified benign (GNU cp emits this when src is a non-copyable type)"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_mixed_stat_and_preserve_perms_is_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: ENOTSUPP stat + preserve-perms (kapsis#335 trace shape) → benign"
    local mixed=$'cp: cannot stat \'/x/a.ipc\': Operation not supported\ncp: preserving permissions for \'/y/.\': Permission denied'
    if ! _atomic_cp_stderr_is_benign_only "$mixed"; then
        echo "  FAIL: mixed ENOTSUPP + preserve-perms (the actual kapsis#335 trace) must be classified benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_preserve_perms_for_file_path_is_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: 'preserving permissions' for file path (not dir-with-slash) → benign"
    local line=$'cp: preserving permissions for \'/x/file.txt\': Permission denied'
    if ! _atomic_cp_stderr_is_benign_only "$line"; then
        echo "  FAIL: 'preserving permissions for FILE': benign regardless of dir/file form"
        return 1
    fi
    return 0
}

# ----- Review feedback (PR #336): coverage gaps + side-effect signaling -----

test_atomic_cp_stderr_preserve_perms_unrecognized_reason_is_not_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: 'preserving permissions ... Read-only file system' → not benign (PR #336 review HIGH)"
    # An unrecognized errno suffix on a preserve-perms line is NOT in the
    # narrow EACCES|EPERM whitelist; classifier must reject. A future
    # regex widening (e.g. `.*` instead of the specific reason strings)
    # would silently regress this — pinned here.
    local line=$'cp: preserving permissions for \'/x/.\': Read-only file system'
    if _atomic_cp_stderr_is_benign_only "$line"; then
        echo "  FAIL: 'preserving permissions ... Read-only file system' must NOT be classified benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_multiple_preserve_perms_lines_are_benign() {
    log_test "_atomic_cp_stderr_is_benign_only: multiple 'preserving permissions' lines → benign (PR #336 review)"
    local many=$'cp: preserving permissions for \'/x/a/.\': Permission denied\ncp: preserving permissions for \'/x/b/.\': Permission denied\ncp: preserving permissions for \'/x/c/.\': Operation not permitted'
    if ! _atomic_cp_stderr_is_benign_only "$many"; then
        echo "  FAIL: multiple preserve-perms lines must all classify as benign"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_kind_signal_stat_only() {
    log_test "_atomic_cp_stderr_is_benign_only: _ATOMIC_CP_BENIGN_KIND='stat-fail' when only stat lines present"
    local line=$'cp: cannot stat \'/x/foo.ipc\': No such file or directory'
    _atomic_cp_stderr_is_benign_only "$line" || {
        echo "  FAIL: classifier should accept this line"
        return 1
    }
    if [[ "${_ATOMIC_CP_BENIGN_KIND:-}" != "stat-fail" ]]; then
        echo "  FAIL: expected _ATOMIC_CP_BENIGN_KIND=stat-fail, got '${_ATOMIC_CP_BENIGN_KIND:-}'"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_kind_signal_preserve_perms_only() {
    log_test "_atomic_cp_stderr_is_benign_only: _ATOMIC_CP_BENIGN_KIND='preserve-perms' when only preserve-perms lines present"
    local line=$'cp: preserving permissions for \'/x/.\': Permission denied'
    _atomic_cp_stderr_is_benign_only "$line" || {
        echo "  FAIL: classifier should accept this line"
        return 1
    }
    if [[ "${_ATOMIC_CP_BENIGN_KIND:-}" != "preserve-perms" ]]; then
        echo "  FAIL: expected _ATOMIC_CP_BENIGN_KIND=preserve-perms, got '${_ATOMIC_CP_BENIGN_KIND:-}'"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_kind_signal_mixed() {
    log_test "_atomic_cp_stderr_is_benign_only: _ATOMIC_CP_BENIGN_KIND='mixed' when both line types present"
    local mixed=$'cp: cannot stat \'/x/foo.ipc\': No such file or directory\ncp: preserving permissions for \'/x/.\': Permission denied'
    _atomic_cp_stderr_is_benign_only "$mixed" || {
        echo "  FAIL: classifier should accept mixed benign stderr"
        return 1
    }
    if [[ "${_ATOMIC_CP_BENIGN_KIND:-}" != "mixed" ]]; then
        echo "  FAIL: expected _ATOMIC_CP_BENIGN_KIND=mixed, got '${_ATOMIC_CP_BENIGN_KIND:-}'"
        return 1
    fi
    return 0
}

test_atomic_cp_stderr_kind_cleared_on_rejection() {
    log_test "_atomic_cp_stderr_is_benign_only: _ATOMIC_CP_BENIGN_KIND cleared when stderr is unrecognized"
    # Pre-set kind to detect that the classifier resets it on entry,
    # even when the stderr is ultimately rejected.
    _ATOMIC_CP_BENIGN_KIND="stale-value"
    local real_err=$'cp: cannot create directory \'/x\': Read-only file system'
    if _atomic_cp_stderr_is_benign_only "$real_err"; then
        echo "  FAIL: real error must NOT classify benign"
        return 1
    fi
    if [[ -n "${_ATOMIC_CP_BENIGN_KIND:-}" ]]; then
        echo "  FAIL: _ATOMIC_CP_BENIGN_KIND must be cleared on rejection, got '${_ATOMIC_CP_BENIGN_KIND}'"
        return 1
    fi
    return 0
}

test_atomic_restore_modes_basic() {
    log_test "_atomic_restore_modes: mirrors src mode bits onto dst (PR #336 review HIGH — private-key mode leak fix)"
    local base="$TEST_TEMP_DIR/restore-modes-basic"
    local src="$base/src"
    local dst="$base/dst"

    mkdir -p "$src/.ssh"
    echo "private" > "$src/.ssh/id_rsa"
    echo "public" > "$src/.ssh/id_rsa.pub"
    chmod 0700 "$src/.ssh"
    chmod 0600 "$src/.ssh/id_rsa"
    chmod 0644 "$src/.ssh/id_rsa.pub"

    # Simulate the "cp -p's fchmod failed" outcome: dst tree exists with
    # the right files but mode bits are at cp defaults.
    mkdir -p "$dst/.ssh"
    cp "$src/.ssh/id_rsa" "$dst/.ssh/id_rsa"
    cp "$src/.ssh/id_rsa.pub" "$dst/.ssh/id_rsa.pub"
    chmod 0755 "$dst/.ssh"
    chmod 0644 "$dst/.ssh/id_rsa"      # ← would be world-readable
    chmod 0644 "$dst/.ssh/id_rsa.pub"

    _atomic_restore_modes "$src" "$dst" || {
        echo "  FAIL: _atomic_restore_modes returned non-zero"
        return 1
    }

    # Cross-platform stat: GNU first, then BSD fallback.
    _get_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1" 2>/dev/null; }
    local m_ssh m_priv m_pub
    m_ssh=$(_get_mode "$dst/.ssh")
    m_priv=$(_get_mode "$dst/.ssh/id_rsa")
    m_pub=$(_get_mode "$dst/.ssh/id_rsa.pub")

    [[ "$m_ssh"  == "700" ]] || { echo "  FAIL: .ssh dir mode should be 700, got $m_ssh"; return 1; }
    [[ "$m_priv" == "600" ]] || { echo "  FAIL: id_rsa mode should be 600 (private), got $m_priv"; return 1; }
    [[ "$m_pub"  == "644" ]] || { echo "  FAIL: id_rsa.pub mode should be 644, got $m_pub"; return 1; }
    return 0
}

test_atomic_restore_modes_missing_dst_entry_is_tolerated() {
    log_test "_atomic_restore_modes: tolerates dst entries missing from src (no crash, returns 0)"
    local base="$TEST_TEMP_DIR/restore-modes-missing"
    local src="$base/src"
    local dst="$base/dst"
    mkdir -p "$src" "$dst"
    echo "only-in-src" > "$src/extra.txt"
    chmod 0600 "$src/extra.txt"
    # dst has NO matching entry — _atomic_restore_modes should skip
    # cleanly without crashing.
    _atomic_restore_modes "$src" "$dst" || {
        echo "  FAIL: should return 0 when dst is missing src entries"
        return 1
    }
    return 0
}

# ----- Integration: main atomic-copy path (no scratch, no last-resort) -----

test_atomic_copy_dir_main_path_tolerates_benign_stat_errors() {
    log_test "atomic_copy_dir: main path tolerates benign cp ENOENT when count matches (Issue #328)"

    local src="$TEST_TEMP_DIR/src/main_benign_src"
    local dst="$TEST_TEMP_DIR/dst/main_benign_dst"

    mkdir -p "$src"
    echo "alpha" > "$src/a.txt"
    echo "beta" > "$src/b.txt"

    BENIGN_STAT_NAMES=".fake-socket-a.ipc .fake-socket-b.ipc"
    _install_benign_stat_cp_mock

    atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib
    unset BENIGN_STAT_NAMES EXTRA_STDERR

    assert_equals "0" "$rc" "Should succeed: cp non-zero is benign and counts match"
    assert_file_exists "$dst/a.txt" "Regular file a.txt must be present in dst"
    assert_file_exists "$dst/b.txt" "Regular file b.txt must be present in dst"
}

test_atomic_copy_dir_main_path_rejects_mixed_real_error() {
    log_test "atomic_copy_dir: main path rejects mixed benign+real cp stderr (classifier path) (Issue #328)"

    local src="$TEST_TEMP_DIR/src/main_mixed_src"
    local dst="$TEST_TEMP_DIR/dst/main_mixed_dst"

    mkdir -p "$src"
    echo "x" > "$src/file.txt"

    BENIGN_STAT_NAMES=".benign.ipc"
    EXTRA_STDERR="cp: cannot create regular file 'blocked': Permission denied"
    _install_benign_stat_cp_mock

    # Capture atomic_copy_dir's stderr (log lines) to pin the failure mode.
    local out
    out=$(atomic_copy_dir "$src" "$dst" 2>&1)
    local rc=$?

    _reset_atomic_copy_lib
    unset BENIGN_STAT_NAMES EXTRA_STDERR

    assert_not_equals "0" "$rc" "Mixed benign+real cp stderr must NOT succeed"
    # Pin failure to the classifier-rejection path (not count mismatch).
    # Main-path failure emits "atomic_copy_dir: cp failed for <dst>",
    # distinct from the trailing-fallback's "atomic_copy_dir: fallback
    # cp failed for <dst>". A count-mismatch path would instead emit
    # "file count mismatch" and would NOT emit the main-path "cp failed".
    assert_contains "$out" "atomic_copy_dir: cp failed for" \
        "Mixed benign+real stderr must log main-path 'cp failed for' (classifier rejection)"
    if [[ "$out" == *"file count mismatch"* ]]; then
        echo "  FAIL: log contains 'file count mismatch' but failure should be from classifier rejection"
        return 1
    fi
    return 0
}

test_atomic_copy_dir_main_path_rejects_benign_with_count_mismatch() {
    log_test "atomic_copy_dir: main path count check catches dropped file even with benign stderr (Issue #328)"

    local src="$TEST_TEMP_DIR/src/main_count_src"
    local dst="$TEST_TEMP_DIR/dst/main_count_dst"

    mkdir -p "$src"
    echo "a" > "$src/a.txt"
    echo "b" > "$src/b.txt"
    echo "c" > "$src/c.txt"

    # cp emits ONLY benign stderr but actually drops a regular file.
    # Classifier says "benign"; count check (3 vs 2) must reject.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    cp() {
        local args=("$@")
        local n=${#args[@]}
        local last=${args[n-1]}
        local has_rp=0
        local a
        for a in "$@"; do
            [[ "$a" == "-rp" ]] && has_rp=1 && break
        done
        if [[ $has_rp -eq 1 ]]; then
            command cp -p "$src/a.txt" "${last}/a.txt"
            command cp -p "$src/b.txt" "${last}/b.txt"
            echo "cp: cannot stat '$last/.fake.ipc': No such file or directory" >&2
            return 1
        fi
        command cp "$@"
    }

    local out
    out=$(atomic_copy_dir "$src" "$dst" 2>&1)
    local rc=$?

    _reset_atomic_copy_lib

    assert_not_equals "0" "$rc" "Count mismatch must reject even when cp stderr is benign"
    # Pin failure to the count-mismatch path. Classifier rejection would
    # log "atomic_copy_dir: cp failed for"; count mismatch logs "file
    # count mismatch" (and falls through to "atomic_copy_dir: fallback
    # cp failed for", which is a different message we tolerate).
    assert_contains "$out" "file count mismatch" \
        "Benign stderr with dropped file must log 'file count mismatch' (count check)"
    if [[ "$out" == *"atomic_copy_dir: cp failed for"* ]]; then
        echo "  FAIL: log contains main-path 'cp failed for' but failure should be count mismatch"
        return 1
    fi
    return 0
}

# ----- Integration: scratch-fallback path (mktemp-in-parent fails) -----

test_atomic_copy_dir_scratch_path_tolerates_benign_stat_errors() {
    log_test "atomic_copy_dir: scratch-fallback path tolerates benign cp ENOENT (Issue #328 coverage gap)"

    local src="$TEST_TEMP_DIR/src/scratch_benign_src"
    local parent="$TEST_TEMP_DIR/dst/scratch_benign_case"
    local dst="$parent/payload"

    mkdir -p "$src" "$dst"
    echo "alpha" > "$src/a.txt"
    echo "beta" > "$src/b.txt"

    # Force the primary mktemp to fail (simulating an RO dirname(dst))
    # so atomic_copy_dir enters the scratch-fallback branch.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local args=("$@")
        for a in "${args[@]}"; do
            if [[ "$a" == "$parent/"* ]]; then
                echo "mktemp: failed to create directory via template '$a': Read-only file system" >&2
                return 1
            fi
        done
        command mktemp "$@"
    }

    BENIGN_STAT_NAMES=".scratch-socket.ipc"
    BENIGN_STAT_SRC_PREFIX="$src/"  # only fire on src→scratch leg
    _install_benign_stat_cp_mock

    KAPSIS_SCRATCH_DIR="$TEST_TEMP_DIR/scratch_benign" \
        atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib
    unset BENIGN_STAT_NAMES BENIGN_STAT_SRC_PREFIX

    assert_equals "0" "$rc" "Scratch-fallback path should succeed when cp's non-zero is benign"
    assert_file_exists "$dst/a.txt" "a.txt should land via scratch path despite benign stderr"
    assert_file_exists "$dst/b.txt" "b.txt should land via scratch path despite benign stderr"
}

# ----- Integration: last-resort direct-cp path (both mktemps fail) -----

test_atomic_copy_dir_last_resort_tolerates_benign_stat_errors() {
    log_test "atomic_copy_dir: last-resort direct cp tolerates benign cp ENOENT (Issue #328 coverage gap)"

    local src="$TEST_TEMP_DIR/src/lastresort_benign_src"
    local parent="$TEST_TEMP_DIR/dst/lastresort_benign_case"
    local dst="$parent/payload"
    local scratch="$TEST_TEMP_DIR/scratch_lastresort"

    mkdir -p "$src" "$dst" "$scratch"
    echo "alpha" > "$src/a.txt"
    echo "beta" > "$src/b.txt"

    # Force BOTH mktemps to fail (primary parent AND scratch base) so
    # atomic_copy_dir enters the last-resort direct-cp branch.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    mktemp() {
        local args=("$@")
        for a in "${args[@]}"; do
            if [[ "$a" == "$parent/"* ]] || [[ "$a" == "$scratch/"* ]]; then
                echo "mktemp: failed to create directory via template '$a': Read-only file system" >&2
                return 1
            fi
        done
        command mktemp "$@"
    }

    BENIGN_STAT_NAMES=".lastresort-socket.ipc"
    BENIGN_STAT_SRC_PREFIX="$src/"  # only fire on src→dst direct leg
    _install_benign_stat_cp_mock

    KAPSIS_SCRATCH_DIR="$scratch" \
        atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib
    unset BENIGN_STAT_NAMES BENIGN_STAT_SRC_PREFIX

    assert_equals "0" "$rc" "Last-resort direct cp should succeed when cp's non-zero is benign"
    assert_file_exists "$dst/a.txt" "a.txt should land via last-resort direct cp"
    assert_file_exists "$dst/b.txt" "b.txt should land via last-resort direct cp"
}

# ----- Integration: kapsis#335 end-to-end (ENOTSUPP + preserving-perms) -----

test_atomic_copy_dir_main_path_tolerates_kapsis335_pattern() {
    log_test "atomic_copy_dir: main path tolerates ENOTSUPP + preserving-permissions in same cp stderr (Issue #335 end-to-end)"

    local src="$TEST_TEMP_DIR/src/k335_src"
    local dst="$TEST_TEMP_DIR/dst/k335_dst"

    mkdir -p "$src"
    echo "alpha" > "$src/a.txt"
    echo "beta" > "$src/b.txt"

    # Reproduce the exact kapsis#335 stderr shape: one ENOTSUPP "cannot
    # stat" line for a fake socket AND a "preserving permissions" line
    # for the tmp dir cp could not chmod-back. Real files ARE copied;
    # cp returns 1. atomic_copy_dir must classify both lines as benign,
    # pass the count check (sockets aren't counted), and succeed.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    cp() {
        local args=("$@")
        local n=${#args[@]}
        local last=${args[n-1]}
        local has_rp=0
        local a
        for a in "$@"; do
            [[ "$a" == "-rp" ]] && has_rp=1 && break
        done
        if [[ $has_rp -eq 1 ]]; then
            command cp "$@"
            echo "cp: cannot stat '$last/.fake-socket.ipc': Operation not supported" >&2
            echo "cp: preserving permissions for '$last/.': Permission denied" >&2
            return 1
        fi
        command cp "$@"
    }

    atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib

    assert_equals "0" "$rc" "ENOTSUPP + preserving-perms must be tolerated when counts match"
    assert_file_exists "$dst/a.txt" "a.txt must be present after kapsis#335-shape cp"
    assert_file_exists "$dst/b.txt" "b.txt must be present after kapsis#335-shape cp"
}

test_atomic_copy_dir_makes_restrictive_dst_writable() {
    log_test "atomic_copy_dir: defensive chmod allows replacement of pre-created restrictive-mode dst (Issue #335 C)"

    local src="$TEST_TEMP_DIR/src/k335c_src"
    local dst="$TEST_TEMP_DIR/dst/k335c_dst"

    mkdir -p "$src"
    echo "new-payload" > "$src/payload.txt"

    # Simulate entrypoint's pre-creation of dst: existing dir with a
    # stale file and mode 0500 (read+exec but NO write for owner).
    # Without the defensive chmod, the subsequent rm-rf would fail to
    # unlink stale.txt and the replacement step would error out. With
    # the chmod, rm-rf succeeds and atomic_copy_dir replaces dst
    # cleanly.
    mkdir -p "$dst"
    echo "stale" > "$dst/stale.txt"
    chmod 0500 "$dst"

    atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    # Restore mode so cleanup can succeed regardless of test outcome.
    chmod 0755 "$dst" 2>/dev/null || true

    assert_equals "0" "$rc" "atomic_copy_dir must succeed by chmod-ing restrictive dst before rm-rf"
    assert_file_exists "$dst/payload.txt" "Fresh payload must land in dst after replacement"
    assert_file_not_exists "$dst/stale.txt" "Stale dst content must be replaced, not merged"
}

test_atomic_copy_dir_chmod_recursive_on_nested_subdirs() {
    log_test "atomic_copy_dir: defensive chmod is -R (PR #336 review: nested restrictive subdirs)"

    local src="$TEST_TEMP_DIR/src/k335c_nested_src"
    local dst="$TEST_TEMP_DIR/dst/k335c_nested_dst"

    mkdir -p "$src"
    echo "fresh-top" > "$src/top.txt"

    # Pre-create dst with a nested restrictive subdir containing a stale
    # file. Without -R on the defensive chmod, the chmod fixes the top
    # level but the nested subdir remains 0500, the recursive rm-rf
    # fails to unlink stale-nested.txt, and atomic_copy_dir errors out.
    mkdir -p "$dst/subdir"
    echo "stale-nested" > "$dst/subdir/stale-nested.txt"
    chmod 0500 "$dst/subdir"
    chmod 0500 "$dst"

    atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    chmod -R 0755 "$dst" 2>/dev/null || true

    assert_equals "0" "$rc" "atomic_copy_dir must succeed when dst contains nested restrictive subdirs"
    assert_file_exists "$dst/top.txt" "Fresh payload must land at the top level"
    assert_file_not_exists "$dst/subdir/stale-nested.txt" "Nested stale content must be replaced (chmod -R was effective)"
    [[ ! -d "$dst/subdir" ]] || {
        echo "  FAIL: subdir from old dst tree should be gone after replacement"
        return 1
    }
    return 0
}

test_atomic_copy_dir_skips_defensive_chmod_when_dst_already_writable() {
    log_test "atomic_copy_dir: defensive chmod short-circuits when dst is already writable (PR #336 review MED: avoid 24k syscalls)"

    local src="$TEST_TEMP_DIR/src/k335c_skip_src"
    local dst="$TEST_TEMP_DIR/dst/k335c_skip_dst"

    mkdir -p "$src"
    echo "payload" > "$src/payload.txt"

    # Pre-create dst with normal writable perms. Capture the mtime to
    # detect whether chmod ran (chmod updates ctime; we use a simple
    # observability proxy by counting chmod invocations via a wrapper).
    mkdir -p "$dst"
    echo "stale" > "$dst/stale.txt"
    # shellcheck disable=SC2218  # chmod override is defined below; this call uses the real one
    chmod 0755 "$dst"

    # Wrap chmod to count invocations during atomic_copy_dir. We only
    # care that chmod -R u+rwx on $dst itself is skipped — the inner
    # `find -type d -exec chmod u+w` on the tmp_dir is unrelated.
    local chmod_calls_file="$TEST_TEMP_DIR/chmod-calls-$$"
    : > "$chmod_calls_file"
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    chmod() {
        # Record the FIRST positional after the mode for inspection.
        echo "$*" >> "$chmod_calls_file"
        command chmod "$@"
    }

    atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib
    unset -f chmod 2>/dev/null || true

    assert_equals "0" "$rc" "atomic_copy_dir should succeed when dst is already writable"
    assert_file_exists "$dst/payload.txt" "Fresh payload must land in dst"
    # The defensive `chmod -R u+rwx "$dst"` invocation must NOT have run.
    if grep -q "\-R u+rwx $dst\$" "$chmod_calls_file"; then
        echo "  FAIL: defensive 'chmod -R u+rwx $dst' should be skipped when dst is already writable"
        echo "  chmod calls recorded:"
        cat "$chmod_calls_file"
        return 1
    fi
    return 0
}

test_atomic_copy_dir_handles_symlink_dst_by_canonicalizing() {
    log_test "atomic_copy_dir: defensive chmod canonicalizes symlink dst (PR #336 review HIGH: CWE-367 / macOS chmod-on-symlink)"

    local src="$TEST_TEMP_DIR/src/k335c_link_src"
    local real_dst="$TEST_TEMP_DIR/dst/k335c_link_real"
    local link_dst="$TEST_TEMP_DIR/dst/k335c_link_via"

    mkdir -p "$src"
    echo "payload" > "$src/payload.txt"

    mkdir -p "$real_dst"
    echo "stale" > "$real_dst/stale.txt"
    chmod 0500 "$real_dst"
    ln -s "$real_dst" "$link_dst"

    atomic_copy_dir "$src" "$link_dst" 2>/dev/null
    local rc=$?

    chmod -R 0755 "$real_dst" 2>/dev/null || true

    # Whether dst was the symlink or the canonicalized target, the
    # operation must succeed and the fresh payload must be visible
    # through both paths.
    assert_equals "0" "$rc" "atomic_copy_dir must succeed when dst is a symlink to a restrictive dir"
    assert_file_exists "$link_dst/payload.txt" "Fresh payload must be visible through the symlink"
    assert_file_not_exists "$link_dst/stale.txt" "Stale content under the real target must be replaced"
}

# ----- Integration: scratch-fallback path with preserve-perms mode restore -----

test_atomic_copy_dir_restores_modes_after_preserve_perms_accepted() {
    log_test "atomic_copy_dir: restores src mode bits when classifier accepts preserve-perms (PR #336 review HIGH: SSH key mode leak)"

    local src="$TEST_TEMP_DIR/src/preserve_perms_modes_src"
    local dst="$TEST_TEMP_DIR/dst/preserve_perms_modes_dst"

    mkdir -p "$src/.ssh"
    echo "private-key-bytes" > "$src/.ssh/id_rsa"
    chmod 0700 "$src/.ssh"
    chmod 0600 "$src/.ssh/id_rsa"

    # Mock cp: real-copy the files but DROP the mode bits (simulate
    # cp -p's fchmod failure) AND emit the benign preserve-perms
    # stderr that the classifier accepts.
    # shellcheck disable=SC2317  # invoked indirectly via shell override
    cp() {
        local args=("$@")
        local n=${#args[@]}
        local last=${args[n-1]}
        local has_rp=0
        local a
        for a in "$@"; do
            [[ "$a" == "-rp" ]] && has_rp=1 && break
        done
        if [[ $has_rp -eq 1 ]]; then
            # Replicate the data without -p (so modes drop to umask defaults)
            command cp -r "$src/." "$last/" 2>/dev/null
            # Force loose modes to simulate the fchmod failure outcome
            find "$last" -type d -exec command chmod 0755 {} + 2>/dev/null || true
            find "$last" -type f -exec command chmod 0644 {} + 2>/dev/null || true
            echo "cp: preserving permissions for '$last/.': Permission denied" >&2
            return 1
        fi
        command cp "$@"
    }

    atomic_copy_dir "$src" "$dst" 2>/dev/null
    local rc=$?

    _reset_atomic_copy_lib

    _get_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1" 2>/dev/null; }
    local m_ssh m_priv
    m_ssh=$(_get_mode "$dst/.ssh")
    m_priv=$(_get_mode "$dst/.ssh/id_rsa")

    assert_equals "0" "$rc" "atomic_copy_dir must succeed with preserve-perms benign"
    [[ "$m_ssh"  == "700" ]] || { echo "  FAIL: .ssh dir mode should be RESTORED to 700, got $m_ssh"; return 1; }
    [[ "$m_priv" == "600" ]] || { echo "  FAIL: id_rsa mode should be RESTORED to 600 (private), got $m_priv — this is the kapsis#336 review's SSH-key-leak finding"; return 1; }
    return 0
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "Atomic Copy Library (atomic-copy.sh)"

    # Setup
    setup_atomic_copy_tests

    # Ensure cleanup on exit
    trap cleanup_atomic_copy_tests EXIT

    # atomic_copy_file() tests
    run_test test_atomic_copy_file_basic
    run_test test_atomic_copy_file_preserves_content
    run_test test_atomic_copy_file_size_validation
    run_test test_atomic_copy_file_json_validation
    run_test test_atomic_copy_file_creates_parent_dirs
    run_test test_atomic_copy_file_missing_source
    run_test test_atomic_copy_file_empty_file
    run_test test_atomic_copy_file_large_file
    run_test test_atomic_copy_file_no_temp_files_on_success
    run_test test_atomic_copy_file_overwrites_existing
    run_test test_atomic_copy_file_spaces_in_path
    run_test test_atomic_copy_file_writable

    # Permission preservation tests (issue #159)
    run_test test_atomic_copy_file_preserves_permissions
    run_test test_atomic_copy_file_readonly_gets_write

    # atomic_copy_dir() tests
    run_test test_atomic_copy_dir_basic
    run_test test_atomic_copy_dir_preserves_structure
    run_test test_atomic_copy_dir_missing_source
    run_test test_atomic_copy_dir_no_temp_dirs_on_success
    run_test test_atomic_copy_dir_writable

    # Permission preservation tests for directories (issue #159)
    run_test test_atomic_copy_dir_preserves_file_permissions
    run_test test_atomic_copy_dir_directories_writable

    # Rollback tests (issue #164)
    run_test test_atomic_copy_file_rollback_removes_corrupt_dst
    run_test test_atomic_copy_file_rollback_validation_detects_mismatch
    run_test test_atomic_copy_file_rollback_removes_dst_on_validation_failure

    # RO-parent fallback tests (issue #328)
    run_test test_atomic_copy_dir_ro_parent_writable_dst
    run_test test_atomic_copy_dir_ro_parent_ro_dst
    run_test test_atomic_copy_dir_surfaces_mktemp_stderr
    run_test test_atomic_copy_file_surfaces_cp_stderr

    # Ensemble-review follow-up tests (issue #328 post-review hardening)
    run_test test_atomic_copy_dir_scratch_resets_prepopulated_dst
    run_test test_atomic_copy_dir_last_resort_returns_success_when_cp_works
    run_test test_atomic_copy_dir_mktemp_stderr_does_not_corrupt_path_on_success

    # Issue #328 root-cause follow-up: tolerate benign cp stderr from
    # virtio-fs (sockets/FIFOs readdir-visible but stat-invisible).
    # Helper unit tests (split per-scenario for failure-isolation):
    run_test test_atomic_cp_stderr_empty_is_not_benign
    run_test test_atomic_cp_stderr_whitespace_only_is_not_benign
    run_test test_atomic_cp_stderr_single_benign_line
    run_test test_atomic_cp_stderr_multiple_benign_lines
    run_test test_atomic_cp_stderr_mixed_benign_and_real_is_not_benign
    run_test test_atomic_cp_stderr_unrelated_failure_is_not_benign
    run_test test_atomic_cp_stderr_different_enoent_verb_is_not_benign
    # Issue #335 follow-up: ENOTSUPP + preserving-permissions classifier
    run_test test_atomic_cp_stderr_stat_enotsupp_is_benign
    run_test test_atomic_cp_stderr_preserve_perms_eacces_is_benign
    run_test test_atomic_cp_stderr_preserve_perms_eperm_is_benign
    run_test test_atomic_cp_stderr_preserve_perms_enoent_is_benign
    run_test test_atomic_cp_stderr_mixed_stat_and_preserve_perms_is_benign
    run_test test_atomic_cp_stderr_preserve_perms_for_file_path_is_benign
    # Integration tests for the three patched cp call sites:
    run_test test_atomic_copy_dir_main_path_tolerates_benign_stat_errors
    run_test test_atomic_copy_dir_main_path_rejects_mixed_real_error
    run_test test_atomic_copy_dir_main_path_rejects_benign_with_count_mismatch
    run_test test_atomic_copy_dir_scratch_path_tolerates_benign_stat_errors
    run_test test_atomic_copy_dir_last_resort_tolerates_benign_stat_errors
    # Issue #335 end-to-end integration tests
    run_test test_atomic_copy_dir_main_path_tolerates_kapsis335_pattern
    run_test test_atomic_copy_dir_makes_restrictive_dst_writable
    # PR #336 review feedback (HIGH + MEDIUM coverage gaps)
    run_test test_atomic_cp_stderr_preserve_perms_unrecognized_reason_is_not_benign
    run_test test_atomic_cp_stderr_multiple_preserve_perms_lines_are_benign
    run_test test_atomic_cp_stderr_kind_signal_stat_only
    run_test test_atomic_cp_stderr_kind_signal_preserve_perms_only
    run_test test_atomic_cp_stderr_kind_signal_mixed
    run_test test_atomic_cp_stderr_kind_cleared_on_rejection
    run_test test_atomic_restore_modes_basic
    run_test test_atomic_restore_modes_missing_dst_entry_is_tolerated
    run_test test_atomic_copy_dir_chmod_recursive_on_nested_subdirs
    run_test test_atomic_copy_dir_skips_defensive_chmod_when_dst_already_writable
    run_test test_atomic_copy_dir_handles_symlink_dst_by_canonicalizing
    run_test test_atomic_copy_dir_restores_modes_after_preserve_perms_accepted

    # Summary
    print_summary
}

main "$@"
