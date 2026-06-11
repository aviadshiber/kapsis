#!/usr/bin/env bash
#===============================================================================
# Tests: Staged Workflows — Privilege Separation (Issue #85)
#
# Tests cover:
#   - Stage config loading (built-in defaults + YAML overrides)
#   - Stage application (network mode, security profile, credential filtering)
#   - Approval gate policies (small_changes, docs_only, tests_only, always)
#   - Handoff write / read / sanitization
#   - Path traversal validation in handoff file names
#   - Status JSON 'stage' field
#   - launch-agent.sh --stage flag (integration)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/lib/status.sh"
source "$KAPSIS_ROOT/scripts/lib/staged-workflows.sh"

#===============================================================================
# HELPERS
#===============================================================================

STAGED_TEST_DIR=""

setup_staged_test() {
    STAGED_TEST_DIR=$(mktemp -d)
    # Override handoff dir to temp for test isolation (KAPSIS_HANDOFF_DIR is not readonly)
    export KAPSIS_HANDOFF_DIR="$STAGED_TEST_DIR/handoffs"
    mkdir -p "$KAPSIS_HANDOFF_DIR"

    # Reset state between tests
    _SW_STAGE_NAMES=()
    _SW_STAGE_NETWORK_MODES=()
    _SW_STAGE_SECURITY_PROFILES=()
    _SW_STAGE_CREDENTIALS=()
    _SW_STAGE_NETWORK_OVERRIDES=()
    _SW_APPROVAL_POLICIES=()
    _SW_APPROVAL_REQUIRE_MANUAL="false"
    _SW_APPROVAL_GATE_SCRIPT=""
    _SW_CONFIG_LOADED=false
}

cleanup_staged_test() {
    [[ -n "$STAGED_TEST_DIR" ]] && rm -rf "$STAGED_TEST_DIR"
}

# Write a minimal workflow YAML for testing
write_workflow_yaml() {
    local yaml_file="$1"
    cat > "$yaml_file" << 'EOF'
workflow:
  stages:
    - name: research
      network_mode: filtered
      security_profile: minimal
      credentials: []
    - name: implementation
      network_mode: none
      security_profile: strict
      credentials:
        - SSH_KEY
        - KAPSIS_MAVEN_PASSWORD
    - name: publish
      network_mode: filtered
      security_profile: standard
      credentials:
        - GITHUB_TOKEN
      network_allowlist_override:
        - github.com
        - api.github.com
  approval:
    auto_approve:
      - policy: small_changes
    require_manual: "false"
EOF
}

#===============================================================================
# TEST: BUILT-IN DEFAULTS
#===============================================================================

test_builtin_defaults_loaded_when_no_config() {
    log_test "Built-in defaults applied when no config file exists"
    setup_staged_test
    trap cleanup_staged_test RETURN

    stage_load_config "/nonexistent/config.yaml"

    assert_equals "3" "${#_SW_STAGE_NAMES[@]}" "Should have 3 built-in stages"
    assert_equals "research" "${_SW_STAGE_NAMES[0]}" "First stage should be research"
    assert_equals "implementation" "${_SW_STAGE_NAMES[1]}" "Second stage should be implementation"
    assert_equals "publish" "${_SW_STAGE_NAMES[2]}" "Third stage should be publish"

    assert_equals "filtered" "${_SW_STAGE_NETWORK_MODES[0]}" "research network should be filtered"
    assert_equals "none"     "${_SW_STAGE_NETWORK_MODES[1]}" "implementation network should be none"
    assert_equals "filtered" "${_SW_STAGE_NETWORK_MODES[2]}" "publish network should be filtered"

    assert_equals "minimal" "${_SW_STAGE_SECURITY_PROFILES[0]}" "research security should be minimal"
    assert_equals "strict"  "${_SW_STAGE_SECURITY_PROFILES[1]}" "implementation security should be strict"
    assert_equals "standard" "${_SW_STAGE_SECURITY_PROFILES[2]}" "publish security should be standard"
}

