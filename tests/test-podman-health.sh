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
    # Updated fake (post-review): image check succeeds (cached), run succeeds.
    _make_fake_podman "$tmpdir/podman" \
        'if [[ "$1" == "image" && "$2" == "exists" ]]; then exit 0; fi' \
        'exit 0'

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
    # Updated fake: image check succeeds (so we reach the run), run fails.
    _make_fake_podman "$tmpdir/podman" \
        'if [[ "$1" == "image" && "$2" == "exists" ]]; then exit 0; fi' \
        'exit 42'

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
    # Updated fake: image check succeeds; `run` invocations log argv.
    _make_fake_podman "$tmpdir/podman" \
        'if [[ "$1" == "image" && "$2" == "exists" ]]; then exit 0; fi' \
        'if [[ "$1" == "run" ]]; then printf "%s\n" "$@" > '"$tmpdir"'/argv.log; fi' \
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
    assert_contains "$argv" "--entrypoint" "probe should bypass image entrypoint via --entrypoint sh"
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
    log_test "count_running_kapsis_containers counts labeled responsive containers"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman: ps returns three container IDs; exec succeeds for all
    # (simulating responsive containers — Issue #348 added the responsiveness
    # probe to count_running_kapsis_containers).
    _make_fake_podman "$tmpdir/podman" \
        'case "$1" in
            ps)   printf "%s\n" "abc123" "def456" "xyz789" ;;
            exec) exit 0 ;;
            *)    exit 0 ;;
        esac'

    local out
    out=$(bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' count_running_kapsis_containers
    " 2>&1)
    rm -rf "$tmpdir"
    assert_equals "3" "$out" "Should count 3 containers when podman ps returns 3 responsive IDs"
}

#===============================================================================
# count_running_kapsis_containers — zombie exclusion (Issue #348)
#===============================================================================

test_count_excludes_wedged_containers() {
    log_test "count_running_kapsis_containers excludes wedged containers (Issue #348)"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman: ps returns mixed IDs; exec succeeds for `alive*` and fails
    # for `wedge*` (simulating D-state PID-1 unresponsive to exec).
    _make_fake_podman "$tmpdir/podman" \
        'case "$1" in
            ps)
                printf "%s\n" "alive1" "wedge1" "alive2"
                ;;
            exec)
                # $2 is the container id
                if [[ "$2" == wedge* ]]; then exit 1; fi
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac'

    local out
    out=$(bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_VFS_EXEC_PROBE_TIMEOUT=1 \
        count_running_kapsis_containers
    " 2>/dev/null)
    rm -rf "$tmpdir"
    assert_equals "2" "$out" "Should count only the 2 responsive containers"
}

test_count_excludes_all_when_no_timeout_binary() {
    log_test "count_running_kapsis_containers excludes all when no timeout binary (Issue #348, fail-closed)"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Marker file: if `exec` is ever invoked, the test should fail. With no
    # timeout binary, _probe_container_responsive must return early without
    # invoking podman exec at all.
    _make_fake_podman "$tmpdir/podman" \
        'case "$1" in
            ps)   printf "%s\n" "id1" "id2" ;;
            exec) touch '"$tmpdir"'/exec-was-called; exit 0 ;;
            *)    exit 0 ;;
        esac'

    local out
    out=$(bash -c "
        $(_load_lib_with_macos)
        # Belt-and-braces: clear any cached timeout-cmd from compat.sh sourcing.
        unset _KAPSIS_TIMEOUT_CMD
        # Stub the timeout resolver to simulate no timeout/gtimeout on PATH.
        _vfs_timeout_cmd() { printf ''; return 0; }
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' count_running_kapsis_containers
    " 2>/dev/null)

    local exec_called="no"
    [[ -f "$tmpdir/exec-was-called" ]] && exec_called="yes"
    rm -rf "$tmpdir"
    assert_equals "0" "$out" "Count must be 0 when no timeout binary (fail-closed)"
    assert_equals "no" "$exec_called" "podman exec must NOT be invoked without a timeout wrapper"
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
    # - image exists         -> exit 0 (cached; probe proceeds to `run`)
    # - run <image> <cmd>    -> exit 42   (probe fails)
    # - ps ...               -> print kapsis IDs (other containers running)
    # - machine stop/start   -> recorded & exit 0
    _make_fake_podman "$tmpdir/podman" \
        'case "$1" in
            image)
                if [[ "$2" == "exists" ]]; then exit 0; fi
                exit 0 ;;
            run)     echo "$@" >> '"$tmpdir"'/calls.log; exit 42 ;;
            ps)      printf "%s\n" "other1" "other2" ;;
            exec)    exit 0 ;;
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
            image)
                [[ "$2" == "exists" ]] && exit 0
                exit 0 ;;
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
            image)   [[ "$2" == "exists" ]] && exit 0; exit 0 ;;
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
# maybe_autoheal_podman_vm — zombie sweep (Issue #348)
#===============================================================================

