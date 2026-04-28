#!/usr/bin/env bash
#===============================================================================
# Kapsis Liveness Monitor
#
# Background daemon that monitors agent health inside the container and
# auto-kills hung agent processes. Runs as a background subshell before
# the entrypoint exec's into the agent (same pattern as DNS watchdog).
#
# Detection strategy (three signals; all must indicate inactivity to trigger kill):
#   1. status.json updated_at - hook fires on every PostToolUse
#   2. /proc/1/io read_bytes+write_bytes - catches activity during thinking
#   3. TCP connection quality to AI API endpoints (port 443) — two-tier grace:
#        "active"  (rx/tx queues or retransmit non-zero) → soft grace (Issue #267)
#        "idle"    (connection open but all queues zero)  → hard grace (Issue #267)
#
# Kill decision: updated_at stale for timeout AND I/O unchanged for 2+
# consecutive check cycles THEN Signal 3 provides bounded grace:
#   active connection → up to api_soft_skip cycles before kill
#   idle connection   → up to api_hard_skip cycles before kill
#   no connection     → kill immediately
# SIGTERM, wait 10s, SIGKILL.
#
# DNS Security Model (two layers):
#   1. Host-pinned baseline from /etc/kapsis/pinned-dns.conf (read-only
#      mount — cannot be tampered with inside the container). IPs are
#      NEVER discarded at runtime.
#   2. Union-only TTL-aware re-resolution: periodic refresh adds new IPs
#      but never removes pinned ones. DNS poisoning can only expand the
#      allowlist (less dangerous than false kills).
#
# Environment Variables:
#   KAPSIS_LIVENESS_TIMEOUT            - Kill after N seconds of no activity (default: 900)
#   KAPSIS_LIVENESS_GRACE_PERIOD       - Skip checks for N seconds after start (default: 300)
#   KAPSIS_LIVENESS_CHECK_INTERVAL     - Check every N seconds (default: 30)
#   KAPSIS_LIVENESS_IPS_TTL            - Re-resolve API IPs after N seconds (default: 300)
#   KAPSIS_LIVENESS_DNS_TIMEOUT        - DNS resolution timeout in seconds (default: 2)
#   KAPSIS_LIVENESS_MAX_IPS_PER_DOMAIN - Max IPs to track per domain (default: 8)
#   KAPSIS_LIVENESS_API_SOFT_SKIP      - Grace cycles for active connections (default: 20 = 10 min)
#   KAPSIS_LIVENESS_API_HARD_SKIP      - Grace cycles for idle connections (default: 6 = 3 min)
#
# Usage: Called by entrypoint.sh before exec, not directly.
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_LIVENESS_MONITOR_LOADED:-}" ]] && return 0
_KAPSIS_LIVENESS_MONITOR_LOADED=1

#===============================================================================
# Configuration
#===============================================================================

_LIVENESS_TIMEOUT="${KAPSIS_LIVENESS_TIMEOUT:-900}"
_LIVENESS_GRACE="${KAPSIS_LIVENESS_GRACE_PERIOD:-300}"
_LIVENESS_INTERVAL="${KAPSIS_LIVENESS_CHECK_INTERVAL:-30}"

# API connection signal configuration
_LIVENESS_IPS_TTL="${KAPSIS_LIVENESS_IPS_TTL:-300}"
_LIVENESS_DNS_TIMEOUT="${KAPSIS_LIVENESS_DNS_TIMEOUT:-2}"
_LIVENESS_MAX_IPS_PER_DOMAIN="${KAPSIS_LIVENESS_MAX_IPS_PER_DOMAIN:-8}"

# Two-tier API grace (Issue #267): bounded deferral based on connection quality.
# Soft grace: connection has data in flight (rx/tx queue non-zero or retransmitting).
# Hard grace: connection open but all queues zero (keepalive, thinking phase, or zombie).
# With a 30s check interval: 20 cycles = 10 min soft, 6 cycles = 3 min hard.
_LIVENESS_API_SOFT_SKIP="${KAPSIS_LIVENESS_API_SOFT_SKIP:-20}"
_LIVENESS_API_HARD_SKIP="${KAPSIS_LIVENESS_API_HARD_SKIP:-6}"

# Overrideable proc paths — set to temp files in tests
_LIVENESS_PROC_TCP="${_LIVENESS_PROC_TCP:-/proc/net/tcp}"
_LIVENESS_PROC_TCP6="${_LIVENESS_PROC_TCP6:-/proc/net/tcp6}"

# Post-completion short timeout (Issue #257): when agent reports completion
# but process hasn't exited, use this shorter timeout instead of the full timeout
_LIVENESS_COMPLETION_TIMEOUT="${KAPSIS_LIVENESS_COMPLETION_TIMEOUT:-120}"

# Mount check configuration (Issue #248) — independent of liveness timeout kill
_MOUNT_CHECK_ENABLED="${KAPSIS_MOUNT_CHECK_ENABLED:-false}"
_MOUNT_CHECK_RETRIES="${KAPSIS_MOUNT_CHECK_RETRIES:-2}"
_MOUNT_CHECK_RETRY_DELAY="${KAPSIS_MOUNT_CHECK_RETRY_DELAY:-5}"
_MOUNT_CHECK_PROBE_TIMEOUT="${KAPSIS_MOUNT_CHECK_PROBE_TIMEOUT:-5}"
_MOUNT_CHECK_DELAY="${KAPSIS_MOUNT_CHECK_DELAY:-30}"

