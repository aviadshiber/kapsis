#!/usr/bin/env bash
#===============================================================================
# Test: Cleanup --vm-health behaviors (Issue #243)
#
# Verifies the fixes from issue #243:
#   1. `--vm-health` and other explicit action flags skip the unconditional
#      default cleanups (worktrees/sandboxes/status/sanitized-git/audit).
#   2. Bare invocation (no flags) still runs defaults (backward compat).
#   3. `--all` still runs everything.
#   4. `get_dir_size()` survives permission errors (`chmod 000`) without
#      tripping `set -euo pipefail`.
#   5. `get_dir_size()` survives `du` hanging on stale mounts (timeout
#      wrapper + fallback to 0).
#   6. `clean_sandboxes()` skips symlinks to prevent symlink-following
#      attacks (a symlink pointing at / must not be followed by rm -rf).
#
# Category: validation
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

#===============================================================================
# Static-content assertions on kapsis-cleanup.sh
#===============================================================================

test_explicit_action_requested_variable_declared() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "explicit_action_requested=false" \
        "main() should declare explicit_action_requested=false"
}

test_explicit_action_requested_set_by_action_flags() {
    # Each of these flags must set explicit_action_requested=true so that
    # the default cleanup block is suppressed when they are used in isolation.
    local content
    content=$(cat "$CLEANUP_SCRIPT")

    # We require explicit_action_requested=true to appear at least once
    # per action flag. We verify by checking that the case branch block
    # for each flag contains the assignment.
    local flags=(
        "--all"
        "--volumes"
        "--images"
        "--containers"
        "--logs"
        "--ssh-cache"
        "--branches"
        "--worktrees"
        "--vm-health"
    )

    for flag in "${flags[@]}"; do
        # Extract the case-branch body for this flag using awk.
        local branch
        branch=$(awk -v pat="$flag)" '
            $0 ~ pat {capture=1; next}
            capture && /;;/ {capture=0}
            capture {print}
        ' "$CLEANUP_SCRIPT")
        assert_contains "$branch" "explicit_action_requested=true" \
            "Branch for $flag should set explicit_action_requested=true"
    done
}

test_default_cleanups_gated_on_explicit_action_requested() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    # The refactor replaces unconditional defaults with a guarded block. The
    # guard must check explicit_action_requested AND preserve the --all escape
    # hatch so `--all` still runs everything.
    # shellcheck disable=SC2016 # literal substring match, not expansion
    assert_contains "$content" '"$explicit_action_requested" != "true"' \
        "Default cleanup block should be guarded on explicit_action_requested"
    # shellcheck disable=SC2016
    assert_contains "$content" '"$CLEAN_ALL" == "true"' \
        "Default cleanup guard should still honor --all"
}

test_get_dir_size_uses_timeout_wrapper() {
    # The timeout-binary selection is delegated to `_du_timeout_cmd`, which
    # emits "timeout $DU_TIMEOUT_SECS" on Linux and "gtimeout $DU_TIMEOUT_SECS"
    # on macOS (when coreutils is installed). get_dir_size calls that helper
    # and runs the resulting command in front of `du -sk`.
    local content
    content=$(cat "$CLEANUP_SCRIPT")

    assert_contains "$content" "readonly DU_TIMEOUT_SECS=" \
        "DU_TIMEOUT_SECS constant must be declared"
    assert_contains "$content" "_du_timeout_cmd()" \
        "_du_timeout_cmd helper must be defined"
    assert_contains "$content" 'echo "timeout $DU_TIMEOUT_SECS"' \
        "_du_timeout_cmd should emit a 'timeout' command on Linux"
    assert_contains "$content" 'echo "gtimeout $DU_TIMEOUT_SECS"' \
        "_du_timeout_cmd should prefer 'gtimeout' on macOS when available"
    assert_contains "$content" 'timeout_cmd=$(_du_timeout_cmd)' \
        "get_dir_size must resolve the timeout binary via _du_timeout_cmd"
    assert_contains "$content" '$timeout_cmd du -sk' \
        "get_dir_size must invoke du through the timeout wrapper when available"
}

test_get_dir_size_handles_pipeline_failure() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    # The fix depends on `|| kb=0` to keep set -e happy when the pipeline
    # returns non-zero (pipefail + du permission-denied).
    assert_contains "$content" "| cut -f1) || kb=0" \
        "get_dir_size must fall back to kb=0 on pipeline failure"
}

