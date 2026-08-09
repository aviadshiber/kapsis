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

# --- Task 1: GIT_DIR export in worktree mode ---
# CONTAINER_GIT_PATH is a readonly constant (/workspace/.git-safe), so we cannot
# exercise setup_worktree_git against a temp dir on the host. The bug was in the
# DISPATCH (short-circuiting the call away), so guard that via source inspection.

test_dispatch_calls_setup_worktree_git_not_shortcircuit() {
    assert_file_not_contains "$ENTRYPOINT" '== "worktree" ]] || setup_worktree_git' \
        "dispatch must not short-circuit setup_worktree_git away in worktree mode"
    assert_file_contains "$ENTRYPOINT" 'setup_worktree_git || log_warn' \
        "worktree branch must call setup_worktree_git explicitly"
}

test_setup_worktree_git_still_exports_gitdir() {
    # The function that makes in-container git work must still export GIT_DIR
    # to the mounted sanitized .git-safe.
    assert_file_contains "$ENTRYPOINT" 'export GIT_DIR="${CONTAINER_GIT_PATH}"' \
        "setup_worktree_git must export GIT_DIR to the sanitized git dir"
}

test_entrypoint_main_is_source_guarded() {
    # Needed so unit tests can source the script without running the container.
    assert_file_contains "$ENTRYPOINT" 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then' \
        "main must be guarded so the file is sourceable in tests"
}

# --- Task 2: sanitized git mounted read-write ---

test_sanitized_git_mounted_rw() {
    # generate_volume_mounts_worktree calls add_common_volume_mounts, which needs
    # many run-time globals, so assert on the source: the sanitized git mount must
    # NOT carry :ro (agent must be able to commit), while the objects DB stays :ro.
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
    run_test test_dispatch_calls_setup_worktree_git_not_shortcircuit
    run_test test_setup_worktree_git_still_exports_gitdir
    run_test test_entrypoint_main_is_source_guarded
    run_test test_sanitized_git_mounted_rw
    print_summary
}
main "$@"
