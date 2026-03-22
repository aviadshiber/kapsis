#!/usr/bin/env bash
#===============================================================================
# Kapsis Liveness Monitor
#
# Background daemon that monitors agent health inside the container and
# auto-kills hung agent processes. Runs as a background subshell before
# the entrypoint exec's into the agent (same pattern as DNS watchdog).
#
# Detection strategy (two signals, both must be stale to trigger kill):
#   1. status.json updated_at - hook fires on every PostToolUse
#   2. /proc/1/io read_bytes+write_bytes - catches activity during thinking
#
# Kill decision: updated_at stale for timeout AND I/O unchanged for 2+
# consecutive check cycles -> SIGTERM, wait 10s, SIGKILL.
#
# Environment Variables:
#   KAPSIS_LIVENESS_TIMEOUT        - Kill after N seconds of no activity (default: 1800)
#   KAPSIS_LIVENESS_GRACE_PERIOD   - Skip checks for N seconds after start (default: 300)
#   KAPSIS_LIVENESS_CHECK_INTERVAL - Check every N seconds (default: 30)
#
# Usage: Called by entrypoint.sh before exec, not directly.
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_LIVENESS_MONITOR_LOADED:-}" ]] && return 0
_KAPSIS_LIVENESS_MONITOR_LOADED=1

#===============================================================================
# Configuration
#===============================================================================

_LIVENESS_TIMEOUT="${KAPSIS_LIVENESS_TIMEOUT:-1800}"
_LIVENESS_GRACE="${KAPSIS_LIVENESS_GRACE_PERIOD:-300}"
_LIVENESS_INTERVAL="${KAPSIS_LIVENESS_CHECK_INTERVAL:-30}"

# Agent PID to monitor (after exec, the agent becomes PID 1)
_LIVENESS_AGENT_PID=1

#===============================================================================
# Logging (lightweight, no dependency on logging.sh which may not be sourced
# in the background subshell after exec replaces the parent)
#===============================================================================

_liveness_log() {
    local level="$1"
    shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [${level}] liveness-monitor: $*" >&2
}

#===============================================================================
# I/O Monitoring
#===============================================================================

