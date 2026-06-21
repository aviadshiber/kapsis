#!/usr/bin/env bash
#===============================================================================
# Test: Committer Identity Resolution
#
# Verifies that launch-agent.sh and worktree-manager.sh resolve the git
# committer identity in the documented precedence order:
#   1. --author CLI flag (CLI_AUTHOR)
#   2. First entry of git.co_authors (GIT_CO_AUTHORS)
#   3. Host git config user.name / user.email
#   4. Synthetic "Kapsis Agent <id>" fallback
#
# Also verifies the sanitized git config written by create_safe_git_config
# honours KAPSIS_COMMITTER_NAME / KAPSIS_COMMITTER_EMAIL env vars.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_AGENT="$KAPSIS_ROOT/scripts/launch-agent.sh"
WORKTREE_MANAGER="$KAPSIS_ROOT/scripts/worktree-manager.sh"

# Extract the resolve_committer_identity function into a sourceable form so we
# can exercise it without running the full launch-agent.sh main() flow.
# We use awk to slice out the function definition.
extract_resolver() {
    awk '/^resolve_committer_identity\(\) \{/,/^\}$/' "$LAUNCH_AGENT"
}

run_resolver() {
    # Runs resolve_committer_identity in a clean subshell with given vars.
    # Args: AGENT_ID, CLI_AUTHOR, GIT_CO_AUTHORS, host_git_name, host_git_email
    local agent_id="$1"
    local cli_author="$2"
    local git_co_authors="$3"
    local host_name="$4"
    local host_email="$5"

    local fn_body
    fn_body=$(extract_resolver)

    # Use a fake HOME with isolated git config
    local fake_home
    fake_home=$(mktemp -d)

    # Provide minimal log_info stub to avoid framework dependency
    bash -c "
        set -euo pipefail
        export HOME='$fake_home'
        export XDG_CONFIG_HOME='$fake_home/.config'
        if [[ -n '$host_name' ]]; then
            git config --global user.name '$host_name'
        fi
        if [[ -n '$host_email' ]]; then
            git config --global user.email '$host_email'
        fi
        log_info() { :; }
        AGENT_ID='$agent_id'
        CLI_AUTHOR='$cli_author'
        GIT_CO_AUTHORS='$git_co_authors'
        $fn_body
        resolve_committer_identity
        echo \"\$KAPSIS_COMMITTER_NAME|\$KAPSIS_COMMITTER_EMAIL\"
    "

    rm -rf "$fake_home"
}

#===============================================================================
# TEST CASES
#===============================================================================

test_cli_author_takes_precedence() {
    log_test "Testing --author flag takes precedence over config and host"
    local result
    result=$(run_resolver "abc123" \
        "Alice <alice@example.com>" \
        "Bob <bob@example.com>|Carol <carol@example.com>" \
        "Host User" "host@example.com")
    assert_equals "Alice|alice@example.com" "$result" \
        "Should resolve to --author"
}

test_first_co_author_used_when_no_cli_author() {
    log_test "Testing first git.co_authors entry used when --author absent"
    local result
    result=$(run_resolver "abc123" \
        "" \
        "Bob <bob@example.com>|Carol <carol@example.com>" \
        "Host User" "host@example.com")
    assert_equals "Bob|bob@example.com" "$result" \
        "Should resolve to first co-author"
}

test_host_git_used_when_no_config() {
    log_test "Testing host git config used when no --author and no co_authors"
    local result
    result=$(run_resolver "abc123" "" "" "Host User" "host@example.com")
    assert_equals "Host User|host@example.com" "$result" \
        "Should resolve to host git identity"
}

test_synthetic_fallback_when_nothing_set() {
    log_test "Testing synthetic Kapsis Agent fallback when nothing configured"
    local result
    result=$(run_resolver "abc123" "" "" "" "")
    assert_equals "Kapsis Agent abc123|kapsis-agent-abc123@localhost" "$result" \
        "Should fall back to synthetic identity"
}

test_create_safe_git_config_honours_env() {
    log_test "Testing create_safe_git_config writes resolved identity"

    local tmpdir
    tmpdir=$(mktemp -d)
    local worktree_path="$tmpdir/worktree"
    local config_path="$tmpdir/config"
    mkdir -p "$worktree_path"
    (cd "$worktree_path" && git init -q)

    # Source only the function — guard sourcing in a subshell
    (
        # Stub logging functions that worktree-manager.sh expects
        log_info() { :; }
        log_debug() { :; }
        log_warn() { :; }
        log_error() { :; }
        log_success() { :; }
        export KAPSIS_COMMITTER_NAME="Resolved User"
        export KAPSIS_COMMITTER_EMAIL="resolved@example.com"
        # shellcheck disable=SC1090
        source "$WORKTREE_MANAGER"
        create_safe_git_config "$config_path" "$worktree_path" "agent-xyz"
    )

    assert_file_contains "$config_path" "name = Resolved User" \
        "Config should contain resolved committer name"
    assert_file_contains "$config_path" "email = resolved@example.com" \
        "Config should contain resolved committer email"

    rm -rf "$tmpdir"
}

test_create_safe_git_config_falls_back_when_env_unset() {
    log_test "Testing create_safe_git_config falls back to synthetic identity"

    local tmpdir
    tmpdir=$(mktemp -d)
    local worktree_path="$tmpdir/worktree"
    local config_path="$tmpdir/config"
    mkdir -p "$worktree_path"
    (cd "$worktree_path" && git init -q)

    (
        log_info() { :; }
        log_debug() { :; }
        log_warn() { :; }
        log_error() { :; }
        log_success() { :; }
        unset KAPSIS_COMMITTER_NAME KAPSIS_COMMITTER_EMAIL
        # shellcheck disable=SC1090
        source "$WORKTREE_MANAGER"
        create_safe_git_config "$config_path" "$worktree_path" "fallback-id"
    )

    assert_file_contains "$config_path" "name = Kapsis Agent fallback-id" \
        "Config should fall back to synthetic name"
    assert_file_contains "$config_path" "email = kapsis-agent-fallback-id@localhost" \
        "Config should fall back to synthetic email"

    rm -rf "$tmpdir"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Committer Identity Resolution"

    run_test test_cli_author_takes_precedence
    run_test test_first_co_author_used_when_no_cli_author
    run_test test_host_git_used_when_no_config
    run_test test_synthetic_fallback_when_nothing_set
    run_test test_create_safe_git_config_honours_env
    run_test test_create_safe_git_config_falls_back_when_env_unset

    print_summary
}

main "$@"
