#!/usr/bin/env bash
# Tests for worktree-mode in-container git: GIT_DIR export + rw sanitized mount.
# Architecture B (designs/2026-08-09-worktree-in-container-push-design.md).
set -uo pipefail
# shellcheck disable=SC2016  # single-quoted ${...} are intentional literal source-match patterns
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/lib/test-framework.sh"

ENTRYPOINT="$KAPSIS_ROOT/scripts/entrypoint.sh"
LAUNCH="$KAPSIS_ROOT/scripts/launch-agent.sh"

# Exercise setup_worktree_git for real against a temp CONTAINER_GIT_PATH. The real
# constant is readonly (= /workspace/.git-safe, absent on the host) and
# test-framework.sh already sourced constants.sh, so we run the function in a fresh
# bash subprocess where CONTAINER_GIT_PATH is not readonly. Prints "rc=<n> gitdir=<GIT_DIR>".
_run_setup_worktree_git() {
    local cgp="$1"
    bash -c '
        log_debug(){ :; }; log_info(){ :; }; log_warn(){ :; }
        CONTAINER_GIT_PATH="'"$cgp"'"
        eval "$(sed -n "/^setup_worktree_git()/,/^}/p" "'"$ENTRYPOINT"'")"
        GIT_DIR=""
        setup_worktree_git; rc=$?
        printf "rc=%s gitdir=%s\n" "$rc" "${GIT_DIR:-}"
    '
}

# --- Task 1 (functional): setup_worktree_git exports GIT_DIR ---

test_setup_worktree_git_exports_gitdir_when_meta_present() {
    local d; d=$(mktemp -d); mkdir -p "$d/gitsafe"
    printf 'BRANCH=feature/x\n' > "$d/gitsafe/kapsis-meta"
    local out; out=$(_run_setup_worktree_git "$d/gitsafe")
    assert_equals "rc=0 gitdir=$d/gitsafe" "$out" "GIT_DIR exported to sanitized .git-safe (rc=0)"
    rm -rf "$d"
}

test_setup_worktree_git_returns_nonzero_without_meta() {
    local d; d=$(mktemp -d); mkdir -p "$d/gitsafe"  # no kapsis-meta
    local out; out=$(_run_setup_worktree_git "$d/gitsafe")
    assert_equals "rc=1 gitdir=" "$out" "returns non-zero + GIT_DIR unset when kapsis-meta absent"
    rm -rf "$d"
}

# --- Task 1 (regression guard): dispatch must CALL setup_worktree_git ---
# The bug was the dispatch short-circuiting the call away in worktree mode; guard
# the exact buggy/fixed wording so a refactor can't silently reintroduce it.

test_dispatch_calls_setup_worktree_git_not_shortcircuit() {
    assert_file_not_contains "$ENTRYPOINT" '== "worktree" ]] || setup_worktree_git' \
        "dispatch must not short-circuit setup_worktree_git away in worktree mode"
    assert_file_contains "$ENTRYPOINT" 'setup_worktree_git || log_warn' \
        "worktree branch must call setup_worktree_git explicitly"
}

test_entrypoint_main_is_source_guarded() {
    assert_file_contains "$ENTRYPOINT" 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then' \
        "main must be guarded so the file is sourceable in tests"
}

# --- Task 2: sanitized git mounted read-write ---

test_sanitized_git_mounted_rw() {
    local body
    body=$(awk '/^generate_volume_mounts_worktree\(\)/{f=1} f{print} f&&/^}/{exit}' "$LAUNCH")
    assert_contains "$body" '${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}"' \
        "sanitized git must be mounted read-write (no :ro)"
    assert_not_contains "$body" '${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}:ro"' \
        "sanitized git must NOT be mounted :ro"
    assert_contains "$body" '${OBJECTS_PATH}:${CONTAINER_OBJECTS_PATH}:ro"' \
        "objects DB must stay read-only"
}

main() {
    run_test test_setup_worktree_git_exports_gitdir_when_meta_present
    run_test test_setup_worktree_git_returns_nonzero_without_meta
    run_test test_dispatch_calls_setup_worktree_git_not_shortcircuit
    run_test test_entrypoint_main_is_source_guarded
    run_test test_sanitized_git_mounted_rw
    print_summary
}
main "$@"
