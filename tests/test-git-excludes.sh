#!/usr/bin/env bash
#===============================================================================
# Test: Git Excludes (info/exclude)
#
# Verifies that the git exclude mechanism works correctly:
# 1. Creates info/exclude with protective patterns
# 2. Is idempotent (doesn't add patterns twice)
# 3. Contains all required protective patterns
# 4. Patterns actually cause git to ignore files
#
# This test suite validates the fix for issue #89 where .gitignore
# modifications were appearing in user PRs. The new approach uses
# $GIT_DIR/info/exclude which is local-only and never committed.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the worktree-manager to get access to ensure_git_excludes
source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

#===============================================================================
# TEST SETUP/TEARDOWN
#===============================================================================

TEST_WORKTREE=""

setup_test_worktree() {
    local test_name="$1"
    TEST_WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-test-worktree-${test_name}-XXXXXX")

    # Initialize as git repo for realistic testing
    cd "$TEST_WORKTREE"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false

    # Create initial commit so we have a valid repo state
    echo "# Test Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    echo "$TEST_WORKTREE"
}

cleanup_test_worktree() {
    if [[ -n "$TEST_WORKTREE" && -d "$TEST_WORKTREE" ]]; then
        rm -rf "$TEST_WORKTREE"
    fi
    TEST_WORKTREE=""
}

#===============================================================================
# TEST CASES: ensure_git_excludes
#===============================================================================

test_creates_info_exclude_when_none_exists() {
    log_test "Testing info/exclude creation when none exists"

    setup_test_worktree "create"

    local exclude_path="$TEST_WORKTREE/.git/info/exclude"

    # Remove info/exclude if it exists (git init may create it)
    rm -f "$exclude_path" 2>/dev/null || true

    # Run the function
    ensure_git_excludes "$TEST_WORKTREE"

    # Verify info/exclude was created
    assert_file_exists "$exclude_path" "Should create info/exclude"

    # Verify it contains the marker
    assert_file_contains "$exclude_path" "Kapsis protective patterns" "Should contain marker"

    cleanup_test_worktree
}

test_appends_to_existing_info_exclude() {
    log_test "Testing append to existing info/exclude without overwriting"

    setup_test_worktree "append"

    local exclude_path="$TEST_WORKTREE/.git/info/exclude"

    # Ensure info directory exists
    mkdir -p "$TEST_WORKTREE/.git/info"

    # Create existing info/exclude with some patterns
    local original_content="# Project-specific excludes
*.local
.env.local
secrets/"
    echo "$original_content" > "$exclude_path"

    local original_lines
    original_lines=$(wc -l < "$exclude_path")

    # Run the function
    ensure_git_excludes "$TEST_WORKTREE"

    # Verify original content is preserved (check first line)
    local first_line
    first_line=$(head -1 "$exclude_path")
    assert_equals "$first_line" "# Project-specific excludes" "Original first line should be preserved"

    # Verify original patterns still exist
    assert_file_contains "$exclude_path" "*.local" "Original *.local pattern should exist"
    assert_file_contains "$exclude_path" "secrets/" "Original secrets/ pattern should exist"

    # Verify Kapsis patterns were added
    assert_file_contains "$exclude_path" "Kapsis protective patterns" "Should contain Kapsis marker"
    assert_file_contains "$exclude_path" ".kapsis/" "Should contain .kapsis/ pattern"

    # Verify file grew (didn't replace)
    local new_lines
    new_lines=$(wc -l < "$exclude_path")
    if [[ $new_lines -le $original_lines ]]; then
        log_fail "File should have grown, not shrunk (was $original_lines, now $new_lines)"
        cleanup_test_worktree
        return 1
    fi

    cleanup_test_worktree
}

test_idempotent_no_duplicate_patterns() {
    log_test "Testing idempotency - no duplicate patterns on multiple calls"

    setup_test_worktree "idempotent"

    local exclude_path="$TEST_WORKTREE/.git/info/exclude"

    # Run the function twice
    ensure_git_excludes "$TEST_WORKTREE"
    local lines_after_first
    lines_after_first=$(wc -l < "$exclude_path")

    ensure_git_excludes "$TEST_WORKTREE"
    local lines_after_second
    lines_after_second=$(wc -l < "$exclude_path")

    # Line count should be the same
    assert_equals "$lines_after_first" "$lines_after_second" "Line count should be same after second call"

    # Count occurrences of the marker - should be exactly 1
    local marker_count
    marker_count=$(grep -c "Kapsis protective patterns" "$exclude_path" || echo "0")
    assert_equals "$marker_count" "1" "Should have exactly one marker comment"

    cleanup_test_worktree
}

