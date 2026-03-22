#!/usr/bin/env bash
#===============================================================================
# Test: Agent Type Detection Chain (#213)
#
# Tests the agent type detection priority order:
# 1. --agent CLI flag (existing, tested elsewhere)
# 2. Config filename normalization (existing, tested elsewhere)
# 3. agent.type from YAML config (NEW)
# 4. Image name pattern matching (existing, tested elsewhere)
# 5. Command string inference (NEW)
# 6. Default: "unknown"
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

#===============================================================================
# TEST: agent.type from YAML config
#===============================================================================

test_config_type_field_claude() {
    log_test "Testing agent.type: claude-cli from config overrides unknown"

    source "$LIB_DIR/agent-types.sh"

    # Simulate: AGENT_NAME=slack-bot-agent (unknown), AGENT_CONFIG_TYPE=claude-cli
    local agent_type="unknown"
    local AGENT_CONFIG_TYPE="claude-cli"

    if [[ "$agent_type" == "unknown" && -n "${AGENT_CONFIG_TYPE:-}" ]]; then
        local config_type
        config_type=$(normalize_agent_type "$AGENT_CONFIG_TYPE")
        if [[ "$config_type" != "unknown" ]]; then
            agent_type="$config_type"
        fi
    fi

    assert_equals "claude-cli" "$agent_type" "Should resolve to claude-cli from config type"
}

test_config_type_field_codex() {
    log_test "Testing agent.type: codex from config normalizes to codex-cli"

    source "$LIB_DIR/agent-types.sh"

    local agent_type="unknown"
    local AGENT_CONFIG_TYPE="codex"

    if [[ "$agent_type" == "unknown" && -n "${AGENT_CONFIG_TYPE:-}" ]]; then
        local config_type
        config_type=$(normalize_agent_type "$AGENT_CONFIG_TYPE")
        if [[ "$config_type" != "unknown" ]]; then
            agent_type="$config_type"
        fi
    fi

    assert_equals "codex-cli" "$agent_type" "Should normalize codex to codex-cli"
}

test_config_type_field_unknown_ignored() {
    log_test "Testing agent.type with unrecognized value stays unknown"

    source "$LIB_DIR/agent-types.sh"

    local agent_type="unknown"
    local AGENT_CONFIG_TYPE="my-custom-bot"

    if [[ "$agent_type" == "unknown" && -n "${AGENT_CONFIG_TYPE:-}" ]]; then
        local config_type
        config_type=$(normalize_agent_type "$AGENT_CONFIG_TYPE")
        if [[ "$config_type" != "unknown" ]]; then
            agent_type="$config_type"
        fi
    fi

    assert_equals "unknown" "$agent_type" "Unrecognized type should stay unknown"
}

test_config_type_not_used_when_name_resolves() {
    log_test "Testing agent.type is not used when AGENT_NAME resolves"

    source "$LIB_DIR/agent-types.sh"

    # Simulate: AGENT_NAME=claude (resolves to claude-cli), config type is codex
    local agent_type
    agent_type=$(normalize_agent_type "claude")
    local AGENT_CONFIG_TYPE="codex"

    # Config type should NOT override when name already resolved
    if [[ "$agent_type" == "unknown" && -n "${AGENT_CONFIG_TYPE:-}" ]]; then
        local config_type
        config_type=$(normalize_agent_type "$AGENT_CONFIG_TYPE")
        if [[ "$config_type" != "unknown" ]]; then
            agent_type="$config_type"
        fi
    fi

    assert_equals "claude-cli" "$agent_type" "Name resolution takes priority over config type"
}

#===============================================================================
# TEST: Command string inference
#===============================================================================

test_command_inference_claude() {
    log_test "Testing command inference for claude"

    local agent_type="unknown"
    local AGENT_COMMAND="claude --dangerously-skip-permissions -p \"\$(cat /task-spec.md)\""

    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*claude\ --*|*/claude\ *)   agent_type="claude-cli" ;;
            codex\ *|*/codex\ *)                   agent_type="codex-cli" ;;
            gemini\ *|*/gemini\ *)                 agent_type="gemini-cli" ;;
            aider\ *|*/aider\ *)                   agent_type="aider" ;;
        esac
    fi

    assert_equals "claude-cli" "$agent_type" "Should infer claude-cli from command"
}

test_command_inference_claude_with_path() {
    log_test "Testing command inference for /usr/local/bin/claude"

    local agent_type="unknown"
    local AGENT_COMMAND="/usr/local/bin/claude --dangerously-skip-permissions"

    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*claude\ --*|*/claude\ *)   agent_type="claude-cli" ;;
            codex\ *|*/codex\ *)                   agent_type="codex-cli" ;;
            gemini\ *|*/gemini\ *)                 agent_type="gemini-cli" ;;
            aider\ *|*/aider\ *)                   agent_type="aider" ;;
        esac
    fi

    assert_equals "claude-cli" "$agent_type" "Should infer claude-cli from full path"
}

test_command_inference_codex() {
    log_test "Testing command inference for codex"

    local agent_type="unknown"
    local AGENT_COMMAND="codex --approval-mode full-auto \"implement feature\""

    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*claude\ --*|*/claude\ *)   agent_type="claude-cli" ;;
            codex\ *|*/codex\ *)                   agent_type="codex-cli" ;;
            gemini\ *|*/gemini\ *)                 agent_type="gemini-cli" ;;
            aider\ *|*/aider\ *)                   agent_type="aider" ;;
        esac
    fi

    assert_equals "codex-cli" "$agent_type" "Should infer codex-cli from command"
}

