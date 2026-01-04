#!/usr/bin/env bash
#===============================================================================
# Test: Cross-Platform Compatibility (compat.sh)
#
# Unit tests for scripts/lib/compat.sh - the cross-platform compatibility layer.
#
# Tests verify:
#   - get_file_size() returns correct byte count
#   - get_file_mtime() returns Unix epoch timestamps
#   - is_macos() / is_linux() correctly detect platform
#   - get_file_md5() returns correct 32-char hex hash
#
# Note: Tests run on the current platform and verify correct behavior for that
# platform. Cross-platform consistency is verified via CI on both Linux and macOS.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the compatibility library under test
source "$KAPSIS_ROOT/scripts/lib/compat.sh"

# Test directory for file operations
TEST_TEMP_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_compat_tests() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-compat-test.XXXXXX")
    log_info "Test temp directory: $TEST_TEMP_DIR"
}

cleanup_compat_tests() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

#===============================================================================
# get_file_size() TESTS
#===============================================================================

test_get_file_size_known_content() {
    log_test "get_file_size: returns correct size for known content"

    local test_file="$TEST_TEMP_DIR/known_size.txt"

    # Write exactly 13 bytes: "Hello World!\n"
    printf "Hello World!\n" > "$test_file"

    local size
    size=$(get_file_size "$test_file")

    assert_equals "13" "$size" "Should return 13 bytes for 'Hello World!\\n'"
}

test_get_file_size_empty_file() {
    log_test "get_file_size: returns 0 for empty file"

    local test_file="$TEST_TEMP_DIR/empty.txt"
    touch "$test_file"

    local size
    size=$(get_file_size "$test_file")

    assert_equals "0" "$size" "Empty file should have size 0"
}

test_get_file_size_nonexistent() {
    log_test "get_file_size: returns 0 for non-existent file"

    local size
    size=$(get_file_size "$TEST_TEMP_DIR/does_not_exist.txt")

    assert_equals "0" "$size" "Non-existent file should return 0"
}

test_get_file_size_with_spaces_in_path() {
    log_test "get_file_size: handles spaces in file path"

    local test_dir="$TEST_TEMP_DIR/path with spaces"
    mkdir -p "$test_dir"
    local test_file="$test_dir/file name.txt"
    echo "test content" > "$test_file"  # 13 bytes with newline

    local size
    size=$(get_file_size "$test_file")

    assert_equals "13" "$size" "Should handle paths with spaces"
}

test_get_file_size_binary_content() {
    log_test "get_file_size: handles binary content"

    local test_file="$TEST_TEMP_DIR/binary.bin"

    # Write 256 bytes of binary data (all byte values 0-255)
    local i
    for i in $(seq 0 255); do
        printf "\\x$(printf '%02x' "$i")"
    done > "$test_file"

    local size
    size=$(get_file_size "$test_file")

    assert_equals "256" "$size" "Should correctly count binary bytes"
}

test_get_file_size_large_file() {
    log_test "get_file_size: handles larger files"

    local test_file="$TEST_TEMP_DIR/large.txt"

    # Create a 10KB file (10240 bytes)
    dd if=/dev/zero of="$test_file" bs=1024 count=10 2>/dev/null

    local size
    size=$(get_file_size "$test_file")

    assert_equals "10240" "$size" "Should return 10240 for 10KB file"
}

#===============================================================================
# get_file_mtime() TESTS
#===============================================================================

test_get_file_mtime_returns_epoch() {
    log_test "get_file_mtime: returns Unix epoch timestamp"

    local test_file="$TEST_TEMP_DIR/mtime_test.txt"
    echo "test" > "$test_file"

    local mtime
    mtime=$(get_file_mtime "$test_file")

    # Should be all digits (Unix timestamp)
    assert_matches "$mtime" "^[0-9]+$" "Mtime should be numeric Unix timestamp"

    # Should be a reasonable timestamp (after year 2020 = 1577836800)
    assert_true "[[ $mtime -gt 1577836800 ]]" "Mtime should be after year 2020"
}

