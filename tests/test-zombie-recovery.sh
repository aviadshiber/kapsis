#!/usr/bin/env bash
#===============================================================================
# Test: Zombie VM recovery — _kill_vfkit_zombie and _recover_podman_ssh_tunnel
#
# Covers issue #298 (deferred from PR #295): test coverage for the automated
# zombie VM recovery introduced alongside the SSH-tunnel repair in compat.sh.
#
# All tests are QUICK (no container, no real Podman VM needed).
#
# Platform strategy: rather than skipping every test on Linux CI (which turns
# the test file into a no-op), we override is_linux()/is_macos() to make the
# macOS code paths execute on Linux with fully-stubbed external commands.
# Real-VM integration tests belong elsewhere (gated with is_macos checks) but
# the logic is testable on any platform.
#
# Category: validation
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

COMPAT_SCRIPT="$KAPSIS_ROOT/scripts/lib/compat.sh"

#===============================================================================
# Shared stub infrastructure
#===============================================================================

# _setup_stubs: define all external-command stubs and override platform
# detection, then source compat.sh.  Call at the top of every test function
# that exercises _kill_vfkit_zombie or _recover_podman_ssh_tunnel.
#
# After return:
#   $STUB_TMP      — temp dir cleaned up by _teardown_stubs
#   $MARKER_DIR    — directory where stubs write call markers
#   $XDG_DATA_HOME — isolated under $STUB_TMP (scopes all rm -f in compat.sh)
_setup_stubs() {
    STUB_TMP="$(mktemp -d)"
    MARKER_DIR="$STUB_TMP/markers"
    mkdir -p "$MARKER_DIR"

    # Point XDG_DATA_HOME at our temp tree so any rm -f calls in
    # _kill_vfkit_zombie touch only files we created ourselves.
    export XDG_DATA_HOME="$STUB_TMP/xdg-data"
    mkdir -p "$XDG_DATA_HOME"

    # No-op sleep avoids the 3-second wait baked into _kill_vfkit_zombie.
    sleep() { echo "sleep $*" >> "$MARKER_DIR/sleep_calls"; }

    # pkill stub — records call args so tests can verify the exact invocation.
    pkill() {
        local args="$*"
        echo "$args" >> "$MARKER_DIR/pkill_args"
        touch "$MARKER_DIR/pkill_called"
        return 0
    }

    # podman stub — behaviour controlled per-test via PODMAN_INFO_EXIT and
    # PODMAN_STOP_EXIT.  Defaults to success everywhere.
    # Use ${2:-} to avoid nounset errors when called with one argument (e.g.
    # "podman info" has no $2).
    PODMAN_INFO_EXIT="${PODMAN_INFO_EXIT:-0}"
    PODMAN_STOP_EXIT="${PODMAN_STOP_EXIT:-0}"
    podman() {
        echo "podman $*" >> "$MARKER_DIR/podman_calls"
        case "$1 ${2:-}" in
            "info "*)         return "${PODMAN_INFO_EXIT:-0}" ;;
            "machine stop")   return "${PODMAN_STOP_EXIT:-0}" ;;
            "machine start")  touch "$MARKER_DIR/podman_machine_start"; return 0 ;;
            *) return 0 ;;
        esac
    }

    # Override platform detection BEFORE sourcing so the guard block that sets
    # _KAPSIS_TIMEOUT_CMD runs with the right OS.  compat.sh re-defines these,
    # so we also override them again after sourcing (see below).
    is_linux() { return 1; }
    is_macos() { return 0; }

    # Unset guard so sourcing always runs (safe in isolated test subshell).
    unset _KAPSIS_COMPAT_LOADED

    # shellcheck source=scripts/lib/compat.sh
    source "$COMPAT_SCRIPT"

    # Re-override: compat.sh re-defined is_linux/is_macos based on _KAPSIS_OS.
    is_linux() { return 1; }
    is_macos() { return 0; }

    # Force the "no timeout binary" code path so podman is called directly as a
    # shell function (the timeout binary spawns a subprocess that can't see our
    # function stubs).
    _KAPSIS_TIMEOUT_CMD=""
}

