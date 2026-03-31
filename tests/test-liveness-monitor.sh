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

        # Check defaults are set correctly
        [[ "$_LIVENESS_TIMEOUT" == "1800" ]] || exit 1
        [[ "$_LIVENESS_GRACE" == "300" ]] || exit 2
        [[ "$_LIVENESS_INTERVAL" == "30" ]] || exit 3
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should have correct defaults (1800/300/30)"
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

        # Check status file contains heartbeat_at
        local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-test-1.json"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at"' "$status_file" || exit 1
            # Should not be null
            local hb
            hb=$(grep '"heartbeat_at"' "$status_file")
            [[ "$hb" != *"null"* ]] || exit 2
        else
            exit 3
        fi

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

        local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-test-2.json"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at": null' "$status_file" || exit 1
        else
            exit 2
        fi

        rm -rf "$KAPSIS_STATUS_DIR"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "heartbeat_at should be null when not set"
}

#===============================================================================
# UNIT TESTS: API connection detection
#===============================================================================

test_liveness_api_connection_detection_sources() {
    log_test "Testing _liveness_has_active_api_connections function exists after sourcing"

    local exit_code=0
    (
        # Reset source guard so we can re-source
        unset _KAPSIS_LIVENESS_MONITOR_LOADED
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        type _liveness_has_active_api_connections &>/dev/null || exit 1
    ) 2>/dev/null || exit_code=$?

    assert_equals 0 "$exit_code" "Function _liveness_has_active_api_connections should be defined"
}

test_liveness_api_domains_list_populated() {
    log_test "Testing _LIVENESS_API_DOMAINS array is populated"

    local exit_code=0
    (
        unset _KAPSIS_LIVENESS_MONITOR_LOADED
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        [[ ${#_LIVENESS_API_DOMAINS[@]} -ge 5 ]] || exit 1
    ) 2>/dev/null || exit_code=$?

    assert_equals 0 "$exit_code" "Should have at least 5 API domains defined"
}

test_liveness_proc_net_tcp_parsing_no_connections() {
    log_test "Testing /proc/net/tcp parsing returns false when no port 443 connections"

    local tmpdir
    tmpdir=$(mktemp -d)

    # Create a mock /proc/net/tcp with no port 443 connections
    # Port 50 (0032) in ESTABLISHED state (01)
    cat > "$tmpdir/tcp" << 'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 0100007F:0032 01 00000000:00000000 00:00000000 00000000  1000        0 12345
EOF

    local result=0
    # Test the awk pattern directly
    awk '$4 == "01" && $3 ~ /:01BB$/ {found=1; exit} END {exit !found}' "$tmpdir/tcp" 2>/dev/null || result=$?

    assert_not_equals 0 "$result" "Should return false when no port 443 connections exist"

    rm -rf "$tmpdir"
}

test_liveness_proc_net_tcp_parsing_with_443_connection() {
    log_test "Testing /proc/net/tcp parsing detects port 443 (0x01BB) ESTABLISHED connection"

    local tmpdir
    tmpdir=$(mktemp -d)

    # Create a mock /proc/net/tcp with an ESTABLISHED connection to port 443
    # Remote port 01BB = 443, state 01 = ESTABLISHED
    cat > "$tmpdir/tcp" << 'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:C000 68E3A4D2:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 12345
EOF

    local result=0
    awk '$4 == "01" && $3 ~ /:01BB$/ {found=1; exit} END {exit !found}' "$tmpdir/tcp" 2>/dev/null || result=$?

    assert_equals 0 "$result" "Should detect ESTABLISHED connection on port 443"

    rm -rf "$tmpdir"
}

test_liveness_proc_net_tcp_parsing_non_established_443() {
    log_test "Testing /proc/net/tcp ignores non-ESTABLISHED connections to port 443"

    local tmpdir
    tmpdir=$(mktemp -d)

    # State 06 = TIME_WAIT, not ESTABLISHED
    cat > "$tmpdir/tcp" << 'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:C000 68E3A4D2:01BB 06 00000000:00000000 00:00000000 00000000  1000        0 12345
EOF

    local result=0
    awk '$4 == "01" && $3 ~ /:01BB$/ {found=1; exit} END {exit !found}' "$tmpdir/tcp" 2>/dev/null || result=$?

    assert_not_equals 0 "$result" "Should ignore TIME_WAIT connections on port 443"

    rm -rf "$tmpdir"
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

    # API connection detection tests
    run_test test_liveness_api_connection_detection_sources
    run_test test_liveness_api_domains_list_populated
    run_test test_liveness_proc_net_tcp_parsing_no_connections
    run_test test_liveness_proc_net_tcp_parsing_with_443_connection
    run_test test_liveness_proc_net_tcp_parsing_non_established_443

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

    print_summary
}

main "$@"
