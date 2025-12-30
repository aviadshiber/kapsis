#!/usr/bin/env bash
#===============================================================================
# Test: Protective Gitignore
#
# Verifies that the protective .gitignore mechanism works correctly:
# 1. Creates .gitignore when none exists
# 2. Appends to existing .gitignore without overwriting
# 3. Is idempotent (doesn't add patterns twice)
# 4. Contains all required protective patterns
#
# These tests address the issue where agents accidentally committed:
# - ~/.claude/plugins/marketplaces/claude-plugins-official (submodule)
# - .kapsis/task-spec-with-progress.md (internal file)
# See: ~/.claude/issues/kapsis-commits-unrelated-files.md
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the worktree-manager to get access to ensure_protective_gitignore
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
# TEST CASES: ensure_protective_gitignore
#===============================================================================

test_creates_gitignore_when_none_exists() {
    log_test "Testing .gitignore creation when none exists"

    setup_test_worktree "create"

    # Verify no .gitignore exists
    if [[ -f "$TEST_WORKTREE/.gitignore" ]]; then
        rm "$TEST_WORKTREE/.gitignore"
    fi
    assert_file_not_exists "$TEST_WORKTREE/.gitignore" "Should start without .gitignore"

    # Run the function
    ensure_protective_gitignore "$TEST_WORKTREE"

    # Verify .gitignore was created
    assert_file_exists "$TEST_WORKTREE/.gitignore" "Should create .gitignore"

    # Verify it contains the marker
    assert_file_contains "$TEST_WORKTREE/.gitignore" "Kapsis protective patterns" "Should contain marker"

    cleanup_test_worktree
}

test_appends_to_existing_gitignore() {
    log_test "Testing append to existing .gitignore without overwriting"

    setup_test_worktree "append"

    # Create existing .gitignore with project-specific rules
    local original_content="# Project-specific ignores
node_modules/
*.log
dist/
build/
.env"
    echo "$original_content" > "$TEST_WORKTREE/.gitignore"

    local original_lines
    original_lines=$(wc -l < "$TEST_WORKTREE/.gitignore")

    # Run the function
    ensure_protective_gitignore "$TEST_WORKTREE"

    # Verify original content is preserved (check first line)
    local first_line
    first_line=$(head -1 "$TEST_WORKTREE/.gitignore")
    assert_equals "$first_line" "# Project-specific ignores" "Original first line should be preserved"

    # Verify original patterns still exist
    assert_file_contains "$TEST_WORKTREE/.gitignore" "node_modules/" "Original node_modules pattern should exist"
    assert_file_contains "$TEST_WORKTREE/.gitignore" "dist/" "Original dist pattern should exist"
    assert_file_contains "$TEST_WORKTREE/.gitignore" ".env" "Original .env pattern should exist"

    # Verify Kapsis patterns were added
    assert_file_contains "$TEST_WORKTREE/.gitignore" "Kapsis protective patterns" "Should contain Kapsis marker"
    assert_file_contains "$TEST_WORKTREE/.gitignore" ".kapsis/" "Should contain .kapsis/ pattern"

    # Verify file grew (didn't replace)
    local new_lines
    new_lines=$(wc -l < "$TEST_WORKTREE/.gitignore")
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

    # Run the function twice
    ensure_protective_gitignore "$TEST_WORKTREE"
    local lines_after_first
    lines_after_first=$(wc -l < "$TEST_WORKTREE/.gitignore")

    ensure_protective_gitignore "$TEST_WORKTREE"
    local lines_after_second
    lines_after_second=$(wc -l < "$TEST_WORKTREE/.gitignore")

    # Line count should be the same
    assert_equals "$lines_after_first" "$lines_after_second" "Line count should be same after second call"

    # Count occurrences of the marker - should be exactly 1
    local marker_count
    marker_count=$(grep -c "Kapsis protective patterns" "$TEST_WORKTREE/.gitignore" || echo "0")
    assert_equals "$marker_count" "1" "Should have exactly one marker comment"

    cleanup_test_worktree
}

test_contains_all_required_patterns() {
    log_test "Testing all required protective patterns are present"

    setup_test_worktree "patterns"

    ensure_protective_gitignore "$TEST_WORKTREE"

    # Check all required patterns
    assert_file_contains "$TEST_WORKTREE/.gitignore" ".kapsis/" "Should ignore .kapsis/"
    assert_file_contains "$TEST_WORKTREE/.gitignore" ".claude/" "Should ignore .claude/"
    assert_file_contains "$TEST_WORKTREE/.gitignore" ".codex/" "Should ignore .codex/"
    assert_file_contains "$TEST_WORKTREE/.gitignore" ".aider/" "Should ignore .aider/"

    # Check for literal tilde patterns (tricky - need to verify ~ is in file)
    if ! grep -q "^~$" "$TEST_WORKTREE/.gitignore" && ! grep -q "^~/$" "$TEST_WORKTREE/.gitignore"; then
        # At least one tilde pattern should exist
        if ! grep -q "^~" "$TEST_WORKTREE/.gitignore"; then
            log_fail "Should contain literal ~ pattern"
            cleanup_test_worktree
            return 1
        fi
    fi

    cleanup_test_worktree
}

test_gitignore_actually_ignores_files() {
    log_test "Testing that .gitignore patterns actually cause git to ignore files"

    setup_test_worktree "ignore-effect"

    ensure_protective_gitignore "$TEST_WORKTREE"

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

    # .gitignore itself will be untracked, that's expected
    # But .kapsis/ and .claude/ should NOT appear
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

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Protective Gitignore"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    run_test test_creates_gitignore_when_none_exists
    run_test test_appends_to_existing_gitignore
    run_test test_idempotent_no_duplicate_patterns
    run_test test_contains_all_required_patterns
    run_test test_gitignore_actually_ignores_files

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