test_symlink_guard_in_clean_sandboxes() {
    # The guard appears immediately after the [[ -d "$sandbox" ]] check in the
    # sandbox loop of clean_sandboxes(). Capture the lines between the loop
    # header and the first `basename` call and look for the symlink guard.
    local snippet
    snippet=$(awk '/for sandbox in/ {capture=1} capture {print} capture && /basename/ {capture=0}' "$CLEANUP_SCRIPT")
    # shellcheck disable=SC2016 # literal substring match, not expansion
    assert_contains "$snippet" '[[ -L "$sandbox" ]] && continue' \
        "clean_sandboxes should skip symlinks to prevent symlink-following attacks"
}

test_symlink_guard_in_clean_worktrees() {
    # Same attack vector exists in clean_worktrees() -- rm -rf runs on entries
    # under $WORKTREE_DIR that pass [[ -d ]]. A symlink must be skipped.
    local snippet
    snippet=$(awk '/for worktree in/ {capture=1} capture {print} capture && /basename/ {capture=0}' "$CLEANUP_SCRIPT")
    # shellcheck disable=SC2016
    assert_contains "$snippet" '[[ -L "$worktree" ]] && continue' \
        "clean_worktrees should skip symlinks to prevent symlink-following attacks"
}

test_symlink_guard_in_clean_sanitized_git() {
    # Same attack vector in clean_sanitized_git() -- rm -rf runs on entries
    # under $SANITIZED_GIT_DIR that pass [[ -d ]]. A symlink must be skipped.
    local snippet
    snippet=$(awk '/for git_dir in/ {capture=1} capture {print} capture && /basename/ {capture=0}' "$CLEANUP_SCRIPT")
    # shellcheck disable=SC2016
    assert_contains "$snippet" '[[ -L "$git_dir" ]] && continue' \
        "clean_sanitized_git should skip symlinks to prevent symlink-following attacks"
}

#===============================================================================
# Behavioral runtime tests (no container)
#===============================================================================

# Helper: invoke kapsis-cleanup.sh with cleanup functions stubbed out, so we
# can observe which ones ran based on marker files. We load the script into a
# fresh bash subprocess, suppress its automatic `main "$@"` invocation (via
# sed), apply stubs that overwrite each real cleanup function, then call main
# ourselves with the desired args.
_invoke_cleanup() {
    # $1 = marker dir, rest = kapsis-cleanup.sh args
    local marker_dir="$1"
    shift

    local stub_file="$marker_dir/stubs.sh"
    cat > "$stub_file" <<'STUBS'
# Stub out every cleanup function so we can observe which ones ran.
clean_worktrees()      { touch "$MARKER_DIR/clean_worktrees"; }
clean_sandboxes()      { touch "$MARKER_DIR/clean_sandboxes"; }
clean_status()         { touch "$MARKER_DIR/clean_status"; }
clean_sanitized_git()  { touch "$MARKER_DIR/clean_sanitized_git"; }
clean_audit()          { touch "$MARKER_DIR/clean_audit"; }
clean_containers()     { touch "$MARKER_DIR/clean_containers"; }
clean_volumes()        { touch "$MARKER_DIR/clean_volumes"; }
clean_images()         { touch "$MARKER_DIR/clean_images"; }
clean_logs()           { touch "$MARKER_DIR/clean_logs"; }
clean_ssh_cache()      { touch "$MARKER_DIR/clean_ssh_cache"; }
clean_branches()       { touch "$MARKER_DIR/clean_branches"; }
vm_health_check()      { touch "$MARKER_DIR/vm_health_check"; }
print_summary()        { :; }
# Swallow confirmation prompts (FORCE is already true for our tests).
confirm()              { return 0; }
STUBS

    # Run the script in a fresh bash. We inject stubs by trapping DEBUG to
    # redefine functions after the script defines them but before main()
    # executes. Simpler: use `source`-then-invoke after redefining.
    #
    # The cleanest approach is to source the script with a "__source_only__"
    # guard check, but the script doesn't have one. So we:
    #   1. Read the script up to the `main "$@"` line,
    #   2. Replace `main "$@"` with nothing,
    #   3. Source the modified text,
    #   4. Apply stubs,
    #   5. Invoke main with our args.
    MARKER_DIR="$marker_dir" FORCE=true bash -c '
        set +e
        # Load script body without executing main at the end.
        script_body=$(sed "s|^main \"\\\$@\"$|# main invocation suppressed|" "'"$CLEANUP_SCRIPT"'")
        # shellcheck disable=SC1090
        source /dev/stdin <<< "$script_body"
        # Apply stubs that override the real cleanup functions.
        source "'"$stub_file"'"
        # Run main with caller-provided args.
        main "$@"
    ' -- "$@" >/dev/null 2>&1 || true
}

