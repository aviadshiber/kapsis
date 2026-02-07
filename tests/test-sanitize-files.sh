#!/usr/bin/env bash
#===============================================================================
# Test: File Sanitization
#
# Verifies that the sanitize_staged_files function correctly:
# 1. Detects and strips BiDi control characters (CVE-2021-42574)
# 2. Detects and strips zero-width characters
# 3. Detects and strips control characters (preserving TAB/LF/CR)
# 4. Detects and strips ANSI escape sequences
# 5. Detects and strips format control characters
# 6. Handles BOM correctly (preserves at byte 0, strips elsewhere)
# 7. Warns on homoglyph attacks in code files
# 8. Re-stages cleaned files
# 9. Sets KAPSIS_SANITIZE_SUMMARY for commit trailers
#
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the sanitize-files library
source "$KAPSIS_ROOT/scripts/lib/sanitize-files.sh"

#===============================================================================
# TEST SETUP/TEARDOWN
#===============================================================================

TEST_REPO=""

setup_sanitize_test_repo() {
    local test_name="$1"
    TEST_REPO=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-sanitize-test-${test_name}-XXXXXX")

    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false

    # Create initial commit with a clean file
    echo "# Test Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    echo "$TEST_REPO"
}

cleanup_sanitize_test_repo() {
    if [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]]; then
        rm -rf "$TEST_REPO"
    fi
    TEST_REPO=""
    KAPSIS_SANITIZE_SUMMARY=""
}

# Helper to create a file with raw bytes and stage it
create_and_stage_file() {
    local filename="$1"
    local content="$2"

    printf '%s' "$content" > "$filename"
    git add "$filename"
}

#===============================================================================
# STRIP TESTS (16 tests)
#===============================================================================

