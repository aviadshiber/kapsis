#!/usr/bin/env bash
#===============================================================================
# status-sync.sh — Host-side mirror of a Podman status volume (Issue #276)
#
# On macOS we back /kapsis-status with a per-agent Podman named volume that
# lives inside the VM (not over virtio-fs), so agent writes survive virtio-fs
# degradation. Consumers on the host — most importantly
# `kapsis-status.sh --watch`, which polls every 2 seconds — still expect to
# read JSON files from ~/.kapsis/status.
#
# This library bridges the two: start_status_sync spawns a background worker
# that exports the volume into the host status dir on a fixed interval, using
# atomic rename so the reader never sees a torn file. stop_status_sync kills
# the worker and performs a final, synchronous sync so the exit-time state is
# always on disk.
#
# All functions are no-ops when no volume name is provided (Linux path, where
# /kapsis-status remains a direct bind mount).
#===============================================================================

[[ -n "${_KAPSIS_STATUS_SYNC_LOADED:-}" ]] && return 0
_KAPSIS_STATUS_SYNC_LOADED=1

declare -f log_info  &>/dev/null || log_info()  { echo "[INFO] $*"; }
declare -f log_warn  &>/dev/null || log_warn()  { echo "[WARN] $*" >&2; }
declare -f log_error &>/dev/null || log_error() { echo "[ERROR] $*" >&2; }
declare -f log_debug &>/dev/null || log_debug() { [[ "${KAPSIS_DEBUG:-}" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }

_STATUS_SYNC_PODMAN="${KAPSIS_STATUS_SYNC_PODMAN:-podman}"

#-------------------------------------------------------------------------------
# _status_sync_pid_file <agent_id> <host_status_dir>
#
# Returns the path of the PID file used to track the background sync worker.
#-------------------------------------------------------------------------------
_status_sync_pid_file() {
    local agent_id="$1"
    local host_status_dir="$2"
    printf '%s/.sync-%s.pid' "$host_status_dir" "$agent_id"
}

#-------------------------------------------------------------------------------
# _status_sync_once <volume_name> <host_status_dir>
#
# Performs a single export of the named volume into the host status dir.
# Uses `podman volume export | tar -x` so only changed files are rewritten,
# and writes via tar's own --overwrite semantics (whole-file replace).
#
# Silently tolerates transient failures — sync is best-effort: the volume is
# authoritative, host files are a cache for --watch consumers.
#-------------------------------------------------------------------------------
_status_sync_once() {
    local volume_name="$1"
    local host_status_dir="$2"

    mkdir -p "$host_status_dir" 2>/dev/null || return 1

    # `podman volume export` streams a tar of the volume contents to stdout.
    # Extract into the host dir; --overwrite makes updates atomic at the
    # tar-member level (tar uses rename() to replace each file on most tars).
    "$_STATUS_SYNC_PODMAN" volume export "$volume_name" 2>/dev/null \
        | tar -C "$host_status_dir" --no-same-owner -xf - 2>/dev/null \
        || return 1
    return 0
}

#-------------------------------------------------------------------------------
# start_status_sync <agent_id> <volume_name> <host_status_dir> [interval]
#
# Spawns a background worker that mirrors <volume_name> into
# <host_status_dir> every <interval> seconds until stop_status_sync is called
# or the process is killed.
#
# If <volume_name> is empty (Linux path), this is a no-op and returns 0.
#
# Returns 0 on success (worker spawned or no-op), 1 on fatal misuse.
#-------------------------------------------------------------------------------
start_status_sync() {
    local agent_id="${1:-}"
    local volume_name="${2:-}"
    local host_status_dir="${3:-}"
    local interval="${4:-${KAPSIS_STATUS_SYNC_INTERVAL:-${KAPSIS_DEFAULT_STATUS_SYNC_INTERVAL:-2}}}"

    if [[ -z "$agent_id" || -z "$host_status_dir" ]]; then
        log_error "start_status_sync: agent_id and host_status_dir are required"
        return 1
    fi

    # No-op when no volume is configured (Linux / direct bind-mount mode).
    if [[ -z "$volume_name" ]]; then
        log_debug "start_status_sync: no volume configured, skipping (bind-mount mode)"
        return 0
    fi

    # Clamp interval to a sensible range (1..30s).
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 || interval > 30 )); then
        interval=2
    fi

    mkdir -p "$host_status_dir" 2>/dev/null || {
        log_error "start_status_sync: cannot create $host_status_dir"
        return 1
    }

    local pid_file
    pid_file="$(_status_sync_pid_file "$agent_id" "$host_status_dir")"

    # Refuse to double-start.
    if [[ -f "$pid_file" ]]; then
        local existing
        existing="$(cat "$pid_file" 2>/dev/null || echo "")"
        if [[ -n "$existing" ]] && kill -0 "$existing" 2>/dev/null; then
            log_debug "status-sync worker already running (pid=$existing)"
            return 0
        fi
        rm -f "$pid_file" 2>/dev/null || true
    fi

    # Spawn the worker in a subshell so signals to the parent do not kill it
    # prematurely — stop_status_sync is the authoritative terminator.
    # The subshell inherits $volume_name / $host_status_dir / $interval.
    (
        # Worker exits quietly on SIGTERM/SIGINT after a final sync.
        _w_vol="$volume_name"
        _w_dir="$host_status_dir"
        trap '_status_sync_once "$_w_vol" "$_w_dir" >/dev/null 2>&1; exit 0' TERM INT
        while true; do
            _status_sync_once "$_w_vol" "$_w_dir" >/dev/null 2>&1 || true
            sleep "$interval"
        done
    ) &
    local worker_pid=$!
    disown "$worker_pid" 2>/dev/null || true
    printf '%s' "$worker_pid" > "$pid_file"
    log_debug "status-sync worker started (pid=$worker_pid, interval=${interval}s, volume=$volume_name)"
    return 0
}

#-------------------------------------------------------------------------------
# stop_status_sync <agent_id> <volume_name> <host_status_dir>
#
# Terminates the background sync worker (if running) and performs one final
# synchronous export so the exit-time state of the volume is guaranteed to be
# on the host. Safe to call multiple times; safe to call when no worker was
# started (e.g. after an early probe failure).
#
# Returns 0 always.
#-------------------------------------------------------------------------------
stop_status_sync() {
    local agent_id="${1:-}"
    local volume_name="${2:-}"
    local host_status_dir="${3:-}"

    if [[ -z "$agent_id" || -z "$host_status_dir" ]]; then
        return 0
    fi

    local pid_file
    pid_file="$(_status_sync_pid_file "$agent_id" "$host_status_dir")"
    if [[ -f "$pid_file" ]]; then
        local worker_pid
        worker_pid="$(cat "$pid_file" 2>/dev/null || echo "")"
        if [[ -n "$worker_pid" ]] && kill -0 "$worker_pid" 2>/dev/null; then
            kill -TERM "$worker_pid" 2>/dev/null || true
            # Give the worker up to ~2s to drain.
            local i
            for (( i=0; i<20; i++ )); do
                kill -0 "$worker_pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -0 "$worker_pid" 2>/dev/null && kill -KILL "$worker_pid" 2>/dev/null || true
        fi
        rm -f "$pid_file" 2>/dev/null || true
    fi

    # Final sync — runs even if the worker never started, as long as we have a
    # volume name. This is how slack-bot / --watch consumers see the definitive
    # post-exit state.
    if [[ -n "$volume_name" ]]; then
        _status_sync_once "$volume_name" "$host_status_dir" >/dev/null 2>&1 || true
    fi
    return 0
}
