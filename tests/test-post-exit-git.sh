#!/usr/bin/env bash
#===============================================================================
# Test: post-exit-git.sh
#
# Covers the post-exit commit/push logic invoked at the end of every agent run:
#   - No-op when working tree is clean
#   - Commits staged + unstaged + untracked changes
#   - Auto-switches to the expected branch when current branch differs
#   - Emits KAPSIS_PUSH_FALLBACK sentinel on push failure + exits 1 (code 2 of
#     the documented exit-code contract)
#   - Uses custom remote-branch when provided via env or positional arg
#   - Respects KAPSIS_DO_PUSH env var override
#
# Category: git
# Container required: No (uses local bare remotes)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

POST_EXIT_SCRIPT="$KAPSIS_ROOT/scripts/post-exit-git.sh"

SANDBOX=""
UPSTREAM=""
CLONE=""

setup_sandbox() {
    SANDBOX=$(mktemp -d -t kapsis-post-exit-XXXXXX)
    UPSTREAM="$SANDBOX/upstream.git"
    CLONE="$SANDBOX/clone"

    git init -q --bare -b main "$UPSTREAM" 2>/dev/null || git init -q --bare "$UPSTREAM"
    git -C "$UPSTREAM" symbolic-ref HEAD refs/heads/main

    local seed="$SANDBOX/seed"
    git init -q -b main "$seed" 2>/dev/null || { git init -q "$seed" && git -C "$seed" checkout -q -b main; }
    (
        cd "$seed"
        git config user.email "t@k.local"
        git config user.name  "t"
        git config commit.gpgsign false
        echo "root" > README.md
        git add README.md
        git commit -q -m "init"
        git remote add origin "$UPSTREAM"
        git push -q origin main
    )

    git clone -q -b main "$UPSTREAM" "$CLONE"
    (
        cd "$CLONE"
        git config user.email "t@k.local"
        git config user.name  "t"
        git config commit.gpgsign false
        git checkout -q -b feature/work
    )
}

teardown_sandbox() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    SANDBOX=""; UPSTREAM=""; CLONE=""
}

# run_post_exit <branch> <msg> [remote] [do_push_arg] [remote_branch] [env_assignments_prefix]
# Preserves empty positional args by individually single-quoting them.
run_post_exit() {
    local env_prefix="${KAPSIS_ENV_PREFIX:-}"
    local args=""
    local a
    for a in "$@"; do
        args+=" '$a'"
    done
    capture_output "${env_prefix}WORKSPACE='$CLONE' bash '$POST_EXIT_SCRIPT'${args}"
}

#===============================================================================
# NO-OP PATH
#===============================================================================

test_clean_tree_is_noop() {
    log_test "clean working tree: exits 0 and does not commit"
    setup_sandbox
    trap teardown_sandbox RETURN

    local before_commit
    before_commit=$(git -C "$CLONE" rev-parse HEAD)

    run_post_exit "feature/work" "noop test"
    assert_equals 0 "$CAPTURED_EXIT_CODE" "Clean tree must exit 0"
    assert_contains "$CAPTURED_STDOUT" "NO CHANGES TO COMMIT" \
        "Must print the no-op banner"

    local after_commit
    after_commit=$(git -C "$CLONE" rev-parse HEAD)
    assert_equals "$before_commit" "$after_commit" "HEAD must not advance"
}

#===============================================================================
# COMMIT PATH (no push)
#===============================================================================

test_commits_tracked_changes() {
    log_test "commit: tracked edits are committed"
    setup_sandbox
    trap teardown_sandbox RETURN

    echo "edit" >> "$CLONE/README.md"
    run_post_exit "feature/work" "chore: edit"

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must exit 0 on commit success"
    local msg
    msg=$(git -C "$CLONE" log -1 --pretty=%B)
    assert_contains "$msg" "chore: edit" "Commit message must match"
}

test_commits_untracked_new_file() {
    log_test "commit: untracked files are staged via git add -A"
    setup_sandbox
    trap teardown_sandbox RETURN

    echo "new" > "$CLONE/NEW.txt"
    run_post_exit "feature/work" "feat: add NEW.txt"

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must exit 0"
    local listed
    listed=$(git -C "$CLONE" show --name-only --pretty=format: HEAD | tr -d '\n')
    assert_contains "$listed" "NEW.txt" "New file must be part of the commit"
}

test_switches_branch_when_mismatched() {
    log_test "branch mismatch: auto-switches to requested branch"
    setup_sandbox
    trap teardown_sandbox RETURN

    # Create + checkout feature/expected, leave changes, switch away
    (
        cd "$CLONE"
        git checkout -q -b feature/expected
        echo "work" > work.txt
        git add work.txt
        # Keep work staged (not committed) on expected, then go to a side branch
        git stash -q -u
        git checkout -q main
        git stash pop -q
    )
    # Now: HEAD=main with uncommitted work.txt, but we tell post-exit-git
    # the branch should be feature/expected.
    run_post_exit "feature/expected" "feat: work on expected"

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must exit 0"
    assert_contains "$CAPTURED_STDOUT" "differs from expected" \
        "Should warn about branch mismatch"
    local branch
    branch=$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)
    assert_equals "feature/expected" "$branch" \
        "HEAD should end up on feature/expected"
}