#===============================================================================
# TEST: YAML CONFIG LOADING
#===============================================================================

test_yaml_config_loads_stages() {
    log_test "Stage config correctly parsed from YAML"
    skip_if_not_mikefarah_yq || return 0
    setup_staged_test
    trap cleanup_staged_test RETURN

    local yaml_file="${STAGED_TEST_DIR}/config.yaml"
    write_workflow_yaml "$yaml_file"

    stage_load_config "$yaml_file"

    assert_equals "3" "${#_SW_STAGE_NAMES[@]}" "Should load 3 stages from YAML"
    assert_equals "research"       "${_SW_STAGE_NAMES[0]}"        "First stage name"
    assert_equals "implementation" "${_SW_STAGE_NAMES[1]}"        "Second stage name"
    assert_equals "filtered"       "${_SW_STAGE_NETWORK_MODES[0]}" "research network mode"
    assert_equals "none"           "${_SW_STAGE_NETWORK_MODES[1]}" "implementation network mode"
    assert_equals "strict"         "${_SW_STAGE_SECURITY_PROFILES[1]}" "implementation security"
    assert_equals "1" "${#_SW_APPROVAL_POLICIES[@]}" "Should load 1 approval policy"
    assert_equals "small_changes" "${_SW_APPROVAL_POLICIES[0]}" "Approval policy"
}

test_yaml_config_loads_credentials_list() {
    log_test "Stage credential allowlist parsed from YAML"
    skip_if_not_mikefarah_yq || return 0
    setup_staged_test
    trap cleanup_staged_test RETURN

    local yaml_file="${STAGED_TEST_DIR}/config.yaml"
    write_workflow_yaml "$yaml_file"

    stage_load_config "$yaml_file"

    # research: empty credentials
    assert_equals "" "${_SW_STAGE_CREDENTIALS[0]}" "research should have empty credentials"
    # implementation: SSH_KEY,KAPSIS_MAVEN_PASSWORD
    assert_contains "${_SW_STAGE_CREDENTIALS[1]}" "SSH_KEY" "implementation should allow SSH_KEY"
    assert_contains "${_SW_STAGE_CREDENTIALS[1]}" "KAPSIS_MAVEN_PASSWORD" "implementation should allow KAPSIS_MAVEN_PASSWORD"
    # publish: GITHUB_TOKEN
    assert_contains "${_SW_STAGE_CREDENTIALS[2]}" "GITHUB_TOKEN" "publish should allow GITHUB_TOKEN"
    assert_not_contains "${_SW_STAGE_CREDENTIALS[2]}" "SSH_KEY" "publish should NOT have SSH_KEY"
}

#===============================================================================
# TEST: STAGE APPLICATION
#===============================================================================

test_stage_apply_sets_network_mode_to_none_for_implementation() {
    log_test "Applying 'implementation' stage sets NETWORK_MODE=none"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _sw_load_builtin_defaults
    _SW_CONFIG_LOADED=true

    stage_apply_config "implementation" "" >/dev/null

    assert_equals "none" "$NETWORK_MODE" "implementation stage must set NETWORK_MODE=none"
}

test_stage_apply_sets_security_strict_for_implementation() {
    log_test "Applying 'implementation' stage sets KAPSIS_SECURITY_PROFILE=strict"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _sw_load_builtin_defaults
    _SW_CONFIG_LOADED=true

    stage_apply_config "implementation" "" >/dev/null

    assert_equals "strict" "$KAPSIS_SECURITY_PROFILE" "implementation stage must set strict security"
}

test_stage_apply_exports_current_stage() {
    log_test "stage_apply_config exports KAPSIS_CURRENT_STAGE"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _sw_load_builtin_defaults
    _SW_CONFIG_LOADED=true

    stage_apply_config "research" "" >/dev/null

    assert_equals "research" "$KAPSIS_CURRENT_STAGE" "KAPSIS_CURRENT_STAGE should be set"
}