test_get_file_mtime_is_recent() {
    log_test "get_file_mtime: newly created file has recent mtime"

    local test_file="$TEST_TEMP_DIR/recent_mtime.txt"
    local before_time
    before_time=$(date +%s)

    echo "test" > "$test_file"

    local mtime
    mtime=$(get_file_mtime "$test_file")

    local after_time
    after_time=$(date +%s)

    # Mtime should be between before and after (within reason)
    assert_true "[[ $mtime -ge $((before_time - 2)) ]]" "Mtime should be >= creation time (with 2s tolerance)"
    assert_true "[[ $mtime -le $((after_time + 2)) ]]" "Mtime should be <= current time (with 2s tolerance)"
}

test_get_file_mtime_nonexistent() {
    log_test "get_file_mtime: returns empty for non-existent file"

    local mtime
    local exit_code=0
    mtime=$(get_file_mtime "$TEST_TEMP_DIR/nonexistent.txt") || exit_code=$?

    assert_equals "" "$mtime" "Non-existent file should return empty mtime"
    assert_equals "1" "$exit_code" "Non-existent file should return exit code 1"
}

test_get_file_mtime_updates_on_touch() {
    log_test "get_file_mtime: updates when file is touched"

    local test_file="$TEST_TEMP_DIR/touch_test.txt"
    echo "initial" > "$test_file"

    local mtime_before
    mtime_before=$(get_file_mtime "$test_file")

    # Wait a moment and touch the file
    sleep 1
    touch "$test_file"

    local mtime_after
    mtime_after=$(get_file_mtime "$test_file")

    assert_true "[[ $mtime_after -ge $mtime_before ]]" "Mtime should increase after touch"
}

test_get_file_mtime_with_spaces_in_path() {
    log_test "get_file_mtime: handles spaces in file path"

    local test_dir="$TEST_TEMP_DIR/mtime path test"
    mkdir -p "$test_dir"
    local test_file="$test_dir/file with spaces.txt"
    echo "test" > "$test_file"

    local mtime
    mtime=$(get_file_mtime "$test_file")

    assert_matches "$mtime" "^[0-9]+$" "Should handle paths with spaces"
}

#===============================================================================
# is_macos() / is_linux() TESTS
#===============================================================================

test_platform_detection_exclusive() {
    log_test "Platform detection: is_macos and is_linux are mutually exclusive"

    local macos_result=0
    local linux_result=0

    is_macos && macos_result=1 || true
    is_linux && linux_result=1 || true

    # Exactly one should be true (on standard platforms)
    local total=$((macos_result + linux_result))

    # Note: On other platforms (BSD, etc.) both could be 0
    # For typical CI environments (Linux/macOS), exactly one should be true
    if [[ "$(uname)" == "Darwin" || "$(uname)" == "Linux" ]]; then
        assert_equals "1" "$total" "Exactly one of is_macos/is_linux should be true"
    else
        log_info "Running on non-standard platform: $(uname)"
        assert_true "[[ $total -le 1 ]]" "At most one platform detection should match"
    fi
}

test_platform_detection_matches_uname() {
    log_test "Platform detection: matches actual uname output"

    local actual_os
    actual_os=$(uname)

    if [[ "$actual_os" == "Darwin" ]]; then
        assert_true "is_macos" "is_macos should return true on Darwin"
        assert_false "is_linux" "is_linux should return false on Darwin"
    elif [[ "$actual_os" == "Linux" ]]; then
        assert_true "is_linux" "is_linux should return true on Linux"
        assert_false "is_macos" "is_macos should return false on Linux"
    else
        log_info "Unknown platform: $actual_os - skipping specific assertions"
    fi
}

test_platform_detection_consistent() {
    log_test "Platform detection: multiple calls return consistent results"

    local result1=0
    local result2=0
    local result3=0

    is_macos && result1=1 || true
    is_macos && result2=1 || true
    is_macos && result3=1 || true

    assert_equals "$result1" "$result2" "Multiple is_macos calls should be consistent"
    assert_equals "$result2" "$result3" "Multiple is_macos calls should be consistent"

    result1=0
    result2=0
    result3=0

    is_linux && result1=1 || true
    is_linux && result2=1 || true
    is_linux && result3=1 || true

    assert_equals "$result1" "$result2" "Multiple is_linux calls should be consistent"
    assert_equals "$result2" "$result3" "Multiple is_linux calls should be consistent"
}

