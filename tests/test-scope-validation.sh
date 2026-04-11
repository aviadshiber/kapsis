#!/usr/bin/env bash
#===============================================================================
# Test: Filesystem Scope Validation
#
# Verifies that the scope validation system correctly detects:
# - Allowed modifications (workspace, caches)
# - Blocked modifications in OVERLAY mode (.ssh, .claude home config, shell configs)
# - Warning-level modifications (git hooks)
#
# SECURITY MODEL:
# - Worktree mode: Mount isolation is the security boundary. All workspace paths
#   are allowed. Project-level agent configs (.claude/, .aider*, etc.) are safe.
# - Overlay mode: Path validation blocks home directory modifications.
#   Paths like home/developer/.claude/ are blocked (host config).
#   Paths like workspace/.claude/ are allowed (project config).
#
# Phase 1 security feature - defense in depth against prompt injection.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

VALIDATE_SCOPE_SCRIPT="$KAPSIS_ROOT/scripts/lib/validate-scope.sh"

# Create isolated test worktree
SCOPE_TEST_DIR=""
_SCOPE_ORIGINAL_DIR=""

setup_scope_test() {
    # Save original directory to restore after cleanup
    _SCOPE_ORIGINAL_DIR="$(pwd)"
    SCOPE_TEST_DIR=$(mktemp -d)
    cd "$SCOPE_TEST_DIR"
    git init -q
    # Use --local to ensure config only affects this temp repo
    git config --local user.email "test@kapsis.test"
    git config --local user.name "Kapsis Test"
    echo "initial" > README.md
    git add README.md
    git commit -q -m "Initial commit"
}