# AI API domains to monitor for active connections
_LIVENESS_API_DOMAINS=(
    api.anthropic.com
    api.openai.com
    generativelanguage.googleapis.com
    aiplatform.googleapis.com
    bedrock-runtime.amazonaws.com
    api.githubcopilot.com
    openai.azure.com
)

# Layer 1: permanent host-pinned IP baseline (populated from pinned-dns.conf)
_LIVENESS_API_IPS_PINNED=()
# Layer 2: working union set (pinned + resolved, never shrinks below pinned)
_LIVENESS_API_IPS=()
# Epoch seconds of last successful IP resolution (0 = never resolved)
_LIVENESS_IPS_LAST_RESOLVED=0
# Two-tier grace counters (Issue #267): separate counts for active vs idle connections
_LIVENESS_API_SOFT_COUNT=0
_LIVENESS_API_HARD_COUNT=0
# Cached path to ss binary (set once at init, avoids per-cycle command -v)
_LIVENESS_SS_BIN=""
# Cached little-endian hex representations of _LIVENESS_API_IPS for /proc/net/tcp
_LIVENESS_HEX_IPV4=()
_LIVENESS_HEX_IPV6=()

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

# Read total I/O bytes (read + write) across all container processes (Issue #257)
# In container PID namespace, /proc/[0-9]*/io covers only container processes.
# Summing all descendants detects I/O from child processes (MCP servers, tool calls)
# that PID 1's /proc/1/io alone would miss.
# Returns 0 if /proc/io is unavailable (e.g., restricted permissions)
_liveness_get_io_total() {
    local pid="$1"
    # shellcheck disable=SC2086,SC2035
    awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' /proc/[0-9]*/io 2>/dev/null || echo "0"
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

# Get phase from status.json (Issue #257)
# Uses native bash regex to avoid subprocess overhead (same pattern as _liveness_get_updated_at)
_liveness_get_phase() {
    local status_dir="/kapsis-status"
    [[ -d "$status_dir" ]] || status_dir="${HOME}/.kapsis/status"

    local status_file
    for f in "$status_dir"/kapsis-*.json; do
        [[ -f "$f" ]] && status_file="$f" && break
    done

    if [[ -n "${status_file:-}" && -f "$status_file" ]]; then
        local content
        content=$(cat "$status_file" 2>/dev/null) || return
        if [[ "$content" =~ \"phase\":\ *\"([^\"]*)\" ]]; then
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

# Write killed status to status.json (Issue #257: exit code 5 when post-completion)
_liveness_write_killed_status() {
    local reason="$1"
    if type status_phase &>/dev/null && type status_complete &>/dev/null; then
        if type status_is_active &>/dev/null && status_is_active; then
            local phase
            phase=$(_liveness_get_phase)
            local exit_code=137
            if [[ "$phase" == "complete" || "$phase" == "committing" || "$phase" == "pushing" ]]; then
                exit_code=5
                _liveness_log "INFO" "Phase is '$phase' — using exit code 5 (hung after completion)"
            fi
            status_complete "$exit_code" "Agent killed by liveness monitor: $reason"
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
# API Connection Signal
#===============================================================================

# Load pinned IP baseline from host-side pinned DNS file (Layer 1).
# File format: "domain IP1 IP2 ..." per line, # comments (dns-pin.sh format).
# Filters to domains in _LIVENESS_API_DOMAINS and populates _LIVENESS_API_IPS_PINNED.
# If file is absent: logs DEBUG and returns 0 (degraded, not fatal).
_liveness_load_pinned_ips() {
    # KAPSIS_DNS_PINNED_FILE is defined in dns-filter.sh; match its default
    local pinned_file="${KAPSIS_DNS_PINNED_FILE:-/etc/kapsis/pinned-dns.conf}"

    if [[ ! -f "$pinned_file" ]]; then
        _liveness_log "DEBUG" "No pinned DNS file at $pinned_file — Layer 1 baseline empty"
        return 0
    fi

    local domain ip ips_str d is_api_domain
    while IFS= read -r line; do
        # Skip blank lines and comments (dns-pin.sh format: # comment)
        [[ -z "$line" || "$line" == "#"* ]] && continue

        # Parse: "domain IP1 IP2 ..." (write_pinned_dns_file() native format)
        domain="${line%% *}"
        ips_str="${line#* }"

        # Skip malformed lines (no space separator)
        [[ -z "$domain" || "$domain" == "$ips_str" ]] && continue

        # Filter: only store IPs for domains we monitor
        is_api_domain=0
        for d in "${_LIVENESS_API_DOMAINS[@]}"; do
            if [[ "$domain" == "$d" ]]; then
                is_api_domain=1
                break
            fi
        done
        [[ "$is_api_domain" -eq 0 ]] && continue

        # Add each space-separated IP from this line to the pinned baseline
        # shellcheck disable=SC2086  # Intentional word split: $ips_str is space-separated IPs
        for ip in $ips_str; do
            [[ -z "$ip" ]] && continue
            _LIVENESS_API_IPS_PINNED+=("$ip")
        done
    done < "$pinned_file"

    _liveness_log "DEBUG" "Pinned baseline loaded: ${#_LIVENESS_API_IPS_PINNED[@]} IPs from $pinned_file"
}

# Convert IPv4 address to little-endian hex for /proc/net/tcp remote address column.
# /proc/net/tcp stores addresses as 4-byte little-endian hex, e.g.:
#   1.2.3.4   → 04030201
#   127.0.0.1 → 0100007F
_liveness_ip4_to_proc_hex() {
    local ip="$1"
    local a b c d
    # Inline IFS avoids 'local IFS' scoping issues under set -euo pipefail
    IFS='.' read -r a b c d <<< "$ip"
    printf '%02X%02X%02X%02X' "$d" "$c" "$b" "$a"
}

# Convert IPv6 address to little-endian 4-byte-group hex for /proc/net/tcp6.
# /proc/net/tcp6 stores each 4-byte group of the 16-byte address little-endian, e.g.:
#   ::1 → 00000000000000000000000001000000
# Returns 1 (emitting nothing) if python3 is unavailable or the IP is invalid.
# IP is passed as sys.argv[1] (not interpolated into code) to prevent injection.
_liveness_ip6_to_proc_hex() {
    local ip="$1"
    # Validate character set before passing to python3
    [[ "$ip" =~ ^[0-9a-fA-F:\.]+$ ]] || return 1
    command -v python3 &>/dev/null || return 1
    python3 - "$ip" <<'PYEOF'
import sys, socket, struct
try:
    packed = socket.inet_pton(socket.AF_INET6, sys.argv[1])
    result = ''
    for i in range(0, 16, 4):
        result += '%08X' % struct.unpack('<I', packed[i:i+4])[0]
    print(result)
except Exception:
    sys.exit(1)
PYEOF
}

# Rebuild the /proc/net/tcp hex cache from current _LIVENESS_API_IPS.
# Called once after each IP resolution cycle to avoid per-check hex recomputation.
_liveness_rebuild_hex_cache() {
    _LIVENESS_HEX_IPV4=()
    _LIVENESS_HEX_IPV6=()
    local ip hex
    for ip in "${_LIVENESS_API_IPS[@]+"${_LIVENESS_API_IPS[@]}"}"; do
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            hex=$(_liveness_ip4_to_proc_hex "$ip") && _LIVENESS_HEX_IPV4+=("$hex") || true
        elif [[ "$ip" =~ : ]]; then
            hex=$(_liveness_ip6_to_proc_hex "$ip") && _LIVENESS_HEX_IPV6+=("$hex") || true
        fi
    done
}

# TTL-aware union-only IP resolution (Layer 2).
# Reuses resolve_domain_ips() from scripts/lib/compat.sh — does NOT reimplement
# the dig/host/nslookup/python3 fallback chain.
# Security guarantee: pinned IPs are seeded first and NEVER removed.
# Re-resolution can only ADD IPs, not remove them.
#
# Latency note: resolution runs synchronously in the monitor loop. Worst-case
# added latency per cycle when TTL expires = |_LIVENESS_API_DOMAINS| × DNS_TIMEOUT
# (7 × 2s = 14s at defaults). Kills are not blocked — the loop continues after
# resolution — but heartbeat timing may skew slightly on slow DNS.
_liveness_resolve_api_ips() {
    local now
    now=$(date +%s)

    # TTL guard: skip if resolved recently enough
    if [[ "$_LIVENESS_IPS_LAST_RESOLVED" -gt 0 ]] \
        && [[ $(( now - _LIVENESS_IPS_LAST_RESOLVED )) -lt "$_LIVENESS_IPS_TTL" ]]; then
        return 0
    fi

    # Seed working set from pinned baseline (union-only: pinned IPs are NEVER removed)
    declare -A _liveness_seen=()
    _LIVENESS_API_IPS=()
    local ip
    for ip in "${_LIVENESS_API_IPS_PINNED[@]+"${_LIVENESS_API_IPS_PINNED[@]}"}"; do
        if [[ -z "${_liveness_seen[$ip]+x}" ]]; then
            _liveness_seen[$ip]=1
            _LIVENESS_API_IPS+=("$ip")
        fi
    done

    # Source compat.sh if resolve_domain_ips is not already in scope.
    # compat.sh is installed at /opt/kapsis/lib/compat.sh inside containers.
    if ! declare -f resolve_domain_ips &>/dev/null; then
        source "/opt/kapsis/lib/compat.sh" 2>/dev/null || true
    fi

    if declare -f resolve_domain_ips &>/dev/null; then
        local domain
        for domain in "${_LIVENESS_API_DOMAINS[@]}"; do
            local resolved count=0
            resolved=$(resolve_domain_ips "$domain" "$_LIVENESS_DNS_TIMEOUT" 2>/dev/null) || continue
            while IFS= read -r ip; do
                [[ -z "$ip" ]] && continue
                (( count >= _LIVENESS_MAX_IPS_PER_DOMAIN )) && break
                if [[ -z "${_liveness_seen[$ip]+x}" ]]; then
                    _liveness_seen[$ip]=1
                    _LIVENESS_API_IPS+=("$ip")
                fi
                (( count++ )) || true
            done <<< "$resolved"
        done
    fi

    _LIVENESS_IPS_LAST_RESOLVED="$now"
    _liveness_log "DEBUG" "API IPs refreshed: ${#_LIVENESS_API_IPS[@]} total (${#_LIVENESS_API_IPS_PINNED[@]} pinned)"
    _liveness_rebuild_hex_cache
}

# Shared awk helper for /proc/net/tcp and /proc/net/tcp6 IP matching.
# Eliminates duplication between IPv4 and IPv6 /proc/net paths.
# Usage: _liveness_check_proc_tcp_ips <file> <pipe-separated-hex-ips>
# Returns 0 if any listed IP has an ESTABLISHED (state=01) connection to port 443 (01BB).
# HTTPS only — non-443 API ports (e.g. gRPC streams on 443 still covered; plain HTTP not).
_liveness_check_proc_tcp_ips() {
    local file="$1" hex_pattern="$2"
    [[ -r "$file" ]] || return 1
    awk -v ips="$hex_pattern" '
        BEGIN { split(ips, arr, "|"); for (i in arr) ipset[arr[i]] = 1 }
        $4 == "01" && $3 ~ /:01BB$/ {
            split($3, a, ":"); if (a[1] in ipset) { found=1; exit }
        }
        END { exit !found }
    ' "$file" 2>/dev/null
}

# Return connection quality to AI API endpoints (Issue #267 two-tier grace).
#
# Checks /proc/net/tcp[6] for ESTABLISHED connections to known API IPs on port 443.
# Quality is determined by tx_queue, rx_queue, and retransmit fields:
#   "active" — connection found with non-zero tx/rx queue or retransmit counter
#              (data physically in flight — credible live signal)
#   "idle"   — connection found but all queues zero (keepalive, thinking phase, or zombie)
#   "none"   — no ESTABLISHED connection to any API IP found
#
# Falls back to ss for existence detection when /proc/net/tcp has no hex cache.
# Queue-depth quality check uses /proc/net/tcp exclusively (has the data; ss does not).
_liveness_api_connection_strength() {
    [[ "${#_LIVENESS_API_IPS[@]}" -eq 0 ]] && { echo "none"; return 0; }

    # Primary path: /proc/net/tcp — always available in containers, has queue data.
    # /proc/net/tcp format: sl local_addr rem_addr st tx_queue:rx_queue tr:tm retrnsmt ...
    # state 01=ESTABLISHED, port 01BB=443 (hex).
    # Queue fields: $5 = "TTTTTTTT:RRRRRRRR" (hex); $7 = retransmit count (hex).
    local _liveness_awk_prog='
        BEGIN { split(ips, arr, "|"); for (i in arr) ipset[arr[i]] = 1; found=0; active=0 }
        $4 == "01" && $3 ~ /:01BB$/ {
            split($3, a, ":")
            if (a[1] in ipset) {
                found = 1
                split($5, q, ":")
                if (q[1] != "00000000" || q[2] != "00000000" || $7 != "00000000") active = 1
            }
        }
        END { print found ":" active }
    '

    if [[ "${#_LIVENESS_HEX_IPV4[@]}" -gt 0 && -r "$_LIVENESS_PROC_TCP" ]]; then
        local hex_pattern result
        hex_pattern=$(IFS='|'; echo "${_LIVENESS_HEX_IPV4[*]}")
        result=$(awk -v ips="$hex_pattern" "$_liveness_awk_prog" "$_LIVENESS_PROC_TCP" 2>/dev/null) || true
        case "$result" in
            "1:1") echo "active"; return 0 ;;
            "1:0") echo "idle";   return 0 ;;
        esac
    fi

    if [[ "${#_LIVENESS_HEX_IPV6[@]}" -gt 0 && -r "$_LIVENESS_PROC_TCP6" ]]; then
        local hex_pattern result
        hex_pattern=$(IFS='|'; echo "${_LIVENESS_HEX_IPV6[*]}")
        result=$(awk -v ips="$hex_pattern" "$_liveness_awk_prog" "$_LIVENESS_PROC_TCP6" 2>/dev/null) || true
        case "$result" in
            "1:1") echo "active"; return 0 ;;
            "1:0") echo "idle";   return 0 ;;
        esac
    fi

    # Fallback: ss for existence when /proc hex cache is empty.
    # Queue data is unavailable via ss in this path — treat as idle (conservative).
    if [[ -n "$_LIVENESS_SS_BIN" ]]; then
        local ss_output
        ss_output=$("$_LIVENESS_SS_BIN" -tn state established 2>/dev/null | tail -n +2)
        local ip
        for ip in "${_LIVENESS_API_IPS[@]}"; do
            if [[ "$ip" =~ : ]]; then
                [[ "$ss_output" == *" [${ip}]:443"* ]] && { echo "idle"; return 0; }
            else
                [[ "$ss_output" == *" ${ip}:443"* ]] && { echo "idle"; return 0; }
            fi
        done
    fi

    echo "none"
}

# Backward-compatible wrapper: returns 0 if any API connection found, 1 otherwise.
# New code should call _liveness_api_connection_strength() directly for quality info.
_liveness_has_active_api_connections() {
    [[ "$(_liveness_api_connection_strength)" != "none" ]]
}

# Initialize the API connection signal state.
# Must be called before the subshell launch so that the subshell inherits
# the cached ss path, pinned IPs, and initial resolved IP set.
_liveness_init_api_signal() {
    # Deprecation warnings for removed single-tier config vars (Issue #267)
    if [[ -n "${KAPSIS_LIVENESS_API_MAX_SKIP:-}" ]]; then
        _liveness_log "WARN" "KAPSIS_LIVENESS_API_MAX_SKIP is ignored — replaced by KAPSIS_LIVENESS_API_SOFT_SKIP / KAPSIS_LIVENESS_API_HARD_SKIP (issue #267)"
    fi
    if [[ -n "${KAPSIS_LIVENESS_API_STALENESS_OVERRIDE:-}" ]]; then
        _liveness_log "WARN" "KAPSIS_LIVENESS_API_STALENESS_OVERRIDE is ignored — replaced by two-tier grace caps (issue #267)"
    fi
    # Cache ss binary path once (avoids command -v per check cycle)
    _LIVENESS_SS_BIN=$(command -v ss 2>/dev/null) || true
    # Layer 1: load host-pinned IP baseline
    _liveness_load_pinned_ips
    # Force initial resolution immediately (TTL guard will be bypassed)
    _LIVENESS_IPS_LAST_RESOLVED=0
    _liveness_resolve_api_ips
    _liveness_log "INFO" "API signal initialized: ${#_LIVENESS_API_IPS[@]} IPs tracked, ss=${_LIVENESS_SS_BIN:-none}, soft_skip=${_LIVENESS_API_SOFT_SKIP}, hard_skip=${_LIVENESS_API_HARD_SKIP}"
}

#===============================================================================
# Mount Check (Issue #248)
#
# Detects virtio-fs mount drops on macOS during container execution.
# The mount can silently disconnect while the agent is running, making all
# files under /workspace inaccessible. Every probe uses `timeout` because
# degraded virtio-fs can hang stat/ls calls indefinitely.
#
# Signaling: writes a sentinel line to stderr (captured by podman's tee
# pipeline), since /kapsis-status may also be on the same virtio-fs mount.
#===============================================================================

# Check if the workspace mount is still accessible.
# Returns 0 if mount is healthy, 1 if mount appears dropped,
# 124 if probe timed out (hung I/O — definitive failure).
_mount_check_probe() {
    # _MOUNT_CHECK_WORKSPACE overrides the readonly CONTAINER_WORKSPACE_PATH for testing
    local workspace="${_MOUNT_CHECK_WORKSPACE:-${CONTAINER_WORKSPACE_PATH:-/workspace}}"
    local probe_timeout="$_MOUNT_CHECK_PROBE_TIMEOUT"

    # Primary probe: stat the workspace directory itself
    # If virtio-fs drops, stat will fail with ENOENT or EIO, or hang (exit 124)
    # Preserve exact exit code so callers can distinguish timeout (124) from error (1)
    local rc
    timeout "$probe_timeout" stat "$workspace" >/dev/null 2>&1
    rc=$?
    [[ $rc -ne 0 ]] && return $rc

    # Secondary probe: verify files are accessible (empty dir = mount dropped)
    local listing
    listing=$(timeout "$probe_timeout" ls -A "$workspace" 2>/dev/null)
    rc=$?
    [[ $rc -ne 0 ]] && return $rc
    if [[ -z "$listing" ]]; then
        return 1
    fi

    # Tertiary probe (worktree mode only): check git sentinel
    # Catches partial mount degradation where listing works but file reads fail
    if [[ "${KAPSIS_SANDBOX_MODE:-overlay}" == "worktree" ]]; then
        local git_safe="${_MOUNT_CHECK_GIT_PATH:-${CONTAINER_GIT_PATH:-/workspace/.git-safe}}"
        # Use timeout for -d check too — even test -d can hang on severely degraded virtio-fs
        timeout "$probe_timeout" test -d "$git_safe" 2>/dev/null
        rc=$?
        [[ $rc -eq 124 ]] && return $rc  # Hung — report timeout to caller
        if [[ $rc -eq 0 ]]; then
            timeout "$probe_timeout" stat "$git_safe/HEAD" >/dev/null 2>&1
            rc=$?
            [[ $rc -ne 0 ]] && return $rc
        fi
    fi

    return 0
}

# Perform mount check with retries.
# Returns 0 if mount is healthy, 1 if mount failure confirmed.
# If probe hangs (timeout exit 124), skips retries — a hang is definitive.
_mount_check_with_retries() {
    local retries="$_MOUNT_CHECK_RETRIES"
    local delay="$_MOUNT_CHECK_RETRY_DELAY"

    # First check
    _mount_check_probe
    local probe_exit=$?

    if [[ "$probe_exit" -eq 0 ]]; then
        return 0
    fi

    # Check if timeout killed the probe (exit 124) — skip retries for hangs
    if [[ "$probe_exit" -eq 124 ]]; then
        _liveness_log "WARN" "Mount probe timed out (hung I/O) — skipping retries"
        return 1
    fi

    _liveness_log "WARN" "Mount check failed, retrying ${retries} times (delay=${delay}s)"

    local i
    for (( i=1; i<=retries; i++ )); do
        sleep "$delay"
        _mount_check_probe
        local retry_rc=$?
        if [[ "$retry_rc" -eq 0 ]]; then
            _liveness_log "INFO" "Mount check recovered on retry $i"
            return 0
        fi
        if [[ "$retry_rc" -eq 124 ]]; then
            _liveness_log "WARN" "Mount probe timed out on retry $i — aborting retries"
            return 1
        fi
        _liveness_log "WARN" "Mount check retry $i/$retries failed"
    done

    return 1
}

# Write mount-failure status and sentinel line.
# Status write may fail if /kapsis-status is also on virtio-fs — that's OK,
# the stderr sentinel reaches the host via podman's pipe regardless.
_mount_check_write_failed_status() {
    # Write sentinel to stderr — captured by podman tee pipeline on host.
    # Sentinel format (Issue #276 review): tag with the emitting subsystem so
    # the host-side grep is anchored and cannot match arbitrary agent log
    # lines that happen to contain "KAPSIS_MOUNT_FAILURE:" verbatim.
    _liveness_log "ERROR" "KAPSIS_MOUNT_FAILURE[liveness_monitor]: /workspace inaccessible (virtio-fs drop)"

    # Best-effort status write. Explicit error_type="mount_failure" makes the
    # JSON status the source of truth; the stderr sentinel remains as
    # defence-in-depth for cases where the status write itself fails (e.g.
    # when /kapsis-status is also on virtio-fs, pre-#276 macOS install).
    if type status_phase &>/dev/null && type status_complete &>/dev/null; then
        if type status_is_active &>/dev/null && status_is_active; then
            type status_set_error_type &>/dev/null \
                && status_set_error_type "mount_failure" 2>/dev/null || true
            status_complete 4 "Workspace mount lost: /workspace became inaccessible (virtio-fs drop)" 2>/dev/null || true
        fi
    fi
}

# Kill the agent after confirmed mount failure.
_mount_check_kill_agent() {
    local pid="$_LIVENESS_AGENT_PID"

    _liveness_log "ERROR" "MOUNT FAILURE CONFIRMED: /workspace is inaccessible"
    _liveness_log "ERROR" "Likely cause: macOS Podman VM virtio-fs mount drop"
    _liveness_log "ERROR" "Killing agent (PID $pid)"

    # Write status + sentinel before killing
    _mount_check_write_failed_status

    # SIGTERM first, then SIGKILL after 10s (same pattern as liveness kill)
    kill -SIGTERM "$pid" 2>/dev/null || true
    sleep 10

    if kill -0 "$pid" 2>/dev/null; then
        _liveness_log "WARN" "Agent did not exit after SIGTERM, sending SIGKILL"
        kill -SIGKILL "$pid" 2>/dev/null || true
    fi

    _liveness_log "INFO" "Mount check: exiting after kill"
}

#===============================================================================
# Pre-Kill Diagnostics (Issue #257)
#===============================================================================

# Capture diagnostic information before killing the agent.
# Writes to a diagnostics file alongside status.json for post-mortem analysis.
# Must be fast — budget 5s max before SIGTERM.
_liveness_capture_diagnostics() {
    local pid="$1"
    local reason="$2"
    local stale_seconds="$3"

    local diag_dir="/kapsis-status"
    [[ -d "$diag_dir" ]] || diag_dir="${HOME}/.kapsis/status"

    local diag_file="${diag_dir}/kapsis-liveness-diagnostics.txt"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    {
        echo "=== Kapsis Liveness Kill Diagnostics ==="
        echo "Timestamp: $ts"
        echo "Reason: $reason"
        echo "Staleness: ${stale_seconds}s"
        echo "Agent PID: $pid"
        echo ""

        echo "=== Process Tree ==="
        ps aux 2>/dev/null || echo "(ps unavailable)"
        echo ""

        echo "=== Open File Descriptors (PID $pid) ==="
        ls -la "/proc/${pid}/fd/" 2>/dev/null || echo "(fd listing unavailable)"
        echo ""

        echo "=== TCP Connections ==="
        if [[ -n "${_LIVENESS_SS_BIN:-}" ]]; then
            "$_LIVENESS_SS_BIN" -tpn 2>/dev/null || echo "(ss unavailable)"
        elif [[ -r /proc/net/tcp ]]; then
            echo "--- /proc/net/tcp ---"
            cat /proc/net/tcp 2>/dev/null || true
            echo "--- /proc/net/tcp6 ---"
            cat /proc/net/tcp6 2>/dev/null || true
        else
            echo "(no tcp info available)"
        fi
        echo ""

        echo "=== Status JSON ==="
        local status_file
        for f in "$diag_dir"/kapsis-*.json; do
            [[ -f "$f" ]] && status_file="$f" && break
        done
        if [[ -n "${status_file:-}" ]]; then
            cat "$status_file" 2>/dev/null || echo "(status file unreadable)"
        else
            echo "(no status file found)"
        fi
        echo ""

        echo "=== Descendant Process I/O ==="
        local proc_pid
        for proc_io in /proc/[0-9]*/io; do
            proc_pid="${proc_io#/proc/}"
            proc_pid="${proc_pid%/io}"
            echo "--- PID $proc_pid ---"
            cat "$proc_io" 2>/dev/null || echo "(unreadable)"
        done
        echo ""

        echo "=== Process States ==="
        local name state
        for proc_status in /proc/[0-9]*/status; do
            proc_pid="${proc_status#/proc/}"
            proc_pid="${proc_pid%/status}"
            name=$(awk '/^Name:/ {print $2}' "$proc_status" 2>/dev/null) || name="?"
            state=$(awk '/^State:/ {print $2}' "$proc_status" 2>/dev/null) || state="?"
            echo "PID $proc_pid: $name ($state)"
        done

        echo ""
        echo "=== End Diagnostics ==="
    } > "$diag_file" 2>/dev/null || true

    _liveness_log "INFO" "Diagnostics captured to $diag_file"
}

#===============================================================================
# Kill Decision
#===============================================================================

# Kill decision function: returns 0 if the agent should be killed, 1 otherwise.
# Side effects: mutates _LIVENESS_API_SOFT_COUNT and _LIVENESS_API_HARD_COUNT.
# io_stale_cycles (nameref $3) is read but NOT reset — Signal 2 is independent.
_liveness_should_kill() {
    local stale_seconds="$1"
    local timeout="$2"
    local -n _io_stale_ref="$3"

    # Signal 1: updated_at must be stale for at least $timeout seconds
    [[ "$stale_seconds" -ge "$timeout" ]] || return 1

    # Signal 2: I/O must be unchanged for at least 2 consecutive cycles
    if [[ "$_io_stale_ref" -lt 2 ]]; then
        _liveness_log "DEBUG" "updated_at stale (${stale_seconds}s) but I/O still active (stale_cycles=$_io_stale_ref) — extending"
        return 1
    fi

    # Signals 1+2 both met. Signal 3: API connection quality (Issue #267 two-tier grace).
    # io_stale_cycles is NOT reset here — Signal 2 accumulates independently of Signal 3.
    local strength
    strength=$(_liveness_api_connection_strength)

    case "$strength" in
        none)
            # No API connection — no remaining life signal. Kill.
            _LIVENESS_API_SOFT_COUNT=0
            _LIVENESS_API_HARD_COUNT=0
            return 0
            ;;
        active)
            # Data in flight or TCP retransmitting — credible live signal (soft grace).
            (( _LIVENESS_API_SOFT_COUNT++ )) || true
            _LIVENESS_API_HARD_COUNT=0
            if [[ "$_LIVENESS_API_SOFT_COUNT" -lt "$_LIVENESS_API_SOFT_SKIP" ]]; then
                _liveness_log "INFO" "Active API connection (data in flight) — soft grace (${_LIVENESS_API_SOFT_COUNT}/${_LIVENESS_API_SOFT_SKIP})"
                return 1
            fi
            _liveness_log "WARN" "Soft grace cap exceeded (${_LIVENESS_API_SOFT_COUNT}/${_LIVENESS_API_SOFT_SKIP}) — killing"
            _LIVENESS_API_SOFT_COUNT=0
            return 0
            ;;
        idle)
            # Connection open but queues empty — zombie, keepalive, or pre-stream thinking phase.
            (( _LIVENESS_API_HARD_COUNT++ )) || true
            _LIVENESS_API_SOFT_COUNT=0
            if [[ "$_LIVENESS_API_HARD_COUNT" -lt "$_LIVENESS_API_HARD_SKIP" ]]; then
                _liveness_log "INFO" "Idle API connection (queues empty) — hard grace (${_LIVENESS_API_HARD_COUNT}/${_LIVENESS_API_HARD_SKIP})"
                return 1
            fi
            _liveness_log "WARN" "Hard grace cap exceeded (${_LIVENESS_API_HARD_COUNT}/${_LIVENESS_API_HARD_SKIP}) — killing"
            _LIVENESS_API_HARD_COUNT=0
            return 0
            ;;
    esac

    # Unreachable — _liveness_api_connection_strength always prints one of the three values.
    return 0
}