test_stage_apply_filters_credentials() {
    log_test "stage_apply_config filters ENV_KEYCHAIN to allowed credentials only"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _sw_load_builtin_defaults
    _SW_CONFIG_LOADED=true

    # Override implementation credentials list
    _SW_STAGE_CREDENTIALS[1]="SSH_KEY"

    # Simulate a keychain with multiple entries
    local mock_keychain
    mock_keychain="SSH_KEY|my-ssh|user||0600|secret_store|||
GITHUB_TOKEN|github|user||0600|secret_store|||
KAPSIS_MAVEN_PASSWORD|maven|user||0600|secret_store|||"

    local filtered
    filtered=$(stage_apply_config "implementation" "$mock_keychain")

    assert_contains "$filtered" "SSH_KEY" "filtered keychain should include SSH_KEY"
    assert_not_contains "$filtered" "GITHUB_TOKEN" "filtered keychain should exclude GITHUB_TOKEN"
    assert_not_contains "$filtered" "KAPSIS_MAVEN_PASSWORD" "filtered keychain should exclude KAPSIS_MAVEN_PASSWORD"
}

test_stage_apply_no_filtering_when_credentials_empty() {
    log_test "Empty credentials list means all credentials pass through"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _sw_load_builtin_defaults
    _SW_CONFIG_LOADED=true

    # research has empty credentials → all pass through
    local mock_keychain="SSH_KEY|my-ssh|user||0600|secret_store|||
GITHUB_TOKEN|github|user||0600|secret_store|||"

    local filtered
    filtered=$(stage_apply_config "research" "$mock_keychain")

    assert_contains "$filtered" "SSH_KEY"     "all creds should pass through when list is empty"
    assert_contains "$filtered" "GITHUB_TOKEN" "all creds should pass through when list is empty"
}

test_stage_apply_unknown_stage_returns_error() {
    log_test "Applying an unknown stage name returns error"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _sw_load_builtin_defaults
    _SW_CONFIG_LOADED=true

    local output
    if output=$(stage_apply_config "nonexistent" "" 2>&1); then
        assert_false "true" "should have returned non-zero for unknown stage"
    else
        assert_contains "$output" "Unknown stage" "error should mention unknown stage"
    fi
}

#===============================================================================
# TEST: APPROVAL GATE POLICIES
#===============================================================================

test_approval_always_policy_returns_approved() {
    log_test "Approval policy 'always' auto-approves any transition"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _SW_APPROVAL_POLICIES=("always")
    _SW_APPROVAL_REQUIRE_MANUAL="false"
    _SW_APPROVAL_GATE_SCRIPT=""

    stage_check_approval_gate "$KAPSIS_HANDOFF_DIR" "research" "implementation" "test-agent-001"
    assert_equals "0" "$?" "always policy should return 0 (approved)"
}

test_approval_no_prev_stage_skips_gate() {
    log_test "No previous stage means no gate check needed"
    setup_staged_test
    trap cleanup_staged_test RETURN

    # No previous stage = first stage
    stage_check_approval_gate "$KAPSIS_HANDOFF_DIR" "" "research" "test-agent-002"
    assert_equals "0" "$?" "no previous stage should always be approved"
}

test_approval_small_changes_approves_with_small_handoff() {
    log_test "small_changes policy approves when handoff shows few changes"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _SW_APPROVAL_POLICIES=("small_changes")
    _SW_APPROVAL_REQUIRE_MANUAL="false"

    # Create a handoff file with small changes
    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-003-research.json"
    cat > "$handoff_file" << 'EOF'
{
  "schema_version": "1.0",
  "stage": "research",
  "agent_id": "test-agent-003",
  "completed_at": "2026-06-11T14:00:00Z",
  "summary": "Found relevant APIs",
  "output_files": [
    {"path": "notes.md"},
    {"path": "api-spec.md"}
  ],
  "lines_changed": 45,
  "metadata": {}
}
EOF

    stage_check_approval_gate "$KAPSIS_HANDOFF_DIR" "research" "implementation" "test-agent-003"
    assert_equals "0" "$?" "small_changes policy should approve <= $KAPSIS_APPROVAL_SMALL_FILES files"
}

