#!/usr/bin/env bash
#===============================================================================
# Tests for Podman health probe / auto-heal (Issue #276)
#
# Verifies that:
# - probe_virtio_fs_health is a no-op on Linux
# - probe_virtio_fs_health invokes the correct probe container on macOS
#   (mocked via a fake `podman` on PATH)
# - count_running_kapsis_containers greps podman ps output correctly
# - maybe_autoheal_podman_vm refuses to restart when other kapsis containers
#   are running
# - maybe_autoheal_podman_vm restarts + retries when safe
#
# All podman/timeout interactions are mocked — no real Podman VM is started.
#
# Run: ./tests/test-podman-health.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

#-------------------------------------------------------------------------------
# Fresh library load helper — re-sources podman-health.sh into a child shell
# so each test starts with defaults. Also forces is_macos=true so the macOS
# path is exercised even on Linux CI.
#-------------------------------------------------------------------------------
_make_fake_podman() {
    # Writes a fake podman script to $1 and echoes its dir on stdout.
    # $2..$N are the shell statements inside the fake. Use "$@" to see args.
    local target="$1"
    shift
    mkdir -p "$(dirname "$target")"
    {
        echo "#!/usr/bin/env bash"
        for line in "$@"; do
            echo "$line"
        done
    } > "$target"
    chmod +x "$target"
}

_load_lib_with_macos() {
    # Returns a preamble that: forces is_macos=true, stubs logging, sources
    # constants.sh, compat.sh (for _KAPSIS_TIMEOUT_CMD etc.), podman-health.sh.
    cat <<EOF
set -u
log_debug() { :; }
log_info()  { :; }
log_warn()  { echo "[WARN] \$*" >&2; }
log_error() { echo "[ERROR] \$*" >&2; }
log_success() { :; }
source "$LIB_DIR/constants.sh"
source "$LIB_DIR/compat.sh"
# Override OS detection after compat.sh sourced, so macOS path is always taken
is_macos() { return 0; }
is_linux() { return 1; }
source "$LIB_DIR/podman-health.sh"
EOF
}

#===============================================================================
# probe_virtio_fs_health
#===============================================================================