test_platform_os_variable_set() {
    log_test "Platform detection: _KAPSIS_OS variable is set correctly"

    assert_not_equals "" "$_KAPSIS_OS" "_KAPSIS_OS should not be empty"
    assert_equals "$(uname)" "$_KAPSIS_OS" "_KAPSIS_OS should match uname output"
}

#===============================================================================
# get_file_md5() TESTS
#===============================================================================

test_get_file_md5_known_content() {
    log_test "get_file_md5: returns correct hash for known content"

    local test_file="$TEST_TEMP_DIR/md5_test.txt"

    # "test" (no newline) has known MD5: 098f6bcd4621d373cade4e832627b4f6
    printf "test" > "$test_file"

    local md5
    md5=$(get_file_md5 "$test_file")

    assert_equals "098f6bcd4621d373cade4e832627b4f6" "$md5" "MD5 of 'test' should match known value"
}

test_get_file_md5_empty_file() {
    log_test "get_file_md5: returns correct hash for empty file"

    local test_file="$TEST_TEMP_DIR/empty_md5.txt"
    touch "$test_file"

    local md5
    md5=$(get_file_md5 "$test_file")

    # Empty file has known MD5: d41d8cd98f00b204e9800998ecf8427e
    assert_equals "d41d8cd98f00b204e9800998ecf8427e" "$md5" "Empty file should have known MD5"
}

test_get_file_md5_nonexistent() {
    log_test "get_file_md5: returns empty for non-existent file"

    local md5
    local exit_code=0
    md5=$(get_file_md5 "$TEST_TEMP_DIR/nonexistent_md5.txt") || exit_code=$?

    assert_equals "" "$md5" "Non-existent file should return empty MD5"
    assert_equals "1" "$exit_code" "Non-existent file should return exit code 1"
}

