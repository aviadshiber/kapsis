#!/usr/bin/env bash
#===============================================================================
# Kapsis Liveness Monitor
#
# Background daemon that monitors agent health inside the container and
# auto-kills hung agent processes. Runs as a background subshell before
# the entrypoint exec's into the agent (same pattern as DNS watchdog).
#
# Detection strategy (three signals; updated_at + I/O must both be stale
# AND no active AI API connection to trigger kill):
#   1. status.json updated_at - hook fires on every PostToolUse
#   2. /proc/1/io read_bytes+write_bytes - catches activity during thinking
#   3. Active TCP connections to AI API endpoints (port 443) - prevents
#      false-positive kills when agents wait on subagent Task calls
#
# Kill decision: updated_at stale for timeout AND I/O unchanged for 2+
# consecutive check cycles AND no active AI API TCP connections ->
# SIGTERM, wait 10s, SIGKILL.
#
# DNS Security Model (three layers):
#   1. Host-pinned baseline from /etc/kapsis/pinned-dns.conf (read-only
#      mount — cannot be tampered with inside the container). IPs are
#      NEVER discarded at runtime.
#   2. Union-only TTL-aware re-resolution: periodic refresh adds new IPs
#      but never removes pinned ones. DNS poisoning can only expand the
#      allowlist (less dangerous than false kills).
#   3. Maximum skip cap (KAPSIS_LIVENESS_API_MAX_SKIP cycles) prevents
#      an attacker holding an idle keep-alive connection indefinitely.
#
# Environment Variables:
#   KAPSIS_LIVENESS_TIMEOUT          - Kill after N seconds of no activity (default: 1800)
#   KAPSIS_LIVENESS_GRACE_PERIOD     - Skip checks for N seconds after start (default: 300)
#   KAPSIS_LIVENESS_CHECK_INTERVAL   - Check every N seconds (default: 30)
#   KAPSIS_LIVENESS_IPS_TTL          - Re-resolve API IPs after N seconds (default: 300)
#   KAPSIS_LIVENESS_DNS_TIMEOUT      - DNS resolution timeout in seconds (default: 2)
#   KAPSIS_LIVENESS_MAX_IPS_PER_DOMAIN - Max IPs to track per domain (default: 8)
#   KAPSIS_LIVENESS_API_MAX_SKIP     - Max cycles to skip kill for API connections (default: 240)
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

# API connection signal configuration
_LIVENESS_IPS_TTL="${KAPSIS_LIVENESS_IPS_TTL:-300}"
_LIVENESS_DNS_TIMEOUT="${KAPSIS_LIVENESS_DNS_TIMEOUT:-2}"
_LIVENESS_MAX_IPS_PER_DOMAIN="${KAPSIS_LIVENESS_MAX_IPS_PER_DOMAIN:-8}"
_LIVENESS_API_MAX_SKIP="${KAPSIS_LIVENESS_API_MAX_SKIP:-240}"

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
# Layer 3: consecutive cycles the kill was skipped due to active API connection
_LIVENESS_API_SKIP_COUNT=0
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

# Check whether the agent currently has active TCP connections to AI API endpoints.
# Used to prevent false-positive kills when agents wait on long-running API calls
# (e.g., subagent Task tool calls that may take minutes with no local I/O activity).
#
# Method 1: ss (preferred) — uses cached _LIVENESS_SS_BIN, strips header with tail -n +2,
#   uses leading-space anchor to prevent substring IP match (1.2.3.4 ≠ substring of 21.2.3.4)
# Method 2: /proc/net/tcp fallback — uses pre-computed hex arrays, no subprocess per IP
#
# Returns 0 if an active API connection is found, 1 otherwise.
_liveness_has_active_api_connections() {
    # No IPs resolved yet — cannot detect API connections
    [[ "${#_LIVENESS_API_IPS[@]}" -eq 0 ]] && return 1

    # Method 1: ss (fast path — cached binary, bash pattern matching, no subprocesses per IP)
    if [[ -n "$_LIVENESS_SS_BIN" ]]; then
        local ss_output
        # ss always prints a header line; tail -n +2 strips it so [[ -n ]] is meaningful
        ss_output=$("$_LIVENESS_SS_BIN" -tn state established 2>/dev/null | tail -n +2)
        local ip
        for ip in "${_LIVENESS_API_IPS[@]}"; do
            if [[ "$ip" =~ : ]]; then
                # IPv6: ss formats as [addr]:port
                [[ "$ss_output" == *" [${ip}]:443"* ]] && return 0
            else
                # IPv4: leading-space anchor prevents 1.2.3.4 matching 21.2.3.4
                [[ "$ss_output" == *" ${ip}:443"* ]] && return 0
            fi
        done
        return 1
    fi

    # Method 2: /proc/net/tcp fallback (pre-computed hex arrays, no per-IP subprocesses)
    if [[ "${#_LIVENESS_HEX_IPV4[@]}" -gt 0 ]]; then
        local hex_pattern
        hex_pattern=$(IFS='|'; echo "${_LIVENESS_HEX_IPV4[*]}")
        _liveness_check_proc_tcp_ips /proc/net/tcp "$hex_pattern" && return 0
    fi

    if [[ "${#_LIVENESS_HEX_IPV6[@]}" -gt 0 ]]; then
        local hex_pattern
        hex_pattern=$(IFS='|'; echo "${_LIVENESS_HEX_IPV6[*]}")
        _liveness_check_proc_tcp_ips /proc/net/tcp6 "$hex_pattern" && return 0
    fi

    return 1
}