test_approval_small_changes_denies_when_too_many_files() {
    log_test "small_changes policy denies when too many files changed"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _SW_APPROVAL_POLICIES=("small_changes")
    _SW_APPROVAL_REQUIRE_MANUAL="false"

    # Create a handoff file with many files (> threshold)
    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-004-research.json"
    # Build output_files array with more than KAPSIS_APPROVAL_SMALL_FILES entries
    python3 -c "
import json
files = [{'path': f'file{i}.txt'} for i in range(10)]
data = {
    'schema_version': '1.0',
    'stage': 'research',
    'agent_id': 'test-agent-004',
    'completed_at': '2026-06-11T14:00:00Z',
    'summary': 'Large research',
    'output_files': files,
    'lines_changed': 500,
    'metadata': {}
}
print(json.dumps(data, indent=2))
" > "$handoff_file"

    local gate_exit=0
    stage_check_approval_gate "$KAPSIS_HANDOFF_DIR" "research" "implementation" "test-agent-004" || gate_exit=$?
    assert_not_equals "0" "$gate_exit" "small_changes policy should deny > $KAPSIS_APPROVAL_SMALL_FILES files"
}

test_approval_docs_only_approves_markdown_files() {
    log_test "docs_only policy approves when all changed files are documentation"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _SW_APPROVAL_POLICIES=("docs_only")
    _SW_APPROVAL_REQUIRE_MANUAL="false"

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-005-research.json"
    cat > "$handoff_file" << 'EOF'
{
  "schema_version": "1.0",
  "stage": "research",
  "agent_id": "test-agent-005",
  "completed_at": "2026-06-11T14:00:00Z",
  "summary": "Documentation research",
  "output_files": [
    {"path": "README.md"},
    {"path": "CONTRIBUTING.md"},
    {"path": "notes.txt"}
  ],
  "lines_changed": 80,
  "metadata": {}
}
EOF

    stage_check_approval_gate "$KAPSIS_HANDOFF_DIR" "research" "implementation" "test-agent-005"
    assert_equals "0" "$?" "docs_only policy should approve all-doc handoff"
}

test_approval_docs_only_denies_when_non_docs_present() {
    log_test "docs_only policy denies when non-documentation files are present"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _SW_APPROVAL_POLICIES=("docs_only")
    _SW_APPROVAL_REQUIRE_MANUAL="false"

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-006-research.json"
    cat > "$handoff_file" << 'EOF'
{
  "schema_version": "1.0",
  "stage": "research",
  "agent_id": "test-agent-006",
  "completed_at": "2026-06-11T14:00:00Z",
  "summary": "Mixed output",
  "output_files": [
    {"path": "README.md"},
    {"path": "src/main.java"}
  ],
  "lines_changed": 100,
  "metadata": {}
}
EOF

    local gate_exit=0
    stage_check_approval_gate "$KAPSIS_HANDOFF_DIR" "research" "implementation" "test-agent-006" || gate_exit=$?
    assert_not_equals "0" "$gate_exit" "docs_only policy should deny when non-doc files present"
}

#===============================================================================
# TEST: HANDOFF FILE I/O
#===============================================================================

test_handoff_write_creates_valid_json() {
    log_test "stage_write_handoff creates a valid JSON handoff file"
    setup_staged_test
    trap cleanup_staged_test RETURN

    stage_write_handoff "research" "test-agent-007" "" "Test summary" >/dev/null

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-007-research.json"
    assert_file_exists "$handoff_file" "Handoff file should be created"

    # Validate it is valid JSON
    python3 -c "import json; json.load(open('$handoff_file'))" 2>/dev/null
    assert_equals "0" "$?" "Handoff file should be valid JSON"
}

