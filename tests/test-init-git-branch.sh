#!/usr/bin/env bash
#===============================================================================
# Test: init-git-branch.sh
#
# Covers the branch-init logic invoked on every agent launch:
#   - Creating a new branch when the remote branch does not exist
#   - Creating from an explicit base branch (Fix #116)
#   - Gracefully falling back when the requested base ref is missing
#   - Checking out + tracking an existing remote branch
#   - Honoring a custom remote-branch name different from the local name
#
# Strategy: build a throwaway local bare repo to act as "origin", clone it,
# set WORKSPACE to the clone, and invoke init-git-branch.sh as a subprocess.
#
# Category: git
# Container required: No
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

INIT_GIT_SCRIPT="$KAPSIS_ROOT/scripts/init-git-branch.sh"

# Per-test git sandboxes
SANDBOX=""
UPSTREAM=""
CLONE=""

setup_sandbox() {
    SANDBOX=$(mktemp -d -t kapsis-init-git-XXXXXX)
    UPSTREAM="$SANDBOX/upstream.git"
    CLONE="$SANDBOX/clone"

    # Create a bare upstream repo with one commit on `main`. Explicitly set
    # the HEAD symbolic ref so `git clone` picks up main as the default branch
    # regardless of the host's init.defaultBranch setting.
    git init -q --bare -b main "$UPSTREAM" 2>/dev/null || git init -q --bare "$UPSTREAM"
    git -C "$UPSTREAM" symbolic-ref HEAD refs/heads/main

    local seed="$SANDBOX/seed"
    git init -q -b main "$seed" 2>/dev/null || { git init -q "$seed" && git -C "$seed" checkout -q -b main; }
    (
        cd "$seed"
        git config user.email "t@k.local"
        git config user.name  "t"
        git config commit.gpgsign false
        echo "hello" > README.md
        git add README.md
        git commit -q -m "init"
        git remote add origin "$UPSTREAM"
        git push -q origin main
    )

    # Clone the upstream — explicit -b main handles older git defaults
    git clone -q -b main "$UPSTREAM" "$CLONE"
    (
        cd "$CLONE"
        git config user.email "t@k.local"
        git config user.name  "t"
        git config commit.gpgsign false
    )
}

teardown_sandbox() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    SANDBOX=""
    UPSTREAM=""
    CLONE=""
}

# run_init <branch> [remote] [base-branch] [remote-branch]
# Runs init-git-branch.sh with WORKSPACE pointing at the clone. Args are quoted
# individually so empty strings are preserved (capture_output → eval would
# otherwise collapse them).
run_init() {
    local args=""
    local a
    for a in "$@"; do
        # Quote with single quotes; embedded single quotes would need escaping
        # but none of our test inputs contain them.
        args+=" '$a'"
    done
    capture_output "WORKSPACE='$CLONE' bash '$INIT_GIT_SCRIPT'${args}"
}

# Returns the current branch name of the clone
current_branch() {
    git -C "$CLONE" rev-parse --abbrev-ref HEAD
}

#===============================================================================
# NEW BRANCH — remote branch does NOT exist
#===============================================================================

test_creates_new_branch_from_head_when_remote_missing() {
    log_test "new branch: created from current HEAD when remote absent"
    setup_sandbox
    trap teardown_sandbox RETURN

    run_init feature/new-work

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must exit 0"
    assert_contains "$CAPTURED_STDOUT" "CREATING NEW BRANCH" \
        "Should print CREATING NEW BRANCH banner"
    assert_equals "feature/new-work" "$(current_branch)" \
        "Clone must be on the new local branch"
}

test_creates_new_branch_from_explicit_base() {
    log_test "new branch: explicit base-branch is honored (Fix #116)"
    setup_sandbox
    trap teardown_sandbox RETURN

    # Create a second remote branch `release/v1` with a known commit
    (
        cd "$CLONE"
        git checkout -q -b release/v1
        echo "v1" > VERSION
        git add VERSION
        git commit -q -m "v1"
        git push -q origin release/v1
        git checkout -q main
    )

    run_init feature/on-v1 origin release/v1

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must exit 0"
    assert_contains "$CAPTURED_STDOUT" "Base: release/v1" \
        "Banner should name the chosen base ref"
    assert_equals "feature/on-v1" "$(current_branch)" \
        "Clone must be on the new branch"
    # The VERSION file from release/v1 should be present in the working tree
    if [[ ! -f "$CLONE/VERSION" ]]; then
        _log_failure "VERSION file missing — new branch was not created from release/v1"
        return 1
    fi
}

