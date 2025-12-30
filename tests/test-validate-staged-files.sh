#!/usr/bin/env bash
#===============================================================================
# Test: Validate Staged Files
#
# Verifies that the validate_staged_files function correctly:
# 1. Detects literal ~ paths in staged files
# 2. Detects .kapsis/ internal files
# 3. Detects accidental submodule references (mode 160000)
# 4. Removes suspicious files from staging
# 5. Doesn't interfere with legitimate files
#
# These tests recreate the exact failing scenarios from:
# - ~/.claude/issues/kapsis-commits-unrelated-files.md
# Where an agent committed:
# - ~/.claude/plugins/marketplaces/claude-plugins-official (submodule mode 160000)
# - .kapsis/task-spec-with-progress.md (internal file)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the post-container-git to get access to validate_staged_files
source "$KAPSIS_ROOT/scripts/post-container-git.sh"

#===============================================================================
# TEST SETUP/TEARDOWN
#===============================================================================

TEST_REPO=""

setup_test_repo() {
    local test_name="$1"
    TEST_REPO=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-test-repo-${test_name}-XXXXXX")

    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"

    # Create initial commit
    echo "# Test Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    echo "$TEST_REPO"
}

cleanup_test_repo() {
    if [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]]; then
        rm -rf "$TEST_REPO"
    fi
    TEST_REPO=""
}

#===============================================================================
# TEST CASES: validate_staged_files
#===============================================================================

