#!/usr/bin/env bash
#===============================================================================
# Test: Container Artifact Commit Exclusion (Issue #391)
#
# Verifies that Kapsis infrastructure artifacts are never committed to the
# user's branch:
#
#   1. .bak* files (e.g. .mvn/extensions.xml.bak2) are filtered before commit
#   2. .claude/settings.json modifications are filtered before commit
#   3. inject_gist_instructions() writes to .kapsis/CLAUDE.md and
#      .kapsis/AGENTS.md — NOT to workspace-root CLAUDE.md / AGENTS.md
#
# All tests run without containers (--quick compatible).
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests
# shellcheck disable=SC2034  # Variables used by sourced scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

export KAPSIS_LOG_TO_FILE=false
export KAPSIS_LOG_CONSOLE=false
export KAPSIS_STATUS_ENABLED=false

source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-artifact-commit-exclusion"
source "$KAPSIS_ROOT/scripts/lib/status.sh"
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/lib/git-remote-utils.sh"
source "$KAPSIS_ROOT/scripts/post-container-git.sh"

# Global test repo path
TEST_REPO=""

#===============================================================================
# HELPERS
#===============================================================================

setup_test_repo() {
    local test_name="$1"
    TEST_REPO=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-test-391-${test_name}-XXXXXX")
    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false
    echo "# Test Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"
}

cleanup_test_repo() {
    if [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]]; then
        cd /
        rm -rf "$TEST_REPO"
    fi
    TEST_REPO=""
}

#===============================================================================
# TESTS: .bak* files excluded via KAPSIS_DEFAULT_COMMIT_EXCLUDE
#===============================================================================

test_bak_pattern_in_constants() {
    log_test "KAPSIS_GIT_EXCLUDE_PATTERNS contains *.bak* gitignore pattern (issue #391)"
    local has_bak
    has_bak=$(echo "$KAPSIS_GIT_EXCLUDE_PATTERNS" | grep -c '\.bak' || true)
    # shellcheck disable=SC2016  # assert_true evals single-quoted expressions
    assert_true '[[ "$has_bak" -ge 1 ]]' \
        "KAPSIS_GIT_EXCLUDE_PATTERNS must contain a .bak* pattern for info/exclude"
}

test_bak_file_unstaged_by_validate() {
    log_test ".mvn/extensions.xml.bak2 is unstaged by validate_staged_files (issue #391)"
    setup_test_repo "bak"
    cd "$TEST_REPO"

    mkdir -p ".mvn"
    echo "<extensions/>" > ".mvn/extensions.xml"
    echo "<extensions/>" > ".mvn/extensions.xml.bak2"
    git add .mvn/extensions.xml .mvn/extensions.xml.bak2

    local staged_bak_before
    staged_bak_before=$(git diff --cached --name-only | grep "\.bak" || echo "")
    if [[ -z "$staged_bak_before" ]]; then
        log_fail ".bak2 file should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    validate_staged_files "$TEST_REPO"

    local staged_bak_after
    staged_bak_after=$(git diff --cached --name-only | grep "\.bak" || echo "")
    assert_equals "" "$staged_bak_after" ".bak2 file must be unstaged after validate_staged_files"

    # The real .xml file should still be staged
    local staged_xml
    staged_xml=$(git diff --cached --name-only | grep "extensions\.xml$" || echo "")
    # shellcheck disable=SC2016  # assert_true evals single-quoted expressions
    assert_true '[[ -n "$staged_xml" ]]' \
        "extensions.xml (non-bak) must remain staged after filtering"

    cleanup_test_repo
}

test_numbered_bak_files_excluded() {
    log_test "*.bak[0-9]* files (bak1, bak10, etc.) are unstaged by validate_staged_files"
    setup_test_repo "baknum"
    cd "$TEST_REPO"

    echo "config" > "config.yml.bak1"
    echo "config" > "config.yml.bak10"
    git add config.yml.bak1 config.yml.bak10

    validate_staged_files "$TEST_REPO"

    local staged_after
    staged_after=$(git diff --cached --name-only | grep "\.bak" || echo "")
    assert_equals "" "$staged_after" "Numbered .bak files must be unstaged after validate_staged_files"

    cleanup_test_repo
}