test_missing_base_falls_back_to_head() {
    log_test "new branch: missing base ref warns and falls back to HEAD"
    setup_sandbox
    trap teardown_sandbox RETURN

    run_init feature/fallback origin does-not-exist

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must still exit 0 after fallback"
    assert_contains "$CAPTURED_STDOUT" "Base ref 'does-not-exist' not found" \
        "Should warn about missing base"
    assert_equals "feature/fallback" "$(current_branch)" \
        "Clone must be on the requested branch (created from HEAD)"
}

#===============================================================================
# EXISTING REMOTE BRANCH — checkout + track
#===============================================================================

test_tracks_existing_remote_branch() {
    log_test "existing remote: checks out local branch tracking remote"
    setup_sandbox
    trap teardown_sandbox RETURN

    # Seed an existing remote branch with unique content
    (
        cd "$CLONE"
        git checkout -q -b feature/already-there
        echo "existing" > EXISTING.md
        git add EXISTING.md
        git commit -q -m "seed"
        git push -q origin feature/already-there
        # Go back to main and DELETE the local branch so the script must
        # re-create it from the remote
        git checkout -q main
        git branch -qD feature/already-there
    )

    run_init feature/already-there

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must exit 0"
    assert_contains "$CAPTURED_STDOUT" "CONTINUING FROM EXISTING REMOTE BRANCH" \
        "Should print CONTINUING banner"
    assert_equals "feature/already-there" "$(current_branch)" \
        "Clone must be on the re-created local branch"
    assert_file_exists "$CLONE/EXISTING.md" \
        "Remote branch contents must be present"
}

test_distinct_local_and_remote_branch_names() {
    log_test "custom remote-branch: local name != remote name is supported"
    setup_sandbox
    trap teardown_sandbox RETURN

    # Seed a remote branch called 'upstream/weird-name' (literal branch name)
    (
        cd "$CLONE"
        git checkout -q -b upstream-weird-name
        echo "u" > UPSTREAM_FILE
        git add UPSTREAM_FILE
        git commit -q -m "seed"
        git push -q origin upstream-weird-name
        git checkout -q main
        git branch -qD upstream-weird-name
    )

    # local BRANCH = claude/my-work, REMOTE_BRANCH = upstream-weird-name
    run_init "claude/my-work" origin "" "upstream-weird-name"

    assert_equals 0 "$CAPTURED_EXIT_CODE" "Must exit 0"
    assert_contains "$CAPTURED_STDOUT" "CONTINUING FROM EXISTING REMOTE BRANCH" \
        "Should print CONTINUING banner (remote branch exists under a different name)"
    assert_equals "claude/my-work" "$(current_branch)" \
        "Clone must be on the requested local name"
    assert_file_exists "$CLONE/UPSTREAM_FILE" \
        "Remote branch's content must be checked out"
}

#===============================================================================
# ARG VALIDATION
#===============================================================================

test_missing_branch_argument_fails() {
    log_test "arg validation: missing branch argument exits non-zero"
    setup_sandbox
    trap teardown_sandbox RETURN

    # Call with NO branch argument
    capture_output "WORKSPACE='$CLONE' bash '$INIT_GIT_SCRIPT'"
    if [[ "$CAPTURED_EXIT_CODE" -eq 0 ]]; then
        _log_failure "Expected non-zero exit when branch argument is missing"
        return 1
    fi
    assert_contains "$CAPTURED_STDERR" "Branch name required" \
        "Should produce the documented error"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "init-git-branch.sh"

    run_test test_creates_new_branch_from_head_when_remote_missing
    run_test test_creates_new_branch_from_explicit_base
    run_test test_missing_base_falls_back_to_head
    run_test test_tracks_existing_remote_branch
    run_test test_distinct_local_and_remote_branch_names
    run_test test_missing_branch_argument_fails

    print_summary
}

main "$@"