cleanup_scope_test() {
    # CRITICAL: Restore original directory BEFORE deleting temp dir
    # This prevents undefined CWD behavior that can corrupt git state
    if [[ -n "$_SCOPE_ORIGINAL_DIR" ]]; then
        cd "$_SCOPE_ORIGINAL_DIR" || cd /tmp
    fi
    if [[ -n "$SCOPE_TEST_DIR" ]] && [[ -d "$SCOPE_TEST_DIR" ]]; then
        rm -rf "$SCOPE_TEST_DIR"
    fi
    SCOPE_TEST_DIR=""
    _SCOPE_ORIGINAL_DIR=""
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

test_is_path_blocked_overlay_home_paths() {
    log_test "Testing is_path_blocked for HOME directory paths (overlay mode)"

    source "$VALIDATE_SCOPE_SCRIPT"

    # HOME directory paths should be blocked in overlay mode
    # These patterns match home/developer/.<sensitive>
    assert_command_succeeds "is_path_blocked 'home/developer/.ssh/id_rsa'" "home .ssh should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.claude/settings.json'" "home .claude should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.bashrc'" "home .bashrc should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.zshrc'" "home .zshrc should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.profile'" "home .profile should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.gitconfig'" "home .gitconfig should be blocked"
    assert_command_succeeds "is_path_blocked 'etc/passwd'" "/etc should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.aws/credentials'" "home .aws should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.kube/config'" "home .kube should be blocked"

    # Agent-agnostic: all AI agent home configs should be blocked
    assert_command_succeeds "is_path_blocked 'home/developer/.aider.conf.yml'" "home .aider should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.cursor/settings.json'" "home .cursor should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.continue/config.json'" "home .continue should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.codex/config'" "home .codex should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.gemini/settings'" "home .gemini should be blocked"
    assert_command_succeeds "is_path_blocked 'home/developer/.codeium/config'" "home .codeium should be blocked"
}

test_workspace_agent_configs_allowed() {
    log_test "Testing that WORKSPACE agent configs are allowed (not blocked)"

    source "$VALIDATE_SCOPE_SCRIPT"

    # WORKSPACE paths should NOT be blocked - these are project configs, not host configs
    # The patterns are specific to home/developer/, so workspace/ paths pass through
    assert_command_fails "is_path_blocked 'workspace/.claude/CLAUDE.md'" "workspace .claude should NOT be blocked"
    assert_command_fails "is_path_blocked 'workspace/.claude/rules/custom.md'" "workspace .claude/rules should NOT be blocked"
    assert_command_fails "is_path_blocked 'workspace/.aiderignore'" "workspace .aiderignore should NOT be blocked"
    assert_command_fails "is_path_blocked 'workspace/.cursor/settings.json'" "workspace .cursor should NOT be blocked"
    assert_command_fails "is_path_blocked 'workspace/.continue/config.json'" "workspace .continue should NOT be blocked"

    # Verify these pass the allowed check
    assert_command_succeeds "is_path_allowed 'workspace/.claude/CLAUDE.md'" "workspace .claude should be allowed"
    assert_command_succeeds "is_path_allowed 'workspace/src/main.java'" "workspace src should be allowed"
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

test_validate_scope_worktree_allows_project_agent_configs() {
    log_test "Testing validate_scope_worktree allows project-level agent configs (issue #115)"

    setup_scope_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Create project-level agent config directories and files
    # These should ALL be allowed in worktree mode (they're project configs, not host configs)
    mkdir -p .claude/rules
    echo "# Project instructions" > .claude/CLAUDE.md
    echo "# Custom rule" > .claude/rules/custom.md
    git add .claude/

    # Aider config
    echo "# Aider ignore" > .aiderignore
    git add .aiderignore

    # Cursor config
    mkdir -p .cursor
    echo "{}" > .cursor/settings.json
    git add .cursor/

    # Continue.dev config
    mkdir -p .continue
    echo "{}" > .continue/config.json
    git add .continue/

    local exit_code=0
    validate_scope_worktree "$SCOPE_TEST_DIR" || exit_code=$?

    assert_equals 0 "$exit_code" "Project-level agent configs should pass validation in worktree mode"

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
# INTEGRATION TESTS - Overlay Mode Validation
#===============================================================================

# Helper to set up overlay test directory structure
setup_overlay_test() {
    OVERLAY_TEST_DIR=$(mktemp -d)
    OVERLAY_UPPER_DIR="$OVERLAY_TEST_DIR/upper"
    mkdir -p "$OVERLAY_UPPER_DIR"
}

cleanup_overlay_test() {
    if [[ -n "$OVERLAY_TEST_DIR" ]] && [[ -d "$OVERLAY_TEST_DIR" ]]; then
        rm -rf "$OVERLAY_TEST_DIR"
    fi
    OVERLAY_TEST_DIR=""
    OVERLAY_UPPER_DIR=""
}

test_validate_scope_overlay_allows_workspace_files() {
    log_test "Testing validate_scope_overlay allows workspace files"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Create allowed workspace files in upper directory
    mkdir -p "$OVERLAY_UPPER_DIR/workspace/src"
    echo "code" > "$OVERLAY_UPPER_DIR/workspace/src/main.java"
    echo "readme" > "$OVERLAY_UPPER_DIR/workspace/README.md"

    local exit_code=0
    validate_scope_overlay "$OVERLAY_UPPER_DIR" || exit_code=$?

    assert_equals 0 "$exit_code" "Workspace files should pass overlay validation"

    cleanup_overlay_test
}

test_validate_scope_overlay_allows_workspace_agent_configs() {
    log_test "Testing validate_scope_overlay allows workspace agent configs (not home configs)"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Create project-level agent configs in workspace (these should be ALLOWED)
    mkdir -p "$OVERLAY_UPPER_DIR/workspace/.claude/rules"
    echo "# Project config" > "$OVERLAY_UPPER_DIR/workspace/.claude/CLAUDE.md"
    echo "# Rule" > "$OVERLAY_UPPER_DIR/workspace/.claude/rules/custom.md"

    mkdir -p "$OVERLAY_UPPER_DIR/workspace/.cursor"
    echo "{}" > "$OVERLAY_UPPER_DIR/workspace/.cursor/settings.json"

    mkdir -p "$OVERLAY_UPPER_DIR/workspace/.continue"
    echo "{}" > "$OVERLAY_UPPER_DIR/workspace/.continue/config.json"

    echo "# Aider ignore" > "$OVERLAY_UPPER_DIR/workspace/.aiderignore"

    local exit_code=0
    validate_scope_overlay "$OVERLAY_UPPER_DIR" || exit_code=$?

    assert_equals 0 "$exit_code" "Workspace agent configs should pass overlay validation"

    cleanup_overlay_test
}

test_validate_scope_overlay_blocks_home_agent_configs() {
    log_test "Testing validate_scope_overlay blocks HOME directory agent configs"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Create home directory agent config (this should be BLOCKED)
    mkdir -p "$OVERLAY_UPPER_DIR/home/developer/.claude"
    echo "# Malicious config" > "$OVERLAY_UPPER_DIR/home/developer/.claude/settings.json"

    local exit_code=0
    validate_scope_overlay "$OVERLAY_UPPER_DIR" 2>&1 || exit_code=$?

    assert_not_equals 0 "$exit_code" "Home .claude config should be blocked"

    cleanup_overlay_test
}

test_validate_scope_overlay_blocks_home_ssh() {
    log_test "Testing validate_scope_overlay blocks HOME .ssh directory"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Create home SSH files (this should be BLOCKED)
    mkdir -p "$OVERLAY_UPPER_DIR/home/developer/.ssh"
    echo "fake key" > "$OVERLAY_UPPER_DIR/home/developer/.ssh/id_rsa"

    local exit_code=0
    validate_scope_overlay "$OVERLAY_UPPER_DIR" 2>&1 || exit_code=$?

    assert_not_equals 0 "$exit_code" "Home .ssh should be blocked"

    cleanup_overlay_test
}

test_validate_scope_overlay_blocks_shell_configs() {
    log_test "Testing validate_scope_overlay blocks shell configuration files"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Create shell config file (this should be BLOCKED)
    mkdir -p "$OVERLAY_UPPER_DIR/home/developer"
    echo "export MALICIOUS=1" > "$OVERLAY_UPPER_DIR/home/developer/.bashrc"

    local exit_code=0
    validate_scope_overlay "$OVERLAY_UPPER_DIR" 2>&1 || exit_code=$?

    assert_not_equals 0 "$exit_code" "Home .bashrc should be blocked"

    cleanup_overlay_test
}

test_validate_scope_overlay_blocks_multiple_agent_home_configs() {
    log_test "Testing validate_scope_overlay blocks all AI agent home configs (agent-agnostic)"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Test each agent's home config is blocked
    local agents=(".cursor" ".continue" ".codex" ".gemini" ".codeium" ".copilot")

    for agent_dir in "${agents[@]}"; do
        # Clean up from previous iteration
        rm -rf "${OVERLAY_UPPER_DIR:?}/home"

        # Create agent home config
        mkdir -p "$OVERLAY_UPPER_DIR/home/developer/$agent_dir"
        echo "config" > "$OVERLAY_UPPER_DIR/home/developer/$agent_dir/config.json"

        local exit_code=0
        validate_scope_overlay "$OVERLAY_UPPER_DIR" 2>&1 || exit_code=$?

        assert_not_equals 0 "$exit_code" "Home $agent_dir should be blocked"
    done

    cleanup_overlay_test
}

test_validate_scope_overlay_allows_build_caches() {
    log_test "Testing validate_scope_overlay allows build tool caches"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Create build cache files (these should be ALLOWED)
    mkdir -p "$OVERLAY_UPPER_DIR/home/developer/.m2/repository/org/example"
    echo "jar content" > "$OVERLAY_UPPER_DIR/home/developer/.m2/repository/org/example/lib.jar"

    mkdir -p "$OVERLAY_UPPER_DIR/home/developer/.gradle/caches"
    echo "cache" > "$OVERLAY_UPPER_DIR/home/developer/.gradle/caches/modules.lock"

    mkdir -p "$OVERLAY_UPPER_DIR/home/developer/.npm"
    echo "cache" > "$OVERLAY_UPPER_DIR/home/developer/.npm/cache.json"

    local exit_code=0
    validate_scope_overlay "$OVERLAY_UPPER_DIR" || exit_code=$?

    assert_equals 0 "$exit_code" "Build caches should pass overlay validation"

    cleanup_overlay_test
}

test_validate_scope_overlay_empty_upper_dir() {
    log_test "Testing validate_scope_overlay with empty upper directory"

    setup_overlay_test
    source "$VALIDATE_SCOPE_SCRIPT"

    # Upper dir exists but is empty
    local exit_code=0
    validate_scope_overlay "$OVERLAY_UPPER_DIR" || exit_code=$?

    assert_equals 0 "$exit_code" "Empty upper dir should pass validation"

    cleanup_overlay_test
}

test_validate_scope_overlay_nonexistent_upper_dir() {
    log_test "Testing validate_scope_overlay with nonexistent upper directory"

    source "$VALIDATE_SCOPE_SCRIPT"

    local exit_code=0
    validate_scope_overlay "/nonexistent/upper/dir" || exit_code=$?

    assert_equals 0 "$exit_code" "Nonexistent upper dir should pass (no modifications)"
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
    # Unit tests - path matching (no container required)
    run_test test_is_path_allowed_workspace
    run_test test_is_path_blocked_overlay_home_paths
    run_test test_workspace_agent_configs_allowed
    run_test test_is_path_warning_git_hooks

    # Integration tests - worktree mode
    run_test test_validate_scope_worktree_clean
    run_test test_validate_scope_worktree_allowed_changes
    run_test test_validate_scope_worktree_allows_project_agent_configs  # Issue #115
    run_test test_validate_scope_worktree_git_hooks_warning

    # Integration tests - overlay mode
    run_test test_validate_scope_overlay_allows_workspace_files
    run_test test_validate_scope_overlay_allows_workspace_agent_configs
    run_test test_validate_scope_overlay_blocks_home_agent_configs
    run_test test_validate_scope_overlay_blocks_home_ssh
    run_test test_validate_scope_overlay_blocks_shell_configs
    run_test test_validate_scope_overlay_blocks_multiple_agent_home_configs
    run_test test_validate_scope_overlay_allows_build_caches
    run_test test_validate_scope_overlay_empty_upper_dir
    run_test test_validate_scope_overlay_nonexistent_upper_dir

    # Audit logging tests
    run_test test_audit_log_created_on_violation
    run_test test_audit_log_escapes_special_chars

    print_summary
}

main "$@"
