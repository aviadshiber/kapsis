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
# Also verifies that:
#   - The sanitized git config written by create_safe_git_config honours
#     KAPSIS_COMMITTER_NAME / KAPSIS_COMMITTER_EMAIL env vars.
#   - validate_author_format rejects multi-line / shell-metachar injection
#     (PR #416 security review).
#   - post-container-git's commit_changes records the resolved identity in
#     the actual git commit (PR #416 test review).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_AGENT="$KAPSIS_ROOT/scripts/launch-agent.sh"
WORKTREE_MANAGER="$KAPSIS_ROOT/scripts/worktree-manager.sh"
POST_CONTAINER_GIT="$KAPSIS_ROOT/scripts/post-container-git.sh"

# Runs resolve_committer_identity in an isolated subshell.
#
# Args via env (NOT positional, NOT string interpolation) so values with
# quotes / spaces / special chars cannot break the test harness — see
# PR #416 test-reviewer's "critical" finding.
#
# Env consumed:
#   T_AGENT_ID, T_CLI_AUTHOR, T_GIT_CO_AUTHORS, T_HOST_NAME, T_HOST_EMAIL
run_resolver() {
    local fake_home
    fake_home=$(mktemp -d)
    # shellcheck disable=SC2064  # path captured at trap install time intentionally
    trap "rm -rf '$fake_home'" RETURN

    HOME="$fake_home" \
    XDG_CONFIG_HOME="$fake_home/.config" \
    GIT_CONFIG_NOSYSTEM=1 \
    T_AGENT_ID="$1" \
    T_CLI_AUTHOR="$2" \
    T_GIT_CO_AUTHORS="$3" \
    T_HOST_NAME="$4" \
    T_HOST_EMAIL="$5" \
    LAUNCH_AGENT="$LAUNCH_AGENT" \
    bash -c '
        set -euo pipefail
        # Stub logging before sourcing so the script does not require log files
        log_info()    { :; }
        log_debug()   { :; }
        log_warn()    { :; }
        log_error()   { :; }
        log_success() { :; }
        export -f log_info log_debug log_warn log_error log_success
        # Seed host git config inside the isolated HOME
        if [[ -n "$T_HOST_NAME" ]]; then
            git config --global user.name "$T_HOST_NAME"
        fi
        if [[ -n "$T_HOST_EMAIL" ]]; then
            git config --global user.email "$T_HOST_EMAIL"
        fi
        # Sourcing launch-agent.sh: the trailing `main "$@"` is guarded by
        # `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` so this does not execute main.
        # shellcheck disable=SC1090
        source "$LAUNCH_AGENT"
        AGENT_ID="$T_AGENT_ID"
        CLI_AUTHOR="$T_CLI_AUTHOR"
        GIT_CO_AUTHORS="$T_GIT_CO_AUTHORS"
        resolve_committer_identity
        printf "%s|%s\n" "$KAPSIS_COMMITTER_NAME" "$KAPSIS_COMMITTER_EMAIL"
    '
}

#===============================================================================
# TEST CASES: precedence
#===============================================================================

test_cli_author_takes_precedence() {
    log_test "Testing --author takes precedence over config and host"
    local result
    result=$(run_resolver "abc123" \
        "Alice <alice@example.com>" \
        "Bob <bob@example.com>|Carol <carol@example.com>" \
        "Host User" "host@example.com")
    assert_equals "Alice|alice@example.com" "$result" "Should resolve to --author"
}

test_first_co_author_used_when_no_cli_author() {
    log_test "Testing first git.co_authors used when --author absent"
    local result
    result=$(run_resolver "abc123" "" \
        "Bob <bob@example.com>|Carol <carol@example.com>" \
        "Host User" "host@example.com")
    assert_equals "Bob|bob@example.com" "$result" "Should resolve to first co-author"
}

test_host_git_used_when_no_config() {
    log_test "Testing host git config used when no --author and no co_authors"
    local result
    result=$(run_resolver "abc123" "" "" "Host User" "host@example.com")
    assert_equals "Host User|host@example.com" "$result" "Should use host git identity"
}

test_synthetic_fallback_when_nothing_set() {
    log_test "Testing synthetic Kapsis Agent fallback when nothing configured"
    local result
    result=$(run_resolver "abc123" "" "" "" "")
    assert_equals "Kapsis Agent abc123|kapsis-agent-abc123@localhost" "$result" \
        "Should fall back to synthetic identity"
}

#===============================================================================
# TEST CASES: edge cases (PR #416 review follow-up)
#===============================================================================

