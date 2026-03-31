#!/usr/bin/env bash
#===============================================================================
# Kapsis Liveness Monitor
#
# Background daemon that monitors agent health inside the container and
# auto-kills hung agent processes. Runs as a background subshell before
# the entrypoint exec's into the agent (same pattern as DNS watchdog).
#
# Detection strategy (three signals, all must indicate inactivity to trigger kill):
#   1. status.json updated_at - hook fires on every PostToolUse
#   2. /proc/1/io read_bytes+write_bytes - catches activity during thinking
#   3. TCP connections to AI API endpoints on port 443 - catches agents
#      waiting on subagent/API responses (e.g., Task tool calls)
#
# Kill decision: updated_at stale for timeout AND I/O unchanged for 2+
# consecutive check cycles AND no active API connections -> SIGTERM, wait 10s, SIGKILL.
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
        content=$(cat "$status_file" 2>/dev/null) || return
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
            # Trigger a status write to persist heartbeat_at.
            # Read current phase/progress from status file to avoid overwriting them.
            local status_file
            status_file=$(status_get_file 2>/dev/null || echo "")
            local current_phase="running"
            local current_progress=0
            if [[ -n "$status_file" && -f "$status_file" ]]; then
                local file_content
                file_content=$(<"$status_file") 2>/dev/null || true
                if [[ "$file_content" =~ \"phase\":\ *\"([^\"]*)\" ]]; then
                    current_phase="${BASH_REMATCH[1]}"
                fi
                if [[ "$file_content" =~ \"progress\":\ *([0-9]+) ]]; then
                    current_progress="${BASH_REMATCH[1]}"
                fi
            fi
            status_phase "$current_phase" "$current_progress" "" 2>/dev/null || true
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
# Network Activity Detection
#===============================================================================

# Known AI API endpoint domains that agents connect to.
# Used as a third liveness signal: if the agent has active TCP connections
# to these endpoints, it is waiting on an API response (e.g., subagent Task
# tool), not hung.
_LIVENESS_API_DOMAINS=(
    api.anthropic.com
    api.openai.com
    generativelanguage.googleapis.com
    aiplatform.googleapis.com
    bedrock-runtime.amazonaws.com
    api.githubcopilot.com
    openai.azure.com
)

# Resolved IP addresses of AI API endpoints (populated once at monitor start
# by _liveness_resolve_api_ips).  Only connections to these IPs are treated
# as a valid liveness signal — arbitrary port-443 connections are ignored.
_LIVENESS_API_IPS=()

# Resolve _LIVENESS_API_DOMAINS to IP addresses and populate _LIVENESS_API_IPS.
# Called once at the beginning of the monitor loop.  Domains that fail to
# resolve are silently skipped (the agent may not need all providers).
_liveness_resolve_api_ips() {
    _LIVENESS_API_IPS=()
    local domain
    for domain in "${_LIVENESS_API_DOMAINS[@]}"; do
        local ips
        # getent is available in virtually all Linux containers
        if command -v getent &>/dev/null; then
            ips=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u) || true
        elif command -v dig &>/dev/null; then
            ips=$(dig +short A "$domain" 2>/dev/null; dig +short AAAA "$domain" 2>/dev/null) || true
        elif command -v host &>/dev/null; then
            ips=$(host "$domain" 2>/dev/null | awk '/has (IPv[46] )?address/ {print $NF}') || true
        fi
        local ip
        for ip in $ips; do
            # Basic sanity: skip empty/error lines
            [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]] && _LIVENESS_API_IPS+=("$ip")
        done
    done

    if [[ ${#_LIVENESS_API_IPS[@]} -gt 0 ]]; then
        _liveness_log "INFO" "Resolved ${#_LIVENESS_API_IPS[@]} API endpoint IPs for liveness checks"
    else
        _liveness_log "WARN" "Could not resolve any API endpoint IPs — API connection check will be unavailable"
    fi
}

# Convert an IPv4 address to the hex format used in /proc/net/tcp.
# Example: 104.18.0.1 -> 01001268  (little-endian 32-bit)
_liveness_ip4_to_proc_hex() {
    local ip="$1"
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    # /proc/net/tcp stores IPv4 in little-endian hex
    printf '%02X%02X%02X%02X' "${octets[3]}" "${octets[2]}" "${octets[1]}" "${octets[0]}"
}

# Convert an IPv6 address to the hex format used in /proc/net/tcp6.
# Expands :: notation and outputs 32 hex chars (groups in little-endian 32-bit words).
_liveness_ip6_to_proc_hex() {
    local ip="$1"
    # Expand IPv6 via printf trick: use python or perl if available, else skip
    local expanded
    if command -v python3 &>/dev/null; then
        expanded=$(python3 -c "import ipaddress; print(ipaddress.ip_address('$ip').exploded)" 2>/dev/null) || return 1
    else
        return 1
    fi

    # Remove colons -> 32 hex chars
    expanded="${expanded//:/}"
    # /proc/net/tcp6 stores each 32-bit word in little-endian
    local result=""
    local i
    for i in 0 8 16 24; do
        local word="${expanded:$i:8}"
        # Reverse byte order within each 32-bit word
        result+="${word:6:2}${word:4:2}${word:2:2}${word:0:2}"
    done
    echo "$result"
}

# Check whether the agent (PID 1) has established TCP connections to known
# AI API endpoints on port 443.  Returns 0 (true) if at least one such
# connection exists, 1 otherwise.
#
# SECURITY: Only matches connections to IPs resolved from _LIVENESS_API_DOMAINS
# at monitor startup — not arbitrary port-443 traffic.  This prevents a
# compromised agent from keeping any HTTPS connection open to bypass the
# liveness kill.
#
# Strategy:
#   1. Preferred: `ss -tn state established` — available in most containers
#      that include iproute2.  Filters output against resolved API IPs.
#   2. Fallback: parse /proc/net/tcp{,6} directly — always available on Linux.
#      Matches hex-encoded API IPs with ESTABLISHED state on port 01BB (443).
_liveness_has_active_api_connections() {
    # No resolved IPs means we cannot perform this check
    if [[ ${#_LIVENESS_API_IPS[@]} -eq 0 ]]; then
        return 1
    fi

    # --- Method 1: ss (iproute2) -------------------------------------------
    if command -v ss &>/dev/null; then
        local ss_output
        ss_output=$(ss -tn state established 2>/dev/null) || true
        if [[ -n "$ss_output" ]]; then
            local ip
            for ip in "${_LIVENESS_API_IPS[@]}"; do
                # Match remote address ip:443 — bracket IPv6 in ss output
                if [[ "$ip" == *:* ]]; then
                    # IPv6: ss shows [ip]:port
                    echo "$ss_output" | grep -qF "[${ip}]:443" && {
                        _liveness_log "DEBUG" "Active API connection to [${ip}]:443 detected via ss"
                        return 0
                    }
                else
                    # IPv4: ss shows ip:port
                    echo "$ss_output" | grep -qF "${ip}:443" && {
                        _liveness_log "DEBUG" "Active API connection to ${ip}:443 detected via ss"
                        return 0
                    }
                fi
            done
        fi
    fi

    # --- Method 2: /proc/net/tcp{,6} ---------------------------------------
    # Build a set of hex-encoded API IPs for fast matching
    local -a hex_ipv4=()
    local -a hex_ipv6=()
    local ip
    for ip in "${_LIVENESS_API_IPS[@]}"; do
        if [[ "$ip" == *:* ]]; then
            local hex
            hex=$(_liveness_ip6_to_proc_hex "$ip") && [[ -n "$hex" ]] && hex_ipv6+=("$hex")
        else
            hex_ipv4+=("$(_liveness_ip4_to_proc_hex "$ip")")
        fi
    done

    # Check /proc/net/tcp (IPv4)
    if [[ -r /proc/net/tcp && ${#hex_ipv4[@]} -gt 0 ]]; then
        local hex_pattern
        hex_pattern=$(IFS='|'; echo "${hex_ipv4[*]}")
        # Column 3 = remote addr:port, column 4 = state; 01 = ESTABLISHED, 01BB = port 443
        if awk -v ips="$hex_pattern" '
            BEGIN { split(ips, arr, "|"); for (i in arr) ipset[arr[i]] = 1 }
            $4 == "01" && $3 ~ /:01BB$/ {
                split($3, a, ":");
                if (a[1] in ipset) { found=1; exit }
            }
            END { exit !found }
        ' /proc/net/tcp 2>/dev/null; then
            _liveness_log "DEBUG" "Active API connection detected via /proc/net/tcp"
            return 0
        fi
    fi

    # Check /proc/net/tcp6 (IPv6)
    if [[ -r /proc/net/tcp6 && ${#hex_ipv6[@]} -gt 0 ]]; then
        local hex_pattern
        hex_pattern=$(IFS='|'; echo "${hex_ipv6[*]}")
        if awk -v ips="$hex_pattern" '
            BEGIN { split(ips, arr, "|"); for (i in arr) ipset[arr[i]] = 1 }
            $4 == "01" && $3 ~ /:01BB$/ {
                split($3, a, ":");
                if (a[1] in ipset) { found=1; exit }
            }
            END { exit !found }
        ' /proc/net/tcp6 2>/dev/null; then
            _liveness_log "DEBUG" "Active API connection detected via /proc/net/tcp6"
            return 0
        fi
    fi

    return 1
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

    # Resolve API endpoint IPs once at startup for connection checking
    _liveness_resolve_api_ips

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
                # Both signals stale — but check for active API connections
                # before killing. An agent waiting on a subagent API response
                # (e.g., Task tool) has no disk I/O and no hook fires, but it
                # IS alive: it holds an ESTABLISHED TCP connection to the API.
                if _liveness_has_active_api_connections; then
                    _liveness_log "INFO" "updated_at stale (${stale_seconds}s) and I/O idle (${io_stale_cycles} cycles), but active API connection(s) found — skipping kill"
                    continue
                fi

                # All three signals confirm the agent is hung
                _liveness_log "WARN" "Agent hung detected! updated_at stale for ${stale_seconds}s, I/O unchanged for ${io_stale_cycles} cycles, no active API connections"
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