# Shared fake podman for the sweep tests. State machine:
#   image exists  -> 0
#   run (probe)   -> fail (42) on first call, succeed (0) on subsequent calls
#   ps            -> emit the IDs passed in $KAPSIS_TEST_PS_IDS env
#   exec ID       -> wedged ID (matches "wedge*") -> $KAPSIS_TEST_WEDGE_EXIT
#                    (default 124 — matches real `timeout` exit on a hung
#                    child); everything else -> 0
#   rm -f ID      -> exit code from $KAPSIS_TEST_RM_EXIT (default 0)
#   machine ...   -> record + exit 0
_make_sweep_fake_podman() {
    local target="$1"
    local state_file="$2"
    local calls_log="$3"
    echo "0" > "$state_file"
    cat > "$target" <<EOF
#!/usr/bin/env bash
set -u
calls_log='$calls_log'
state_file='$state_file'
case "\${1:-}" in
    image)
        [[ "\${2:-}" == "exists" ]] && exit 0
        exit 0
        ;;
    run)
        n=\$(cat "\$state_file")
        n=\$((n+1))
        echo "\$n" > "\$state_file"
        if [[ \$n -eq 1 ]]; then exit 42; else exit 0; fi
        ;;
    ps)
        # Emit the IDs configured by the test via env.
        for id in \${KAPSIS_TEST_PS_IDS:-}; do printf '%s\n' "\$id"; done
        exit 0
        ;;
    exec)
        # \$2 is the container id
        if [[ "\${2:-}" == wedge* ]]; then exit "\${KAPSIS_TEST_WEDGE_EXIT:-124}"; fi
        exit 0
        ;;
    rm)
        # rm -f <id>
        echo "rm \$*" >> "\$calls_log"
        exit "\${KAPSIS_TEST_RM_EXIT:-0}"
        ;;
    machine)
        echo "machine \$*" >> "\$calls_log"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$target"
}

test_autoheal_recovers_when_only_wedged_containers_present() {
    log_test "maybe_autoheal_podman_vm restarts VM when only wedged zombies present (Issue #348)"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_sweep_fake_podman "$tmpdir/podman" "$tmpdir/state" "$tmpdir/calls.log"

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_TEST_PS_IDS='wedge1' \
        KAPSIS_VFS_EXEC_PROBE_TIMEOUT=1 \
        KAPSIS_VFS_RECOVERY_DELAY=1 \
        maybe_autoheal_podman_vm 1 2 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Heal must succeed when the only running container is wedged"
    assert_contains "$calls" "machine stop" "VM must be stopped (heal proceeded past count check)"
    assert_contains "$calls" "machine start" "VM must be started after stop"
}

