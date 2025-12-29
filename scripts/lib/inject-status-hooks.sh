#!/usr/bin/env bash
# inject-status-hooks.sh - Inject Kapsis status hooks into agent settings
#
# This script injects Kapsis status tracking hooks into AI agent configurations.
# It runs inside the container after CoW setup, so modifications don't affect
# the host configuration.
#
# Supported agents:
#   - Claude Code: ~/.claude/settings.local.json (JSON, merged by Claude)
#   - Codex CLI: ~/.codex/config.yaml (YAML, merged hooks section)
#   - Gemini CLI: ~/.gemini/hooks/*.sh (Shell scripts in hooks directory)
#
# Usage: Called automatically by entrypoint.sh for supported agents
#        Or call directly: ./inject-status-hooks.sh [agent-type]
#
# Environment:
#   KAPSIS_STATUS_AGENT_ID - Required: Agent ID for status tracking
#   KAPSIS_AGENT_TYPE      - Agent type (claude-cli, codex-cli, gemini-cli, etc.)
#   KAPSIS_SCRIPTS         - Path to Kapsis scripts directory

set -euo pipefail

# Source logging if available
if [[ -f "${KAPSIS_LIB:-/opt/kapsis/lib}/logging.sh" ]]; then
    # shellcheck source=logging.sh
    source "${KAPSIS_LIB:-/opt/kapsis/lib}/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_debug() { :; }
    log_success() { echo "[OK] $*"; }
fi

#===============================================================================
# Configuration
#===============================================================================

# Hook paths inside container
# Hooks are at /opt/kapsis/hooks/, not in the scripts subdirectory
KAPSIS_HOOK_DIR="${KAPSIS_HOME:-/opt/kapsis}/hooks"
STATUS_HOOK="${KAPSIS_HOOK_DIR}/kapsis-status-hook.sh"
STOP_HOOK="${KAPSIS_HOOK_DIR}/kapsis-stop-hook.sh"

#===============================================================================
# Claude Code Hook Injection (JSON-based)
#===============================================================================

inject_claude_hooks() {
    local settings_dir="${HOME}/.claude"
    local settings_local="${settings_dir}/settings.local.json"

    # Ensure directory exists
    mkdir -p "$settings_dir"

    # Create base file if missing
    if [[ ! -f "$settings_local" ]]; then
        echo '{}' > "$settings_local"
        log_debug "Created empty settings.local.json"
    fi

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - cannot inject Claude hooks"
        return 1
    fi

    # Inject hooks using jq (merge, don't overwrite)
    local tmp_file
    tmp_file=$(mktemp)

    if jq --arg status_hook "$STATUS_HOOK" --arg stop_hook "$STOP_HOOK" '
        # Ensure hooks object exists
        .hooks //= {} |

        # Ensure PostToolUse array exists
        .hooks.PostToolUse //= [] |

        # Add status hook to PostToolUse if not already present
        if ([.hooks.PostToolUse[].hooks[]? | select(.command == $status_hook)] | length) == 0 then
            .hooks.PostToolUse += [{
                "matcher": "*",
                "hooks": [{"type": "command", "command": $status_hook, "timeout": 5}]
            }]
        else . end |

        # Ensure Stop array exists
        .hooks.Stop //= [] |

        # Add stop hook if not already present
        if ([.hooks.Stop[].hooks[]? | select(.command == $stop_hook)] | length) == 0 then
            .hooks.Stop += [{
                "hooks": [{"type": "command", "command": $stop_hook, "timeout": 5}]
            }]
        else . end
    ' "$settings_local" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$settings_local"
        chmod 600 "$settings_local"
        log_success "Claude Code hooks injected (merged with existing)"
        return 0
    else
        rm -f "$tmp_file"
        log_warn "Failed to inject Claude hooks - JSON parsing error"
        return 1
    fi
}

#===============================================================================
# Codex CLI Hook Injection (YAML-based)
#===============================================================================

