#!/usr/bin/env bash
#===============================================================================
# Test: Container .claude staging (real-image e2e for PR #380 follow-up)
#
# Verifies the host → container propagation of ~/.claude (in particular
# settings.json::enabledPlugins) survives kapsis staging end-to-end, even when
# the podman runtime bind-mounts a per-agent `conversations/` subdir into
# $HOME/.claude (which historically caused atomic_copy_dir to silently nest
# its tmp dir inside the destination and produce an empty settings.json).
#
# Catches two distinct regressions:
#   1. Containerfile missing `mkdir -p /kapsis-upper /kapsis-work` →
#      fuse-overlayfs fails for every staged config and falls back to
#      atomic_copy_dir on every cold start.
#   2. atomic_copy_dir's rm-rf-and-mv loses content when dst has a busy
#      bind-mount descendant → settings.json::enabledPlugins arrives empty,
#      inject-plugin-hooks.sh silently rejects every plugin.
#
# REQUIRES: Container environment (Podman) — auto-skipped via skip_if_no_overlay_rw.
#           CAP_SYS_ADMIN inside container for the conversations-mount simulation.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST 1: /kapsis-upper and /kapsis-work exist in the image and are developer-owned
#
# Catches Containerfile regression. Without this, fuse-overlayfs fails for
# every staged config (mkdir of $upper_base subdir fails silently) and we
# pay the atomic-copy-fallback cost on every container cold start.
#===============================================================================