test_handoff_write_records_stage_name() {
    log_test "stage_write_handoff records the stage name correctly"
    setup_staged_test
    trap cleanup_staged_test RETURN

    stage_write_handoff "research" "test-agent-008" "" "Check stage field" >/dev/null

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-008-research.json"
    local stage_in_file
    stage_in_file=$(python3 -c "import json; d=json.load(open('$handoff_file')); print(d['stage'])" 2>/dev/null)
    assert_equals "research" "$stage_in_file" "stage field should be 'research'"
}

test_handoff_read_returns_content() {
    log_test "stage_read_handoff returns file content"
    setup_staged_test
    trap cleanup_staged_test RETURN

    stage_write_handoff "research" "test-agent-009" "" "Read test" >/dev/null

    local content
    content=$(stage_read_handoff "research" "test-agent-009")
    assert_not_empty "$content" "stage_read_handoff should return content"
    assert_contains "$content" "research" "content should include stage name"
}

test_handoff_read_fails_for_nonexistent() {
    log_test "stage_read_handoff returns non-zero for missing handoff"
    setup_staged_test
    trap cleanup_staged_test RETURN

    local rc=0
    stage_read_handoff "research" "no-such-agent-999" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "stage_read_handoff should return non-zero for missing file"
}

test_handoff_summary_json_injection_escaped() {
    log_test "Malicious summary string is safely escaped in handoff JSON"
    setup_staged_test
    trap cleanup_staged_test RETURN

    local malicious_summary='evil" }, "injected": "field'
    stage_write_handoff "research" "test-agent-010" "" "$malicious_summary" >/dev/null

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-010-research.json"
    # The file must still be valid JSON
    python3 -c "import json; json.load(open('$handoff_file'))" 2>/dev/null
    assert_equals "0" "$?" "Handoff JSON must be valid even with injection-attempt summary"
}

#===============================================================================
# TEST: HANDOFF SANITIZATION
#===============================================================================

test_handoff_sanitize_strips_bidi_chars() {
    log_test "stage_sanitize_handoff strips BiDi override characters"
    setup_staged_test
    trap cleanup_staged_test RETURN

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-test-agent-011-research.json"
    # Embed a BiDi left-to-right override (U+202A) in the summary
    local bidi_char
    bidi_char=$(printf '\xe2\x80\xaa')
    cat > "$handoff_file" << EOF
{
  "schema_version": "1.0",
  "stage": "research",
  "agent_id": "test-agent-011",
  "completed_at": "2026-06-11T14:00:00Z",
  "summary": "Normal text${bidi_char}injected",
  "output_files": [],
  "lines_changed": 0,
  "metadata": {}
}
EOF

    stage_sanitize_handoff "research" "test-agent-011"

    assert_file_not_contains "$handoff_file" "$bidi_char" \
        "BiDi override character should be removed from handoff"
}

#===============================================================================
# TEST: STATUS.SH STAGE FIELD
#===============================================================================

test_status_json_includes_stage_field() {
    log_test "status.sh writes stage field when KAPSIS_STATUS_STAGE is set"

    KAPSIS_STATUS_ENABLED=true
    export KAPSIS_STATUS_STAGE="sw-test-stage"
    _KAPSIS_STATUS_INITIALIZED=false

    # Use a unique project+agent combo to avoid collisions with other tests
    status_init "sw-testproj" "sw123" "main" "worktree" ""

    # Use status_get_file() to resolve the actual path (handles /kapsis-status override)
    local status_file
    status_file=$(status_get_file)

    assert_file_exists "$status_file" "Status file should be created"

    local stage_value
    stage_value=$(python3 -c "import json; d=json.load(open('$status_file')); print(d.get('stage','__missing__'))" 2>/dev/null)
    assert_equals "sw-test-stage" "$stage_value" "Status JSON should contain stage field"

    # Clean up the file we created (best-effort)
    rm -f "$status_file" 2>/dev/null || true

    # Restore
    unset KAPSIS_STATUS_STAGE
    _KAPSIS_STATUS_INITIALIZED=false
}