_teardown_stubs() {
    [[ -n "${STUB_TMP:-}" ]] && rm -rf "$STUB_TMP"
    unset STUB_TMP MARKER_DIR PODMAN_INFO_EXIT PODMAN_STOP_EXIT
    unset XDG_DATA_HOME
    # Unset all stub functions so they don't leak into subsequent tests that
    # might not call _setup_stubs (e.g. a future pure-static test).
    unset -f sleep pkill podman is_linux is_macos _kill_vfkit_zombie 2>/dev/null || true
}

#===============================================================================
# _kill_vfkit_zombie tests
#===============================================================================

test_kill_vfkit_zombie_invokes_pkill_with_machine_pattern() {
    _setup_stubs
    _kill_vfkit_zombie "podman-machine-default"
    assert_file_exists "$MARKER_DIR/pkill_called" \
        "_kill_vfkit_zombie must call pkill"
    local args
    args="$(cat "$MARKER_DIR/pkill_args")"
    assert_contains "$args" "-9" \
        "pkill must use -9 (force kill)"
    # The literal pkill -f pattern is "vfkit.*<machine>" — assert each
    # component separately so the test intent is clear (no regex semantics here).
    assert_contains "$args" "vfkit" \
        "pkill pattern must include vfkit"
    assert_contains "$args" "podman-machine-default" \
        "pkill pattern must include machine name"
    _teardown_stubs
}

test_kill_vfkit_zombie_scoped_to_machine_name() {
    _setup_stubs
    _kill_vfkit_zombie "my-custom-machine"
    local args
    args="$(cat "$MARKER_DIR/pkill_args")"
    assert_contains "$args" "my-custom-machine" \
        "pkill pattern must include the custom machine name"
    # Default machine name must NOT appear when a custom name is given.
    local contains_default=false
    [[ "$args" == *"podman-machine-default"* ]] && contains_default=true
    assert_equals "$contains_default" "false" \
        "pkill pattern must not bleed into unrelated machine names"
    _teardown_stubs
}

test_kill_vfkit_zombie_removes_stale_runtime_files_only() {
    _setup_stubs

    # Seed a fake machine state dir with all file types that exist in reality.
    local machine_dir="${XDG_DATA_HOME}/containers/podman/machine/applehv/podman-machine-default"
    mkdir -p "$machine_dir"
    touch "${machine_dir}/podman.pid"
    touch "${machine_dir}/podman.sock"
    touch "${machine_dir}/podman.lock"
    touch "${machine_dir}/machine.json"    # config — must survive
    touch "${machine_dir}/disk.qcow2"     # disk image — must survive
    touch "${machine_dir}/ignition.ign"   # ignition config — must survive

    _kill_vfkit_zombie "podman-machine-default"

    # Runtime files must be gone.
    assert_file_not_exists "${machine_dir}/podman.pid"  ".pid files must be removed"
    assert_file_not_exists "${machine_dir}/podman.sock" ".sock files must be removed"
    assert_file_not_exists "${machine_dir}/podman.lock" ".lock files must be removed"

    # Configuration/disk files must be intact.
    assert_file_exists "${machine_dir}/machine.json"  ".json config must not be deleted"
    assert_file_exists "${machine_dir}/disk.qcow2"    ".qcow2 disk image must not be deleted"
    assert_file_exists "${machine_dir}/ignition.ign"  ".ign ignition config must not be deleted"

    _teardown_stubs
}

test_kill_vfkit_zombie_noop_on_missing_machine_dir() {
    _setup_stubs
    # Call with XDG_DATA_HOME pointing at a tree that has no machine dir at all.
    # The function must return successfully (the [[ -d ]] guard skips the rm).
    local rc=0
    _kill_vfkit_zombie "nonexistent-machine" || rc=$?
    assert_equals "$rc" "0" \
        "_kill_vfkit_zombie must not fail when machine state dir is absent"
    _teardown_stubs
}

test_kill_vfkit_zombie_default_machine_name() {
    _setup_stubs
    # Call with no argument — should use "podman-machine-default".
    _kill_vfkit_zombie
    local args
    args="$(cat "$MARKER_DIR/pkill_args")"
    assert_contains "$args" "podman-machine-default" \
        "No-arg call must default to podman-machine-default"
    _teardown_stubs
}

#===============================================================================
# _recover_podman_ssh_tunnel tests
#===============================================================================