test_probe_is_noop_on_linux() {
    log_test "probe_virtio_fs_health returns 0 on Linux without invoking podman"
    local out
    out=$(bash -c "
        log_debug() { :; }; log_info() { :; }; log_warn() { :; }; log_error() { :; }
        source '$LIB_DIR/constants.sh'
        source '$LIB_DIR/compat.sh'
        is_macos() { return 1; }; is_linux() { return 0; }
        source '$LIB_DIR/podman-health.sh'
        KAPSIS_VFS_PROBE_PODMAN=/bin/false probe_virtio_fs_health && echo PASS
    " 2>&1)
    assert_contains "$out" "PASS" "Should return 0 on Linux even with broken podman"
}

test_probe_passes_when_podman_succeeds() {
    log_test "probe_virtio_fs_health returns 0 when probe container exits 0"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_fake_podman "$tmpdir/podman" 'exit 0'

    local out rc=0
    out=$(bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' probe_virtio_fs_health 1 && echo PASS
    " 2>&1) || rc=$?

    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "probe should succeed when fake podman exits 0"
    assert_contains "$out" "PASS" "probe should return 0 path"
}

test_probe_fails_when_podman_fails() {
    log_test "probe_virtio_fs_health returns 1 when probe container exits non-zero"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_fake_podman "$tmpdir/podman" 'exit 42'

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' probe_virtio_fs_health 1
    " &>/dev/null || rc=$?

    rm -rf "$tmpdir"
    assert_equals "1" "$rc" "probe should return 1 when podman exits non-zero"
}

test_probe_invokes_podman_run_with_bind_mount() {
    log_test "probe_virtio_fs_health invokes 'podman run' with a bind mount"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman logs its argv to a file and exits 0.
    _make_fake_podman "$tmpdir/podman" \
        'printf "%s\n" "$@" > '"$tmpdir"'/argv.log' \
        'exit 0'

    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' probe_virtio_fs_health 1
    " &>/dev/null || true

    local argv
    argv=$(cat "$tmpdir/argv.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_contains "$argv" "run" "podman should be invoked as 'podman run ...'"
    assert_contains "$argv" "--rm" "probe container should be --rm"
    assert_contains "$argv" "/probe" "probe container should bind-mount /probe"
}

#===============================================================================
# count_running_kapsis_containers
#===============================================================================

test_count_zero_when_no_containers() {
    log_test "count_running_kapsis_containers returns 0 when no containers"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman: regardless of args, produce empty output for `ps`.
    _make_fake_podman "$tmpdir/podman" \
        'if [[ "$1" == "ps" ]]; then exit 0; else exit 0; fi'

    local out
    out=$(bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' count_running_kapsis_containers
    " 2>&1)
    rm -rf "$tmpdir"
    assert_equals "0" "$out" "Should return 0 when podman ps produces no output"
}

test_count_uses_label_filter() {
    log_test "count_running_kapsis_containers invokes podman ps with label filter"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman records its argv for the ps call.
    _make_fake_podman "$tmpdir/podman" \
        'if [[ "$1" == "ps" ]]; then printf "%s\n" "$@" > '"$tmpdir"'/argv.log; fi' \
        'exit 0'

    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' count_running_kapsis_containers
    " &>/dev/null || true

    local argv
    argv=$(cat "$tmpdir/argv.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    # The post-review implementation filters by the kapsis.managed label so
    # user containers named "kapsis-*" don't stall auto-heal.
    assert_contains "$argv" "--filter" "ps should use --filter"
    assert_contains "$argv" "label=kapsis.managed=true" "Filter should target the managed label"
}

test_count_reports_only_labeled_containers() {
    log_test "count_running_kapsis_containers counts labeled containers"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman: when asked for ps, print three container IDs (simulating
    # that the --filter already matched only managed containers).
    _make_fake_podman "$tmpdir/podman" \
        'if [[ "$1" == "ps" ]]; then printf "%s\n" "abc123" "def456" "xyz789"; fi'

    local out
    out=$(bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' count_running_kapsis_containers
    " 2>&1)
    rm -rf "$tmpdir"
    assert_equals "3" "$out" "Should count 3 containers when podman ps returns 3 IDs"
}

#===============================================================================
# maybe_autoheal_podman_vm
#===============================================================================

test_autoheal_noop_on_linux() {
    log_test "maybe_autoheal_podman_vm returns 0 on Linux without probing"
    local rc=0
    bash -c "
        log_debug() { :; }; log_info() { :; }; log_warn() { :; }; log_error() { :; }
        log_success() { :; }
        source '$LIB_DIR/constants.sh'
        source '$LIB_DIR/compat.sh'
        is_macos() { return 1; }; is_linux() { return 0; }
        source '$LIB_DIR/podman-health.sh'
        maybe_autoheal_podman_vm
    " &>/dev/null || rc=$?
    assert_equals "0" "$rc" "Should be a no-op on Linux"
}

test_autoheal_fastpath_returns_0_when_probe_passes() {
    log_test "maybe_autoheal_podman_vm returns 0 without restart when probe passes"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman records arg count to detect whether 'machine stop' was invoked.
    _make_fake_podman "$tmpdir/podman" \
        'echo "$@" >> '"$tmpdir"'/calls.log' \
        'exit 0'

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' maybe_autoheal_podman_vm 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Should return 0 when probe passes"
    assert_not_contains "$calls" "machine stop" "Should NOT restart VM when probe passes"
}

test_autoheal_refuses_when_other_containers_running() {
    log_test "maybe_autoheal_podman_vm refuses to restart when other kapsis containers are live"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman:
    # - run <image> <cmd>   -> exit 42   (probe fails)
    # - ps ...              -> print kapsis names (other containers running)
    # - machine stop/start  -> recorded & exit 0
    _make_fake_podman "$tmpdir/podman" \
        'case "$1" in
            run)     echo "$@" >> '"$tmpdir"'/calls.log; exit 42 ;;
            ps)      printf "%s\n" "kapsis-other1" "kapsis-other2" ;;
            machine) echo "machine $*" >> '"$tmpdir"'/calls.log; exit 0 ;;
            *)       echo "unknown: $*" >&2; exit 1 ;;
        esac'

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' maybe_autoheal_podman_vm 1 1 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "1" "$rc" "Should return 1 when other kapsis containers are running"
    assert_not_contains "$calls" "machine stop" "Must NOT restart VM with other agents running"
}

test_autoheal_restarts_when_safe_and_probe_recovers() {
    log_test "maybe_autoheal_podman_vm restarts VM and succeeds when recovery works"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Tracks call count so we can fail the first probe and pass the second.
    local state_file="$tmpdir/state"
    echo "0" > "$state_file"

    _make_fake_podman "$tmpdir/podman" \
        'case "$1" in
            run)
                # "run" is only used by the probe path.
                n=$(cat '"$state_file"')
                n=$((n+1))
                echo "$n" > '"$state_file"'
                if [[ $n -eq 1 ]]; then
                    exit 42   # initial probe fails
                else
                    exit 0    # post-restart probe passes
                fi
                ;;
            ps)
                # No other kapsis containers — restart is safe.
                exit 0
                ;;
            machine)
                echo "machine $*" >> '"$tmpdir"'/calls.log
                exit 0
                ;;
            *)
                exit 1
                ;;
        esac'

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_VFS_RECOVERY_DELAY=1 \
        maybe_autoheal_podman_vm 1 2 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Should recover after VM restart"
    assert_contains "$calls" "machine stop" "Should stop the VM"
    assert_contains "$calls" "machine start" "Should start the VM"
}

test_autoheal_disabled_refuses_restart() {
    log_test "KAPSIS_VFS_AUTOHEAL_ENABLED=false refuses to restart even when safe"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_fake_podman "$tmpdir/podman" \
        'case "$1" in
            run)     echo "$@" >> '"$tmpdir"'/calls.log; exit 42 ;;
            ps)      exit 0 ;;
            machine) echo "machine $*" >> '"$tmpdir"'/calls.log; exit 0 ;;
            *)       exit 1 ;;
        esac'

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_VFS_AUTOHEAL_ENABLED=false \
        maybe_autoheal_podman_vm 1 1 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "1" "$rc" "Should return 1 when auto-heal disabled"
    assert_not_contains "$calls" "machine stop" "Must NOT restart VM when auto-heal disabled"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Podman Health Probe & Auto-Heal (Issue #276)"

    log_info "=== probe_virtio_fs_health ==="
    run_test test_probe_is_noop_on_linux
    run_test test_probe_passes_when_podman_succeeds
    run_test test_probe_fails_when_podman_fails
    run_test test_probe_invokes_podman_run_with_bind_mount

    log_info "=== count_running_kapsis_containers ==="
    run_test test_count_zero_when_no_containers
    run_test test_count_uses_label_filter
    run_test test_count_reports_only_labeled_containers

    log_info "=== maybe_autoheal_podman_vm ==="
    run_test test_autoheal_noop_on_linux
    run_test test_autoheal_fastpath_returns_0_when_probe_passes
    run_test test_autoheal_refuses_when_other_containers_running
    run_test test_autoheal_restarts_when_safe_and_probe_recovers
    run_test test_autoheal_disabled_refuses_restart

    print_summary
}

main "$@"
