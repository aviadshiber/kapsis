#!/usr/bin/env bash
# scripts/lib/launch-lock.sh
#
# Launch-phase serialization mutex.
#
# Why this exists
# ---------------
# On macOS Podman applehv hosts, the Apple Virtualization framework's
# virtio-fs server has a documented cache-coherency bug (Apple Feedback
# FB16008360, podman/podman#23061, podman/podman#24725) that produces:
#
#   overlayfs: failed to create directory .../<id>/work/work (errno: 13);
#               mounting read-only
#   overlayfs: failed to get metacopy (-2)
#
# inside the VM and surfaces as Kapsis exit code 4 / error_type=mount_failure.
# When two agent launches overlap their heavy host-side metadata I/O window
# (git worktree add on a multi-GB repo, sanitized-git prep, overlay upper/work
# dir creation), the shared AVF virtio-fs cache wedges and ALL in-flight
# containers see lookup failures in the same instant — producing "same-second
# failure cluster" exit-code-4s across unrelated agents.
#
# This helper provides a host-scoped advisory lock that callers wrap around
# their launch I/O burst. While one agent holds the lock, other launches
# block until it is released (plus an optional post-release cooldown so the
# VM-side mount has time to stabilize before the next launch's `podman run`
# starts a fresh overlay).
#
# The lock is INTENTIONALLY scoped per host (not per project / not per repo)
# because the AVF virtio-fs server is a single shared resource. Two agents
# launching against different repos can wedge the same cache.
#
# Design choices
# --------------
# - Uses `mkdir` (atomic on POSIX) for the lock — `flock` is not portable to
#   macOS without an extra Homebrew install, and we already use the mkdir
#   pattern in kapsis (see _gc_lock_acquire in launch-agent.sh).
# - Stale-lock recovery: if the PID file inside the lock dir names a dead
#   process, the lock is force-released and re-acquired. Protects against
#   crashed launches deadlocking the next agent.
# - Default-on for Darwin only. On Linux hosts virtio-fs runs natively in
#   the kernel; the AVF cache race does not apply, so the lock would add
#   pointless contention. Users can override with KAPSIS_LAUNCH_LOCK_ENABLED.
# - Acquire-timeout default 600 s — bounded so a wedged holder eventually
#   fails the new launch loudly rather than hanging forever.
# - Post-cooldown default 5 s on macOS — measured empirically as enough for
#   the VM's overlay mount to settle after `podman run`. Tunable via
#   KAPSIS_LAUNCH_LOCK_POST_COOLDOWN.

# shellcheck disable=SC2034  # used by sourcing scripts
KAPSIS_LAUNCH_LOCK_DIR="${KAPSIS_LAUNCH_LOCK_DIR:-$HOME/.kapsis/locks/launch.lock.d}"
KAPSIS_LAUNCH_LOCK_TIMEOUT="${KAPSIS_LAUNCH_LOCK_TIMEOUT:-600}"

# Default-on for Darwin, default-off elsewhere.
if [[ -z "${KAPSIS_LAUNCH_LOCK_ENABLED:-}" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        KAPSIS_LAUNCH_LOCK_ENABLED=true
    else
        KAPSIS_LAUNCH_LOCK_ENABLED=false
    fi
fi

# 5 s post-cooldown on macOS, 0 elsewhere.
if [[ -z "${KAPSIS_LAUNCH_LOCK_POST_COOLDOWN:-}" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        KAPSIS_LAUNCH_LOCK_POST_COOLDOWN=5
    else
        KAPSIS_LAUNCH_LOCK_POST_COOLDOWN=0
    fi
fi

# Internal state — non-empty when this process holds the lock.
_LAUNCH_LOCK_HELD=""

# launch_lock_acquire — block until the host-scoped launch lock is held.
#
# Returns 0 on success, 1 on timeout or if disabled. Idempotent: a process
# that already holds the lock just returns 0 immediately.
#
# Callers should pair this with launch_lock_release in an EXIT trap so the
# lock is released even on abnormal termination.
launch_lock_acquire() {
    if [[ "$KAPSIS_LAUNCH_LOCK_ENABLED" != "true" ]]; then
        return 0
    fi
    if [[ -n "$_LAUNCH_LOCK_HELD" ]]; then
        return 0  # already held
    fi

    local lock_dir="$KAPSIS_LAUNCH_LOCK_DIR"
    local timeout_s="$KAPSIS_LAUNCH_LOCK_TIMEOUT"
    local pid_file="$lock_dir/pid"

    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || {
        log_warn "launch_lock_acquire: cannot create $(dirname "$lock_dir") — proceeding without lock"
        return 0
    }

    local waited=0
    local logged_wait=false
    while ! mkdir "$lock_dir" 2>/dev/null; do
        # Stale-lock recovery: if PID file names a dead process, reclaim.
        if [[ -f "$pid_file" ]]; then
            local holder_pid
            holder_pid=$(cat "$pid_file" 2>/dev/null || echo "")
            if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
                log_warn "launch_lock_acquire: reclaiming stale lock from dead PID $holder_pid"
                rm -rf "$lock_dir"
                continue
            fi
            if [[ "$logged_wait" != "true" ]] && (( waited == 0 )); then
                log_info "launch_lock_acquire: waiting for launch held by PID ${holder_pid:-unknown} (max ${timeout_s}s)"
                logged_wait=true
            fi
        fi

        if (( waited >= timeout_s )); then
            log_warn "launch_lock_acquire: timeout after ${timeout_s}s — proceeding without lock (risk of virtio-fs cluster failure)"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo "$$" > "$pid_file"
    _LAUNCH_LOCK_HELD="$lock_dir"
    if (( waited > 0 )); then
        log_info "launch_lock_acquire: acquired after ${waited}s wait"
    else
        log_debug "launch_lock_acquire: acquired immediately"
    fi
    return 0
}

# launch_lock_release — release the host-scoped launch lock (with cooldown).
#
# Sleeps for KAPSIS_LAUNCH_LOCK_POST_COOLDOWN seconds BEFORE removing the lock
# dir, giving the VM-side overlay mount time to stabilize so the next agent's
# `podman run` doesn't race the current one.
#
# Safe to call when no lock is held (no-op).
launch_lock_release() {
    if [[ -z "$_LAUNCH_LOCK_HELD" ]]; then
        return 0
    fi

    local cooldown="$KAPSIS_LAUNCH_LOCK_POST_COOLDOWN"
    if (( cooldown > 0 )); then
        log_debug "launch_lock_release: cooldown ${cooldown}s before release"
        sleep "$cooldown"
    fi

    rm -rf "$_LAUNCH_LOCK_HELD" 2>/dev/null || true
    log_debug "launch_lock_release: released $_LAUNCH_LOCK_HELD"
    _LAUNCH_LOCK_HELD=""
}