test_recover_ssh_tunnel_healthy_sets_probe_passed() {
    _setup_stubs
    # Healthy tunnel: podman info returns 0.
    PODMAN_INFO_EXIT=0

    unset KAPSIS_SSH_PROBE_PASSED
    _recover_podman_ssh_tunnel 5 1 0

    assert_equals "${KAPSIS_SSH_PROBE_PASSED:-}" "1" \
        "KAPSIS_SSH_PROBE_PASSED must be set to 1 on healthy probe"
    # No restart should have been attempted.
    assert_file_not_exists "$MARKER_DIR/podman_machine_start" \
        "podman machine start must NOT be called when tunnel is healthy"
    _teardown_stubs
}

test_recover_ssh_tunnel_broken_attempts_machine_restart() {
    _setup_stubs
    # Broken tunnel: info always fails.
    PODMAN_INFO_EXIT=1
    PODMAN_STOP_EXIT=0

    _recover_podman_ssh_tunnel 1 1 0 || true

    # podman machine start must have been called as part of recovery.
    assert_file_exists "$MARKER_DIR/podman_machine_start" \
        "podman machine start must be called when tunnel probe fails"
    _teardown_stubs
}

test_recover_ssh_tunnel_stop_timeout_calls_zombie_killer() {
    _setup_stubs
    # Broken tunnel + stop fails (simulates a timeout / hung stop).
    PODMAN_INFO_EXIT=1
    PODMAN_STOP_EXIT=1   # non-zero triggers _kill_vfkit_zombie

    _recover_podman_ssh_tunnel 1 1 0 || true

    # pkill is only invoked by _kill_vfkit_zombie, so its marker file confirms
    # the zombie killer was called — consistent with the other stub patterns.
    assert_file_exists "$MARKER_DIR/pkill_called" \
        "_kill_vfkit_zombie must be called (via pkill) when podman machine stop fails"
    _teardown_stubs
}

test_recover_ssh_tunnel_exhausted_retries_returns_nonzero() {
    _setup_stubs
    # Probe always fails — should exhaust retries and return non-zero.
    PODMAN_INFO_EXIT=1
    PODMAN_STOP_EXIT=0

    local rc=0
    _recover_podman_ssh_tunnel 1 1 0 || rc=$?

    assert_equals "$rc" "1" \
        "_recover_podman_ssh_tunnel must return 1 when all retries are exhausted"
    _teardown_stubs
}

test_recover_ssh_tunnel_documents_no_machine_name_validation() {
    _setup_stubs
    # _kill_vfkit_zombie passes KAPSIS_PODMAN_MACHINE to pkill -f without
    # sanitizing it (unlike _podman_machine_restart in podman-health.sh which
    # validates against ^[a-zA-Z0-9_-]+$).  This test is a regression anchor:
    # it verifies the current unsanitized behaviour so that if validation is
    # added to compat.sh in the future, this test must be updated consciously.
    export KAPSIS_PODMAN_MACHINE="bad;nameinjected"
    PODMAN_INFO_EXIT=1   # force probe failure so recovery path runs
    PODMAN_STOP_EXIT=1   # force stop failure so _kill_vfkit_zombie is called

    _recover_podman_ssh_tunnel 1 1 0 || true

    # The crafted name must appear verbatim in pkill args, confirming it is
    # passed through to the OS without sanitization.
    assert_file_exists "$MARKER_DIR/pkill_called" \
        "_kill_vfkit_zombie must have been called during recovery"
    local args
    args="$(cat "$MARKER_DIR/pkill_args")"
    assert_contains "$args" "bad;nameinjected" \
        "machine name is passed to pkill unsanitized (regression anchor for current behaviour)"
    unset KAPSIS_PODMAN_MACHINE
    _teardown_stubs
}

#===============================================================================
# Run
#===============================================================================

run_test test_kill_vfkit_zombie_invokes_pkill_with_machine_pattern
run_test test_kill_vfkit_zombie_scoped_to_machine_name
run_test test_kill_vfkit_zombie_removes_stale_runtime_files_only
run_test test_kill_vfkit_zombie_noop_on_missing_machine_dir
run_test test_kill_vfkit_zombie_default_machine_name
run_test test_recover_ssh_tunnel_healthy_sets_probe_passed
run_test test_recover_ssh_tunnel_broken_attempts_machine_restart
run_test test_recover_ssh_tunnel_stop_timeout_calls_zombie_killer
run_test test_recover_ssh_tunnel_exhausted_retries_returns_nonzero
run_test test_recover_ssh_tunnel_documents_no_machine_name_validation

print_summary