# Initialize the API connection signal state.
# Must be called before the subshell launch so that the subshell inherits
# the cached ss path, pinned IPs, and initial resolved IP set.
_liveness_init_api_signal() {
    # Cache ss binary path once (avoids command -v per check cycle)
    _LIVENESS_SS_BIN=$(command -v ss 2>/dev/null) || true
    # Layer 1: load host-pinned IP baseline
    _liveness_load_pinned_ips
    # Force initial resolution immediately (TTL guard will be bypassed)
    _LIVENESS_IPS_LAST_RESOLVED=0
    _liveness_resolve_api_ips
    _liveness_log "INFO" "API signal initialized: ${#_LIVENESS_API_IPS[@]} IPs tracked, ss=${_LIVENESS_SS_BIN:-none}"
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
    # Write sentinel to stderr — captured by podman tee pipeline on host
    _liveness_log "ERROR" "KAPSIS_MOUNT_FAILURE: /workspace inaccessible (virtio-fs drop)"

    # Best-effort status write (may fail if status mount is also gone)
    if type status_phase &>/dev/null && type status_complete &>/dev/null; then
        if type status_is_active &>/dev/null && status_is_active; then
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
# Kill Decision
#===============================================================================

# Kill decision function: returns 0 if the agent should be killed, 1 otherwise.
# Side effects: mutates io_stale_cycles (via nameref) and _LIVENESS_API_SKIP_COUNT.
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

    # Signal 3: check for active API connections
    if _liveness_has_active_api_connections; then
        # Agent is waiting on an AI API call — skip kill.
        # Reset io_stale_cycles so the agent gets a fresh 2-cycle window once
        # the API call finishes and the TCP connection closes.
        local prev_io_cycles="$_io_stale_ref"
        _io_stale_ref=0
        (( _LIVENESS_API_SKIP_COUNT++ )) || true
        if [[ "$_LIVENESS_API_SKIP_COUNT" -ge "$_LIVENESS_API_MAX_SKIP" ]]; then
            # Layer 3: cap exceeded — kill anyway to prevent indefinite bypass
            _liveness_log "WARN" "API skip cap exceeded (${_LIVENESS_API_SKIP_COUNT}/${_LIVENESS_API_MAX_SKIP}), proceeding with kill"
            _LIVENESS_API_SKIP_COUNT=0
            _io_stale_ref="$prev_io_cycles"
            # fall through — return 0 (kill)
        else
            _liveness_log "INFO" "Active API connection — skipping kill (${_LIVENESS_API_SKIP_COUNT}/${_LIVENESS_API_MAX_SKIP})"
            return 1
        fi
    else
        _LIVENESS_API_SKIP_COUNT=0
    fi

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

    _liveness_log "INFO" "Starting (timeout=${timeout}s, grace=${grace}s, interval=${interval}s, mount_check=${mount_check_active})"

    # Grace period: sleep before starting checks
    if [[ "$grace" -gt 0 ]]; then
        _liveness_log "INFO" "Grace period: sleeping ${grace}s before monitoring"
        sleep "$grace"
        # Mount check delay is relative to container start, not post-grace
        # Account for grace period already elapsed
        ((mount_check_elapsed += grace)) || true
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

        # Decision logic: kill only when all three signals are stale
        if _liveness_should_kill "$stale_seconds" "$timeout" io_stale_cycles; then
            # All three signals stale (or cap exceeded): agent is hung
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
    if [[ "${KAPSIS_LIVENESS_ENABLED:-false}" != "true" ]]; then
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