# Read total I/O bytes (read + write) from /proc/<pid>/io
# Returns 0 if /proc/io is unavailable (e.g., restricted permissions)
_liveness_get_io_total() {
    local pid="$1"
    if [[ -r "/proc/${pid}/io" ]]; then
        awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "/proc/${pid}/io" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

#===============================================================================
# Status File Monitoring
#===============================================================================

# Get updated_at timestamp from status.json
# Uses native bash regex to avoid subprocess overhead
_liveness_get_updated_at() {
    local status_dir="/kapsis-status"
    [[ -d "$status_dir" ]] || status_dir="${HOME}/.kapsis/status"

    local status_file
    # Find the status file (there should be exactly one for this agent)
    for f in "$status_dir"/kapsis-*.json; do
        [[ -f "$f" ]] && status_file="$f" && break
    done

    if [[ -n "${status_file:-}" && -f "$status_file" ]]; then
        local content
        content=$(<"$status_file") 2>/dev/null || return
        if [[ "$content" =~ \"updated_at\":\ *\"([^\"]*)\" ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    fi
}

# Write heartbeat to status.json via the status library
# Falls back to direct file update if status functions aren't available
_liveness_write_heartbeat() {
    if type status_set_heartbeat &>/dev/null && type status_is_active &>/dev/null; then
        if status_is_active; then
            status_set_heartbeat
            # Trigger a status write with current phase to persist heartbeat
            local current_phase
            current_phase=$(status_get_phase 2>/dev/null || echo "running")
            status_phase "$current_phase" "" "" 2>/dev/null || true
        fi
    fi
}

# Write killed status to status.json
_liveness_write_killed_status() {
    local reason="$1"
    if type status_phase &>/dev/null && type status_complete &>/dev/null; then
        if type status_is_active &>/dev/null && status_is_active; then
            status_complete 137 "Agent killed by liveness monitor: $reason"
        fi
    fi
}

# Convert ISO 8601 timestamp to epoch seconds
# Handles format: 2026-03-22T10:30:00Z
_liveness_ts_to_epoch() {
    local ts="$1"
    # Remove trailing Z and replace T with space for date parsing
    ts="${ts%Z}"
    ts="${ts/T/ }"
    date -u -d "$ts" +%s 2>/dev/null || \
        date -u -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || \
        echo "0"
}

#===============================================================================
# Monitor Loop
#===============================================================================

_liveness_monitor_loop() {
    local timeout="$_LIVENESS_TIMEOUT"
    local grace="$_LIVENESS_GRACE"
    local interval="$_LIVENESS_INTERVAL"
    local pid="$_LIVENESS_AGENT_PID"

    _liveness_log "INFO" "Starting (timeout=${timeout}s, grace=${grace}s, interval=${interval}s)"

    # Grace period: sleep before starting checks
    if [[ "$grace" -gt 0 ]]; then
        _liveness_log "INFO" "Grace period: sleeping ${grace}s before monitoring"
        sleep "$grace"
    fi

    # State tracking
    local prev_io_total=0
    local prev_updated_at=""
    local stale_seconds=0       # How long updated_at has been stale
    local io_stale_cycles=0     # Consecutive cycles with no I/O change

    # Initialize with current values
    prev_io_total=$(_liveness_get_io_total "$pid")
    prev_updated_at=$(_liveness_get_updated_at)

    _liveness_log "INFO" "Monitoring active (initial io=$prev_io_total)"

    while true; do
        sleep "$interval"

        # Check if agent process is still alive
        if ! kill -0 "$pid" 2>/dev/null; then
            _liveness_log "INFO" "Agent process (PID $pid) no longer running, exiting monitor"
            return 0
        fi

        # Read current values
        local current_io_total
        current_io_total=$(_liveness_get_io_total "$pid")
        local current_updated_at
        current_updated_at=$(_liveness_get_updated_at)

        # Write heartbeat (independent of agent activity)
        _liveness_write_heartbeat

        # Check I/O activity
        if [[ "$current_io_total" == "$prev_io_total" ]]; then
            ((io_stale_cycles++)) || true
        else
            io_stale_cycles=0
            prev_io_total="$current_io_total"
        fi

        # Check updated_at freshness
        if [[ "$current_updated_at" == "$prev_updated_at" ]]; then
            # updated_at hasn't changed since last check
            ((stale_seconds += interval)) || true
        else
            # Hook fired — agent is active
            stale_seconds=0
            prev_updated_at="$current_updated_at"
        fi

        # Decision logic
        if [[ "$stale_seconds" -ge "$timeout" ]]; then
            if [[ "$io_stale_cycles" -ge 2 ]]; then
                # Both signals stale: agent is hung
                _liveness_log "WARN" "Agent hung detected! updated_at stale for ${stale_seconds}s, I/O unchanged for ${io_stale_cycles} cycles"
                _liveness_log "WARN" "Sending SIGTERM to PID $pid"

                # Write killed status before sending signal
                _liveness_write_killed_status "No activity for ${stale_seconds}s (updated_at stale, I/O idle)"

                # SIGTERM first, then SIGKILL after 10s
                kill -SIGTERM "$pid" 2>/dev/null || true
                sleep 10

                if kill -0 "$pid" 2>/dev/null; then
                    _liveness_log "WARN" "Agent did not exit after SIGTERM, sending SIGKILL"
                    kill -SIGKILL "$pid" 2>/dev/null || true
                fi

                _liveness_log "INFO" "Liveness monitor exiting after kill"
                return 0
            else
                _liveness_log "DEBUG" "updated_at stale (${stale_seconds}s) but I/O still active (stale_cycles=$io_stale_cycles) — extending"
            fi
        fi
    done
}

#===============================================================================
# Public API
#===============================================================================

# Start the liveness monitor as a background process
# Must be called before exec (after which PID 1 becomes the agent)
start_liveness_monitor() {
    if [[ "${KAPSIS_LIVENESS_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    _liveness_log "INFO" "Launching background liveness monitor"

    # Run in background subshell (survives exec, reparented to PID 1)
    ( _liveness_monitor_loop ) &
    local monitor_pid=$!

    _liveness_log "INFO" "Liveness monitor started (PID: $monitor_pid)"
}