test_contains_all_required_patterns() {
    log_test "Testing all required protective patterns are present"

    setup_test_worktree "patterns"

    local exclude_path="$TEST_WORKTREE/.git/info/exclude"

    ensure_git_excludes "$TEST_WORKTREE"

    # Check all required patterns
    assert_file_contains "$exclude_path" ".kapsis/" "Should ignore .kapsis/"
    assert_file_contains "$exclude_path" ".claude/" "Should ignore .claude/"
    assert_file_contains "$exclude_path" ".codex/" "Should ignore .codex/"
    assert_file_contains "$exclude_path" ".aider/" "Should ignore .aider/"

    # Check for literal tilde patterns (tricky - need to verify ~ is in file)
    if ! grep -q "^~$" "$exclude_path" && ! grep -q "^~/$" "$exclude_path"; then
        # At least one tilde pattern should exist
        if ! grep -q "^~" "$exclude_path"; then
            log_fail "Should contain literal ~ pattern"
            cleanup_test_worktree
            return 1
        fi
    fi

    cleanup_test_worktree
}

test_info_exclude_actually_ignores_files() {
    log_test "Testing that info/exclude patterns actually cause git to ignore files"

    setup_test_worktree "ignore-effect"

    ensure_git_excludes "$TEST_WORKTREE"

    cd "$TEST_WORKTREE"

    # Create files that should be ignored
    mkdir -p .kapsis
    echo "task spec" > .kapsis/task-spec.md

    mkdir -p .claude/plugins
    echo "config" > .claude/config.json

    # Create a literal ~ directory (simulating failed tilde expansion)
    # shellcheck disable=SC2088 # Intentional: creating literal ~ directory, not expanding
    mkdir -p '~/.claude/plugins'
    # shellcheck disable=SC2088
    echo "should be ignored" > '~/.claude/plugins/test'

    # Check git status - these should NOT appear as untracked
    local untracked
    untracked=$(git status --porcelain 2>/dev/null || echo "")

    # .kapsis/ and .claude/ should NOT appear
    if echo "$untracked" | grep -q "\.kapsis/"; then
        log_fail ".kapsis/ files should be ignored by git"
        cleanup_test_worktree
        return 1
    fi

    if echo "$untracked" | grep -q "\.claude/"; then
        log_fail ".claude/ files should be ignored by git"
        cleanup_test_worktree
        return 1
    fi

    # Note: literal ~ directory might still show up depending on git version
    # The validate_staged_files function handles this as a safety net

    cleanup_test_worktree
}

test_gitignore_not_modified() {
    log_test "Testing that .gitignore is NOT modified (issue #89 fix)"

    setup_test_worktree "gitignore-unchanged"

    # Create a .gitignore with known content
    local original_content="node_modules/
dist/
*.log"
    echo "$original_content" > "$TEST_WORKTREE/.gitignore"

    # Get checksum before
    local before_checksum
    before_checksum=$(md5sum "$TEST_WORKTREE/.gitignore" | awk '{print $1}')

    # Run ensure_git_excludes
    ensure_git_excludes "$TEST_WORKTREE"

    # Get checksum after
    local after_checksum
    after_checksum=$(md5sum "$TEST_WORKTREE/.gitignore" | awk '{print $1}')

    # .gitignore should be UNCHANGED
    assert_equals "$before_checksum" "$after_checksum" ".gitignore should NOT be modified"

    # Verify content is exactly the same
    local current_content
    current_content=$(cat "$TEST_WORKTREE/.gitignore")
    assert_equals "$current_content" "$original_content" ".gitignore content should be unchanged"

    cleanup_test_worktree
}

test_works_without_existing_gitignore() {
    log_test "Testing that ensure_git_excludes works without any .gitignore"

    setup_test_worktree "no-gitignore"

    # Ensure no .gitignore exists
    rm -f "$TEST_WORKTREE/.gitignore" 2>/dev/null || true

    # Run ensure_git_excludes - should NOT create .gitignore
    ensure_git_excludes "$TEST_WORKTREE"

    # .gitignore should NOT exist
    assert_file_not_exists "$TEST_WORKTREE/.gitignore" ".gitignore should NOT be created"

    # But info/exclude should exist
    assert_file_exists "$TEST_WORKTREE/.git/info/exclude" "info/exclude should be created"

    cleanup_test_worktree
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Git Excludes (info/exclude) - Issue #89 Fix"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    run_test test_creates_info_exclude_when_none_exists
    run_test test_appends_to_existing_info_exclude
    run_test test_idempotent_no_duplicate_patterns
    run_test test_contains_all_required_patterns
    run_test test_info_exclude_actually_ignores_files
    run_test test_gitignore_not_modified
    run_test test_works_without_existing_gitignore

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
