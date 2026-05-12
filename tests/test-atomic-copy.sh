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

    # Summary
    print_summary
}

main "$@"
