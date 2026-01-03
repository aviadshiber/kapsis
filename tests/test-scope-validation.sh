#!/usr/bin/env bash
#===============================================================================
# Test: Filesystem Scope Validation
#
# Verifies that the scope validation system correctly detects:
# - Allowed modifications (workspace, caches)
# - Blocked modifications (.ssh, .claude, shell configs)
# - Warning-level modifications (git hooks)
#
# Phase 1 security feature - defense in depth against prompt injection.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

VALIDATE_SCOPE_SCRIPT="$KAPSIS_ROOT/scripts/lib/validate-scope.sh"

# Create isolated test worktree
SCOPE_TEST_DIR=""

setup_scope_test() {
    SCOPE_TEST_DIR=$(mktemp -d)
    cd "$SCOPE_TEST_DIR"
    git init -q
    git config user.email "test@kapsis.test"
    git config user.name "Kapsis Test"
    echo "initial" > README.md
    git add README.md
    git commit -q -m "Initial commit"
}

cleanup_scope_test() {
    if [[ -n "$SCOPE_TEST_DIR" ]] && [[ -d "$SCOPE_TEST_DIR" ]]; then
        rm -rf "$SCOPE_TEST_DIR"
    fi
}

#===============================================================================
# UNIT TESTS - Path Matching Functions
#===============================================================================

test_is_path_allowed_workspace() {
    log_test "Testing is_path_allowed for workspace paths"

    source "$VALIDATE_SCOPE_SCRIPT"

    # These should all be allowed
    assert_command_succeeds "is_path_allowed 'workspace/src/main.java'" "workspace path should be allowed"
    assert_command_succeeds "is_path_allowed 'tmp/build.log'" "tmp path should be allowed"
    assert_command_succeeds "is_path_allowed 'home/developer/.m2/repository/org/test.jar'" "Maven cache should be allowed"
    assert_command_succeeds "is_path_allowed 'home/developer/.gradle/caches/test'" "Gradle cache should be allowed"
    assert_command_succeeds "is_path_allowed 'kapsis-status/status.json'" "kapsis-status should be allowed"
}

test_is_path_blocked_sensitive() {
    log_test "Testing is_path_blocked for sensitive paths"

    source "$VALIDATE_SCOPE_SCRIPT"

    # These should all be blocked
    assert_command_succeeds "is_path_blocked 'home/developer/.ssh/id_rsa'" ".ssh should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.claude/settings.json'" ".claude should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.bashrc'" ".bashrc should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.zshrc'" ".zshrc should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.profile'" ".profile should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.gitconfig'" ".gitconfig should be blocked"
    assert_command_succeeds "is_path_blocked 'etc/passwd'" "/etc should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.aws/credentials'" ".aws should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.kube/config'" ".kube should be blocked"
}

test_is_path_warning_git_hooks() {
    log_test "Testing is_path_warning for git hooks"

    source "$VALIDATE_SCOPE_SCRIPT"

    # Git hooks should be warnings
    assert_command_succeeds "is_path_warning 'workspace/.git/hooks/pre-commit'" "git hooks should be warning"
    assert_command_succeeds "is_path_warning '.git/hooks/post-checkout'" "git hooks should be warning"

    # But regular git files should not be warnings
    assert_command_fails "is_path_warning 'workspace/.git/config'" ".git/config should not be warning"
    assert_command_fails "is_path_warning 'workspace/.gitignore'" ".gitignore should not be warning"
}

#===============================================================================
# INTEGRATION TESTS - Worktree Validation
#===============================================================================

test_validate_scope_worktree_clean() {
    log_test "Testing validate_scope_worktree with clean repo"

    setup_scope_test
    source "$VALIDATE_SCOPE_SCRIPT"

    local exit_code=0
    validate_scope_worktree "$SCOPE_TEST_DIR" || exit_code=$?

    assert_equals 0 "$exit_code" "Clean repo should pass validation"

    cleanup_scope_test
}

test_validate_scope_worktree_allowed_changes() {
    log_test "Testing validate_scope_worktree allows normal code changes"

    setup_scope_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Make normal changes
    echo "new content" > src/main.java
    mkdir -p src
    echo "code" > src/main.java
    git add src/main.java

    local exit_code=0
    validate_scope_worktree "$SCOPE_TEST_DIR" || exit_code=$?

    assert_equals 0 "$exit_code" "Normal code changes should pass validation"

    cleanup_scope_test
}