test_bare_invocation_runs_defaults() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-bare.XXXXXX")

    _invoke_cleanup "$marker_dir" --dry-run

    assert_file_exists "$marker_dir/clean_worktrees"     "clean_worktrees should run on bare invocation"
    assert_file_exists "$marker_dir/clean_sandboxes"     "clean_sandboxes should run on bare invocation"
    assert_file_exists "$marker_dir/clean_status"        "clean_status should run on bare invocation"
    assert_file_exists "$marker_dir/clean_sanitized_git" "clean_sanitized_git should run on bare invocation"
    assert_file_exists "$marker_dir/clean_audit"         "clean_audit should run on bare invocation"

    rm -rf "$marker_dir"
}

test_vm_health_alone_skips_defaults() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-vm.XXXXXX")

    _invoke_cleanup "$marker_dir" --vm-health --dry-run

    assert_file_exists     "$marker_dir/vm_health_check"     "--vm-health should invoke vm_health_check"
    assert_file_not_exists "$marker_dir/clean_worktrees"     "--vm-health alone must NOT trigger clean_worktrees"
    assert_file_not_exists "$marker_dir/clean_sandboxes"     "--vm-health alone must NOT trigger clean_sandboxes"
    assert_file_not_exists "$marker_dir/clean_status"        "--vm-health alone must NOT trigger clean_status"
    assert_file_not_exists "$marker_dir/clean_sanitized_git" "--vm-health alone must NOT trigger clean_sanitized_git"
    assert_file_not_exists "$marker_dir/clean_audit"         "--vm-health alone must NOT trigger clean_audit"

    rm -rf "$marker_dir"
}

test_containers_flag_alone_skips_defaults() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-c.XXXXXX")

    _invoke_cleanup "$marker_dir" --containers --force --dry-run

    assert_file_exists     "$marker_dir/clean_containers"    "--containers should invoke clean_containers"
    assert_file_not_exists "$marker_dir/clean_worktrees"     "--containers alone must NOT trigger clean_worktrees"
    assert_file_not_exists "$marker_dir/clean_sandboxes"     "--containers alone must NOT trigger clean_sandboxes"
    assert_file_not_exists "$marker_dir/clean_audit"         "--containers alone must NOT trigger clean_audit"

    rm -rf "$marker_dir"
}

test_all_flag_still_runs_everything() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-all.XXXXXX")

    _invoke_cleanup "$marker_dir" --all --force --dry-run

    assert_file_exists "$marker_dir/clean_worktrees"     "--all should still run clean_worktrees"
    assert_file_exists "$marker_dir/clean_sandboxes"     "--all should still run clean_sandboxes"
    assert_file_exists "$marker_dir/clean_status"        "--all should still run clean_status"
    assert_file_exists "$marker_dir/clean_sanitized_git" "--all should still run clean_sanitized_git"
    assert_file_exists "$marker_dir/clean_audit"         "--all should still run clean_audit"
    assert_file_exists "$marker_dir/clean_containers"    "--all should still run clean_containers"
    assert_file_exists "$marker_dir/vm_health_check"     "--all should still run vm_health_check"

    rm -rf "$marker_dir"
}

# Regression: `--worktrees` alone must invoke clean_worktrees AND NOT run the
# rest of the default cleanup set. A prior refactor of this file introduced
# the case branch that flipped explicit_action_requested=true WITHOUT setting
# a CLEAN_WORKTREES flag, turning `--worktrees` into a silent no-op. Catch
# that class of bug in the future.
test_worktrees_flag_alone_runs_only_worktrees() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-wt.XXXXXX")

    _invoke_cleanup "$marker_dir" --worktrees --force --dry-run

    assert_file_exists     "$marker_dir/clean_worktrees"     "--worktrees alone MUST invoke clean_worktrees"
    assert_file_not_exists "$marker_dir/clean_sandboxes"     "--worktrees alone must NOT trigger clean_sandboxes"
    assert_file_not_exists "$marker_dir/clean_status"        "--worktrees alone must NOT trigger clean_status"
    assert_file_not_exists "$marker_dir/clean_sanitized_git" "--worktrees alone must NOT trigger clean_sanitized_git"
    assert_file_not_exists "$marker_dir/clean_audit"         "--worktrees alone must NOT trigger clean_audit"
    assert_file_not_exists "$marker_dir/clean_containers"    "--worktrees alone must NOT trigger clean_containers"
    assert_file_not_exists "$marker_dir/vm_health_check"     "--worktrees alone must NOT trigger vm_health_check"

    rm -rf "$marker_dir"
}