test_autoheal_sweep_attempts_rm_for_wedged() {
    log_test "maybe_autoheal_podman_vm runs rm -f on wedged containers (Issue #348)"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_sweep_fake_podman "$tmpdir/podman" "$tmpdir/state" "$tmpdir/calls.log"

    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_TEST_PS_IDS='wedge1' \
        KAPSIS_VFS_EXEC_PROBE_TIMEOUT=1 \
        KAPSIS_VFS_RECOVERY_DELAY=1 \
        maybe_autoheal_podman_vm 1 2 1
    " &>/dev/null || true

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_contains "$calls" "rm -f wedge1" "Sweep must invoke 'podman rm -f' on wedged container"
}

test_autoheal_sweep_tolerates_rm_failure() {
    log_test "maybe_autoheal_podman_vm restarts even if rm -f fails on wedged (Issue #348)"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_sweep_fake_podman "$tmpdir/podman" "$tmpdir/state" "$tmpdir/calls.log"

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_TEST_PS_IDS='wedge1' \
        KAPSIS_TEST_RM_EXIT=137 \
        KAPSIS_VFS_EXEC_PROBE_TIMEOUT=1 \
        KAPSIS_VFS_RECOVERY_DELAY=1 \
        maybe_autoheal_podman_vm 1 2 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Heal must still succeed when rm -f exits non-zero (VM restart reaps zombie)"
    assert_contains "$calls" "machine stop" "Restart must proceed despite rm -f failure"
}

test_autoheal_still_refuses_when_responsive_containers_running() {
    log_test "maybe_autoheal_podman_vm still refuses when responsive containers are running (Issue #348 regression)"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_sweep_fake_podman "$tmpdir/podman" "$tmpdir/state" "$tmpdir/calls.log"

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_TEST_PS_IDS='alive1 alive2' \
        KAPSIS_VFS_EXEC_PROBE_TIMEOUT=1 \
        KAPSIS_VFS_RECOVERY_DELAY=1 \
        maybe_autoheal_podman_vm 1 2 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "1" "$rc" "Must still refuse when other responsive agents are live"
    assert_not_contains "$calls" "machine stop" "Must NOT restart VM with responsive agents running"
    assert_not_contains "$calls" "rm -f" "Must NOT rm -f responsive containers"
}

test_autoheal_skips_rm_for_raced_exit_containers() {
    log_test "maybe_autoheal_podman_vm skips rm -f when probe rc != 124 (raced exit, not wedged — PR #349 review)"
    local tmpdir
    tmpdir=$(mktemp -d)
    _make_sweep_fake_podman "$tmpdir/podman" "$tmpdir/state" "$tmpdir/calls.log"

    # Probe returns 125 (the conventional "podman exec failed to start" rc for
    # a container that exited under us) — NOT 124. This is the race case, not
    # a wedged D-state. Auto-heal should proceed (the container isn't really
    # running) but it should NOT try to `rm -f` a vanished container.
    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_TEST_PS_IDS='wedge1' \
        KAPSIS_TEST_WEDGE_EXIT=125 \
        KAPSIS_VFS_EXEC_PROBE_TIMEOUT=1 \
        KAPSIS_VFS_RECOVERY_DELAY=1 \
        maybe_autoheal_podman_vm 1 2 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Heal must proceed (raced-exit container doesn't block restart)"
    assert_contains "$calls" "machine stop" "VM restart must still proceed"
    assert_not_contains "$calls" "rm -f" "Must NOT rm -f a container that already exited (probe rc != 124)"
}

#===============================================================================
# REVIEW-GAP TESTS (Issue #276 second-round review)
#===============================================================================

test_autoheal_retry_exhaustion_returns_1() {
    log_test "maybe_autoheal_podman_vm returns 1 when every retry fails after restart"

    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman:
    # - volume run (probe): always fail — both pre-restart and post-restart
    # - ps:                  no other kapsis containers
    # - machine stop/start:  succeed
    cat > "$tmpdir/podman" <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-}" in
    run)
        echo "run" >> '$tmpdir/calls.log'
        exit 42
        ;;
    ps)      exit 0 ;;
    machine) echo "machine \$*" >> '$tmpdir/calls.log'; exit 0 ;;
    image)   exit 0 ;;
    *)       exit 1 ;;