#===============================================================================
# Monitor Loop
#===============================================================================

_liveness_monitor_loop() {
    local timeout="$_LIVENESS_TIMEOUT"
    local grace="$_LIVENESS_GRACE"
    local interval="$_LIVENESS_INTERVAL"
    local pid="$_LIVENESS_AGENT_PID"

    # Mount check has its own shorter grace period (Issue #248)
    local mount_check_active="$_MOUNT_CHECK_ENABLED"
    local mount_check_delay="$_MOUNT_CHECK_DELAY"
    local mount_check_elapsed=0

    _liveness_log "INFO" "Starting (timeout=${timeout}s, grace=${grace}s, interval=${interval}s, mount_check=${mount_check_active}, mount_check_delay=${mount_check_delay}s)"

    # Grace period: sleep before starting liveness checks.
    #
    # Mount check has its OWN shorter delay (mount_check_delay, default 30s) that is
    # intentionally independent of the liveness grace period.  Previously, both shared
    # the same sleep: the full grace period elapsed first, then mount_check_elapsed was
    # set to grace (300), making the first mount check fire at grace+interval = 330s —
    # not at the intended 30s.  This created a 330-second blind window where a dropped
    # virtio-fs mount went undetected (confirmed by forensic timing: 9e9488 failed at
    # exactly 341s = 300s grace + 30s interval + 11s retry overhead).
    #
    # Fix: when mount checking is enabled and mount_check_delay < grace, split the
    # grace period: fire the early mount probe at mount_check_delay, then sleep the
    # remaining (grace - mount_check_delay) before normal liveness monitoring begins.
    if [[ "$grace" -gt 0 ]]; then
        if [[ "$mount_check_active" == "true" && "$mount_check_delay" -le "$grace" ]]; then
            # Phase 1: sleep until mount_check_delay, then do an early mount probe
            _liveness_log "INFO" "Grace period: early mount check in ${mount_check_delay}s (liveness grace=${grace}s)"
            sleep "$mount_check_delay"
            ((mount_check_elapsed += mount_check_delay)) || true
            _liveness_log "INFO" "Early mount check firing (${mount_check_elapsed}s elapsed)"
            if ! _mount_check_with_retries; then
                _mount_check_kill_agent
                return 0
            fi
            _liveness_log "INFO" "Early mount check passed"
            # Phase 2: sleep the remaining grace before liveness monitoring starts
            local remaining_grace=$(( grace - mount_check_delay ))
            if [[ "$remaining_grace" -gt 0 ]]; then
                _liveness_log "INFO" "Sleeping ${remaining_grace}s remaining grace before liveness monitoring"
                sleep "$remaining_grace"
                ((mount_check_elapsed += remaining_grace)) || true
            fi
        else
            # Mount check disabled, or mount_check_delay > grace: sleep full grace
            _liveness_log "DEBUG" "Early mount check not applicable (mount_check_active=${mount_check_active}, mount_check_delay=${mount_check_delay}s, grace=${grace}s)"
            _liveness_log "INFO" "Grace period: sleeping ${grace}s before monitoring"
            sleep "$grace"
            ((mount_check_elapsed += grace)) || true
        fi
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

        # Mount check (Issue #248) — runs before liveness signals, kills immediately
        if [[ "$mount_check_active" == "true" ]]; then
            ((mount_check_elapsed += interval)) || true
            if [[ "$mount_check_elapsed" -ge "$mount_check_delay" ]]; then
                if ! _mount_check_with_retries; then
                    _mount_check_kill_agent
                    return 0
                fi
            fi
        fi

        # Refresh API IP list (no-op if TTL has not expired)
        _liveness_resolve_api_ips

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

        # Issue #257: Phase-aware timeout — if agent reported completion but
        # process hasn't exited, use shorter timeout (stuck child process scenario).
        # Issue #267: Completion timeout is unconditional — API connections in the
        # completion phase get zero extra tolerance (agent has already reported done).
        local effective_timeout="$timeout"
        local current_phase
        current_phase=$(_liveness_get_phase)
        if [[ "$current_phase" == "complete" || "$current_phase" == "committing" || "$current_phase" == "pushing" ]]; then
            effective_timeout="$_LIVENESS_COMPLETION_TIMEOUT"
            _liveness_log "DEBUG" "Phase=$current_phase — using completion timeout (${effective_timeout}s)"
        fi

        # Decision logic: kill when Signals 1+2 are stale and Signal 3 grace is exhausted
        if _liveness_should_kill "$stale_seconds" "$effective_timeout" io_stale_cycles; then
            local kill_type="standard hung"
            if [[ "$current_phase" == "complete" || "$current_phase" == "committing" || "$current_phase" == "pushing" ]]; then
                kill_type="hung after completion (phase=$current_phase)"
            fi
            _liveness_log "WARN" "Agent $kill_type detected! updated_at stale for ${stale_seconds}s, I/O unchanged for ${io_stale_cycles} cycles"
            _liveness_log "WARN" "Sending SIGTERM to PID $pid"

            # Issue #257: Capture diagnostics before kill
            _liveness_capture_diagnostics "$pid" "No activity for ${stale_seconds}s ($kill_type)" "$stale_seconds"

            # Write killed status before sending signal
            _liveness_write_killed_status "No activity for ${stale_seconds}s ($kill_type)"

            # SIGTERM first, then SIGKILL after 10s
            kill -SIGTERM "$pid" 2>/dev/null || true
            sleep 10

            if kill -0 "$pid" 2>/dev/null; then
                _liveness_log "WARN" "Agent did not exit after SIGTERM, sending SIGKILL"
                kill -SIGKILL "$pid" 2>/dev/null || true
            fi

            _liveness_log "INFO" "Liveness monitor exiting after kill"
            return 0
        fi
    done
}