#===============================================================================
# TESTS: .claude/settings.json excluded via KAPSIS_DEFAULT_COMMIT_EXCLUDE
#===============================================================================

test_claude_settings_pattern_in_constants() {
    log_test "KAPSIS_DEFAULT_COMMIT_EXCLUDE contains .claude/settings.json pattern (issue #391)"
    local has_pattern
    has_pattern=$(echo "$KAPSIS_DEFAULT_COMMIT_EXCLUDE" | grep -c 'settings\.json' || true)
    # shellcheck disable=SC2016  # assert_true evals single-quoted expressions
    assert_true '[[ "$has_pattern" -ge 1 ]]' \
        "KAPSIS_DEFAULT_COMMIT_EXCLUDE must contain a .claude/settings.json pattern"
}

test_claude_settings_json_unstaged_by_validate() {
    log_test ".claude/settings.json is unstaged by validate_staged_files (issue #391)"
    setup_test_repo "claude-settings"
    cd "$TEST_REPO"

    # Simulate a tracked .claude/settings.json that Kapsis mutated
    mkdir -p ".claude"
    echo '{"hooks":{}}' > ".claude/settings.json"
    git add .claude/settings.json
    git commit --quiet -m "Add .claude/settings.json"

    # Simulate Kapsis mutation (adds hooks)
    echo '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"/opt/kapsis/hooks/kapsis-status-hook.sh"}]}]}}' \
        > ".claude/settings.json"
    git add .claude/settings.json

    local staged_before
    staged_before=$(git diff --cached --name-only | grep "settings\.json" || echo "")
    if [[ -z "$staged_before" ]]; then
        log_fail ".claude/settings.json should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    validate_staged_files "$TEST_REPO"

    local staged_after
    staged_after=$(git diff --cached --name-only | grep "settings\.json" || echo "")
    assert_equals "" "$staged_after" ".claude/settings.json must be unstaged after validate_staged_files"

    cleanup_test_repo
}

#===============================================================================
# TESTS: inject_gist_instructions writes to .kapsis/, not workspace root
#===============================================================================

# Saved HOME value for env restoration in gist tests
_ORIG_HOME="$HOME"
GIST_TEST_HOME=""
GIST_TEST_WORKSPACE=""

setup_gist_test_env() {
    GIST_TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-gist-home-XXXXXX")
    GIST_TEST_WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-gist-ws-XXXXXX")
    export HOME="$GIST_TEST_HOME"
    export KAPSIS_WORKSPACE="$GIST_TEST_WORKSPACE"
    export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"
    export KAPSIS_INJECT_GIST="true"
    export KAPSIS_GIST_FILE="$GIST_TEST_WORKSPACE/.kapsis/gist.txt"
    mkdir -p "$GIST_TEST_HOME/.kapsis/logs"
    # Reset injection guard so inject_gist_instructions runs fresh each test
    unset _KAPSIS_INJECT_STATUS_HOOKS_LOADED 2>/dev/null || true
}

cleanup_gist_test_env() {
    export HOME="$_ORIG_HOME"
    rm -rf "${GIST_TEST_HOME:-}" "${GIST_TEST_WORKSPACE:-}"
    GIST_TEST_HOME=""
    GIST_TEST_WORKSPACE=""
    unset KAPSIS_WORKSPACE KAPSIS_INJECT_GIST KAPSIS_GIST_FILE 2>/dev/null || true
    unset _KAPSIS_INJECT_STATUS_HOOKS_LOADED 2>/dev/null || true
}

# Source inject-status-hooks to get inject_gist_instructions; guard with a
# sub-shell unset so sourcing the library here doesn't permanently set the
# source-guard and block re-sourcing in the main test body.
_source_inject_hooks() {
    unset _KAPSIS_INJECT_STATUS_HOOKS_LOADED 2>/dev/null || true
    # shellcheck source=../scripts/lib/inject-status-hooks.sh
    source "$KAPSIS_ROOT/scripts/lib/inject-status-hooks.sh"
}