esac
EOF
    chmod +x "$tmpdir/podman"

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_VFS_RECOVERY_DELAY=1 \
        KAPSIS_VFS_PROBE_SKIP_IF_MISSING=false \
        maybe_autoheal_podman_vm 1 2 1
    " &>/dev/null || rc=$?

    local calls
    calls=$(cat "$tmpdir/calls.log" 2>/dev/null || echo "")
    local run_count
    run_count=$(grep -c '^run$' <<<"$calls" || true)
    rm -rf "$tmpdir"
    assert_equals "1" "$rc" "Should return 1 when all retries after restart fail"
    assert_contains "$calls" "machine stop" "Must still have attempted the restart"
    # Expected run calls: 1 initial probe + 2 retries = 3.
    assert_equals "3" "$run_count" \
        "Should attempt the probe exactly (1 + max_retries) = 3 times"
}

test_probe_skipped_when_image_missing_and_skip_enabled() {
    log_test "probe_virtio_fs_health skips cleanly when the probe image is not cached"

    local tmpdir
    tmpdir=$(mktemp -d)
    # Fake podman:
    # - image exists: always returns 1 (not cached)
    # - run:          unreachable; if we hit it, the skip logic is broken
    cat > "$tmpdir/podman" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    image)
        if [[ "\${2:-}" == "exists" ]]; then
            exit 1
        fi
        ;;
    run)
        echo "SHOULD_NOT_RUN" > '$tmpdir/marker'
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$tmpdir/podman"

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_VFS_PROBE_IMAGE='kapsis-sandbox:latest' \
        KAPSIS_VFS_PROBE_SKIP_IF_MISSING=true \
        probe_virtio_fs_health 1
    " &>/dev/null || rc=$?

    local marker_present="no"
    [[ -f "$tmpdir/marker" ]] && marker_present="yes"
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Skip path must return 0 (not 'degraded')"
    assert_equals "no" "$marker_present" \
        "Must NOT invoke 'podman run' when the image isn't cached and skip is enabled"
}

test_probe_pulls_image_when_skip_disabled() {
    log_test "probe_virtio_fs_health pulls the image when skip-if-missing is disabled"

    local tmpdir
    tmpdir=$(mktemp -d)
    local pulled="$tmpdir/pulled"
    # Fake podman:
    # - image exists <img>: fails first (not cached), succeeds after `pull`
    # - pull <img>:         touches the marker and exits 0
    # - run:                succeeds (probe passes after pull)
    cat > "$tmpdir/podman" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    image)
        if [[ "\${2:-}" == "exists" ]]; then
            [[ -f '$pulled' ]] && exit 0 || exit 1
        fi
        ;;
    pull)
        touch '$pulled'
        exit 0
        ;;
    run)
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$tmpdir/podman"

    local rc=0
    bash -c "
        $(_load_lib_with_macos)
        KAPSIS_VFS_PROBE_PODMAN='$tmpdir/podman' \
        KAPSIS_VFS_PROBE_IMAGE='kapsis-sandbox:latest' \
        KAPSIS_VFS_PROBE_SKIP_IF_MISSING=false \
        probe_virtio_fs_health 1
    " &>/dev/null || rc=$?

    local marker_present="no"
    [[ -f "$pulled" ]] && marker_present="yes"
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Probe should succeed after successful pull + probe run"
    assert_equals "yes" "$marker_present" \
        "podman pull must have been invoked when skip-if-missing=false"
}