test_host_name_only_falls_through_to_synthetic() {
    log_test "Testing partial host git (name only, no email) falls through"
    local result
    result=$(run_resolver "abc123" "" "" "Host User" "")
    assert_equals "Kapsis Agent abc123|kapsis-agent-abc123@localhost" "$result" \
        "Should fall through when host email missing"
}

test_host_email_only_falls_through_to_synthetic() {
    log_test "Testing partial host git (email only, no name) falls through"
    local result
    result=$(run_resolver "abc123" "" "" "" "host@example.com")
    assert_equals "Kapsis Agent abc123|kapsis-agent-abc123@localhost" "$result" \
        "Should fall through when host name missing"
}

test_name_with_single_quote_resolves() {
    log_test "Testing name with single quote (e.g. O'Brien) resolves correctly"
    local result
    result=$(run_resolver "abc123" "O'Brien <ob@example.com>" "" "" "")
    assert_equals "O'Brien|ob@example.com" "$result" \
        "Single quote in name must survive the harness"
}

#===============================================================================
# TEST CASES: validate_author_format (security boundary)
#===============================================================================

run_validator() {
    # Returns "0" or "1" — the exit code of validate_author_format.
    local value="$1"
    HOME="$(mktemp -d)" GIT_CONFIG_NOSYSTEM=1 LAUNCH_AGENT="$LAUNCH_AGENT" \
        T_VALUE="$value" bash -c '
        set -uo pipefail
        log_info() { :; }; log_debug() { :; }; log_warn() { :; }
        log_error() { :; }; log_success() { :; }
        export -f log_info log_debug log_warn log_error log_success
        # shellcheck disable=SC1090
        source "$LAUNCH_AGENT"
        if validate_author_format "$T_VALUE"; then
            echo 0
        else
            echo 1
        fi
    '
}

test_validator_accepts_simple() {
    log_test "validate_author_format accepts simple Name <email>"
    assert_equals "0" "$(run_validator "Alice <alice@example.com>")" \
        "Should accept simple identity"
}

test_validator_accepts_dotted_name() {
    log_test "validate_author_format accepts dotted names"
    assert_equals "0" "$(run_validator "Jon Doe <jon.d@example.com>")" \
        "Should accept names with dots"
}

test_validator_rejects_newline_in_email() {
    log_test "validate_author_format rejects newline in email (injection)"
    local payload
    payload=$'Alice <alice@x.com\n[core]\n\thooksPath = /tmp/evil>'
    assert_equals "1" "$(run_validator "$payload")" \
        "Newline in email portion must be rejected (PR #416 RCE fix)"
}

test_validator_rejects_no_email() {
    log_test "validate_author_format rejects bare name (no email)"
    assert_equals "1" "$(run_validator "JustAName")" \
        "Bare name without <email> must be rejected"
}

test_validator_rejects_empty_email() {
    log_test "validate_author_format rejects empty email <>"
    assert_equals "1" "$(run_validator "Name <>")" \
        "Empty email must be rejected"
}

test_validator_rejects_space_in_email() {
    log_test "validate_author_format rejects space in email"
    assert_equals "1" "$(run_validator "Name <a b@x.com>")" \
        "Space inside email must be rejected"
}

#===============================================================================
# TEST CASES: create_safe_git_config
#===============================================================================

test_create_safe_git_config_honours_env() {
    log_test "create_safe_git_config writes resolved identity"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local worktree_path="$tmpdir/worktree"
    local config_path="$tmpdir/config"
    mkdir -p "$worktree_path"
    (cd "$worktree_path" && git init -q)

    (
        log_info() { :; }; log_debug() { :; }; log_warn() { :; }
        log_error() { :; }; log_success() { :; }
        export KAPSIS_COMMITTER_NAME="Resolved User"
        export KAPSIS_COMMITTER_EMAIL="resolved@example.com"
        # shellcheck disable=SC1090
        source "$WORKTREE_MANAGER"
        create_safe_git_config "$config_path" "$worktree_path" "agent-xyz"
    )

    # Use git config --file to read back — exercises the same code path used to write
    local got_name got_email
    got_name=$(git config --file "$config_path" user.name)
    got_email=$(git config --file "$config_path" user.email)
    assert_equals "Resolved User" "$got_name" "user.name should be resolved value"
    assert_equals "resolved@example.com" "$got_email" "user.email should be resolved value"
}

