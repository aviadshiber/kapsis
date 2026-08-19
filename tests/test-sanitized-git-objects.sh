#!/usr/bin/env bash
#===============================================================================
# Tests for Sanitized Git Objects (writable dir + alternate) — Architecture B.
#
# The sanitized-git objects store is a WRITABLE local dir that borrows the parent
# object DB read-only via objects/info/alternates (so in-container `git commit`
# can write new objects). After container exit the host re-points the alternate
# from the container path (/workspace/.git-objects) to the host objects path.
#
# Exercises the production repoint_sanitized_git_objects() (launch-agent.sh) and
# _prepare_objects_alternate() (worktree-manager.sh).
#
# Run: ./tests/test-sanitized-git-objects.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"
source "$LIB_DIR/constants.sh"

# Logging stubs expected by the extracted production functions
if ! type log_debug &>/dev/null; then
    log_debug() { :; }
    log_warn() { echo "[WARN] $*" >&2; }
fi
# Extract the production functions under test (avoids sourcing whole scripts)
eval "$(sed -n '/^repoint_sanitized_git_objects()/,/^}/p' "$KAPSIS_ROOT/scripts/launch-agent.sh")"
eval "$(sed -n '/^_prepare_objects_alternate()/,/^}/p' "$KAPSIS_ROOT/scripts/worktree-manager.sh")"
eval "$(sed -n '/^_neutralize_sanitized_git_hooks()/,/^}/p' "$KAPSIS_ROOT/scripts/launch-agent.sh")"

_alt() { cat "$1/objects/info/alternates" 2>/dev/null; }  # read alternate line