test_detects_literal_tilde_paths() {
    log_test "Testing detection of literal ~ paths (failed tilde expansion)"

    setup_test_repo "tilde"
    cd "$TEST_REPO"

    # Create a literal ~ directory (exactly what happens when tilde expansion fails)
    # shellcheck disable=SC2088 # Intentional: creating literal ~ directory to test bug fix
    mkdir -p '~/.claude/plugins/marketplaces'
    # shellcheck disable=SC2088
    echo "should not be committed" > '~/.claude/plugins/test.txt'

    # Stage the file
    # shellcheck disable=SC2088
    git add '~/.claude/plugins/test.txt'

    # Verify it's staged
    local staged_before
    staged_before=$(git diff --cached --name-only)
    if [[ -z "$staged_before" ]]; then
        log_fail "File should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    # Run validation
    validate_staged_files "$TEST_REPO"

    # Verify it was unstaged
    local staged_after
    staged_after=$(git diff --cached --name-only | grep "^~" || echo "")
    if [[ -n "$staged_after" ]]; then
        log_fail "Literal ~ files should be unstaged after validation"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_detects_kapsis_internal_files() {
    log_test "Testing detection of .kapsis/ internal files"

    setup_test_repo "kapsis"
    cd "$TEST_REPO"

    # Create .kapsis directory with internal files (exactly as reported in issue)
    mkdir -p .kapsis
    echo "# Task Spec" > .kapsis/task-spec-with-progress.md
    echo "status: in_progress" > .kapsis/status.json

    # Stage the files
    git add .kapsis/

    # Verify staged
    local staged_before
    staged_before=$(git diff --cached --name-only | grep "^\.kapsis/" || echo "")
    if [[ -z "$staged_before" ]]; then
        log_fail ".kapsis/ files should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    # Run validation
    validate_staged_files "$TEST_REPO"

    # Verify unstaged
    local staged_after
    staged_after=$(git diff --cached --name-only | grep "^\.kapsis/" || echo "")
    if [[ -n "$staged_after" ]]; then
        log_fail ".kapsis/ files should be unstaged after validation"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_detects_submodule_references() {
    log_test "Testing detection of accidental submodule references (mode 160000)"

    setup_test_repo "submodule"
    cd "$TEST_REPO"

    # Create a directory that looks like a submodule (has .git inside)
    # This is exactly what happened with claude-plugins-official
    mkdir -p 'plugins/test-plugin'
    cd 'plugins/test-plugin'
    git init --quiet
    echo "plugin code" > index.js
    git add index.js
    git config user.email "test@plugin.local"
    git config user.name "Plugin Test"
    git commit --quiet -m "Plugin init"
    cd "$TEST_REPO"

    # Stage the "submodule" - git will detect it as mode 160000
    git add 'plugins/test-plugin'

    # Note: At this point git has detected it as a submodule (mode 160000)

    # Run validation
    validate_staged_files "$TEST_REPO"

    # Check if submodule reference was removed from staging
    # Note: The directory might still exist but shouldn't be staged as submodule
    local staged_after
    staged_after=$(git diff --cached --raw 2>/dev/null | grep "160000" || echo "")
    if [[ -n "$staged_after" ]]; then
        log_fail "Submodule references (mode 160000) should be unstaged"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_preserves_legitimate_files() {
    log_test "Testing that legitimate files are preserved"

    setup_test_repo "legitimate"
    cd "$TEST_REPO"

    # Create legitimate project files
    mkdir -p src
    echo "console.log('hello');" > src/index.js
    echo "# API Documentation" > docs.md
    mkdir -p tests
    echo "test code" > tests/test.js

    # Stage legitimate files
    git add src/ docs.md tests/

    # Count staged files before
    local count_before
    count_before=$(git diff --cached --name-only | wc -l)

    # Run validation
    validate_staged_files "$TEST_REPO"

    # Count staged files after
    local count_after
    count_after=$(git diff --cached --name-only | wc -l)

    # Should be the same
    assert_equals "$count_before" "$count_after" "Legitimate file count should be preserved"

    # Verify specific files still staged
    local staged
    staged=$(git diff --cached --name-only)
    if ! echo "$staged" | grep -q "src/index.js"; then
        log_fail "src/index.js should still be staged"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_removes_literal_tilde_directory() {
    log_test "Testing removal of literal ~ directory from worktree"

    setup_test_repo "tilde-dir"
    cd "$TEST_REPO"

    # Create literal ~ directory
    # shellcheck disable=SC2088 # Intentional: creating literal ~ directory to test cleanup
    mkdir -p '~/.claude'
    # shellcheck disable=SC2088
    echo "should be removed" > '~/.claude/config'

    # Verify it exists
    if [[ ! -d '~' ]]; then
        log_fail "Literal ~ directory should exist before test"
        cleanup_test_repo
        return 1
    fi

    # Stage something to trigger validation path
    echo "trigger" > trigger.txt
    # shellcheck disable=SC2088
    git add trigger.txt '~/.claude/config' 2>/dev/null || true

    # Run validation
    validate_staged_files "$TEST_REPO"

    # Verify ~ directory was removed
    if [[ -d '~' ]]; then
        log_fail "Literal ~ directory should be removed after validation"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_handles_mixed_files() {
    log_test "Testing mixed legitimate and suspicious files"

    setup_test_repo "mixed"
    cd "$TEST_REPO"

    # Create mix of files
    echo "good code" > good.js
    mkdir -p .kapsis
    echo "bad" > .kapsis/spec.md
    # shellcheck disable=SC2088 # Intentional: creating literal ~ directory
    mkdir -p '~/.claude'
    # shellcheck disable=SC2088
    echo "bad" > '~/.claude/config'
    echo "more good code" > app.js

    # Stage everything
    # shellcheck disable=SC2088
    git add good.js app.js .kapsis/ '~/.claude/' 2>/dev/null || git add good.js app.js .kapsis/

    # Run validation
    validate_staged_files "$TEST_REPO"

    # Check staged files
    local staged
    staged=$(git diff --cached --name-only)

    # Good files should be staged
    if ! echo "$staged" | grep -q "good.js"; then
        log_fail "good.js should still be staged"
        cleanup_test_repo
        return 1
    fi

    if ! echo "$staged" | grep -q "app.js"; then
        log_fail "app.js should still be staged"
        cleanup_test_repo
        return 1
    fi

    # Bad files should NOT be staged
    if echo "$staged" | grep -q "\.kapsis/"; then
        log_fail ".kapsis/ should not be staged"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_regression_claude_plugins_submodule() {
    log_test "REGRESSION: ~/.claude/plugins/marketplaces/claude-plugins-official submodule"

    # This test recreates the exact scenario from the bug report
    setup_test_repo "regression-submodule"
    cd "$TEST_REPO"

    # Create the exact path structure from the bug
    # shellcheck disable=SC2088 # Intentional: recreating exact bug scenario with literal ~
    mkdir -p '~/.claude/plugins/marketplaces/claude-plugins-official'
    # shellcheck disable=SC2088
    cd '~/.claude/plugins/marketplaces/claude-plugins-official'
    git init --quiet
    echo "plugin content" > plugin.js
    git add plugin.js
    git config user.email "test@plugin.local"
    git config user.name "Plugin"
    git commit --quiet -m "Init plugin"
    cd "$TEST_REPO"

    # Stage it (this creates the submodule reference that was the bug)
    # shellcheck disable=SC2088
    git add '~/.claude/plugins/marketplaces/claude-plugins-official' 2>/dev/null || true

    # Run validation - this should catch and remove it
    validate_staged_files "$TEST_REPO"

    # Verify nothing with ~ is staged
    local staged
    staged=$(git diff --cached --name-only)
    if echo "$staged" | grep -q "^~"; then
        log_fail "REGRESSION: ~ paths should not be staged"
        cleanup_test_repo
        return 1
    fi

    # Verify no submodules staged
    local submodules
    submodules=$(git diff --cached --raw | grep "160000" || echo "")
    if [[ -n "$submodules" ]]; then
        log_fail "REGRESSION: Submodule should not be staged"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_regression_kapsis_task_spec() {
    log_test "REGRESSION: .kapsis/task-spec-with-progress.md commit"

    # This test recreates the exact file from the bug report
    setup_test_repo "regression-kapsis"
    cd "$TEST_REPO"

    # Create the exact file from the bug report
    mkdir -p .kapsis
    cat > .kapsis/task-spec-with-progress.md << 'EOF'
# Task Specification

## Status: In Progress

## Task
Implement feature X

## Progress
- [x] Step 1
- [ ] Step 2
EOF

    # Stage it
    git add .kapsis/task-spec-with-progress.md

    # Run validation
    validate_staged_files "$TEST_REPO"

    # Verify it was unstaged
    local staged
    staged=$(git diff --cached --name-only)
    if echo "$staged" | grep -q "\.kapsis/task-spec-with-progress.md"; then
        log_fail "REGRESSION: .kapsis/task-spec-with-progress.md should not be staged"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Validate Staged Files"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    run_test test_detects_literal_tilde_paths
    run_test test_detects_kapsis_internal_files
    run_test test_detects_submodule_references
    run_test test_preserves_legitimate_files
    run_test test_removes_literal_tilde_directory
    run_test test_handles_mixed_files
    run_test test_regression_claude_plugins_submodule
    run_test test_regression_kapsis_task_spec

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