test_command_inference_gemini() {
    log_test "Testing command inference for gemini"

    local agent_type="unknown"
    local AGENT_COMMAND="gemini --sandbox -p task"

    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*claude\ --*|*/claude\ *)   agent_type="claude-cli" ;;
            codex\ *|*/codex\ *)                   agent_type="codex-cli" ;;
            gemini\ *|*/gemini\ *)                 agent_type="gemini-cli" ;;
            aider\ *|*/aider\ *)                   agent_type="aider" ;;
        esac
    fi

    assert_equals "gemini-cli" "$agent_type" "Should infer gemini-cli from command"
}

test_command_inference_aider() {
    log_test "Testing command inference for aider"

    local agent_type="unknown"
    local AGENT_COMMAND="aider --yes --auto-commits"

    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*claude\ --*|*/claude\ *)   agent_type="claude-cli" ;;
            codex\ *|*/codex\ *)                   agent_type="codex-cli" ;;
            gemini\ *|*/gemini\ *)                 agent_type="gemini-cli" ;;
            aider\ *|*/aider\ *)                   agent_type="aider" ;;
        esac
    fi

    assert_equals "aider" "$agent_type" "Should infer aider from command"
}

test_command_inference_no_match() {
    log_test "Testing command inference with non-matching command"

    local agent_type="unknown"
    local AGENT_COMMAND="python run_agent.py --task implement"

    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*claude\ --*|*/claude\ *)   agent_type="claude-cli" ;;
            codex\ *|*/codex\ *)                   agent_type="codex-cli" ;;
            gemini\ *|*/gemini\ *)                 agent_type="gemini-cli" ;;
            aider\ *|*/aider\ *)                   agent_type="aider" ;;
        esac
    fi

    assert_equals "unknown" "$agent_type" "Should stay unknown for non-matching command"
}

test_command_inference_not_used_when_config_type_resolves() {
    log_test "Testing command inference skipped when config type resolves"

    source "$LIB_DIR/agent-types.sh"

    local agent_type="unknown"
    local AGENT_CONFIG_TYPE="codex-cli"
    local AGENT_COMMAND="claude --dangerously-skip-permissions"

    # Step 1: config type override
    if [[ "$agent_type" == "unknown" && -n "${AGENT_CONFIG_TYPE:-}" ]]; then
        local config_type
        config_type=$(normalize_agent_type "$AGENT_CONFIG_TYPE")
        if [[ "$config_type" != "unknown" ]]; then
            agent_type="$config_type"
        fi
    fi

    # Step 2: command inference (should be skipped since agent_type != unknown)
    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*claude\ --*|*/claude\ *)   agent_type="claude-cli" ;;
        esac
    fi

    assert_equals "codex-cli" "$agent_type" "Config type should prevent command inference"
}

#===============================================================================
# TEST: Config verifier validation of agent.type
#===============================================================================

test_config_verifier_valid_agent_type() {
    log_test "Testing config verifier accepts valid agent.type"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  type: claude-cli
  command: "claude --dangerously-skip-permissions"
EOF

    local output
    local exit_code=0
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || exit_code=$?

    assert_contains "$output" "Valid agent.type" "Should validate claude-cli"

    rm -f "$config_file"
}

test_config_verifier_unknown_agent_type() {
    log_test "Testing config verifier warns on unknown agent.type"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  type: my-custom-bot
  command: "claude --dangerously-skip-permissions"
EOF

    local output
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || true

    assert_contains "$output" "not recognized" "Should warn about unknown type"

    rm -f "$config_file"
}

test_config_verifier_no_agent_type() {
    log_test "Testing config verifier accepts config without agent.type"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "claude --dangerously-skip-permissions"
EOF

    local output
    local exit_code=0
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should pass without agent.type"

    rm -f "$config_file"
}

#===============================================================================
# TEST: YAML config parsing
#===============================================================================

test_yaml_agent_type_parsing() {
    log_test "Testing agent.type YAML parsing with yq"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  type: claude-cli
  command: "claude --dangerously-skip-permissions"
EOF

    local agent_type
    agent_type=$(yq -r '.agent.type // ""' "$config_file" 2>/dev/null || echo "")

    assert_equals "claude-cli" "$agent_type" "Should parse agent.type from YAML"

    rm -f "$config_file"
}

test_yaml_agent_type_missing() {
    log_test "Testing agent.type absent from YAML returns empty"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "claude --dangerously-skip-permissions"
EOF

    local agent_type
    agent_type=$(yq -r '.agent.type // ""' "$config_file" 2>/dev/null || echo "")

    assert_equals "" "$agent_type" "Should return empty when agent.type is absent"

    rm -f "$config_file"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Agent Type Detection (#213)"

    log_info "=== Config Type Field ==="
    run_test test_config_type_field_claude
    run_test test_config_type_field_codex
    run_test test_config_type_field_unknown_ignored
    run_test test_config_type_not_used_when_name_resolves

    log_info "=== Command String Inference ==="
    run_test test_command_inference_claude
    run_test test_command_inference_claude_with_path
    run_test test_command_inference_codex
    run_test test_command_inference_gemini
    run_test test_command_inference_aider
    run_test test_command_inference_no_match
    run_test test_command_inference_not_used_when_config_type_resolves

    log_info "=== Config Verifier ==="
    run_test test_config_verifier_valid_agent_type
    run_test test_config_verifier_unknown_agent_type
    run_test test_config_verifier_no_agent_type

    log_info "=== YAML Parsing ==="
    run_test test_yaml_agent_type_parsing
    run_test test_yaml_agent_type_missing

    print_summary
}

main "$@"