test_strips_bidi_rlo_lro() {
    log_test "Testing BiDi RLO/LRO stripped from file"

    setup_sanitize_test_repo "bidi-rlo"
    cd "$TEST_REPO"

    # Create file with RLO and LRO characters
    # RLO (U+202E) = $'\xe2\x80\xae', LRO (U+202D) = $'\xe2\x80\xad'
    local content="function check() { // "$'\xe2\x80\xae'"if (admin)"$'\xe2\x80\xac'" { return true; } }"
    create_and_stage_file "auth.js" "$content"

    # Run sanitization
    sanitize_staged_files "$TEST_REPO"

    # Verify BiDi chars removed
    local result
    result=$(cat "$TEST_REPO/auth.js")
    if [[ "$result" == *$'\xe2\x80\xae'* ]] || [[ "$result" == *$'\xe2\x80\xad'* ]]; then
        log_fail "BiDi RLO/LRO should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    # Verify file is re-staged
    local staged
    staged=$(git diff --cached --name-only)
    if [[ "$staged" != *"auth.js"* ]]; then
        log_fail "Cleaned file should be re-staged"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_strips_bidi_isolates() {
    log_test "Testing BiDi isolates (LRI/RLI/FSI/PDI) stripped"

    setup_sanitize_test_repo "bidi-isolates"
    cd "$TEST_REPO"

    # LRI (U+2066), RLI (U+2067), FSI (U+2068), PDI (U+2069)
    local content="var x = "$'\xe2\x81\xa6'"admin"$'\xe2\x81\xa9'";"
    create_and_stage_file "test.js" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.js")
    if [[ "$result" == *$'\xe2\x81\xa6'* ]] || [[ "$result" == *$'\xe2\x81\xa9'* ]]; then
        log_fail "BiDi isolates should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_strips_zwsp() {
    log_test "Testing ZWSP (Zero Width Space) stripped"

    setup_sanitize_test_repo "zwsp"
    cd "$TEST_REPO"

    # ZWSP (U+200B) = $'\xe2\x80\x8b'
    local content="hello"$'\xe2\x80\x8b'"world"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\xe2\x80\x8b'* ]]; then
        log_fail "ZWSP should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    assert_equals "helloworld" "$result" "Content should be 'helloworld' after stripping ZWSP"

    cleanup_sanitize_test_repo
}

test_strips_zwnj_zwj() {
    log_test "Testing ZWNJ and ZWJ stripped"

    setup_sanitize_test_repo "zwnj-zwj"
    cd "$TEST_REPO"

    # ZWNJ (U+200C) = $'\xe2\x80\x8c', ZWJ (U+200D) = $'\xe2\x80\x8d'
    local content="test"$'\xe2\x80\x8c'"one"$'\xe2\x80\x8d'"two"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\xe2\x80\x8c'* ]] || [[ "$result" == *$'\xe2\x80\x8d'* ]]; then
        log_fail "ZWNJ/ZWJ should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_strips_word_joiner_invisible_separator() {
    log_test "Testing Word Joiner and Invisible Separator stripped"

    setup_sanitize_test_repo "wj-is"
    cd "$TEST_REPO"

    # WJ (U+2060) = $'\xe2\x81\xa0', IS (U+2063) = $'\xe2\x81\xa3'
    local content="word"$'\xe2\x81\xa0'"join"$'\xe2\x81\xa3'"sep"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\xe2\x81\xa0'* ]] || [[ "$result" == *$'\xe2\x81\xa3'* ]]; then
        log_fail "Word Joiner / Invisible Separator should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_strips_control_chars() {
    log_test "Testing control characters (0x01, 0x02, 0x7F) stripped"

    setup_sanitize_test_repo "control"
    cd "$TEST_REPO"

    # SOH (0x01), STX (0x02), DEL (0x7F)
    local content="normal"$'\x01'"text"$'\x02'"here"$'\x7f'"end"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\x01'* ]] || [[ "$result" == *$'\x02'* ]] || [[ "$result" == *$'\x7f'* ]]; then
        log_fail "Control characters should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    assert_equals "normaltexthereend" "$result" "Control chars should be removed"

    cleanup_sanitize_test_repo
}

test_preserves_tab_lf_cr() {
    log_test "Testing TAB, LF, CR preserved"

    setup_sanitize_test_repo "preserve-whitespace"
    cd "$TEST_REPO"

    # TAB (0x09), LF (0x0A), CR (0x0D)
    local content="line1"$'\t'"tabbed"$'\n'"line2"$'\r\n'"line3"
    create_and_stage_file "test.txt" "$content"

    local before
    before=$(cat "$TEST_REPO/test.txt" | LC_ALL=C od -An -tx1)

    sanitize_staged_files "$TEST_REPO"

    local after
    after=$(cat "$TEST_REPO/test.txt" | LC_ALL=C od -An -tx1)

    # Content should be unchanged (TAB, LF, CR preserved)
    assert_equals "$before" "$after" "TAB, LF, CR should be preserved"

    cleanup_sanitize_test_repo
}

test_strips_ansi_escape() {
    log_test "Testing ANSI escape (0x1B) stripped"

    setup_sanitize_test_repo "ansi"
    cd "$TEST_REPO"

    # ESC (0x1B) followed by ANSI sequence
    local content="normal"$'\x1b'"[31mred"$'\x1b'"[0mnormal"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\x1b'* ]]; then
        log_fail "ANSI escape should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_strips_soft_hyphen() {
    log_test "Testing soft hyphen (U+00AD) stripped"

    setup_sanitize_test_repo "soft-hyphen"
    cd "$TEST_REPO"

    # Soft hyphen (U+00AD) = $'\xc2\xad'
    local content="long"$'\xc2\xad'"word"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\xc2\xad'* ]]; then
        log_fail "Soft hyphen should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    assert_equals "longword" "$result" "Soft hyphen should be removed"

    cleanup_sanitize_test_repo
}

test_strips_line_para_separator() {
    log_test "Testing line/paragraph separator stripped"

    setup_sanitize_test_repo "line-para-sep"
    cd "$TEST_REPO"

    # Line Separator (U+2028) = $'\xe2\x80\xa8', Paragraph Separator (U+2029) = $'\xe2\x80\xa9'
    local content="line1"$'\xe2\x80\xa8'"line2"$'\xe2\x80\xa9'"para2"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\xe2\x80\xa8'* ]] || [[ "$result" == *$'\xe2\x80\xa9'* ]]; then
        log_fail "Line/paragraph separators should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_strips_mongolian_vowel_separator() {
    log_test "Testing Mongolian vowel separator (U+180E) stripped"

    setup_sanitize_test_repo "mongolian"
    cd "$TEST_REPO"

    # Mongolian Vowel Separator (U+180E) = $'\xe1\xa0\x8e'
    local content="text"$'\xe1\xa0\x8e'"here"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")
    if [[ "$result" == *$'\xe1\xa0\x8e'* ]]; then
        log_fail "Mongolian vowel separator should be stripped"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_preserves_bom_at_byte_0() {
    log_test "Testing BOM at byte 0 preserved"

    setup_sanitize_test_repo "bom-start"
    cd "$TEST_REPO"

    # BOM (U+FEFF) = $'\xef\xbb\xbf' at start
    local content=$'\xef\xbb\xbf'"// JavaScript file"$'\n'"var x = 1;"
    create_and_stage_file "test.js" "$content"

    sanitize_staged_files "$TEST_REPO"

    # Check first 3 bytes are still BOM
    local first_bytes
    first_bytes=$(head -c 3 "$TEST_REPO/test.js" | LC_ALL=C od -An -tx1 | tr -d ' ')

    assert_equals "efbbbf" "$first_bytes" "BOM at byte 0 should be preserved"

    cleanup_sanitize_test_repo
}

test_strips_bom_mid_file() {
    log_test "Testing BOM mid-file stripped"

    setup_sanitize_test_repo "bom-mid"
    cd "$TEST_REPO"

    # BOM (U+FEFF) = $'\xef\xbb\xbf' in middle of file
    local content="start"$'\xef\xbb\xbf'"middle"$'\xef\xbb\xbf'"end"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")

    # Count BOMs remaining
    local bom_count
    bom_count=$(LC_ALL=C grep -c $'\xef\xbb\xbf' "$TEST_REPO/test.txt" 2>/dev/null) || bom_count=0

    assert_equals "0" "$bom_count" "Mid-file BOMs should be stripped"
    assert_equals "startmiddleend" "$result" "Content should have BOMs removed"

    cleanup_sanitize_test_repo
}

test_strips_multiple_char_classes() {
    log_test "Testing multiple character classes in same file all stripped"

    setup_sanitize_test_repo "multi-class"
    cd "$TEST_REPO"

    # Mix of BiDi, zero-width, control, and format characters
    local content="start"$'\xe2\x80\xae'"bidi"$'\xe2\x80\x8b'"zwsp"$'\x01'"ctrl"$'\xc2\xad'"soft"
    create_and_stage_file "test.txt" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/test.txt")

    assert_equals "startbidizwspctrlsoft" "$result" "All dangerous chars should be stripped"

    cleanup_sanitize_test_repo
}

test_file_content_correct_after_stripping() {
    log_test "Testing file content is correct after stripping"

    setup_sanitize_test_repo "content-check"
    cd "$TEST_REPO"

    # Realistic JavaScript with Trojan Source attack
    local content='function isAdmin(user) {
    // Check if user is'"$'\xe2\x80\xae'"' admin'"$'\xe2\x80\xac'"'
    return user.role === "admin";
}'
    create_and_stage_file "auth.js" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/auth.js")

    # Verify function structure intact
    assert_contains "$result" "function isAdmin" "Function declaration should be intact"
    assert_contains "$result" "return user.role" "Return statement should be intact"

    # Verify no BiDi characters
    if [[ "$result" == *$'\xe2\x80\xae'* ]] || [[ "$result" == *$'\xe2\x80\xac'* ]]; then
        log_fail "BiDi chars should be stripped from auth.js"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_file_restaged_after_stripping() {
    log_test "Testing file is re-staged after stripping"

    setup_sanitize_test_repo "restage"
    cd "$TEST_REPO"

    # Stage a file with dangerous content
    local content="test"$'\xe2\x80\x8b'"content"
    create_and_stage_file "dirty.txt" "$content"

    # Get staged content hash before sanitization
    local staged_before
    staged_before=$(git diff --cached --name-only | sort)

    sanitize_staged_files "$TEST_REPO"

    # Verify file is still staged (with cleaned content)
    local staged_after
    staged_after=$(git diff --cached --name-only | sort)

    assert_contains "$staged_after" "dirty.txt" "Cleaned file should be re-staged"

    # Verify the staged version is clean
    local staged_content
    staged_content=$(git show :dirty.txt 2>/dev/null)

    if [[ "$staged_content" == *$'\xe2\x80\x8b'* ]]; then
        log_fail "Staged version should be clean"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

#===============================================================================
# HOMOGLYPH TESTS (4 tests)
#===============================================================================

test_homoglyph_warns_js_mixed_latin() {
    log_test "Testing Cyrillic in .js file mixed with Latin warns"

    setup_sanitize_test_repo "homoglyph-js"
    cd "$TEST_REPO"

    # Cyrillic 'а' (U+0430) mixed with Latin
    # а = $'\xd0\xb0'
    local content='var admin = "user";
var аdmin = "hacker";  // Cyrillic а looks like Latin a'
    create_and_stage_file "auth.js" "$content"

    # Capture log output
    local output
    output=$(sanitize_staged_files "$TEST_REPO" 2>&1)

    # Should warn about homoglyphs
    assert_contains "$output" "HOMOGLYPH" "Should warn about homoglyphs in .js file"

    cleanup_sanitize_test_repo
}

test_homoglyph_not_flagged_md() {
    log_test "Testing Cyrillic in .md file not flagged"

    setup_sanitize_test_repo "homoglyph-md"
    cd "$TEST_REPO"

    # Cyrillic mixed with Latin in markdown (documentation)
    local content='# Привет мир (Hello World)

This is a document with Cyrillic text mixed with Latin.'
    create_and_stage_file "docs.md" "$content"

    local output
    output=$(sanitize_staged_files "$TEST_REPO" 2>&1)

    # Should NOT warn for markdown files
    if [[ "$output" == *"HOMOGLYPH"* ]]; then
        log_fail "Should not flag homoglyphs in .md files"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_homoglyph_pure_cyrillic_not_flagged() {
    log_test "Testing pure Cyrillic (no Latin context) not flagged"

    setup_sanitize_test_repo "homoglyph-pure"
    cd "$TEST_REPO"

    # Pure Cyrillic without Latin on same line
    local content='// Комментарий на русском
const x = 1;'
    create_and_stage_file "test.js" "$content"

    local output
    output=$(sanitize_staged_files "$TEST_REPO" 2>&1)

    # Should NOT warn for pure Cyrillic lines
    if [[ "$output" == *"HOMOGLYPH"* ]]; then
        log_fail "Should not flag pure Cyrillic lines"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_homoglyph_skip_config() {
    log_test "Testing KAPSIS_SANITIZE_SKIP_HOMOGLYPHS=true skips warning"

    setup_sanitize_test_repo "homoglyph-skip"
    cd "$TEST_REPO"

    # Cyrillic mixed with Latin
    local content='var admin = "user"; var аdmin = "hacker";'
    create_and_stage_file "auth.js" "$content"

    # Enable skip homoglyphs
    local old_skip="$KAPSIS_SANITIZE_SKIP_HOMOGLYPHS"
    export KAPSIS_SANITIZE_SKIP_HOMOGLYPHS=true

    local output
    output=$(sanitize_staged_files "$TEST_REPO" 2>&1)

    export KAPSIS_SANITIZE_SKIP_HOMOGLYPHS="$old_skip"

    # Should NOT warn when skip is enabled
    if [[ "$output" == *"HOMOGLYPH"* ]]; then
        log_fail "Should not warn when KAPSIS_SANITIZE_SKIP_HOMOGLYPHS=true"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

#===============================================================================
# INTEGRATION TESTS (7 tests)
#===============================================================================

test_clean_files_return_0() {
    log_test "Testing clean files return 0, no modifications"

    setup_sanitize_test_repo "clean"
    cd "$TEST_REPO"

    # Stage a clean file
    echo "Normal content with no dangerous chars" > clean.txt
    git add clean.txt

    local before_hash
    before_hash=$(git hash-object clean.txt)

    sanitize_staged_files "$TEST_REPO"
    local result=$?

    local after_hash
    after_hash=$(git hash-object clean.txt)

    assert_equals "0" "$result" "Clean files should return 0"
    assert_equals "$before_hash" "$after_hash" "Clean file should not be modified"

    cleanup_sanitize_test_repo
}

test_binary_files_skipped() {
    log_test "Testing binary files skipped"

    setup_sanitize_test_repo "binary"
    cd "$TEST_REPO"

    # Create a binary file with NUL bytes (git will detect as binary)
    # and dangerous chars that would be stripped from text
    printf '\x00\x01\x02\x89PNG\r\n\x1a\n\xe2\x80\xae\x00\x00' > image.png
    git add image.png

    # Verify git sees it as binary (should show - - for numstat)
    local numstat
    numstat=$(git diff --cached --numstat | grep image.png)
    if [[ "$numstat" != "-	-	image.png" ]]; then
        # If not detected as binary, skip this test
        log_skip "Git doesn't detect file as binary on this platform"
        cleanup_sanitize_test_repo
        return 0
    fi

    local before_hash
    before_hash=$(git hash-object image.png)

    sanitize_staged_files "$TEST_REPO"

    local after_hash
    after_hash=$(git hash-object image.png)

    assert_equals "$before_hash" "$after_hash" "Binary file should not be modified"

    cleanup_sanitize_test_repo
}

test_empty_staging_returns_0() {
    log_test "Testing empty staging area returns 0"

    setup_sanitize_test_repo "empty"
    cd "$TEST_REPO"

    # Don't stage anything new

    sanitize_staged_files "$TEST_REPO"
    local result=$?

    assert_equals "0" "$result" "Empty staging should return 0"

    cleanup_sanitize_test_repo
}

test_disabled_returns_0() {
    log_test "Testing KAPSIS_SANITIZE_ENABLED=false returns 0"

    setup_sanitize_test_repo "disabled"
    cd "$TEST_REPO"

    # Stage file with dangerous content
    local content="test"$'\xe2\x80\xae'"content"
    create_and_stage_file "dirty.txt" "$content"

    local before_hash
    before_hash=$(git hash-object dirty.txt)

    # Disable sanitization
    local old_enabled="$KAPSIS_SANITIZE_ENABLED"
    export KAPSIS_SANITIZE_ENABLED=false

    sanitize_staged_files "$TEST_REPO"
    local result=$?

    export KAPSIS_SANITIZE_ENABLED="$old_enabled"

    local after_hash
    after_hash=$(git hash-object dirty.txt)

    assert_equals "0" "$result" "Disabled sanitization should return 0"
    assert_equals "$before_hash" "$after_hash" "File should not be modified when disabled"

    cleanup_sanitize_test_repo
}

test_multiple_files_cleaned() {
    log_test "Testing multiple files with multiple issues all cleaned"

    setup_sanitize_test_repo "multi-file"
    cd "$TEST_REPO"

    # Stage multiple files with different issues
    create_and_stage_file "file1.js" "code"$'\xe2\x80\xae'"bidi"
    create_and_stage_file "file2.py" "text"$'\xe2\x80\x8b'"zwsp"
    create_and_stage_file "file3.rb" "ruby"$'\x01'"ctrl"

    sanitize_staged_files "$TEST_REPO"

    # Verify all cleaned
    local content1 content2 content3
    content1=$(cat "$TEST_REPO/file1.js")
    content2=$(cat "$TEST_REPO/file2.py")
    content3=$(cat "$TEST_REPO/file3.rb")

    assert_equals "codebidi" "$content1" "file1.js should be cleaned"
    assert_equals "textzwsp" "$content2" "file2.py should be cleaned"
    assert_equals "rubyctrl" "$content3" "file3.rb should be cleaned"

    cleanup_sanitize_test_repo
}

test_sanitize_summary_set() {
    log_test "Testing KAPSIS_SANITIZE_SUMMARY set correctly after cleaning"

    setup_sanitize_test_repo "summary"
    cd "$TEST_REPO"

    # Stage file with dangerous content
    create_and_stage_file "dirty.js" "code"$'\xe2\x80\xae'"bidi"$'\xe2\x80\x8b'"zwsp"

    sanitize_staged_files "$TEST_REPO"

    # Check summary is set
    if [[ -z "$KAPSIS_SANITIZE_SUMMARY" ]]; then
        log_fail "KAPSIS_SANITIZE_SUMMARY should be set"
        cleanup_sanitize_test_repo
        return 1
    fi

    assert_contains "$KAPSIS_SANITIZE_SUMMARY" "Sanitized-By: Kapsis" "Summary should contain Sanitized-By"
    assert_contains "$KAPSIS_SANITIZE_SUMMARY" "dirty.js" "Summary should contain filename"

    cleanup_sanitize_test_repo
}

test_audit_jsonl_created() {
    log_test "Testing audit JSONL file created on findings"

    setup_sanitize_test_repo "audit"
    cd "$TEST_REPO"

    # Use a temp audit dir
    local audit_dir
    audit_dir=$(mktemp -d)
    export KAPSIS_AUDIT_DIR="$audit_dir"

    # Stage file with dangerous content
    create_and_stage_file "dirty.txt" "test"$'\xe2\x80\xae'"bidi"

    sanitize_staged_files "$TEST_REPO"

    # Check audit file exists
    local audit_file="$audit_dir/sanitize-findings.jsonl"
    if [[ ! -f "$audit_file" ]]; then
        log_fail "Audit JSONL file should be created"
        rm -rf "$audit_dir"
        unset KAPSIS_AUDIT_DIR
        cleanup_sanitize_test_repo
        return 1
    fi

    # Check content
    local audit_content
    audit_content=$(cat "$audit_file")
    assert_contains "$audit_content" '"total_chars_removed"' "Audit should contain total_chars_removed"
    assert_contains "$audit_content" '"files_cleaned"' "Audit should contain files_cleaned"

    rm -rf "$audit_dir"
    unset KAPSIS_AUDIT_DIR
    cleanup_sanitize_test_repo
}

#===============================================================================
# REGRESSION TESTS (3 tests)
#===============================================================================

test_regression_cve_2021_42574() {
    log_test "REGRESSION: CVE-2021-42574 exact Trojan Source pattern cleaned"

    setup_sanitize_test_repo "cve-trojan"
    cd "$TEST_REPO"

    # Exact Trojan Source pattern from the CVE
    # Uses RLO (U+202E) and LRI/PDI to hide malicious code
    local content='#include <stdio.h>

int main() {
    int isAdmin = 0;
    /*'"$'\xe2\x81\xa6'"' } '"$'\xe2\x81\xa9'"''"$'\xe2\x81\xa6'"' if (isAdmin) '"$'\xe2\x81\xa9'"''"$'\xe2\x80\x8b'"'
    // Check admin status
    if (isAdmin) {
        printf("Welcome, admin!\n");
    }
    return 0;
}'
    create_and_stage_file "trojan.c" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/trojan.c")

    # Should not contain any BiDi or zero-width chars
    if LC_ALL=C grep -q $'[\xe2\x80\x8b\xe2\x81\xa6\xe2\x81\xa9]' "$TEST_REPO/trojan.c" 2>/dev/null; then
        log_fail "CVE-2021-42574 pattern should be cleaned"
        cleanup_sanitize_test_repo
        return 1
    fi

    cleanup_sanitize_test_repo
}

test_regression_ansi_hiding_diff() {
    log_test "REGRESSION: ANSI escape hiding malicious diff cleaned"

    setup_sanitize_test_repo "ansi-hide"
    cd "$TEST_REPO"

    # ANSI sequence that could hide malicious code in terminal output
    local content='// Normal code
'"$'\x1b'"'[8m// Hidden malicious code'"$'\x1b'"'[0m
// More normal code'
    create_and_stage_file "hidden.js" "$content"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/hidden.js")

    # Should not contain any ESC characters
    if [[ "$result" == *$'\x1b'* ]]; then
        log_fail "ANSI escape sequences should be cleaned"
        cleanup_sanitize_test_repo
        return 1
    fi

    # Content should still have the visible text
    assert_contains "$result" "Normal code" "Normal code should be preserved"
    assert_contains "$result" "Hidden malicious code" "Hidden text should now be visible"

    cleanup_sanitize_test_repo
}

test_regression_cleaned_content_matches_expected() {
    log_test "REGRESSION: Cleaned file content matches expected output"

    setup_sanitize_test_repo "expected-output"
    cd "$TEST_REPO"

    # Create a file with known dangerous characters using proper escaping
    # RLO=\xe2\x80\xae, PDF=\xe2\x80\xac, ZWSP=\xe2\x80\x8b
    local rlo=$'\xe2\x80\xae'
    local pdf=$'\xe2\x80\xac'
    local zwsp=$'\xe2\x80\x8b'
    local content="function auth(user) {
    if (${rlo}user.isAdmin${pdf}) {
        return ${zwsp}true${zwsp};
    }
    return false;
}"
    create_and_stage_file "auth.js" "$content"

    # Expected output after cleaning
    local expected="function auth(user) {
    if (user.isAdmin) {
        return true;
    }
    return false;
}"

    sanitize_staged_files "$TEST_REPO"

    local result
    result=$(cat "$TEST_REPO/auth.js")

    assert_equals "$expected" "$result" "Cleaned content should match expected"

    cleanup_sanitize_test_repo
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "File Sanitization (sanitize-files.sh)"

    # Strip tests (16)
    run_test test_strips_bidi_rlo_lro
    run_test test_strips_bidi_isolates
    run_test test_strips_zwsp
    run_test test_strips_zwnj_zwj
    run_test test_strips_word_joiner_invisible_separator
    run_test test_strips_control_chars
    run_test test_preserves_tab_lf_cr
    run_test test_strips_ansi_escape
    run_test test_strips_soft_hyphen
    run_test test_strips_line_para_separator
    run_test test_strips_mongolian_vowel_separator
    run_test test_preserves_bom_at_byte_0
    run_test test_strips_bom_mid_file
    run_test test_strips_multiple_char_classes
    run_test test_file_content_correct_after_stripping
    run_test test_file_restaged_after_stripping

    # Homoglyph tests (4)
    run_test test_homoglyph_warns_js_mixed_latin
    run_test test_homoglyph_not_flagged_md
    run_test test_homoglyph_pure_cyrillic_not_flagged
    run_test test_homoglyph_skip_config

    # Integration tests (7)
    run_test test_clean_files_return_0
    run_test test_binary_files_skipped
    run_test test_empty_staging_returns_0
    run_test test_disabled_returns_0
    run_test test_multiple_files_cleaned
    run_test test_sanitize_summary_set
    run_test test_audit_jsonl_created

    # Regression tests (3)
    run_test test_regression_cve_2021_42574
    run_test test_regression_ansi_hiding_diff
    run_test test_regression_cleaned_content_matches_expected

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