test_create_safe_git_config_falls_back_when_env_unset() {
    log_test "create_safe_git_config falls back to synthetic identity"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local worktree_path="$tmpdir/worktree"
    local config_path="$tmpdir/config"
    mkdir -p "$worktree_path"
    (cd "$worktree_path" && git init -q)

    (
        log_info() { :; }; log_debug() { :; }; log_warn() { :; }
        log_error() { :; }; log_success() { :; }
        unset KAPSIS_COMMITTER_NAME KAPSIS_COMMITTER_EMAIL
        # shellcheck disable=SC1090
        source "$WORKTREE_MANAGER"
        create_safe_git_config "$config_path" "$worktree_path" "fallback-id"
    )

    local got_name got_email
    got_name=$(git config --file "$config_path" user.name)
    got_email=$(git config --file "$config_path" user.email)
    assert_equals "Kapsis Agent fallback-id" "$got_name" "Should fall back to synthetic name"
    assert_equals "kapsis-agent-fallback-id@localhost" "$got_email" "Should fall back to synthetic email"
}

#===============================================================================
# TEST CASES: post-container-git commit override (T2 from PR #416 review)
#===============================================================================

test_commit_changes_uses_resolved_identity() {
    log_test "commit_changes records KAPSIS_COMMITTER_NAME/EMAIL in actual commit"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q
        git config user.email "default@local"
        git config user.name "Default User"
        git config commit.gpgsign false
        echo "init" > README.md
        git add README.md
        git commit -q -m "initial"
        echo "change" >> README.md
    )

    (
        # Stub the logging functions the post-container script needs
        log_info() { :; }; log_debug() { :; }; log_warn() { :; }
        log_error() { :; }; log_success() { :; }
        # Disable attribution / sanitisation noise that would change the assertion
        export KAPSIS_ATTRIBUTION_COMMIT=""
        export KAPSIS_COMMITTER_NAME="Resolved Committer"
        export KAPSIS_COMMITTER_EMAIL="resolved@example.com"
        # shellcheck disable=SC1090
        source "$POST_CONTAINER_GIT"
        cd "$repo"
        commit_changes "$repo" "test: resolved identity" "agent-zzz" "" >/dev/null 2>&1
    )

    local cn ce an ae
    cn=$(git -C "$repo" log -1 --format='%cn')
    ce=$(git -C "$repo" log -1 --format='%ce')
    an=$(git -C "$repo" log -1 --format='%an')
    ae=$(git -C "$repo" log -1 --format='%ae')
    assert_equals "Resolved Committer" "$cn" "git committer name should be overridden"
    assert_equals "resolved@example.com" "$ce" "git committer email should be overridden"
    assert_equals "Resolved Committer" "$an" "git author name should be overridden"
    assert_equals "resolved@example.com" "$ae" "git author email should be overridden"
}

test_commit_changes_uses_repo_default_when_env_unset() {
    log_test "commit_changes uses repo git config when env vars unset"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q
        git config user.email "default@local"
        git config user.name "Default User"
        git config commit.gpgsign false
        echo "init" > README.md
        git add README.md
        git commit -q -m "initial"
        echo "change" >> README.md
    )

    (
        log_info() { :; }; log_debug() { :; }; log_warn() { :; }
        log_error() { :; }; log_success() { :; }
        export KAPSIS_ATTRIBUTION_COMMIT=""
        unset KAPSIS_COMMITTER_NAME KAPSIS_COMMITTER_EMAIL
        # shellcheck disable=SC1090
        source "$POST_CONTAINER_GIT"
        cd "$repo"
        commit_changes "$repo" "test: default identity" "agent-zzz" "" >/dev/null 2>&1
    )

    local cn
    cn=$(git -C "$repo" log -1 --format='%cn')
    assert_equals "Default User" "$cn" "Should fall through to repo git config"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Committer Identity Resolution"

    # Precedence
    run_test test_cli_author_takes_precedence
    run_test test_first_co_author_used_when_no_cli_author
    run_test test_host_git_used_when_no_config
    run_test test_synthetic_fallback_when_nothing_set

    # Edge cases
    run_test test_host_name_only_falls_through_to_synthetic
    run_test test_host_email_only_falls_through_to_synthetic
    run_test test_name_with_single_quote_resolves

    # Validator (security boundary)
    run_test test_validator_accepts_simple
    run_test test_validator_accepts_dotted_name
    run_test test_validator_rejects_newline_in_email
    run_test test_validator_rejects_no_email
    run_test test_validator_rejects_empty_email
    run_test test_validator_rejects_space_in_email

    # Sanitized git config writer
    run_test test_create_safe_git_config_honours_env
    run_test test_create_safe_git_config_falls_back_when_env_unset

    # post-container-git commit override
    run_test test_commit_changes_uses_resolved_identity
    run_test test_commit_changes_uses_repo_default_when_env_unset

    print_summary
}

main "$@"