test_gist_inject_writes_to_kapsis_claude_md() {
    log_test "inject_gist_instructions() writes to .kapsis/CLAUDE.md, not workspace CLAUDE.md (issue #391)"
    setup_gist_test_env

    # Create a workspace CLAUDE.md as bait (should NOT be modified)
    echo "# Project Docs" > "$GIST_TEST_WORKSPACE/CLAUDE.md"
    local original_content
    original_content=$(cat "$GIST_TEST_WORKSPACE/CLAUDE.md")

    _source_inject_hooks
    inject_gist_instructions

    # workspace CLAUDE.md must be unchanged
    local after_content
    after_content=$(cat "$GIST_TEST_WORKSPACE/CLAUDE.md")
    assert_equals "$original_content" "$after_content" \
        "Workspace CLAUDE.md must NOT be modified by inject_gist_instructions"

    # .kapsis/CLAUDE.md must exist and contain the marker
    assert_file_exists "$GIST_TEST_WORKSPACE/.kapsis/CLAUDE.md" \
        ".kapsis/CLAUDE.md must be created by inject_gist_instructions"
    assert_file_contains "$GIST_TEST_WORKSPACE/.kapsis/CLAUDE.md" "Kapsis Activity Gist" \
        ".kapsis/CLAUDE.md must contain the gist marker"

    cleanup_gist_test_env
}

test_gist_inject_writes_to_kapsis_agents_md() {
    log_test "inject_gist_instructions() writes to .kapsis/AGENTS.md, not workspace AGENTS.md (issue #391)"
    setup_gist_test_env

    echo "# Project Agents" > "$GIST_TEST_WORKSPACE/AGENTS.md"
    local original_content
    original_content=$(cat "$GIST_TEST_WORKSPACE/AGENTS.md")

    _source_inject_hooks
    inject_gist_instructions

    local after_content
    after_content=$(cat "$GIST_TEST_WORKSPACE/AGENTS.md")
    assert_equals "$original_content" "$after_content" \
        "Workspace AGENTS.md must NOT be modified by inject_gist_instructions"

    assert_file_exists "$GIST_TEST_WORKSPACE/.kapsis/AGENTS.md" \
        ".kapsis/AGENTS.md must be created by inject_gist_instructions"

    cleanup_gist_test_env
}

test_gist_inject_creates_kapsis_files_when_workspace_md_absent() {
    log_test "inject_gist_instructions() creates .kapsis/CLAUDE.md even without workspace CLAUDE.md"
    setup_gist_test_env
    # Workspace has NO CLAUDE.md or AGENTS.md

    _source_inject_hooks
    inject_gist_instructions

    assert_file_exists "$GIST_TEST_WORKSPACE/.kapsis/CLAUDE.md" \
        ".kapsis/CLAUDE.md must always be created (not conditional on workspace CLAUDE.md)"
    assert_file_exists "$GIST_TEST_WORKSPACE/.kapsis/AGENTS.md" \
        ".kapsis/AGENTS.md must always be created"

    cleanup_gist_test_env
}

test_gist_inject_skipped_in_overlay_mode() {
    log_test "inject_gist_instructions() is a no-op in overlay mode (regression guard)"
    setup_gist_test_env
    export KAPSIS_SANDBOX_MODE="overlay"

    _source_inject_hooks
    inject_gist_instructions

    local kapsis_dir="$GIST_TEST_WORKSPACE/.kapsis"
    local claude_written=false
    [[ -f "$kapsis_dir/CLAUDE.md" ]] && claude_written=true
    assert_equals "false" "$claude_written" \
        "inject_gist_instructions must be a no-op in overlay mode"

    unset KAPSIS_SANDBOX_MODE 2>/dev/null || true
    cleanup_gist_test_env
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Container Artifact Commit Exclusion (Issue #391)"

    run_test test_bak_pattern_in_constants
    run_test test_bak_file_unstaged_by_validate
    run_test test_numbered_bak_files_excluded
    run_test test_claude_settings_pattern_in_constants
    run_test test_claude_settings_json_unstaged_by_validate
    run_test test_gist_inject_writes_to_kapsis_claude_md
    run_test test_gist_inject_writes_to_kapsis_agents_md
    run_test test_gist_inject_creates_kapsis_files_when_workspace_md_absent
    run_test test_gist_inject_skipped_in_overlay_mode

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