inject_codex_hooks() {
    local config_dir="${HOME}/.codex"
    local config_file="${config_dir}/config.yaml"

    # Ensure directory exists
    mkdir -p "$config_dir"

    # Check if yq is available
    if ! command -v yq &>/dev/null; then
        log_warn "yq not found - cannot inject Codex hooks"
        return 1
    fi

    # Create base file if missing
    if [[ ! -f "$config_file" ]]; then
        echo '# Codex CLI configuration' > "$config_file"
        log_debug "Created empty config.yaml"
    fi

    # Check if hooks already exist using yq
    local existing_hooks
    existing_hooks=$(yq eval '.hooks."exec.post" // []' "$config_file" 2>/dev/null || echo "[]")

    # Check if our hook is already present
    if echo "$existing_hooks" | grep -q "$STATUS_HOOK"; then
        log_debug "Codex hooks already present"
        return 0
    fi

    # Inject hooks using yq (merge, don't overwrite)
    local tmp_file
    tmp_file=$(mktemp)

    if yq eval --inplace "
        .hooks.\"exec.post\" = (.hooks.\"exec.post\" // []) + [\"$STATUS_HOOK\"] |
        .hooks.\"item.create\" = (.hooks.\"item.create\" // []) + [\"$STATUS_HOOK\"] |
        .hooks.\"item.update\" = (.hooks.\"item.update\" // []) + [\"$STATUS_HOOK\"] |
        .hooks.completion = (.hooks.completion // []) + [\"$STOP_HOOK\"] |
        .hooks.\"exec.post\" |= unique |
        .hooks.\"item.create\" |= unique |
        .hooks.\"item.update\" |= unique |
        .hooks.completion |= unique
    " "$config_file" 2>/dev/null; then
        chmod 600 "$config_file"
        log_success "Codex CLI hooks injected (merged with existing)"
        return 0
    else
        log_warn "Failed to inject Codex hooks - YAML parsing error"
        return 1
    fi
}

#===============================================================================
# Gemini CLI Hook Injection (Shell script-based)
#===============================================================================

inject_gemini_hooks() {
    local hooks_dir="${HOME}/.gemini/hooks"

    # Ensure directory exists
    mkdir -p "$hooks_dir"

    # Create post-tool hook wrapper (idempotent - check if already has our hook)
    local post_tool_hook="${hooks_dir}/post-tool.sh"
    if [[ -f "$post_tool_hook" ]] && grep -q "$STATUS_HOOK" "$post_tool_hook" 2>/dev/null; then
        log_debug "Gemini post-tool hook already present"
    else
        # Append to existing or create new
        if [[ -f "$post_tool_hook" ]]; then
            # Append our hook call
            {
                echo ""
                echo "# Kapsis status tracking"
                echo "\"$STATUS_HOOK\" \"\$@\" || true"
            } >> "$post_tool_hook"
        else
            # Create new
            cat > "$post_tool_hook" << EOF
#!/usr/bin/env bash
# Gemini CLI post-tool hook
# Kapsis status tracking
"$STATUS_HOOK" "\$@" || true
EOF
        fi
        chmod +x "$post_tool_hook"
    fi

    # Create completion hook wrapper
    local completion_hook="${hooks_dir}/completion.sh"
    if [[ -f "$completion_hook" ]] && grep -q "$STOP_HOOK" "$completion_hook" 2>/dev/null; then
        log_debug "Gemini completion hook already present"
    else
        if [[ -f "$completion_hook" ]]; then
            {
                echo ""
                echo "# Kapsis status tracking"
                echo "\"$STOP_HOOK\" \"\$@\" || true"
            } >> "$completion_hook"
        else
            cat > "$completion_hook" << EOF
#!/usr/bin/env bash
# Gemini CLI completion hook
# Kapsis status tracking
"$STOP_HOOK" "\$@" || true
EOF
        fi
        chmod +x "$completion_hook"
    fi

    log_success "Gemini CLI hooks injected"
    return 0
}

#===============================================================================
# Main Logic
#===============================================================================

inject_kapsis_hooks() {
    local agent_type="${1:-${KAPSIS_AGENT_TYPE:-}}"

    # Only inject when status tracking is enabled
    if [[ -z "${KAPSIS_STATUS_AGENT_ID:-}" ]]; then
        log_debug "Status tracking not enabled (KAPSIS_STATUS_AGENT_ID not set)"
        return 0
    fi

    # Verify hooks exist
    if [[ ! -x "$STATUS_HOOK" ]]; then
        log_warn "Status hook not found or not executable: $STATUS_HOOK"
        return 0
    fi

    # Route to agent-specific injection
    case "$agent_type" in
        claude|claude-cli|claude-code)
            inject_claude_hooks
            ;;
        codex|codex-cli)
            inject_codex_hooks
            ;;
        gemini|gemini-cli)
            inject_gemini_hooks
            ;;
        *)
            log_debug "Agent type '$agent_type' does not support hook injection"
            return 0
            ;;
    esac
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    inject_kapsis_hooks "$@"
fi