setup_test_env() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/project/.git/objects/pack"
    echo "test-object" > "$TEST_DIR/project/.git/objects/test.obj"
    # sanitized git dir with a container-path alternate (as prepared in-container)
    mkdir -p "$TEST_DIR/sanitized-git/abc123"
    _prepare_objects_alternate "$TEST_DIR/sanitized-git/abc123" "$CONTAINER_OBJECTS_PATH"
}
cleanup_test_env() { [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"; TEST_DIR=""; }

#=== prepare: objects is a writable dir + alternate (not a symlink) ============
test_prepare_creates_writable_objects_with_alternate() {
    log_test "prepare: objects is a writable dir with an alternate (not a symlink)"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    assert_dir_exists "$sg/objects" "objects must be a real directory"
    assert_true "[[ ! -L \"$sg/objects\" ]]" "objects must NOT be a symlink"
    assert_dir_exists "$sg/objects/pack" "objects/pack must exist for new packs"
    assert_equals "$CONTAINER_OBJECTS_PATH" "$(_alt "$sg")" "alternate points at parent objects"
    cleanup_test_env
}

#=== functional: in-container commit writes objects locally, parent stays RO ===
test_in_container_commit_writes_locally() {
    log_test "functional: commit via alternate writes new objects locally"
    local root; root=$(mktemp -d)
    ( cd "$root"; git init -q parent && cd parent && git config user.email a@b.c \
        && git config user.name a && echo hello > f && git add f && git commit -qm base )
    local parent_obj="$root/parent/.git/objects"
    mkdir -p "$root/sg/refs/heads"; printf 'ref: refs/heads/main\n' > "$root/sg/HEAD"
    _prepare_objects_alternate "$root/sg" "$parent_obj"
    chmod -R a-w "$parent_obj"                    # parent objects read-only
    mkdir -p "$root/wt"; echo world > "$root/wt/g"
    local rc=0
    GIT_DIR="$root/sg" GIT_WORK_TREE="$root/wt" git add g >/dev/null 2>&1 || rc=$?
    GIT_DIR="$root/sg" GIT_WORK_TREE="$root/wt" \
        git -c user.email=a@b.c -c user.name=a commit -qm "in-sandbox" >/dev/null 2>&1 || rc=$?
    chmod -R u+w "$parent_obj" 2>/dev/null || true
    assert_equals "0" "$rc" "commit against RO parent (via alternate) must succeed"
    local n
    n=$(find "$root/sg/objects" -type f \( -name '*.pack' -o -path '*/[0-9a-f][0-9a-f]/*' \) 2>/dev/null | wc -l | tr -d ' ')
    assert_true "[[ $n -ge 1 ]]" "new commit objects must land in the local objects dir"
    rm -rf "$root"
}

#=== repoint: rewrite the alternate from container path to host path ===========
test_repoint_rewrites_alternate_to_host() {
    log_test "repoint: alternate rewritten container-path -> host-path"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"
    assert_equals "$CONTAINER_OBJECTS_PATH" "$(_alt "$sg")" "before: container path"
    repoint_sanitized_git_objects "$sg" "$host_objects"
    assert_equals "$host_objects" "$(_alt "$sg")" "after: host objects path"
    cleanup_test_env
}

test_repoint_idempotent() {
    log_test "repoint: idempotent when alternate already host path"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"
    repoint_sanitized_git_objects "$sg" "$host_objects"
    repoint_sanitized_git_objects "$sg" "$host_objects"
    assert_equals "$host_objects" "$(_alt "$sg")" "stays host objects path"
    cleanup_test_env
}

test_fallback_to_kapsis_meta() {
    log_test "repoint: falls back to HOST_OBJECTS_PATH from kapsis-meta"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"
    cat > "$sg/kapsis-meta" << EOF
AGENT_ID=abc123
BRANCH=test-branch
HOST_OBJECTS_PATH=$host_objects
EOF
    repoint_sanitized_git_objects "$sg" ""
    assert_equals "$host_objects" "$(_alt "$sg")" "alternate from kapsis-meta"
    cleanup_test_env
}

#=== guard conditions =========================================================
test_skip_when_no_sanitized_git() {
    log_test "repoint: skip when sanitized git dir missing"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    repoint_sanitized_git_objects "/nonexistent/path" "$TEST_DIR/project/.git/objects"
    assert_equals "$CONTAINER_OBJECTS_PATH" "$(_alt "$sg")" "unchanged when target missing"
    cleanup_test_env
}

test_skip_when_no_objects_path() {
    log_test "repoint: skip when objects_path empty and no kapsis-meta"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    repoint_sanitized_git_objects "$sg" ""
    assert_equals "$CONTAINER_OBJECTS_PATH" "$(_alt "$sg")" "unchanged when objects_path empty"
    cleanup_test_env
}

#=== legacy symlink still handled =============================================
test_repoint_legacy_symlink() {
    log_test "repoint: legacy symlink form still re-pointed"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"
    rm -rf "$sg/objects"; ln -sfn "$CONTAINER_OBJECTS_PATH" "$sg/objects"
    repoint_sanitized_git_objects "$sg" "$host_objects"
    assert_equals "$host_objects" "$(readlink "$sg/objects")" "legacy symlink re-pointed to host"
    cleanup_test_env
}

#=== security: repoint refuses symlinked info/ (no host-file clobber) =========
test_repoint_refuses_symlinked_info() {
    log_test "repoint: symlinked objects/info is refused (no clobber of host file)"
    setup_test_env
    local sg="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"
    # Agent replaces objects/info with a symlink to a sensitive host file.
    local victim="$TEST_DIR/victim.txt"; echo "PRECIOUS" > "$victim"
    rm -rf "$sg/objects/info"; ln -sfn "$TEST_DIR" "$sg/objects/info"
    # Point the (symlinked) alternates target at the victim so a naive `>` clobbers it.
    ln -sfn "$victim" "$sg/objects/info/alternates" 2>/dev/null || true
    repoint_sanitized_git_objects "$sg" "$host_objects"
    assert_file_contains "$victim" "PRECIOUS" "host file must NOT be clobbered via symlinked info/"
    cleanup_test_env
}

#=== security: neutralize agent-planted hooks/config before host git ops =======
test_neutralize_removes_planted_hooks_and_hookspath() {
    log_test "neutralize: strips planted hooks + core.hooksPath from sanitized dir"
    local sg; sg=$(mktemp -d)
    mkdir -p "$sg/hooks"
    printf '#!/bin/sh\necho pwned\n' > "$sg/hooks/pre-commit"; chmod +x "$sg/hooks/pre-commit"
    git config --file "$sg/config" core.hooksPath /evil 2>/dev/null || printf '[core]\n\thooksPath = /evil\n' > "$sg/config"
    _neutralize_sanitized_git_hooks "$sg"
    assert_file_not_exists "$sg/hooks/pre-commit" "planted hook must be removed"
    local hp; hp=$(git config --file "$sg/config" --get core.hooksPath 2>/dev/null || echo "")
    assert_equals "" "$hp" "core.hooksPath must be unset"
    rm -rf "$sg"
}

#=== metadata =================================================================
test_kapsis_meta_written_by_production() {
    log_test "prepare writes HOST_OBJECTS_PATH to kapsis-meta"
    local wm_source="$KAPSIS_ROOT/scripts/worktree-manager.sh"
    local grep_result
    grep_result=$(grep "HOST_OBJECTS_PATH=" "$wm_source" 2>/dev/null || echo "")
    assert_contains "$grep_result" "HOST_OBJECTS_PATH=" "worktree-manager.sh writes HOST_OBJECTS_PATH"
    assert_contains "$grep_result" '.git/objects' "HOST_OBJECTS_PATH references .git/objects"
}

main() {
    print_test_header "Sanitized Git Objects (writable dir + alternate)"

    log_info "=== Prepare + functional commit ==="
    run_test test_prepare_creates_writable_objects_with_alternate
    run_test test_in_container_commit_writes_locally

    log_info "=== Alternate re-pointing ==="
    run_test test_repoint_rewrites_alternate_to_host
    run_test test_repoint_idempotent
    run_test test_fallback_to_kapsis_meta
    run_test test_repoint_legacy_symlink

    log_info "=== Guard Conditions ==="
    run_test test_skip_when_no_sanitized_git
    run_test test_skip_when_no_objects_path

    log_info "=== Security hardening ==="
    run_test test_repoint_refuses_symlinked_info
    run_test test_neutralize_removes_planted_hooks_and_hookspath

    log_info "=== Metadata ==="
    run_test test_kapsis_meta_written_by_production

    print_summary
}

main "$@"
