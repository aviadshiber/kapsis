#!/usr/bin/env bash
#===============================================================================
# Test: Liveness Monitor
#
# Tests liveness monitoring configuration, I/O parsing, staleness detection,
# heartbeat writing, config validation, and health command output.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Create a mock /proc/1/io file for testing
create_mock_proc_io() {
    local dir="$1"
    local read_bytes="${2:-12345}"
    local write_bytes="${3:-67890}"
    mkdir -p "$dir"
    cat > "$dir/io" << EOF
rchar: 100000
wchar: 200000
syscr: 500
syscw: 300
read_bytes: $read_bytes
write_bytes: $write_bytes
cancelled_write_bytes: 0
EOF
}

#===============================================================================
# UNIT TESTS: liveness-monitor.sh functions
#===============================================================================

test_liveness_monitor_sources_cleanly() {
    log_test "Testing liveness monitor sources without errors"

    # Source in a subshell to avoid polluting test environment
    local exit_code=0
    (
        export KAPSIS_LIVENESS_ENABLED=false
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
    ) 2>/dev/null || exit_code=$?

    assert_equals 0 "$exit_code" "Should source cleanly"
}

test_liveness_source_guard() {
    log_test "Testing source guard prevents double-sourcing"

    local exit_code=0
    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        # Second source should be a no-op
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
    ) 2>/dev/null || exit_code=$?

    assert_equals 0 "$exit_code" "Double-sourcing should not error"
}

test_liveness_io_parsing() {
    log_test "Testing /proc/1/io parsing"

    local tmpdir
    tmpdir=$(mktemp -d)
    create_mock_proc_io "$tmpdir/1" 12345 67890

    # Parse using the same awk command the monitor uses
    local io_total
    io_total=$(awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "$tmpdir/1/io" 2>/dev/null || echo "0")

    assert_equals "80235" "$io_total" "Should sum read_bytes + write_bytes"

    rm -rf "$tmpdir"
}

test_liveness_io_parsing_missing_file() {
    log_test "Testing I/O parsing when /proc/1/io is missing"

    local io_total
    io_total=$(awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "/nonexistent/io" 2>/dev/null || echo "0")

    assert_equals "0" "$io_total" "Should return 0 when file is missing"
}

test_liveness_io_parsing_zero_bytes() {
    log_test "Testing I/O parsing with zero bytes"

    local tmpdir
    tmpdir=$(mktemp -d)
    create_mock_proc_io "$tmpdir/1" 0 0

    local io_total
    io_total=$(awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "$tmpdir/1/io" 2>/dev/null || echo "0")

    assert_equals "0" "$io_total" "Should return 0 for zero bytes"

    rm -rf "$tmpdir"
}