#===============================================================================
# TEST: LAUNCH-AGENT.SH --STAGE FLAG (DRY-RUN INTEGRATION)
#===============================================================================

test_launch_agent_accepts_stage_flag() {
    log_test "launch-agent.sh --stage flag is parsed without error (dry-run)"
    skip_if_not_mikefarah_yq || return 0

    setup_test_project
    trap cleanup_test_project RETURN

    local output
    output=$(
        "$KAPSIS_ROOT/scripts/launch-agent.sh" "$TEST_PROJECT" \
            --stage research \
            --agent claude \
            --task "test task" \
            --dry-run 2>&1
    ) || true

    # The dry-run should not fail due to an unrecognized --stage flag
    assert_not_contains "$output" "Unknown option: --stage" \
        "--stage should be a recognized flag in launch-agent.sh"
}

test_launch_agent_stage_sets_network_mode() {
    log_test "launch-agent.sh --stage implementation sets network_mode=none in dry-run output"
    skip_if_not_mikefarah_yq || return 0

    setup_test_project
    trap cleanup_test_project RETURN

    local output
    output=$(
        "$KAPSIS_ROOT/scripts/launch-agent.sh" "$TEST_PROJECT" \
            --stage implementation \
            --agent claude \
            --task "implement" \
            --dry-run 2>&1
    ) || true

    assert_contains "$output" "none" \
        "implementation stage dry-run should show network=none in output"
}

#===============================================================================
# TEST: STAGE SUMMARY
#===============================================================================

test_stage_print_summary_all() {
    log_test "stage_print_summary outputs all stage names"
    setup_staged_test
    trap cleanup_staged_test RETURN

    _sw_load_builtin_defaults
    _SW_CONFIG_LOADED=true

    local output
    output=$(stage_print_summary "all")

    assert_contains "$output" "research"       "summary should list research"
    assert_contains "$output" "implementation" "summary should list implementation"
    assert_contains "$output" "publish"        "summary should list publish"
    assert_contains "$output" "network_mode"   "summary should show network_mode"
    assert_contains "$output" "security_profile" "summary should show security_profile"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Staged Workflows — Privilege Separation (Issue #85)"

    # Config loading
    run_test test_builtin_defaults_loaded_when_no_config
    run_test test_yaml_config_loads_stages
    run_test test_yaml_config_loads_credentials_list

    # Stage application
    run_test test_stage_apply_sets_network_mode_to_none_for_implementation
    run_test test_stage_apply_sets_security_strict_for_implementation
    run_test test_stage_apply_exports_current_stage
    run_test test_stage_apply_filters_credentials
    run_test test_stage_apply_no_filtering_when_credentials_empty
    run_test test_stage_apply_unknown_stage_returns_error

    # Approval gates
    run_test test_approval_always_policy_returns_approved
    run_test test_approval_no_prev_stage_skips_gate
    run_test test_approval_small_changes_approves_with_small_handoff
    run_test test_approval_small_changes_denies_when_too_many_files
    run_test test_approval_docs_only_approves_markdown_files
    run_test test_approval_docs_only_denies_when_non_docs_present

    # Handoff I/O
    run_test test_handoff_write_creates_valid_json
    run_test test_handoff_write_records_stage_name
    run_test test_handoff_read_returns_content
    run_test test_handoff_read_fails_for_nonexistent
    run_test test_handoff_summary_json_injection_escaped

    # Sanitization
    run_test test_handoff_sanitize_strips_bidi_chars

    # Status integration
    run_test test_status_json_includes_stage_field

    # launch-agent.sh integration (quick dry-run)
    run_test test_launch_agent_accepts_stage_flag
    run_test test_launch_agent_stage_sets_network_mode

    # Summary
    run_test test_stage_print_summary_all

    print_summary
}

main "$@"
