#!/usr/bin/env bash
#===============================================================================
# Integration tests for atomic_copy_dir (issues #328 / #335)
#
# These tests complement the unit/component tests in test-atomic-copy.sh:
# they run inside a real kapsis-sandbox container against real GNU cp,
# real chmod, and (on macOS hosts) real virtio-fs behavior. Where the
# unit tests use shell-function overrides to simulate cp stderr, these
# tests verify the same fixes hold under the actual runtime conditions
# the kapsis entrypoint exercises.
#
# Test 1 — defensive chmod against real restrictive-mode dst:
#   Pre-create dst with mode 0500 plus a stale file. atomic_copy_dir
#   must chmod-then-rm-rf-and-replace cleanly. Validates the issue
#   #335-C fix end-to-end (real chmod, no shell mocking).
#
# Test 2 — real GNU cp + real AF_UNIX socket via bind-mount:
#   Create a source dir under HOME containing a real AF_UNIX socket
#   (via Python). Bind-mount into the container. atomic_copy_dir runs
#   real `cp -rp` inside the container against the mount.
#
#   On macOS host (podman + virtio-fs): cp emits
#     `cp: cannot stat 'X.sock': Operation not supported` (or ENOENT
#      on some kernel/cp combos) because virtio-fs does not expose
#      AF_UNIX socket inodes from the macOS host to the Linux guest.
#     This reproduces the kapsis#335 / #328 trace exactly.
#   On Linux host (native bind-mount): cp copies the socket cleanly.
#     Happy path; atomic_copy_dir succeeds without engaging the
#     stderr classifier.
#   Either way: function must return 0 and regular files must land.
#
# Both tests require the kapsis-sandbox image to be built. Skipped
# cleanly if prerequisites are not met (mirrors test-container-libs.sh).
#===============================================================================

set -euo pipefail

# Capture our own dir BEFORE sourcing the framework — the framework
# rebinds SCRIPT_DIR to its own location, so we cache it under a
# uniquely-named variable.
INTEGRATION_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_REPO_ROOT="$(cd "$INTEGRATION_TEST_DIR/.." && pwd)"

# shellcheck source=./lib/test-framework.sh
source "$INTEGRATION_TEST_DIR/lib/test-framework.sh"

# Bind-mount the in-source atomic-copy.sh + logging.sh over the in-image
# copies so the test exercises the working tree, not a stale image. CI's
# image-build pipeline produces images that already contain the same
# source, so this is effectively a no-op in CI; for local dev iteration
# it sidesteps a ~30 min image rebuild after each library edit.
LIB_MOUNT_ARGS=(
    -v "$INTEGRATION_REPO_ROOT/scripts/lib/atomic-copy.sh:/opt/kapsis/lib/atomic-copy.sh:ro"
    -v "$INTEGRATION_REPO_ROOT/scripts/lib/logging.sh:/opt/kapsis/lib/logging.sh:ro"
)

#===============================================================================
# HOST-SIDE FIXTURES
#===============================================================================

# Host directory for bind-mount fixtures. Must live under $HOME so
# podman machine on macOS can see it via the standard virtio-fs share.
ATOMIC_COPY_INT_FIXTURE_DIR="$HOME/.kapsis-atomic-copy-int-$$"

cleanup_fixture_dir() {
    if [[ -d "$ATOMIC_COPY_INT_FIXTURE_DIR" ]]; then
        rm -rf "$ATOMIC_COPY_INT_FIXTURE_DIR" 2>/dev/null || true
    fi
}

# Create a source tree containing 2 regular files + 1 real AF_UNIX
# socket. The socket is bound but not connected — same shape as the
# host-side git fsmonitor / ssh-agent sockets that trigger the
# virtio-fs stat-failure on macOS.
build_host_fixture_with_socket() {
    local src="$1"
    mkdir -p "$src"
    echo "alpha" > "$src/a.txt"
    echo "beta" > "$src/b.txt"
    python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind('$src/fsmonitor--daemon.ipc')
" || {
        log_skip "Could not create AF_UNIX socket fixture (python3 unavailable?)"
        return 1
    }
}

#===============================================================================
# TEST 1: Real chmod + real rm-rf-and-replace against restrictive dst
#===============================================================================