test_vfs_timeout_cmd_returns_empty_when_missing() {
    log_test "_vfs_timeout_cmd returns empty string when no timeout binary is on PATH"

    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/bin"
    # PATH contains only a directory with no timeout/gtimeout binary.

    local result
    result=$(bash -c "
        unset _KAPSIS_TIMEOUT_CMD
        PATH='$tmpdir/bin'
        source '$LIB_DIR/podman-health.sh'
        _vfs_timeout_cmd
    " 2>/dev/null)
    rm -rf "$tmpdir"
    assert_equals "" "$result" "_vfs_timeout_cmd must return empty string when no timeout binary found"
}

test_probe_runs_podman_without_timeout_when_tmo_missing() {
    log_test "probe_virtio_fs_health calls podman directly (no timeout wrapper) when timeout binary absent"

    local tmpdir
    tmpdir=$(mktemp -d)
    local shim_bin="$tmpdir/bin"
    mkdir -p "$shim_bin"
    local argv_log="$tmpdir/argv"

    # Fake podman: logs args, exits 0.
    # Use #!/bin/bash (absolute) — the test restricts PATH to $shim_bin so
    # #!/usr/bin/env bash would fail to locate bash in the child process.
    cat > "$shim_bin/podman" <<EOF
#!/bin/bash
echo "\$@" >> '$argv_log'
exit 0
EOF
    chmod +x "$shim_bin/podman"

    local rc=0
    bash -c "
        unset _KAPSIS_TIMEOUT_CMD
        PATH='$shim_bin'
        log_debug() { :; }; log_info() { :; }; log_warn() { :; }; log_error() { :; }
        log_success() { :; }
        source '$LIB_DIR/constants.sh'
        source '$LIB_DIR/compat.sh'
        is_macos() { return 0; }; is_linux() { return 1; }
        _KAPSIS_TIMEOUT_CMD=''
        source '$LIB_DIR/podman-health.sh'
        KAPSIS_VFS_PROBE_PODMAN='$shim_bin/podman' \
        KAPSIS_VFS_PROBE_IMAGE='kapsis-sandbox:latest' \
        KAPSIS_VFS_PROBE_SKIP_IF_MISSING=false \
        probe_virtio_fs_health 1
    " &>/dev/null || rc=$?

    local argv_content=""
    [[ -f "$argv_log" ]] && argv_content=$(cat "$argv_log")
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Probe must succeed (fake podman exits 0)"
    # The first call to fake podman should be 'image exists ...' and then 'run ...'
    # Without timeout wrapper, the run call begins with 'run' not 'N run'.
    assert_contains "$argv_content" "run" "podman run must be called"
    assert_not_contains "$argv_content" "timeout" \
        "podman run must NOT be wrapped in timeout when no timeout binary found"
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

    log_info "=== count_running_kapsis_containers — zombie exclusion (Issue #348) ==="
    run_test test_count_excludes_wedged_containers
    run_test test_count_excludes_all_when_no_timeout_binary

    log_info "=== maybe_autoheal_podman_vm ==="
    run_test test_autoheal_noop_on_linux
    run_test test_autoheal_fastpath_returns_0_when_probe_passes
    run_test test_autoheal_refuses_when_other_containers_running
    run_test test_autoheal_restarts_when_safe_and_probe_recovers
    run_test test_autoheal_disabled_refuses_restart

    log_info "=== maybe_autoheal_podman_vm — zombie sweep (Issue #348) ==="
    run_test test_autoheal_recovers_when_only_wedged_containers_present
    run_test test_autoheal_sweep_attempts_rm_for_wedged
    run_test test_autoheal_sweep_tolerates_rm_failure
    run_test test_autoheal_still_refuses_when_responsive_containers_running
    run_test test_autoheal_skips_rm_for_raced_exit_containers

    log_info "=== Review-gap tests (Issue #276 second round) ==="
    run_test test_autoheal_retry_exhaustion_returns_1
    run_test test_probe_skipped_when_image_missing_and_skip_enabled
    run_test test_probe_pulls_image_when_skip_disabled
    run_test test_vfs_timeout_cmd_returns_empty_when_missing
    run_test test_probe_runs_podman_without_timeout_when_tmo_missing

    print_summary
}

main "$@"