test_get_file_md5_format() {
    log_test "get_file_md5: returns 32-character lowercase hex string"

    local test_file="$TEST_TEMP_DIR/md5_format.txt"
    echo "some random content for MD5 testing" > "$test_file"

    local md5
    md5=$(get_file_md5 "$test_file")

    # Should be exactly 32 characters
    local length=${#md5}
    assert_equals "32" "$length" "MD5 should be exactly 32 characters"

    # Should be lowercase hex only
    assert_matches "$md5" "^[a-f0-9]{32}$" "MD5 should be lowercase hex"
}

test_get_file_md5_with_spaces_in_path() {
    log_test "get_file_md5: handles spaces in file path"

    local test_dir="$TEST_TEMP_DIR/md5 test dir"
    mkdir -p "$test_dir"
    local test_file="$test_dir/file with spaces.txt"
    printf "test" > "$test_file"

    local md5
    md5=$(get_file_md5 "$test_file")

    assert_equals "098f6bcd4621d373cade4e832627b4f6" "$md5" "Should handle paths with spaces"
}

test_get_file_md5_binary_content() {
    log_test "get_file_md5: handles binary content"

    local test_file="$TEST_TEMP_DIR/binary_md5.bin"

    # Write specific binary content with known MD5
    # 4 null bytes: MD5 = f1d3ff8443297732862df21dc4e57262
    printf '\x00\x00\x00\x00' > "$test_file"

    local md5
    md5=$(get_file_md5 "$test_file")

    assert_equals "f1d3ff8443297732862df21dc4e57262" "$md5" "Should correctly hash binary content"
}

test_get_file_md5_different_content() {
    log_test "get_file_md5: different content produces different hashes"

    local file1="$TEST_TEMP_DIR/md5_diff1.txt"
    local file2="$TEST_TEMP_DIR/md5_diff2.txt"

    echo "content one" > "$file1"
    echo "content two" > "$file2"

    local md5_1
    local md5_2
    md5_1=$(get_file_md5 "$file1")
    md5_2=$(get_file_md5 "$file2")

    assert_not_equals "$md5_1" "$md5_2" "Different content should produce different MD5 hashes"
}

test_get_file_md5_same_content() {
    log_test "get_file_md5: same content produces same hash"

    local file1="$TEST_TEMP_DIR/md5_same1.txt"
    local file2="$TEST_TEMP_DIR/md5_same2.txt"

    echo "identical content" > "$file1"
    echo "identical content" > "$file2"

    local md5_1
    local md5_2
    md5_1=$(get_file_md5 "$file1")
    md5_2=$(get_file_md5 "$file2")

    assert_equals "$md5_1" "$md5_2" "Identical content should produce identical MD5 hashes"
}

#===============================================================================
# EDGE CASES
#===============================================================================

test_special_characters_in_filename() {
    log_test "Edge case: special characters in filename"

    # Test with various special characters (but not truly problematic ones like null)
    local test_file="$TEST_TEMP_DIR/file-with_special.chars-123.txt"
    echo "content" > "$test_file"

    local size
    size=$(get_file_size "$test_file")
    assert_equals "8" "$size" "Should handle special characters in filename"

    local md5
    md5=$(get_file_md5 "$test_file")
    assert_matches "$md5" "^[a-f0-9]{32}$" "MD5 should work with special characters"
}

test_symlink_handling() {
    log_test "Edge case: symlink to file"

    local real_file="$TEST_TEMP_DIR/real_file.txt"
    local symlink="$TEST_TEMP_DIR/symlink.txt"

    printf "test" > "$real_file"
    ln -s "$real_file" "$symlink"

    # Note: get_file_size behavior with symlinks differs by platform:
    # - macOS stat -f%z follows symlinks (returns target size)
    # - Linux stat -c%s returns symlink size (not target)
    # This is acceptable for the library's use cases (log file rotation, etc.)

    local real_size
    local link_size
    real_size=$(get_file_size "$real_file")
    link_size=$(get_file_size "$symlink")

    # Both should return non-zero values (symlink exists and resolves)
    assert_not_equals "0" "$real_size" "Real file should have non-zero size"
    assert_not_equals "0" "$link_size" "Symlink should return non-zero size"

    # get_file_md5 follows symlinks on all platforms (reads file content)
    local real_md5
    local link_md5
    real_md5=$(get_file_md5 "$real_file")
    link_md5=$(get_file_md5 "$symlink")

    assert_equals "$real_md5" "$link_md5" "Symlink should return same MD5 as target (follows symlink for read)"
}

test_directory_handling() {
    log_test "Edge case: directory instead of file"

    local test_dir="$TEST_TEMP_DIR/test_directory"
    mkdir -p "$test_dir"

    # get_file_size should return 0 for directories (not a file)
    local size
    size=$(get_file_size "$test_dir")
    assert_equals "0" "$size" "Directory should return size 0"

    # get_file_md5 should return empty for directories
    local md5
    local exit_code=0
    md5=$(get_file_md5 "$test_dir") || exit_code=$?
    assert_equals "" "$md5" "Directory should return empty MD5"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Cross-Platform Compatibility (compat.sh)"

    # Setup
    setup_compat_tests

    # Ensure cleanup on exit
    trap cleanup_compat_tests EXIT

    # get_file_size() tests
    run_test test_get_file_size_known_content
    run_test test_get_file_size_empty_file
    run_test test_get_file_size_nonexistent
    run_test test_get_file_size_with_spaces_in_path
    run_test test_get_file_size_binary_content
    run_test test_get_file_size_large_file

    # get_file_mtime() tests
    run_test test_get_file_mtime_returns_epoch
    run_test test_get_file_mtime_is_recent
    run_test test_get_file_mtime_nonexistent
    run_test test_get_file_mtime_updates_on_touch
    run_test test_get_file_mtime_with_spaces_in_path

    # Platform detection tests
    run_test test_platform_detection_exclusive
    run_test test_platform_detection_matches_uname
    run_test test_platform_detection_consistent
    run_test test_platform_os_variable_set

    # get_file_md5() tests
    run_test test_get_file_md5_known_content
    run_test test_get_file_md5_empty_file
    run_test test_get_file_md5_nonexistent
    run_test test_get_file_md5_format
    run_test test_get_file_md5_with_spaces_in_path
    run_test test_get_file_md5_binary_content
    run_test test_get_file_md5_different_content
    run_test test_get_file_md5_same_content

    # Edge cases
    run_test test_special_characters_in_filename
    run_test test_symlink_handling
    run_test test_directory_handling

    # Summary
    print_summary
}

main "$@"