# Coverage: every individual action flag must invoke its own action and skip
# the default cleanup set. Parameterizes over the remaining flags not already
# covered by dedicated tests above.
test_each_action_flag_alone_skips_defaults() {
    local -A expected=(
        [--volumes]=clean_volumes
        [--images]=clean_images
        [--logs]=clean_logs
        [--ssh-cache]=clean_ssh_cache
        [--branches]=clean_branches
    )
    local flag marker_dir
    for flag in "${!expected[@]}"; do
        marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-${flag#--}.XXXXXX")
        _invoke_cleanup "$marker_dir" "$flag" --force --dry-run

        assert_file_exists     "$marker_dir/${expected[$flag]}"  "$flag should invoke ${expected[$flag]}"
        assert_file_not_exists "$marker_dir/clean_worktrees"     "$flag alone must NOT trigger clean_worktrees"
        assert_file_not_exists "$marker_dir/clean_sandboxes"     "$flag alone must NOT trigger clean_sandboxes"
        assert_file_not_exists "$marker_dir/clean_audit"         "$flag alone must NOT trigger clean_audit"

        rm -rf "$marker_dir"
    done
}

#===============================================================================
# get_dir_size() resilience under set -euo pipefail
#===============================================================================

# Source just get_dir_size() into a subshell and exercise it.
_get_dir_size() {
    # $1 = directory to measure, prints bytes or errors out.
    local dir="$1"
    bash -c '
        set -euo pipefail
        # Minimal env to source compat.sh then extract the timeout helper,
        # DU_TIMEOUT_SECS, and get_dir_size itself.
        source "'"$KAPSIS_ROOT"'/scripts/lib/compat.sh" 2>/dev/null || true
        eval "$(grep -E "^readonly DU_TIMEOUT_SECS=" "'"$CLEANUP_SCRIPT"'")"
        eval "$(sed -n "/^_du_timeout_cmd()/,/^}/p" "'"$CLEANUP_SCRIPT"'")"
        eval "$(sed -n "/^get_dir_size()/,/^}/p" "'"$CLEANUP_SCRIPT"'")"
        get_dir_size "$1"
    ' -- "$dir"
}

test_get_dir_size_survives_permission_denied() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-perm.XXXXXX")

    # Create an unreadable directory.
    local bad="$marker_dir/forbidden"
    mkdir -p "$bad/inner"
    chmod 000 "$bad"

    # Must NOT fail under set -euo pipefail. Should print 0 or some number
    # without raising an error.
    local output
    output=$(_get_dir_size "$bad" 2>&1) || {
        chmod 755 "$bad"
        rm -rf "$marker_dir"
        _log_failure "get_dir_size failed on chmod 000 dir" "Output: $output"
        return 1
    }

    # Restore perms before cleanup.
    chmod 755 "$bad"
    rm -rf "$marker_dir"

    # Output should be a non-negative integer (likely 0).
    if [[ ! "$output" =~ ^[0-9]+$ ]]; then
        _log_failure "get_dir_size output is not numeric" "Got: $output"
        return 1
    fi
    return 0
}

test_get_dir_size_survives_du_hang() {
    # Simulate `du` hanging by shadowing the timeout wrapper with a fake that
    # returns immediately with the "timed out" exit code (124). The `|| kb=0`
    # fallback must then kick in and print 0.
    #
    # We mock BOTH `timeout` (Linux) and `gtimeout` (macOS + coreutils) so the
    # test is deterministic across platforms. We also extract `_du_timeout_cmd`
    # alongside `get_dir_size` so the helper resolves inside the subshell.

    local mock_dir
    mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-hang.XXXXXX")

    # Fake timeout binaries that always fail with exit 124.
    cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
exit 124
MOCK
    cat > "$mock_dir/gtimeout" <<'MOCK'
#!/usr/bin/env bash
exit 124
MOCK
    chmod +x "$mock_dir/timeout" "$mock_dir/gtimeout"

    local target="$mock_dir/target"
    mkdir -p "$target"

    local output
    output=$(
        export PATH="$mock_dir:$PATH"
        bash -c '
            set -euo pipefail
            source "'"$KAPSIS_ROOT"'/scripts/lib/compat.sh" 2>/dev/null || true
            # Extract the DU_TIMEOUT_SECS constant, the helper, and get_dir_size.
            eval "$(grep -E "^readonly DU_TIMEOUT_SECS=" "'"$CLEANUP_SCRIPT"'")"
            eval "$(sed -n "/^_du_timeout_cmd()/,/^}/p" "'"$CLEANUP_SCRIPT"'")"
            eval "$(sed -n "/^get_dir_size()/,/^}/p" "'"$CLEANUP_SCRIPT"'")"
            get_dir_size "$1"
        ' -- "$target"
    ) 2>&1 || {
        rm -rf "$mock_dir"
        _log_failure "get_dir_size aborted when du/timeout failed" "Output: $output"
        return 1
    }

    rm -rf "$mock_dir"

    # A failing timeout means the pipeline returns non-zero. The fallback
    # sets kb=0, so the final printed value must be 0.
    assert_equals "0" "$output" \
        "get_dir_size must return 0 when timeout fires (du hung on FUSE/NFS)"
}