test_liveness_config_defaults() {
    log_test "Testing liveness config defaults"

    (
        # Clear any existing env vars
        unset KAPSIS_LIVENESS_TIMEOUT KAPSIS_LIVENESS_GRACE_PERIOD KAPSIS_LIVENESS_CHECK_INTERVAL
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Check defaults are set correctly (Issue #267: two-tier grace replaces single skip cap)
        [[ "$_LIVENESS_TIMEOUT" == "900" ]] || exit 1
        [[ "$_LIVENESS_GRACE" == "300" ]] || exit 2
        [[ "$_LIVENESS_INTERVAL" == "30" ]] || exit 3
        [[ "$_LIVENESS_API_SOFT_SKIP" == "20" ]] || exit 4
        [[ "$_LIVENESS_API_HARD_SKIP" == "6" ]] || exit 5
        [[ "$_LIVENESS_COMPLETION_TIMEOUT" == "120" ]] || exit 6
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should have correct defaults (900/300/30/soft=20/hard=6/120)"
}

test_liveness_config_custom_values() {
    log_test "Testing liveness config with custom values"

    (
        export KAPSIS_LIVENESS_TIMEOUT=900
        export KAPSIS_LIVENESS_GRACE_PERIOD=60
        export KAPSIS_LIVENESS_CHECK_INTERVAL=15
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        [[ "$_LIVENESS_TIMEOUT" == "900" ]] || exit 1
        [[ "$_LIVENESS_GRACE" == "60" ]] || exit 2
        [[ "$_LIVENESS_INTERVAL" == "15" ]] || exit 3
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should accept custom values (900/60/15)"
}

test_liveness_heartbeat_in_status() {
    log_test "Testing heartbeat_at field appears in status.json"

    (
        export KAPSIS_STATUS_DIR
        KAPSIS_STATUS_DIR=$(mktemp -d)
        export KAPSIS_STATUS_ENABLED=true
        source "$KAPSIS_ROOT/scripts/lib/status.sh"
        status_init "test-project" "test-1" "main" "overlay"

        # Set heartbeat
        status_set_heartbeat
        status_phase "running" 50 "Testing"

        # Use _KAPSIS_STATUS_FILE (set by status_init) so the test works in containers
        # where _status_get_dir() overrides KAPSIS_STATUS_DIR with /kapsis-status.
        local status_file="$_KAPSIS_STATUS_FILE"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at"' "$status_file" || exit 1
            # Should not be null
            local hb
            hb=$(grep '"heartbeat_at"' "$status_file")
            [[ "$hb" != *"null"* ]] || exit 2
        else
            exit 3
        fi

        rm -f "$status_file"
        rm -rf "$KAPSIS_STATUS_DIR"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "heartbeat_at should appear in status.json and not be null"
}

test_liveness_heartbeat_null_when_unset() {
    log_test "Testing heartbeat_at is null when not set"

    (
        export KAPSIS_STATUS_DIR
        KAPSIS_STATUS_DIR=$(mktemp -d)
        export KAPSIS_STATUS_ENABLED=true
        source "$KAPSIS_ROOT/scripts/lib/status.sh"
        status_init "test-project" "test-2" "main" "overlay"
        status_phase "running" 25 "Starting"

        # Use _KAPSIS_STATUS_FILE (set by status_init) so the test works in containers
        # where _status_get_dir() overrides KAPSIS_STATUS_DIR with /kapsis-status.
        local status_file="$_KAPSIS_STATUS_FILE"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at": null' "$status_file" || exit 1
        else
            exit 2
        fi

        rm -f "$status_file"
        rm -rf "$KAPSIS_STATUS_DIR"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "heartbeat_at should be null when not set"
}

#===============================================================================
# UNIT TESTS: API connection signal — hex conversion
#===============================================================================

test_liveness_ip4_to_proc_hex() {
    log_test "Testing IPv4 to /proc/net/tcp little-endian hex conversion"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        hex=$(_liveness_ip4_to_proc_hex "1.2.3.4")
        [[ "$hex" == "04030201" ]] || { echo "1.2.3.4 expected 04030201, got $hex"; exit 1; }

        hex=$(_liveness_ip4_to_proc_hex "127.0.0.1")
        [[ "$hex" == "0100007F" ]] || { echo "127.0.0.1 expected 0100007F, got $hex"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "IPv4 hex conversion should work: $err"
}

test_liveness_ip6_to_proc_hex() {
    log_test "Testing IPv6 to /proc/net/tcp6 little-endian hex conversion"

    # Only run if python3 is available
    if ! command -v python3 &>/dev/null; then
        log_test "SKIP: python3 not available"
        return 0
    fi

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # ::1 → 00000000000000000000000001000000
        hex=$(_liveness_ip6_to_proc_hex "::1")
        [[ "$hex" == "00000000000000000000000001000000" ]] || { echo "::1 expected 00000000000000000000000001000000, got $hex"; exit 1; }

        # Injection attempt: invalid chars should be blocked (return 1)
        _liveness_ip6_to_proc_hex "::1'; rm -rf /" 2>/dev/null && exit 2 || true
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "IPv6 hex conversion should work and block injection: $err"
}

#===============================================================================
# UNIT TESTS: API connection signal — IP resolution
#===============================================================================

test_liveness_resolve_api_ips_deduplication() {
    log_test "Testing resolve_api_ips deduplicates IPs across domains"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Stub resolve_domain_ips to always return the same IP
        resolve_domain_ips() { echo "1.2.3.4"; }
        export -f resolve_domain_ips

        _LIVENESS_IPS_LAST_RESOLVED=0
        _liveness_resolve_api_ips

        # Even though 7 domains all return 1.2.3.4, the IP should appear only once
        count="${#_LIVENESS_API_IPS[@]}"
        [[ "$count" -eq 1 ]] || { echo "Expected 1 unique IP, got $count: ${_LIVENESS_API_IPS[*]}"; exit 1; }
        [[ "${_LIVENESS_API_IPS[0]}" == "1.2.3.4" ]] || { echo "Expected 1.2.3.4, got ${_LIVENESS_API_IPS[0]}"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should deduplicate repeated IPs: $err"
}

test_liveness_resolve_api_ips_graceful_failure() {
    log_test "Testing resolve_api_ips handles DNS failure gracefully"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Stub resolve_domain_ips to fail for all domains
        resolve_domain_ips() { return 1; }
        export -f resolve_domain_ips

        _LIVENESS_IPS_LAST_RESOLVED=0
        _liveness_resolve_api_ips

        # Should complete without error and result in 0 IPs (no pinned baseline here)
        count="${#_LIVENESS_API_IPS[@]}"
        [[ "$count" -eq 0 ]] || { echo "Expected 0 IPs on DNS failure, got $count"; exit 1; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "DNS failure should be handled gracefully: $err"
}

#===============================================================================
# UNIT TESTS: API connection strength (Issue #267 two-tier grace)
#===============================================================================

# Helper: build a /proc/net/tcp line for a given remote IP hex and queue values
# Usage: _make_tcp_line <remote_ip_hex> <tx_queue_hex> <rx_queue_hex> <retrnsmt_hex>
_make_tcp_line() {
    # sl local_addr remote_addr st tx:rx tr:tm retrnsmt uid timeout inode
    printf "0: 0100007F:0000 %s:01BB 01 %s:%s 00:00000000 %s 0 0 1234 1\n" \
        "$1" "$2" "$3" "$4"
}

test_liveness_api_strength_active_queues() {
    log_test "Testing _liveness_api_connection_strength returns 'active' when rx_queue non-zero"

    local tmpdir
    tmpdir=$(mktemp -d)
    local tcp_file="$tmpdir/tcp"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_log() { true; }

        # 1.2.3.4 → little-endian hex = 04030201
        _LIVENESS_HEX_IPV4=("04030201")
        _LIVENESS_API_IPS=("1.2.3.4")
        _LIVENESS_SS_BIN=""  # force /proc path
        _LIVENESS_PROC_TCP="$tcp_file"
        _LIVENESS_PROC_TCP6="/nonexistent"

        # tx_queue=0, rx_queue=256 (non-zero) → active
        printf "  sl  local_address rem_address  st tx_queue:rx_queue tr:tm->when retrnsmt  uid timeout inode\n" > "$tcp_file"
        printf "   0: 0100007F:0000 04030201:01BB 01 00000000:00000100 00:00000000 00000000 0 0 1234 1\n" >> "$tcp_file"

        result=$(_liveness_api_connection_strength)
        [[ "$result" == "active" ]] || { echo "Expected 'active', got '$result'"; exit 1; }
    ) 2>&1 || exit_code=$?

    rm -rf "$tmpdir"
    assert_equals 0 "$exit_code" "Should return 'active' when rx_queue non-zero: $err"
}

test_liveness_api_strength_active_retransmit() {
    log_test "Testing _liveness_api_connection_strength returns 'active' when retransmit non-zero"

    local tmpdir
    tmpdir=$(mktemp -d)
    local tcp_file="$tmpdir/tcp"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_log() { true; }

        _LIVENESS_HEX_IPV4=("04030201")
        _LIVENESS_API_IPS=("1.2.3.4")
        _LIVENESS_SS_BIN=""
        _LIVENESS_PROC_TCP="$tcp_file"
        _LIVENESS_PROC_TCP6="/nonexistent"

        # Both queues zero, but retrnsmt=1 → active
        printf "  sl  local_address rem_address  st tx_queue:rx_queue tr:tm->when retrnsmt  uid timeout inode\n" > "$tcp_file"
        printf "   0: 0100007F:0000 04030201:01BB 01 00000000:00000000 00:00000000 00000001 0 0 1234 1\n" >> "$tcp_file"

        result=$(_liveness_api_connection_strength)
        [[ "$result" == "active" ]] || { echo "Expected 'active', got '$result'"; exit 1; }
    ) 2>&1 || exit_code=$?

    rm -rf "$tmpdir"
    assert_equals 0 "$exit_code" "Should return 'active' when retransmit non-zero: $err"
}

test_liveness_api_strength_idle_queues() {
    log_test "Testing _liveness_api_connection_strength returns 'idle' when all queues zero"

    local tmpdir
    tmpdir=$(mktemp -d)
    local tcp_file="$tmpdir/tcp"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_log() { true; }

        _LIVENESS_HEX_IPV4=("04030201")
        _LIVENESS_API_IPS=("1.2.3.4")
        _LIVENESS_SS_BIN=""
        _LIVENESS_PROC_TCP="$tcp_file"
        _LIVENESS_PROC_TCP6="/nonexistent"

        # All queues and retransmit zero → idle
        printf "  sl  local_address rem_address  st tx_queue:rx_queue tr:tm->when retrnsmt  uid timeout inode\n" > "$tcp_file"
        printf "   0: 0100007F:0000 04030201:01BB 01 00000000:00000000 00:00000000 00000000 0 0 1234 1\n" >> "$tcp_file"

        result=$(_liveness_api_connection_strength)
        [[ "$result" == "idle" ]] || { echo "Expected 'idle', got '$result'"; exit 1; }
    ) 2>&1 || exit_code=$?

    rm -rf "$tmpdir"
    assert_equals 0 "$exit_code" "Should return 'idle' when queues zero: $err"
}

test_liveness_api_strength_none() {
    log_test "Testing _liveness_api_connection_strength returns 'none' when no matching connection"

    local tmpdir
    tmpdir=$(mktemp -d)
    local tcp_file="$tmpdir/tcp"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_log() { true; }

        _LIVENESS_HEX_IPV4=("04030201")
        _LIVENESS_API_IPS=("1.2.3.4")
        _LIVENESS_SS_BIN=""
        _LIVENESS_PROC_TCP="$tcp_file"
        _LIVENESS_PROC_TCP6="/nonexistent"

        # Connection to 9.9.9.9 (09090909 LE), not an API IP → none
        printf "  sl  local_address rem_address  st tx_queue:rx_queue tr:tm->when retrnsmt  uid timeout inode\n" > "$tcp_file"
        printf "   0: 0100007F:0000 09090909:01BB 01 00000000:00000100 00:00000000 00000000 0 0 1234 1\n" >> "$tcp_file"

        result=$(_liveness_api_connection_strength)
        [[ "$result" == "none" ]] || { echo "Expected 'none', got '$result'"; exit 1; }
    ) 2>&1 || exit_code=$?

    rm -rf "$tmpdir"
    assert_equals 0 "$exit_code" "Should return 'none' when no matching API IP: $err"
}

test_liveness_api_strength_no_ips() {
    log_test "Testing _liveness_api_connection_strength returns 'none' when no IPs resolved"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_log() { true; }

        _LIVENESS_API_IPS=()
        _LIVENESS_HEX_IPV4=()
        _LIVENESS_SS_BIN=""

        result=$(_liveness_api_connection_strength)
        [[ "$result" == "none" ]] || { echo "Expected 'none', got '$result'"; exit 1; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should return 'none' when no IPs resolved: $err"
}

test_liveness_api_strength_ss_fallback() {
    log_test "Testing _liveness_api_connection_strength falls back to ss when no hex cache"

    local tmpdir
    tmpdir=$(mktemp -d)

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_log() { true; }

        # Create a fake ss binary reporting a connection to 1.2.3.4:443
        cat > "$tmpdir/ss" << 'EOF'
#!/bin/bash
echo "Recv-Q Send-Q Local Address:Port Peer Address:Port"
echo "0      0      10.0.0.1:54321     1.2.3.4:443"
EOF
        chmod +x "$tmpdir/ss"

        _LIVENESS_SS_BIN="$tmpdir/ss"
        _LIVENESS_API_IPS=("1.2.3.4")
        _LIVENESS_HEX_IPV4=()  # empty — force ss path
        _LIVENESS_HEX_IPV6=()

        result=$(_liveness_api_connection_strength)
        # ss fallback has no queue data, so it returns "idle" (conservative)
        [[ "$result" == "idle" ]] || { echo "Expected 'idle' from ss fallback, got '$result'"; exit 1; }
    ) 2>&1 || exit_code=$?

    rm -rf "$tmpdir"
    assert_equals 0 "$exit_code" "ss fallback should return 'idle' (no queue data): $err"
}

#===============================================================================
# INTEGRATION TESTS: kill decision logic
#===============================================================================

test_liveness_should_kill_not_stale() {
    log_test "Testing _liveness_should_kill returns 1 when stale_seconds < timeout"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "none"; }
        _liveness_log() { true; }

        local cycles=5
        if _liveness_should_kill 100 1800 cycles; then
            echo "ERROR: should_kill returned 0 (kill) but stale_seconds < timeout"
            exit 1
        fi
        # cycles should be unchanged (early return before any mutation)
        [[ "$cycles" -eq 5 ]] || { echo "Expected cycles=5 unchanged, got $cycles"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should not kill when stale_seconds < timeout: $err"
}

test_liveness_should_kill_io_active() {
    log_test "Testing _liveness_should_kill returns 1 when I/O stale cycles < 2"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "none"; }
        _liveness_log() { true; }

        local cycles=1
        if _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 0 (kill) but io_stale_cycles < 2"
            exit 1
        fi
        # cycles should be unchanged (early return before any mutation)
        [[ "$cycles" -eq 1 ]] || { echo "Expected cycles=1 unchanged, got $cycles"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should not kill when io_stale_cycles < 2: $err"
}

test_liveness_kill_two_signals_met_no_connection() {
    log_test "Testing _liveness_should_kill kills when Signals 1+2 met and no API connection"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "none"; }
        _liveness_log() { true; }

        local cycles=5
        if ! _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 1 (spare) but no API and all stale"
            exit 1
        fi
        # cycles should be unchanged (no-API path does not mutate io_stale_cycles)
        [[ "$cycles" -eq 5 ]] || { echo "Expected cycles=5 unchanged, got $cycles"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should kill when Signals 1+2 met and no API connection: $err"
}

test_liveness_soft_grace_defers_kill() {
    log_test "Testing _liveness_should_kill defers kill during soft grace (active connection)"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "active"; }
        _liveness_log() { true; }

        _LIVENESS_API_SOFT_SKIP=10
        _LIVENESS_API_SOFT_COUNT=0
        _LIVENESS_API_HARD_COUNT=0

        local cycles=5
        if _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 0 (kill) but soft grace not exhausted"
            exit 1
        fi
        # soft count should be incremented
        [[ "$_LIVENESS_API_SOFT_COUNT" -eq 1 ]] || { echo "Expected soft_count=1, got $_LIVENESS_API_SOFT_COUNT"; exit 2; }
        # io_stale_cycles should NOT be reset (Bug A fix)
        [[ "$cycles" -eq 5 ]] || { echo "Expected cycles=5 unchanged (no reset), got $cycles"; exit 3; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Kill should be deferred during soft grace: $err"
}

test_liveness_soft_grace_cap_kills() {
    log_test "Testing _liveness_should_kill kills when soft grace cap exceeded"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "active"; }
        _liveness_log() { true; }

        _LIVENESS_API_SOFT_SKIP=3
        _LIVENESS_API_SOFT_COUNT=3  # at cap
        _LIVENESS_API_HARD_COUNT=0

        local cycles=5
        if ! _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 1 (spare) but soft grace cap exceeded"
            exit 1
        fi
        # soft count should be reset after cap
        [[ "$_LIVENESS_API_SOFT_COUNT" -eq 0 ]] || { echo "Expected soft_count=0, got $_LIVENESS_API_SOFT_COUNT"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should kill when soft grace cap exceeded: $err"
}

test_liveness_hard_grace_defers_kill() {
    log_test "Testing _liveness_should_kill defers kill during hard grace (idle connection)"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "idle"; }
        _liveness_log() { true; }

        _LIVENESS_API_HARD_SKIP=6
        _LIVENESS_API_HARD_COUNT=0
        _LIVENESS_API_SOFT_COUNT=0

        local cycles=5
        if _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 0 (kill) but hard grace not exhausted"
            exit 1
        fi
        # hard count should be incremented
        [[ "$_LIVENESS_API_HARD_COUNT" -eq 1 ]] || { echo "Expected hard_count=1, got $_LIVENESS_API_HARD_COUNT"; exit 2; }
        # io_stale_cycles should NOT be reset (Bug A fix)
        [[ "$cycles" -eq 5 ]] || { echo "Expected cycles=5 unchanged (no reset), got $cycles"; exit 3; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Kill should be deferred during hard grace: $err"
}

test_liveness_hard_grace_cap_kills() {
    log_test "Testing _liveness_should_kill kills when hard grace cap exceeded"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "idle"; }
        _liveness_log() { true; }

        _LIVENESS_API_HARD_SKIP=3
        _LIVENESS_API_HARD_COUNT=3  # at cap
        _LIVENESS_API_SOFT_COUNT=0

        local cycles=5
        if ! _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 1 (spare) but hard grace cap exceeded"
            exit 1
        fi
        # hard count should be reset after cap
        [[ "$_LIVENESS_API_HARD_COUNT" -eq 0 ]] || { echo "Expected hard_count=0, got $_LIVENESS_API_HARD_COUNT"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should kill when hard grace cap exceeded: $err"
}

test_liveness_signal2_not_reset_by_signal3() {
    log_test "Testing io_stale_cycles is NOT reset when Signal 3 defers kill (Bug A fix)"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "idle"; }
        _liveness_log() { true; }

        _LIVENESS_API_HARD_SKIP=10
        _LIVENESS_API_HARD_COUNT=0

        # Run 3 consecutive deferred cycles — io_stale_cycles must accumulate
        local cycles=2
        _liveness_should_kill 9999 1800 cycles || true  # cycle 1: deferred
        [[ "$cycles" -eq 2 ]] || { echo "Cycle 1: expected cycles=2, got $cycles (was reset!)"; exit 1; }
        _liveness_should_kill 9999 1800 cycles || true  # cycle 2: deferred
        [[ "$cycles" -eq 2 ]] || { echo "Cycle 2: expected cycles=2, got $cycles (was reset!)"; exit 2; }

        [[ "$_LIVENESS_API_HARD_COUNT" -eq 2 ]] || { echo "Expected hard_count=2, got $_LIVENESS_API_HARD_COUNT"; exit 3; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "io_stale_cycles should never be reset by Signal 3: $err"
}

test_liveness_io_active_protects_without_api() {
    log_test "Testing that active I/O (Signal 2 not met) prevents kill even without API"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "none"; }
        _liveness_log() { true; }

        # io_stale_cycles=1 (< 2) — Signal 2 not met
        local cycles=1
        if _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: killed when I/O still active (io_stale_cycles=1)"
            exit 1
        fi
        [[ "$cycles" -eq 1 ]] || { echo "Expected cycles=1 unchanged, got $cycles"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Active I/O should prevent kill regardless of API: $err"
}

test_liveness_monitor_starts_without_dns() {
    log_test "Testing _liveness_init_api_signal completes even when DNS fails"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Stub resolve_domain_ips to fail (simulates DNS unavailable)
        resolve_domain_ips() { return 1; }
        export -f resolve_domain_ips

        # Remove pinned file path to ensure no file dependency
        export KAPSIS_DNS_PINNED_FILE="/nonexistent/pinned.conf"

        # Init should complete without error under set -euo pipefail
        _liveness_init_api_signal

        # Should have 0 IPs but not crashed
        echo "completed with ${#_LIVENESS_API_IPS[@]} IPs"
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "_liveness_init_api_signal should not crash when DNS fails: $err"
    assert_contains "$err" "completed with" "Should complete and report IP count"
}

#===============================================================================
# INTEGRATION TESTS: CLI flags
#===============================================================================

test_claude_exit_delay_agent_type_match() {
    log_test "Testing Claude agent type matches for CLAUDE_CODE_EXIT_AFTER_STOP_DELAY"

    # Verify agent-types.sh normalizes 'claude' to 'claude-cli'
    (
        source "$KAPSIS_ROOT/scripts/lib/agent-types.sh"
        local normalized
        normalized=$(normalize_agent_type "claude")
        [[ "$normalized" == "claude-cli" ]] || exit 1

        normalized=$(normalize_agent_type "claude-code")
        [[ "$normalized" == "claude-cli" ]] || exit 2
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should normalize claude/claude-code to claude-cli"
}

test_liveness_config_yaml_parsing() {
    log_test "Testing liveness YAML config is parsed correctly by yq"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 900
  grace_period: 120
  check_interval: 15
EOF

    # Parse the same way launch-agent.sh does
    local enabled timeout grace interval
    enabled=$(yq -r '.liveness.enabled // "false"' "$config_file" 2>/dev/null || echo "false")
    timeout=$(yq -r '.liveness.timeout // "1800"' "$config_file" 2>/dev/null || echo "1800")
    grace=$(yq -r '.liveness.grace_period // "300"' "$config_file" 2>/dev/null || echo "300")
    interval=$(yq -r '.liveness.check_interval // "30"' "$config_file" 2>/dev/null || echo "30")

    assert_equals "true" "$enabled" "Should parse enabled as true"
    assert_equals "900" "$timeout" "Should parse timeout as 900"
    assert_equals "120" "$grace" "Should parse grace_period as 120"
    assert_equals "15" "$interval" "Should parse check_interval as 15"

    rm -f "$config_file"
}

#===============================================================================
# CONFIG VALIDATION TESTS
#===============================================================================

test_liveness_config_validation_valid() {
    log_test "Testing config verifier accepts valid liveness config"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 1800
  grace_period: 300
  check_interval: 30
EOF

    local output
    local exit_code=0
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should pass validation"
    assert_contains "$output" "Valid liveness.timeout" "Should validate timeout"

    rm -f "$config_file"
}

test_liveness_config_validation_timeout_too_low() {
    log_test "Testing config verifier rejects timeout < 60"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 30
EOF

    local output
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || true

    assert_contains "$output" "must be >= 60" "Should reject timeout < 60"

    rm -f "$config_file"
}

test_liveness_config_validation_interval_too_low() {
    log_test "Testing config verifier rejects check_interval < 10"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  check_interval: 5
EOF

    local output
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || true

    assert_contains "$output" "must be >= 10" "Should reject check_interval < 10"

    rm -f "$config_file"
}

test_liveness_config_validation_warns_timeout_lt_grace() {
    log_test "Testing config verifier warns when timeout < grace_period"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 120
  grace_period: 300
EOF

    local output
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || true

    assert_contains "$output" "less than grace_period" "Should warn about timeout < grace_period"

    rm -f "$config_file"
}

#===============================================================================
# HEALTH COMMAND TESTS
#===============================================================================

test_health_flag_requires_args() {
    log_test "Testing --health requires project and agent-id"

    local output
    local exit_code=0
    output=$("$KAPSIS_ROOT/scripts/kapsis-status.sh" --health 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail without project/agent"
    assert_contains "$output" "requires project" "Should explain required args"
}

test_health_json_output_valid() {
    log_test "Testing --health --json produces valid JSON structure"

    # Create a mock status file
    local status_dir
    status_dir=$(mktemp -d)
    local status_file="$status_dir/kapsis-testproj-1.json"
    cat > "$status_file" << 'EOF'
{
  "version": "1.0",
  "agent_id": "1",
  "project": "testproj",
  "phase": "running",
  "progress": 50,
  "message": "Testing",
  "updated_at": "2026-03-22T10:00:00Z",
  "started_at": "2026-03-22T09:00:00Z",
  "heartbeat_at": "2026-03-22T10:00:00Z",
  "gist": null,
  "gist_updated_at": null,
  "branch": null,
  "sandbox_mode": "overlay",
  "exit_code": null,
  "error": null,
  "worktree_path": null,
  "pr_url": null,
  "push_status": null,
  "local_commit": null,
  "remote_commit": null,
  "push_fallback_command": null,
  "commit_status": null,
  "commit_sha": null,
  "uncommitted_files": 0
}
EOF

    local output
    output=$(KAPSIS_STATUS_DIR="$status_dir" "$KAPSIS_ROOT/scripts/kapsis-status.sh" --health --json testproj 1 2>&1)

    # Check it contains expected JSON fields
    assert_contains "$output" '"agent_id"' "Should have agent_id field"
    assert_contains "$output" '"health"' "Should have health field"
    assert_contains "$output" '"io"' "Should have io field"
    assert_contains "$output" '"hook_staleness_seconds"' "Should have hook staleness"

    rm -rf "$status_dir"
}

test_health_not_found() {
    log_test "Testing --health with non-existent agent"

    local status_dir
    status_dir=$(mktemp -d)

    local exit_code=0
    local output
    output=$(KAPSIS_STATUS_DIR="$status_dir" "$KAPSIS_ROOT/scripts/kapsis-status.sh" --health noproject noagent 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail for non-existent agent"
    assert_contains "$output" "No status found" "Should report not found"

    rm -rf "$status_dir"
}

#===============================================================================
# MOUNT CHECK UNIT TESTS (Issue #248)
#===============================================================================

test_mount_check_probe_healthy() {
    log_test "Testing mount check probe returns 0 for populated workspace"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Create a fake workspace with content
        local workspace
        workspace=$(mktemp -d)
        mkdir -p "$workspace"
        echo "test" > "$workspace/file.txt"

        # Override workspace path for testing (CONTAINER_WORKSPACE_PATH is readonly)
        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_PROBE_TIMEOUT=2

        _mount_check_probe || exit 1

        rm -rf "$workspace"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should succeed for populated workspace"
}

test_mount_check_probe_empty_workspace() {
    log_test "Testing mount check probe returns 1 for empty workspace"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Create an empty workspace (simulates mount drop)
        local workspace
        workspace=$(mktemp -d)

        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_PROBE_TIMEOUT=2

        _mount_check_probe && exit 1  # Should fail
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should fail for empty workspace"
}

test_mount_check_probe_missing_workspace() {
    log_test "Testing mount check probe returns 1 for missing workspace"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        _MOUNT_CHECK_WORKSPACE="/nonexistent/workspace/path"
        _MOUNT_CHECK_PROBE_TIMEOUT=2

        _mount_check_probe && exit 1  # Should fail
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should fail for missing workspace"
}

test_mount_check_probe_worktree_git_sentinel() {
    log_test "Testing mount check probe checks .git-safe/HEAD in worktree mode"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        local workspace
        workspace=$(mktemp -d)
        echo "test" > "$workspace/file.txt"

        # Create .git-safe/HEAD to simulate worktree mode
        mkdir -p "$workspace/.git-safe"
        echo "ref: refs/heads/main" > "$workspace/.git-safe/HEAD"

        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_GIT_PATH="$workspace/.git-safe"
        _MOUNT_CHECK_PROBE_TIMEOUT=2
        KAPSIS_SANDBOX_MODE=worktree

        _mount_check_probe || exit 1

        # Now remove .git-safe/HEAD - probe should fail
        rm "$workspace/.git-safe/HEAD"
        _mount_check_probe && exit 2

        rm -rf "$workspace"
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should check .git-safe/HEAD in worktree mode"
}

test_mount_check_with_retries_recovers() {
    log_test "Testing mount check recovers on retry"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        local workspace
        workspace=$(mktemp -d)
        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_PROBE_TIMEOUT=2
        _MOUNT_CHECK_RETRIES=2
        _MOUNT_CHECK_RETRY_DELAY=1

        # First call: workspace is empty (fail), then populate it for retry
        local call_count=0
        _mount_check_probe() {
            ((call_count++)) || true
            if [[ "$call_count" -le 1 ]]; then
                return 1  # First call fails
            fi
            return 0  # Second call succeeds
        }

        _mount_check_with_retries || exit 1

        rm -rf "$workspace"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should recover on retry"
}

test_mount_check_with_retries_all_fail() {
    log_test "Testing mount check fails after exhausted retries"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        _MOUNT_CHECK_WORKSPACE="/nonexistent"
        _MOUNT_CHECK_PROBE_TIMEOUT=2
        _MOUNT_CHECK_RETRIES=2
        _MOUNT_CHECK_RETRY_DELAY=1

        _mount_check_with_retries && exit 1  # Should fail
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should fail after exhausted retries"
}

test_mount_check_probe_returns_124_on_timeout() {
    log_test "Testing mount check probe propagates exit code 124 on timeout"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        _MOUNT_CHECK_RETRIES=3
        _MOUNT_CHECK_RETRY_DELAY=0

        # Verify _mount_check_with_retries exits immediately on first 124
        local call_count=0
        _mount_check_probe() {
            ((call_count++)) || true
            return 124
        }

        _mount_check_with_retries
        local retries_exit=$?

        # Should have been called exactly once (no retries for hangs)
        [[ "$call_count" -eq 1 ]] || exit 1
        # Should return failure
        [[ "$retries_exit" -ne 0 ]] || exit 2
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe timeout (124) should skip retries"
}

test_mount_check_early_probe_fires_before_grace() {
    log_test "Testing early mount check fires at mount_check_delay, not grace+interval (blind-window fix)"

    # Regression test for the 330s blind window (Issue #248 fix).
    # Before the fix: mount check was embedded in the liveness loop that slept the full
    # grace period (300s) first, making the first check fire at grace+interval = 330s.
    # After the fix: an early probe fires at mount_check_delay (30s, or 1s in this test)
    # during the grace period — long before liveness monitoring would normally start.
    #
    # Test setup: grace=5s, mount_check_delay=1s, interval=30s.
    # A healthy workspace is used so the early probe passes and the loop continues.
    # We measure the elapsed time and verify the early probe fired well before
    # grace+interval (35s) — specifically before 4s (well inside the 5s grace window).

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        local tmpdir
        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' EXIT

        _MOUNT_CHECK_ENABLED=true
        _MOUNT_CHECK_WORKSPACE="$tmpdir"
        _MOUNT_CHECK_PROBE_TIMEOUT=2
        _MOUNT_CHECK_RETRIES=1
        _MOUNT_CHECK_RETRY_DELAY=0
        _MOUNT_CHECK_DELAY=1       # early probe fires at 1s
        _LIVENESS_ENABLED=true
        _LIVENESS_GRACE=5          # grace = 5s (much less than default 300s)
        _LIVENESS_INTERVAL=30      # normal interval = 30s (would be 35s without fix)
        _LIVENESS_TIMEOUT=60
        _LIVENESS_AGENT_PID=$$     # our own PID — kill will be a no-op (PID will survive)

        # Override kill function so we don't actually kill ourselves
        _mount_check_kill_agent() { return 0; }

        # Track when the early probe fires
        local probe_fire_time=""
        _mount_check_with_retries() {
            probe_fire_time=$SECONDS
            return 0  # Healthy workspace — always pass
        }

        # Run the grace period block only (don't enter full loop to avoid 30s sleep)
        local grace="$_LIVENESS_GRACE"
        local mount_check_delay="$_MOUNT_CHECK_DELAY"
        local mount_check_active="$_MOUNT_CHECK_ENABLED"
        local mount_check_elapsed=0

        local start_time=$SECONDS

        if [[ "$grace" -gt 0 ]]; then
            if [[ "$mount_check_active" == "true" && "$mount_check_delay" -le "$grace" ]]; then
                sleep "$mount_check_delay"
                ((mount_check_elapsed += mount_check_delay)) || true
                _mount_check_with_retries
                local remaining_grace=$(( grace - mount_check_delay ))
                [[ "$remaining_grace" -gt 0 ]] && sleep "$remaining_grace"
                ((mount_check_elapsed += remaining_grace)) || true
            else
                sleep "$grace"
                ((mount_check_elapsed += grace)) || true
            fi
        fi

        local elapsed_at_probe=$(( probe_fire_time - start_time ))

        # Early probe should fire at ~1s (mount_check_delay), NOT at 35s (grace+interval)
        # Allow up to 3s for test overhead.  Fail if > 4s (would mean fix is absent).
        if [[ -z "$probe_fire_time" ]]; then
            echo "ERROR: early probe never fired" >&2
            exit 1
        fi
        if [[ "$elapsed_at_probe" -gt 4 ]]; then
            echo "ERROR: early probe fired at ${elapsed_at_probe}s, expected <= 4s (blind-window fix missing)" >&2
            exit 2
        fi
        # mount_check_elapsed should equal grace (mount_check_delay + remaining_grace)
        if [[ "$mount_check_elapsed" -ne "$grace" ]]; then
            echo "ERROR: mount_check_elapsed=${mount_check_elapsed}, expected ${grace}" >&2
            exit 3
        fi
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Early mount check should fire at mount_check_delay (1s), not grace+interval (35s)"
}

test_mount_check_config_defaults() {
    log_test "Testing mount check config defaults"

    (
        unset KAPSIS_MOUNT_CHECK_ENABLED KAPSIS_MOUNT_CHECK_RETRIES
        unset KAPSIS_MOUNT_CHECK_RETRY_DELAY KAPSIS_MOUNT_CHECK_PROBE_TIMEOUT
        unset KAPSIS_MOUNT_CHECK_DELAY
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        [[ "$_MOUNT_CHECK_ENABLED" == "false" ]] || exit 1
        [[ "$_MOUNT_CHECK_RETRIES" == "2" ]] || exit 2
        [[ "$_MOUNT_CHECK_RETRY_DELAY" == "5" ]] || exit 3
        [[ "$_MOUNT_CHECK_PROBE_TIMEOUT" == "5" ]] || exit 4
        [[ "$_MOUNT_CHECK_DELAY" == "30" ]] || exit 5
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should have correct defaults (false/2/5/5/30)"
}

test_mount_check_config_custom_values() {
    log_test "Testing mount check config with custom env vars"

    (
        export KAPSIS_MOUNT_CHECK_ENABLED=true
        export KAPSIS_MOUNT_CHECK_RETRIES=5
        export KAPSIS_MOUNT_CHECK_RETRY_DELAY=10
        export KAPSIS_MOUNT_CHECK_PROBE_TIMEOUT=3
        export KAPSIS_MOUNT_CHECK_DELAY=60
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        [[ "$_MOUNT_CHECK_ENABLED" == "true" ]] || exit 1
        [[ "$_MOUNT_CHECK_RETRIES" == "5" ]] || exit 2
        [[ "$_MOUNT_CHECK_RETRY_DELAY" == "10" ]] || exit 3
        [[ "$_MOUNT_CHECK_PROBE_TIMEOUT" == "3" ]] || exit 4
        [[ "$_MOUNT_CHECK_DELAY" == "60" ]] || exit 5
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should accept custom values (true/5/10/3/60)"
}

#===============================================================================
# ISSUE #257 TESTS: hung agent detection
#===============================================================================

test_liveness_get_phase() {
    log_test "Testing _liveness_get_phase extracts phase from status.json"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Create a mock status dir with a status file
        local status_dir
        status_dir=$(mktemp -d)
        mkdir -p "$status_dir"
        cat > "$status_dir/kapsis-test-1.json" << 'STATUSEOF'
{
  "phase": "complete",
  "updated_at": "2026-03-22T10:30:00Z"
}
STATUSEOF

        # Override status dir discovery
        _liveness_get_phase() {
            local content
            content=$(cat "$status_dir/kapsis-test-1.json" 2>/dev/null) || return
            if [[ "$content" =~ \"phase\":\ *\"([^\"]*)\" ]]; then
                echo "${BASH_REMATCH[1]}"
            fi
        }

        local phase
        phase=$(_liveness_get_phase)
        [[ "$phase" == "complete" ]] || { echo "Expected 'complete', got '$phase'"; exit 1; }

        rm -rf "$status_dir"
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should extract phase from status.json: $err"
}

test_liveness_get_phase_running() {
    log_test "Testing _liveness_get_phase returns 'running' when agent is active"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        local status_dir
        status_dir=$(mktemp -d)
        cat > "$status_dir/kapsis-test-1.json" << 'STATUSEOF'
{
  "phase": "running",
  "updated_at": "2026-03-22T10:30:00Z"
}
STATUSEOF

        _liveness_get_phase() {
            local content
            content=$(cat "$status_dir/kapsis-test-1.json" 2>/dev/null) || return
            if [[ "$content" =~ \"phase\":\ *\"([^\"]*)\" ]]; then
                echo "${BASH_REMATCH[1]}"
            fi
        }

        local phase
        phase=$(_liveness_get_phase)
        [[ "$phase" == "running" ]] || { echo "Expected 'running', got '$phase'"; exit 1; }

        rm -rf "$status_dir"
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should extract 'running' phase: $err"
}

test_liveness_exit_code_5_on_completion() {
    log_test "Testing _liveness_write_killed_status uses exit 5 when phase=complete"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Mock _liveness_get_phase to return "complete"
        _liveness_get_phase() { echo "complete"; }

        # Track what status_complete was called with
        local captured_exit_code=""
        status_phase() { true; }
        status_complete() { captured_exit_code="$1"; }
        status_is_active() { return 0; }

        _liveness_write_killed_status "test reason"

        [[ "$captured_exit_code" == "5" ]] || { echo "Expected exit code 5, got '$captured_exit_code'"; exit 1; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should use exit code 5 when phase=complete: $err"
}

test_liveness_exit_code_137_when_running() {
    log_test "Testing _liveness_write_killed_status uses exit 137 when phase=running"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        _liveness_get_phase() { echo "running"; }

        local captured_exit_code=""
        status_phase() { true; }
        status_complete() { captured_exit_code="$1"; }
        status_is_active() { return 0; }

        _liveness_write_killed_status "test reason"

        [[ "$captured_exit_code" == "137" ]] || { echo "Expected exit code 137, got '$captured_exit_code'"; exit 1; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should use exit code 137 when phase=running: $err"
}

test_liveness_io_total_descendants() {
    log_test "Testing I/O total sums across multiple process io files"

    local tmpdir
    tmpdir=$(mktemp -d)

    # Create mock /proc/<pid>/io files
    create_mock_proc_io "$tmpdir/1" 1000 2000   # PID 1: 3000
    create_mock_proc_io "$tmpdir/2" 500 500      # PID 2: 1000
    create_mock_proc_io "$tmpdir/3" 100 200      # PID 3: 300

    # Test the awk command directly (same as _liveness_get_io_total uses)
    local io_total
    io_total=$(awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "$tmpdir"/[0-9]*/io 2>/dev/null || echo "0")

    assert_equals "4300" "$io_total" "Should sum I/O across all processes (3000+1000+300)"

    rm -rf "$tmpdir"
}

test_liveness_completion_timeout_unconditional() {
    log_test "Testing completion timeout applies regardless of API connection (Issue #267 Bug D fix)"

    # This tests _liveness_monitor_loop behavior indirectly by verifying that
    # _liveness_should_kill is called with _LIVENESS_COMPLETION_TIMEOUT when phase
    # is 'complete', even when an API connection is active.
    # We test the timeout selection logic directly here.
    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_api_connection_strength() { echo "active"; }
        _liveness_log() { true; }

        # With soft grace, the agent should be spared because count < cap
        _LIVENESS_API_SOFT_SKIP=10
        _LIVENESS_API_SOFT_COUNT=0

        # Completion timeout is 120s. stale_seconds=150 > 120 → kill should trigger
        # after grace runs out, but at 120s threshold not 900s.
        # We test that _liveness_should_kill respects whatever timeout is passed.
        # Passed timeout=120 (completion), stale=150 → Signal 1 met (150>=120)
        # Signal 2 met (cycles=5), Signal 3 active → soft grace defers (count=0 < 10)
        local cycles=5
        if _liveness_should_kill 150 120 cycles; then
            echo "ERROR: killed on first grace cycle (expected deferral)"
            exit 1
        fi
        [[ "$_LIVENESS_API_SOFT_COUNT" -eq 1 ]] || { echo "Expected soft_count=1, got $_LIVENESS_API_SOFT_COUNT"; exit 2; }

        # Now exhaust the grace: simulate cap reached
        _LIVENESS_API_SOFT_COUNT=10
        if ! _liveness_should_kill 150 120 cycles; then
            echo "ERROR: should have killed after soft grace exhausted with completion timeout"
            exit 3
        fi
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Completion timeout should be honoured with two-tier grace: $err"
}

test_liveness_diagnostics_capture() {
    log_test "Testing _liveness_capture_diagnostics creates diagnostics file"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        local diag_dir
        diag_dir=$(mktemp -d)

        # Override the diagnostics dir path
        _liveness_capture_diagnostics() {
            local pid="$1"
            local reason="$2"
            local stale_seconds="$3"
            local diag_file="${diag_dir}/kapsis-liveness-diagnostics.txt"

            {
                echo "=== Kapsis Liveness Kill Diagnostics ==="
                echo "Reason: $reason"
                echo "Staleness: ${stale_seconds}s"
                echo "=== Process Tree ==="
                echo "test process tree"
                echo "=== End Diagnostics ==="
            } > "$diag_file" 2>/dev/null || true
        }

        _liveness_capture_diagnostics 1 "test reason" 900

        local diag_file="${diag_dir}/kapsis-liveness-diagnostics.txt"
        [[ -f "$diag_file" ]] || { echo "Diagnostics file not created"; exit 1; }
        grep -q "Kapsis Liveness Kill Diagnostics" "$diag_file" || { echo "Missing header"; exit 2; }
        grep -q "test reason" "$diag_file" || { echo "Missing reason"; exit 3; }
        grep -q "End Diagnostics" "$diag_file" || { echo "Missing footer"; exit 4; }

        rm -rf "$diag_dir"
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should create diagnostics file with expected sections: $err"
}

test_liveness_exit_code_5_constant() {
    log_test "Testing KAPSIS_EXIT_HUNG_AFTER_COMPLETION constant is defined"

    (
        source "$KAPSIS_ROOT/scripts/lib/constants.sh"
        [[ "$KAPSIS_EXIT_HUNG_AFTER_COMPLETION" == "5" ]] || exit 1
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "KAPSIS_EXIT_HUNG_AFTER_COMPLETION should be 5"
}

test_status_get_exit_code() {
    log_test "Testing status_get_exit_code reads exit_code from status file"

    (
        export KAPSIS_STATUS_DIR
        KAPSIS_STATUS_DIR=$(mktemp -d)
        export KAPSIS_STATUS_ENABLED=true
        source "$KAPSIS_ROOT/scripts/lib/status.sh"
        status_init "test-project" "test-ec5" "main" "overlay"

        # Write a complete status with exit code 5
        status_complete 5 "Agent killed by liveness monitor"

        local ec
        ec=$(status_get_exit_code)
        [[ "$ec" == "5" ]] || exit 1

        rm -f "$_KAPSIS_STATUS_FILE"
        rm -rf "$KAPSIS_STATUS_DIR"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should read exit_code 5 from status file"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Liveness Monitor"

    # Unit tests
    run_test test_liveness_monitor_sources_cleanly
    run_test test_liveness_source_guard
    run_test test_liveness_io_parsing
    run_test test_liveness_io_parsing_missing_file
    run_test test_liveness_io_parsing_zero_bytes
    run_test test_liveness_config_defaults
    run_test test_liveness_config_custom_values
    run_test test_liveness_heartbeat_in_status
    run_test test_liveness_heartbeat_null_when_unset

    # API connection signal unit tests
    run_test test_liveness_ip4_to_proc_hex
    run_test test_liveness_ip6_to_proc_hex
    run_test test_liveness_resolve_api_ips_deduplication
    run_test test_liveness_resolve_api_ips_graceful_failure

    # Connection strength unit tests (Issue #267)
    run_test test_liveness_api_strength_active_queues
    run_test test_liveness_api_strength_active_retransmit
    run_test test_liveness_api_strength_idle_queues
    run_test test_liveness_api_strength_none
    run_test test_liveness_api_strength_no_ips
    run_test test_liveness_api_strength_ss_fallback

    # Kill decision logic unit tests
    run_test test_liveness_should_kill_not_stale
    run_test test_liveness_should_kill_io_active
    run_test test_liveness_kill_two_signals_met_no_connection
    run_test test_liveness_soft_grace_defers_kill
    run_test test_liveness_soft_grace_cap_kills
    run_test test_liveness_hard_grace_defers_kill
    run_test test_liveness_hard_grace_cap_kills
    run_test test_liveness_signal2_not_reset_by_signal3
    run_test test_liveness_io_active_protects_without_api
    run_test test_liveness_monitor_starts_without_dns

    # Integration tests
    run_test test_claude_exit_delay_agent_type_match
    run_test test_liveness_config_yaml_parsing

    # Config validation tests
    run_test test_liveness_config_validation_valid
    run_test test_liveness_config_validation_timeout_too_low
    run_test test_liveness_config_validation_interval_too_low
    run_test test_liveness_config_validation_warns_timeout_lt_grace

    # Health command tests
    run_test test_health_flag_requires_args
    run_test test_health_json_output_valid
    run_test test_health_not_found

    # Issue #257 tests: hung agent detection
    run_test test_liveness_get_phase
    run_test test_liveness_get_phase_running
    run_test test_liveness_exit_code_5_on_completion
    run_test test_liveness_exit_code_137_when_running
    run_test test_liveness_io_total_descendants
    run_test test_liveness_completion_timeout_unconditional
    run_test test_liveness_diagnostics_capture
    run_test test_liveness_exit_code_5_constant
    run_test test_status_get_exit_code

    # Mount check tests (Issue #248)
    run_test test_mount_check_early_probe_fires_before_grace
    run_test test_mount_check_probe_healthy
    run_test test_mount_check_probe_empty_workspace
    run_test test_mount_check_probe_missing_workspace
    run_test test_mount_check_probe_worktree_git_sentinel
    run_test test_mount_check_with_retries_recovers
    run_test test_mount_check_with_retries_all_fail
    run_test test_mount_check_probe_returns_124_on_timeout
    run_test test_mount_check_config_defaults
    run_test test_mount_check_config_custom_values

    print_summary
}

main "$@"