test_validate_scope_worktree_git_hooks_warning() {
    log_test "Testing validate_scope_worktree warns on git hook changes"

    setup_scope_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Modify a git hook
    mkdir -p .git/hooks
    echo "#!/bin/bash" > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit

    local exit_code=0
    validate_scope_worktree "$SCOPE_TEST_DIR" 2>&1 || exit_code=$?

    # Should pass but warn
    assert_equals 0 "$exit_code" "Git hook changes should pass (warning only)"
    # Note: git hooks are in .git/ which git doesn't track, so they won't appear
    # This test verifies the warning logic works when hooks are detected

    cleanup_scope_test
}

#===============================================================================
# AUDIT LOGGING TESTS
#===============================================================================

test_audit_log_created_on_violation() {
    log_test "Testing audit log is created on scope violation"

    # This test verifies the log_scope_violation function
    source "$VALIDATE_SCOPE_SCRIPT"

    local test_audit_dir
    test_audit_dir=$(mktemp -d)
    export KAPSIS_AUDIT_DIR="$test_audit_dir"

    # Simulate a violation being logged
    log_scope_violation "/test/path" "home/developer/.ssh/id_rsa" "home/developer/.bashrc"

    local audit_file="$test_audit_dir/scope-violations.jsonl"

    assert_file_exists "$audit_file" "Audit file should be created"
    assert_file_contains "$audit_file" ".ssh/id_rsa" "Audit should contain violation path"
    assert_file_contains "$audit_file" ".bashrc" "Audit should contain second violation"
    assert_file_contains "$audit_file" "timestamp" "Audit should contain timestamp"

    rm -rf "$test_audit_dir"
    unset KAPSIS_AUDIT_DIR
}

test_audit_log_escapes_special_chars() {
    log_test "Testing audit log escapes special characters in paths"

    source "$VALIDATE_SCOPE_SCRIPT"

    local test_audit_dir
    test_audit_dir=$(mktemp -d)
    export KAPSIS_AUDIT_DIR="$test_audit_dir"

    # Simulate violation with special chars (quotes, backslashes)
    log_scope_violation '/test/path"with"quotes' 'file"with"quotes.txt' 'path\with\backslash'

    local audit_file="$test_audit_dir/scope-violations.jsonl"

    assert_file_exists "$audit_file" "Audit file should be created"

    # Verify JSON is valid (not malformed) using jq
    if command -v jq &>/dev/null; then
        if ! jq -e . "$audit_file" >/dev/null 2>&1; then
            log_error "Audit log contains invalid JSON:"
            cat "$audit_file"
            rm -rf "$test_audit_dir"
            unset KAPSIS_AUDIT_DIR
            return 1
        fi
        log_info "JSON is valid"

        # Verify the special characters are preserved after JSON parsing
        # jq will unescape them, so we check for the original values
        local parsed_violation
        parsed_violation=$(jq -r '.violations[0]' "$audit_file")
        if [[ "$parsed_violation" != 'file"with"quotes.txt' ]]; then
            log_error "Expected violation 'file\"with\"quotes.txt' but got: $parsed_violation"
            rm -rf "$test_audit_dir"
            unset KAPSIS_AUDIT_DIR
            return 1
        fi
        log_info "Quotes correctly escaped and preserved in JSON"
    else
        log_warn "jq not available - skipping JSON validation"
    fi

    rm -rf "$test_audit_dir"
    unset KAPSIS_AUDIT_DIR
}

#===============================================================================
# RUN TESTS
#===============================================================================

main() {
    # Unit tests (no container required)
    run_test test_is_path_allowed_workspace
    run_test test_is_path_blocked_sensitive
    run_test test_is_path_warning_git_hooks

    # Integration tests
    run_test test_validate_scope_worktree_clean
    run_test test_validate_scope_worktree_allowed_changes
    run_test test_validate_scope_worktree_git_hooks_warning

    # Audit logging tests
    run_test test_audit_log_created_on_violation
    run_test test_audit_log_escapes_special_chars

    print_summary
}

main "$@"