#===============================================================================
# Symlink guard behavioral test
#===============================================================================

test_clean_sandboxes_does_not_follow_symlinks() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-243-link.XXXXXX")

    local sandbox_dir="$marker_dir/sandboxes"
    mkdir -p "$sandbox_dir"

    # Victim directory that must NOT be touched.
    local victim="$marker_dir/victim"
    mkdir -p "$victim"
    touch "$victim/precious.txt"

    # A real sandbox (should be processed normally — but we're in --dry-run
    # so nothing is actually removed; we only care that symlink isn't
    # iterated into).
    mkdir -p "$sandbox_dir/real-proj-123/upper"
    touch "$sandbox_dir/real-proj-123/upper/file.txt"

    # Symlink planted inside sandbox dir pointing at the victim. The old code
    # would follow this during cleanup; the new code must skip it.
    ln -s "$victim" "$sandbox_dir/attack-proj-999"

    # Run clean_sandboxes() in isolation with DRY_RUN=true. Even in dry-run,
    # the function would still call get_dir_size() on the symlink target,
    # which could hang on network filesystems. The guard prevents that.
    # More importantly, we're verifying the guard short-circuits before
    # any processing of the symlinked entry.
    local output
    output=$(
        export KAPSIS_SANDBOX_DIR="$sandbox_dir"
        bash -c '
            set +e
            # shellcheck disable=SC1090
            source "'"$KAPSIS_ROOT"'/scripts/lib/logging.sh" 2>/dev/null || true
            source "'"$KAPSIS_ROOT"'/scripts/lib/compat.sh" 2>/dev/null || true
            source "'"$KAPSIS_ROOT"'/scripts/lib/constants.sh" 2>/dev/null || true
            # Load full script except main().
            script_body=$(sed "s|^main \"\\\$@\"$|# suppressed|" "'"$CLEANUP_SCRIPT"'")
            source /dev/stdin <<< "$script_body"
            DRY_RUN=true
            FORCE=true
            PROJECT_FILTER=""
            AGENT_FILTER=""
            ITEMS_CLEANED=0
            TOTAL_SIZE_FREED=0
            GREEN="" YELLOW="" BLUE="" CYAN="" NC="" BOLD="" RED=""
            clean_sandboxes
        '
    ) 2>&1

    # Victim file must still exist.
    if [[ ! -f "$victim/precious.txt" ]]; then
        rm -rf "$marker_dir"
        _log_failure "Symlink was followed" "Victim file was deleted"
        return 1
    fi

    # The attack entry must NOT appear as a would-remove line. (The real
    # sandbox may appear, but the symlinked one must be silently skipped.)
    if echo "$output" | grep -q "attack-proj-999"; then
        rm -rf "$marker_dir"
        _log_failure "Symlinked entry was processed" "Output mentioned attack-proj-999: $output"
        return 1
    fi

    rm -rf "$marker_dir"
    return 0
}

#===============================================================================
# Runner
#===============================================================================

run_test test_explicit_action_requested_variable_declared
run_test test_explicit_action_requested_set_by_action_flags
run_test test_default_cleanups_gated_on_explicit_action_requested
run_test test_get_dir_size_uses_timeout_wrapper
run_test test_get_dir_size_handles_pipeline_failure
run_test test_symlink_guard_in_clean_sandboxes
run_test test_symlink_guard_in_clean_worktrees
run_test test_symlink_guard_in_clean_sanitized_git
run_test test_bare_invocation_runs_defaults
run_test test_vm_health_alone_skips_defaults
run_test test_containers_flag_alone_skips_defaults
run_test test_all_flag_still_runs_everything
run_test test_worktrees_flag_alone_runs_only_worktrees
run_test test_each_action_flag_alone_skips_defaults
run_test test_get_dir_size_survives_permission_denied
run_test test_get_dir_size_survives_du_hang
run_test test_clean_sandboxes_does_not_follow_symlinks

print_summary