test_kapsis_upper_work_dirs_exist_and_owned() {
    log_test "Testing /kapsis-upper and /kapsis-work exist + developer-owned (Containerfile pre-create)"

    setup_container_test "staging-upperdirs"

    local output
    output=$(run_in_container "
        for d in /kapsis-upper /kapsis-work; do
            if [ ! -d \"\$d\" ]; then
                echo \"\$d MISSING\"
                continue
            fi
            stat -c \"%n %U:%G %a\" \"\$d\"
        done
    ")

    cleanup_container_test

    assert_not_contains "$output" "MISSING" \
        "/kapsis-upper and /kapsis-work must exist in the image — Containerfile RUN mkdir must run"
    assert_contains "$output" "/kapsis-upper developer:developer 755" \
        "/kapsis-upper must be developer-owned with mode 755 for fuse-overlayfs to use it"
    assert_contains "$output" "/kapsis-work developer:developer 755" \
        "/kapsis-work must be developer-owned with mode 755 for fuse-overlayfs to use it"
}

#===============================================================================
# TEST 2: End-to-end staging preserves enabledPlugins under a busy bind-mount
#
# Reproduces the production failure mode. Builds a fixture .claude/ on the
# host with a settings.json containing 3 enabledPlugins, bind-mounts it as
# /kapsis-staging/.claude. Inside the container, pre-creates $HOME/.claude/
# with a busy bind-mounted conversations/ subdir (mirrors how kapsis-launch
# bind-mounts ~/.kapsis/conversations/<agent-id> in real runs). Invokes
# setup_staged_config_overlays from the real entrypoint, then asserts:
#
#   1. $HOME/.claude/settings.json has 3 enabledPlugins (NOT 0, NOT empty)
#   2. No .atomic-copy-dir-* directory survives in $HOME/.claude/
#      (regression check for the mv-into-existing-dst nesting bug)
#   3. The overlay path was used (or, if it fell back to atomic-copy, the
#      atomic-copy merge fallback worked — both are acceptable outcomes)
#===============================================================================

test_claude_staging_enabled_plugins_survive_busy_conversations_mount() {
    log_test "Testing .claude staging preserves settings.json::enabledPlugins under busy bind-mount (PR #380 follow-up)"

    # Probe: skip if rootless container can't create bind mounts. Mirrors the
    # log_skip pattern in test-atomic-copy-integration.sh::busy_mount test so
    # the test output shows [SKIP] rather than silently masquerading as [PASS].
    # NOTE: the framework's run_test still counts a 0-return as PASSED — there
    # is no per-test SKIPPED counter today. Bug reproducer is genuinely
    # unavailable on rootless hosts; CI rootful lanes will exercise it.
    if ! podman run --rm --cap-add=SYS_ADMIN "$KAPSIS_TEST_IMAGE" \
            bash -c 'mkdir -p /tmp/_p_a /tmp/_p_b && mount --bind /tmp/_p_a /tmp/_p_b 2>/dev/null && umount /tmp/_p_b' \
            >/dev/null 2>&1; then
        log_skip "  rootless container cannot create bind mounts (no CAP_SYS_ADMIN) — bug reproducer unavailable on this host"
        return 0
    fi

    # Build host fixture dir under $HOME (podman machine on macOS only
    # exposes $HOME through virtio-fs; /tmp isn't visible).
    local fixture_root
    fixture_root=$(mktemp -d "$HOME/.kapsis-staging-fixture-XXXXXX")
    # shellcheck disable=SC2064  # capture path now
    trap "rm -rf '$fixture_root' 2>/dev/null || true" RETURN

    mkdir -p "$fixture_root/.claude"

    # The fixture settings.json — 3 enabledPlugins, a few other top-level
    # keys to verify they survive the round-trip too.
    cat > "$fixture_root/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "plugin-a@m": true,
    "plugin-b@m": true,
    "plugin-c@m": true
  },
  "model": "claude-opus-4-7",
  "verbose": true,
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "/usr/bin/true"}]
      }
    ]
  }
}
EOF

    # World-readable so developer (uid 1000) inside container can read
    # via --userns=keep-id mapping.
    chmod -R a+rwX "$fixture_root"

    local output exit_code=0
    output=$(podman run --rm \
        --name "kapsis-test-staging-busymount-$$" \
        --userns=keep-id \
        --security-opt label=disable \
        --cap-add=SYS_ADMIN \
        -v "$fixture_root/.claude:/kapsis-staging/.claude:ro" \
        "$KAPSIS_TEST_IMAGE" bash -c '
        set -e
        export HOME=/home/developer
        # Simulate the production bind-mount: $HOME/.claude/conversations
        # is a busy mount that rm -rf cannot unlink.
        mkdir -p $HOME/.claude/conversations
        mkdir -p /tmp/busy-conv-src
        echo "host-conv-file" > /tmp/busy-conv-src/conv.txt
        mount --bind /tmp/busy-conv-src $HOME/.claude/conversations
        trap "umount $HOME/.claude/conversations 2>/dev/null || true" EXIT

        # Capture entrypoint stderr so we can assert on overlay-vs-fallback.
        export KAPSIS_STAGED_CONFIGS=.claude
        export KAPSIS_LOG_LEVEL=info
        source /opt/kapsis/lib/logging.sh
        source /opt/kapsis/lib/atomic-copy.sh
        source /opt/kapsis/lib/compat.sh 2>/dev/null || true

        # Extract setup_staged_config_overlays function from entrypoint.sh
        # without running the whole thing. The function reads
        # KAPSIS_STAGED_CONFIGS, $HOME, and uses fuse-overlayfs/atomic_copy_dir.
        eval "$(awk "/^setup_staged_config_overlays\\(\\) \\{\$/,/^\\}\$/" /opt/kapsis/entrypoint.sh)"

        echo "--- invoking setup_staged_config_overlays ---"
        setup_staged_config_overlays 2>&1
        SSCO_RC=$?
        echo "SSCO_RC=$SSCO_RC"

        # Assertions captured as grep-friendly markers
        echo "--- assertions ---"
        if [ ! -f $HOME/.claude/settings.json ]; then
            echo "ASSERT_FAIL: settings.json missing"
        else
            ENABLED_COUNT=$(jq ".enabledPlugins | length" $HOME/.claude/settings.json 2>/dev/null || echo "PARSE_ERR")
            echo "ENABLED_COUNT=$ENABLED_COUNT"
        fi
        # Regression check: no nested atomic-copy temp dir
        if ls $HOME/.claude/.atomic-copy-dir-* >/dev/null 2>&1; then
            echo "NESTING_BUG"
            ls -la $HOME/.claude/.atomic-copy-dir-*/ 2>&1 | head -5
        else
            echo "NO_NESTING"
        fi
        # Busy mount survived?
        if [ -f $HOME/.claude/conversations/conv.txt ]; then
            echo "BUSY_MOUNT_PRESERVED"
        else
            echo "BUSY_MOUNT_LOST"
        fi
    ' 2>&1) || exit_code=$?

    assert_exit_code 0 "$exit_code" "Container script must exit 0"
    assert_contains "$output" "ENABLED_COUNT=3" \
        "settings.json::enabledPlugins must reach the container with all 3 entries — silent loss here breaks plugin hook injection"
    assert_contains "$output" "NO_NESTING" \
        "No .atomic-copy-dir-* nested inside \$HOME/.claude — load-bearing regression check for the mv-into-existing-dst bug"
    assert_contains "$output" "BUSY_MOUNT_PRESERVED" \
        "Busy conversations bind-mount must survive the staging operation"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Container .claude staging (real-image e2e, PR #380 follow-up)"

    if ! skip_if_no_overlay_rw; then
        echo "Skipping container staging tests — prerequisites not met"
        exit 0
    fi

    setup_test_project

    run_test test_kapsis_upper_work_dirs_exist_and_owned
    run_test test_claude_staging_enabled_plugins_survive_busy_conversations_mount

    cleanup_test_project

    print_summary
}

main "$@"