test_atomic_copy_dir_real_chmod_restrictive_dst_e2e() {
    log_test "atomic_copy_dir: real chmod allows replacement of restrictive-mode dst (issue #335-C, real cp/chmod)"

    setup_container_test "atomic-copy-int-chmod"

    local output
    local exit_code=0
    output=$(run_simple_container "
        set -e
        SRC=/tmp/src
        DST=/tmp/dst
        mkdir -p \$SRC
        echo 'new-payload' > \$SRC/payload.txt

        # Pre-create dst with mode 0500 (read+exec, NO write for owner)
        # containing a stale file. Without the C fix, the subsequent
        # rm-rf would refuse to unlink stale.txt (mode 0500 dir denies
        # unlink) and the replacement would error.
        mkdir -p \$DST
        echo 'stale' > \$DST/stale.txt
        chmod 0500 \$DST

        source /opt/kapsis/lib/logging.sh
        source /opt/kapsis/lib/atomic-copy.sh

        # Capture atomic_copy_dir's exit code directly — PR #336 review
        # caught that capturing \$? after the cleanup-chmod || true
        # always reported 0, masking the actual rc.
        atomic_copy_dir \$SRC \$DST 2>/dev/null
        ACD_RC=\$?
        # Cleanup mode so test framework can remove dst regardless of
        # whether atomic_copy_dir succeeded.
        chmod 0755 \$DST 2>/dev/null || true

        echo ACD_RC=\$ACD_RC
        test -f \$DST/payload.txt && echo HAS_PAYLOAD || echo MISSING_PAYLOAD
        test ! -e \$DST/stale.txt && echo NO_STALE || echo HAS_STALE
    " "${LIB_MOUNT_ARGS[@]}") || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" "Container command should exit 0"
    assert_contains "$output" "ACD_RC=0" "atomic_copy_dir must return 0 (real chmod allowed rm-rf-and-replace)"
    assert_contains "$output" "HAS_PAYLOAD" "Fresh payload must land in dst after replacement"
    assert_contains "$output" "NO_STALE" "Stale dst content must be replaced, not merged"
}

#===============================================================================
# TEST 2: Real GNU cp + real AF_UNIX socket via host bind-mount
#===============================================================================

test_atomic_copy_dir_real_host_socket_e2e() {
    log_test "atomic_copy_dir: real GNU cp + real AF_UNIX socket from host bind-mount (issues #328 / #335 A+B end-to-end)"

    # Skip if python3 isn't available on the host — we can't create
    # the socket fixture without it.
    if ! command -v python3 &>/dev/null; then
        log_skip "Skipping: python3 unavailable on host for socket fixture"
        return 0
    fi

    # $HOME writability guard (PR #336 review: constrained CI environments
    # may have read-only HOME). We use $HOME specifically because podman
    # machine on macOS only exposes $HOME (not /tmp) through virtio-fs.
    if ! mkdir -p "$ATOMIC_COPY_INT_FIXTURE_DIR" 2>/dev/null; then
        log_skip "Skipping: \$HOME not writable for fixture dir ($ATOMIC_COPY_INT_FIXTURE_DIR)"
        return 0
    fi

    local src_host="$ATOMIC_COPY_INT_FIXTURE_DIR/src"
    if ! build_host_fixture_with_socket "$src_host"; then
        log_fail "Failed to build host fixture"
        return 1
    fi

    setup_container_test "atomic-copy-int-socket"

    local output
    local exit_code=0
    # Bind-mount the host fixture at /test-src. On macOS host this
    # routes through virtio-fs and reproduces the stat-on-socket
    # failure pattern from #335. On Linux host this is a native bind
    # mount where cp copies the socket cleanly.
    output=$(run_simple_container "
        set -e
        SRC=/test-src
        DST=/tmp/dst
        PROBE=/tmp/probe-isolated   # NEVER inside DST — PR #336 review
        mkdir -p \$DST

        source /opt/kapsis/lib/logging.sh
        source /opt/kapsis/lib/atomic-copy.sh

        # Capture raw cp behavior in an isolated probe dir so any
        # leftover doesn't contaminate atomic_copy_dir's count check.
        echo '--- raw cp -rp probe ---'
        mkdir -p \$PROBE
        PROBE_OUT=\$(LC_ALL=C cp -rp \$SRC/. \$PROBE/ 2>&1) && PROBE_RC=0 || PROBE_RC=\$?
        rm -rf \$PROBE 2>/dev/null || true
        echo \"PROBE_RC=\$PROBE_RC\"
        # Always echo the captured stderr so it's visible in test diagnostics.
        # Prefix every line with PROBE_STDERR_LINE: for grep-friendliness.
        printf 'PROBE_STDERR_LEN=%s\\n' \"\${#PROBE_OUT}\"
        printf 'PROBE_STDERR_LINE: %s\\n' \"\$PROBE_OUT\" | head -20
        # Classifier-engagement marker: did real cp emit one of the
        # benign patterns this PR teaches the classifier to accept?
        # Reasons whitelist must mirror _ATOMIC_CP_PRESERVE_PERMS_REGEX
        # (Permission denied | Operation not permitted | No such file or
        # directory — the third was discovered empirically during this
        # PR's own e2e test development; see the regex's docstring).
        if echo \"\$PROBE_OUT\" | grep -qE 'cp: cannot stat .+: (No such file or directory|Operation not supported)'; then
            echo 'CLASSIFIER_ENGAGED=1 (stat-fail)'
        elif echo \"\$PROBE_OUT\" | grep -qE 'cp: preserving permissions .+: (Permission denied|Operation not permitted|No such file or directory)'; then
            echo 'CLASSIFIER_ENGAGED=1 (preserve-perms)'
        else
            echo 'CLASSIFIER_ENGAGED=0'
        fi

        echo '--- atomic_copy_dir under test ---'
        # Capture rc separately (PR #336 review: don't shadow via cleanup)
        atomic_copy_dir \$SRC \$DST 2>&1
        ACD_RC=\$?
        echo \"ACD_RC=\$ACD_RC\"
        test -f \$DST/a.txt && echo HAS_A || echo MISSING_A
        test -f \$DST/b.txt && echo HAS_B || echo MISSING_B
    " "${LIB_MOUNT_ARGS[@]}" -v "$src_host:/test-src:ro") || exit_code=$?

    cleanup_container_test
    cleanup_fixture_dir

    assert_exit_code 0 "$exit_code" "Container command should exit 0"
    assert_contains "$output" "ACD_RC=0" "atomic_copy_dir must return 0 despite real cp's socket handling"
    assert_contains "$output" "HAS_A" "Regular file a.txt must be staged"
    assert_contains "$output" "HAS_B" "Regular file b.txt must be staged"

    # PR #336 review HIGH: pin the test to actually exercising the
    # classifier code path on macOS hosts (where virtio-fs reproduces
    # #335). On Linux hosts cp copies sockets cleanly, classifier is
    # never engaged, and this test is a happy-path baseline — emit a
    # log_skip so green isn't conflated with "the fix actually fired".
    if [[ "$output" == *"CLASSIFIER_ENGAGED=1"* ]]; then
        log_info "  classifier WAS engaged (virtio-fs / non-stattable socket); fix path exercised end-to-end"
    elif [[ "$output" == *"CLASSIFIER_ENGAGED=0"* ]]; then
        log_skip "  classifier was NOT engaged (real cp copied socket cleanly — likely Linux native bind-mount). Test passed via happy path; fix code path not exercised on this host."
        # Surface the probe diagnostic so an operator can see what cp emitted.
        printf '%s\n' "$output" | grep -E 'PROBE_RC=|PROBE_STDERR_LEN=|PROBE_STDERR_LINE:' | head -10 | sed 's/^/    /'
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "atomic_copy_dir integration (issues #328 / #335)"

    if ! check_prerequisites; then
        echo "Skipping atomic-copy integration tests — prerequisites not met"
        exit 0
    fi

    setup_test_project
    trap 'cleanup_test_project; cleanup_fixture_dir' EXIT

    run_test test_atomic_copy_dir_real_chmod_restrictive_dst_e2e
    run_test test_atomic_copy_dir_real_host_socket_e2e

    print_summary
}

main "$@"