#===============================================================================
# Standalone Mount Check Loop (Issue #248)
#
# Used when liveness monitoring is disabled but mount checking is enabled.
# When liveness IS enabled, mount checks are integrated into its loop above.
#===============================================================================

_mount_check_loop() {
    local interval="$_LIVENESS_INTERVAL"
    local delay="$_MOUNT_CHECK_DELAY"
    local pid="$_LIVENESS_AGENT_PID"

    _liveness_log "INFO" "Mount check starting (interval=${interval}s, delay=${delay}s, retries=${_MOUNT_CHECK_RETRIES})"

    # Grace period before first check
    if [[ "$delay" -gt 0 ]]; then
        _liveness_log "INFO" "Mount check: waiting ${delay}s before first probe"
        sleep "$delay"
    fi

    while true; do
        sleep "$interval"

        # Check if agent process is still alive
        if ! kill -0 "$pid" 2>/dev/null; then
            _liveness_log "INFO" "Mount check: agent (PID $pid) no longer running, exiting"
            return 0
        fi

        # Perform mount check with retries
        if ! _mount_check_with_retries; then
            _mount_check_kill_agent
            return 0
        fi
    done
}

#===============================================================================
# Public API
#===============================================================================

# Start the liveness monitor as a background process
# Must be called before exec (after which PID 1 becomes the agent)
start_liveness_monitor() {
    if [[ "${KAPSIS_LIVENESS_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    _liveness_log "INFO" "Launching background liveness monitor"

    # Initialize API signal state before subshell launch so the subshell
    # inherits the cached ss path, pinned IPs, and initial resolved IP set
    _liveness_init_api_signal

    # Run in background subshell (survives exec, reparented to PID 1)
    ( _liveness_monitor_loop ) &
    local monitor_pid=$!

    _liveness_log "INFO" "Liveness monitor started (PID: $monitor_pid, mount_check=$_MOUNT_CHECK_ENABLED)"
}

# Start the standalone mount check monitor as a background process.
# Used when liveness monitoring is disabled but mount checking is enabled.
# Must be called before exec (after which PID 1 becomes the agent).
start_mount_check_monitor() {
    if [[ "$_MOUNT_CHECK_ENABLED" != "true" ]]; then
        return 0
    fi

    _liveness_log "INFO" "Launching standalone mount check monitor"

    ( _mount_check_loop ) &
    local monitor_pid=$!

    _liveness_log "INFO" "Mount check monitor started (PID: $monitor_pid)"
}