#===============================================================================
# PUSH PATH (success + fallback)
#===============================================================================

test_push_succeeds_against_real_upstream() {
    log_test "push: commit + push to the (local bare) upstream succeeds"
    setup_sandbox
    trap teardown_sandbox RETURN

    echo "push-me" > "$CLONE/push.txt"
    run_post_exit "feature/work" "chore: push" origin true

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Push against bare upstream must succeed"
    assert_contains "$CAPTURED_STDOUT" "CHANGES PUSHED SUCCESSFULLY" \
        "Must print the success banner"
    # Confirm upstream received the branch
    if ! git -C "$UPSTREAM" rev-parse --verify refs/heads/feature/work >/dev/null 2>&1; then
        _log_failure "feature/work must exist on upstream after push"
        return 1
    fi
}

test_push_fallback_on_failure_emits_sentinel_and_exits_1() {
    log_test "push fallback: failure emits KAPSIS_PUSH_FALLBACK and exits 1"
    setup_sandbox
    trap teardown_sandbox RETURN

    # Make push fail by pointing `origin` at a non-existent path.
    git -C "$CLONE" remote set-url origin "/nonexistent/path.git"

    echo "boom" > "$CLONE/boom.txt"
    run_post_exit "feature/work" "chore: will fail" origin true

    assert_equals 1 "$CAPTURED_EXIT_CODE" "Push failure must exit 1 (exit code 2 of the full contract)"
    assert_contains "$CAPTURED_STDOUT" "KAPSIS_PUSH_FALLBACK: git push origin feature/work:feature/work" \
        "Must emit the structured fallback command line (documented in CLAUDE.md)"
    # Commit must still be local so the agent can recover
    local msg
    msg=$(git -C "$CLONE" log -1 --pretty=%B)
    assert_contains "$msg" "chore: will fail" "Commit must still land locally"
}

test_custom_remote_branch_in_fallback_command() {
    log_test "push fallback: KAPSIS_REMOTE_BRANCH env var is honored"
    setup_sandbox
    trap teardown_sandbox RETURN

    git -C "$CLONE" remote set-url origin "/nonexistent/path.git"
    echo "edit" >> "$CLONE/README.md"

    # Use the KAPSIS_REMOTE_BRANCH env var — distinct from local branch name.
    # run_post_exit prepends $KAPSIS_ENV_PREFIX to the command.
    KAPSIS_ENV_PREFIX="KAPSIS_REMOTE_BRANCH='claude/remote-name' KAPSIS_DO_PUSH=true " \
        run_post_exit "feature/work" "feat: local-to-remote mapping" origin "false"

    assert_equals 1 "$CAPTURED_EXIT_CODE" "Push failure must exit 1"
    assert_contains "$CAPTURED_STDOUT" "KAPSIS_PUSH_FALLBACK: git push origin feature/work:claude/remote-name" \
        "Fallback command must contain remote-branch from env var"
}

test_env_do_push_overrides_positional_false() {
    log_test "env KAPSIS_DO_PUSH=true overrides positional do_push=false"
    setup_sandbox
    trap teardown_sandbox RETURN

    echo "env-push" > "$CLONE/env.txt"

    KAPSIS_ENV_PREFIX="KAPSIS_DO_PUSH=true " \
        run_post_exit "feature/work" "chore: env override" origin "false"

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must succeed against bare upstream"
    assert_contains "$CAPTURED_STDOUT" "PUSHING TO REMOTE" \
        "Env var must turn on the push path even when arg says false"
}

#===============================================================================
# ARG VALIDATION
#===============================================================================

test_missing_branch_arg_fails() {
    log_test "arg validation: missing branch argument exits non-zero"
    setup_sandbox
    trap teardown_sandbox RETURN

    capture_output "WORKSPACE='$CLONE' bash '$POST_EXIT_SCRIPT'"
    if [[ "$CAPTURED_EXIT_CODE" -eq 0 ]]; then
        _log_failure "Expected non-zero exit with missing branch arg"
        return 1
    fi
    assert_contains "$CAPTURED_STDERR" "Branch name required" \
        "Error must name the missing arg"
}

test_missing_commit_msg_fails() {
    log_test "arg validation: missing commit message exits non-zero"
    setup_sandbox
    trap teardown_sandbox RETURN

    capture_output "WORKSPACE='$CLONE' bash '$POST_EXIT_SCRIPT' feature/work"
    if [[ "$CAPTURED_EXIT_CODE" -eq 0 ]]; then
        _log_failure "Expected non-zero exit with missing commit message"
        return 1
    fi
    assert_contains "$CAPTURED_STDERR" "Commit message required" \
        "Error must name the missing arg"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "post-exit-git.sh"

    run_test test_clean_tree_is_noop
    run_test test_commits_tracked_changes
    run_test test_commits_untracked_new_file
    run_test test_switches_branch_when_mismatched
    run_test test_push_succeeds_against_real_upstream
    run_test test_push_fallback_on_failure_emits_sentinel_and_exits_1
    run_test test_custom_remote_branch_in_fallback_command
    run_test test_env_do_push_overrides_positional_false
    run_test test_missing_branch_arg_fails
    run_test test_missing_commit_msg_fails

    print_summary
}

main "$@"
