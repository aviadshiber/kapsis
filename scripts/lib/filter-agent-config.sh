#!/usr/bin/env bash
#===============================================================================
# filter-agent-config.sh - Whitelist hooks and MCP servers in agent configs
#
# Filters Claude Code's settings.json (hooks) and .claude.json (MCP servers)
# based on include lists from the YAML launch config. Only whitelisted entries
# are kept; everything else is removed.
#
# This runs INSIDE the container after CoW overlay setup (files are writable)
# but BEFORE Kapsis hook injection (settings.local.json), so there's no conflict.
#
# Environment:
#   KAPSIS_CLAUDE_HOOKS_INCLUDE  - Comma-separated substrings to match hook commands
#   KAPSIS_CLAUDE_MCP_INCLUDE    - Comma-separated exact MCP server names to keep
#   KAPSIS_AGENT_TYPE            - Agent type (only runs for claude-related types)
#
# Note: Include lists use comma as delimiter, so patterns/names must not contain commas.
#
# Usage: Called automatically by entrypoint.sh
#        source filter-agent-config.sh && filter_claude_agent_config
#===============================================================================

# Source guard
[[ -n "${_KAPSIS_FILTER_AGENT_CONFIG_LOADED:-}" ]] && return 0
_KAPSIS_FILTER_AGENT_CONFIG_LOADED=1

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
# Hook Whitelisting
#
# Filters ~/.claude/settings.json to keep only hooks whose command field
# contains a substring from the include list.
#
# Hook structure in settings.json:
#   {
#     "hooks": {
#       "PostToolUse": [
#         { "matcher": "*", "hooks": [{"type": "command", "command": "..."}] }
#       ],
#       "Stop": [...]
#     }
#   }
#===============================================================================

filter_claude_hooks() {
    local settings_file="${HOME}/.claude/settings.json"
    local include_list="${KAPSIS_CLAUDE_HOOKS_INCLUDE:-}"

    if [[ -z "$include_list" ]]; then
        log_debug "No hook whitelist configured - all hooks pass through"
        return 0
    fi

    if [[ ! -f "$settings_file" ]]; then
        log_debug "No settings.json found - nothing to filter"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - cannot filter hooks"
        return 1
    fi

    # Convert comma-separated list to JSON array for jq
    local patterns_json
    patterns_json=$(echo "$include_list" | tr ',' '\n' | jq -R . | jq -s .)
    log_debug "Hook whitelist patterns: $patterns_json"

    local tmp_file
    tmp_file=$(mktemp)

    # Keep only hooks where at least one command substring-matches the whitelist
    # Empty event types (all hooks removed) are pruned from the output
    if jq --argjson patterns "$patterns_json" '
        if .hooks then
            .hooks |= (with_entries(
                .value |= map(
                    select(
                        [.hooks[]?.command // ""] |
                        any(. as $cmd |
                            $patterns | any(. as $pat | $cmd | contains($pat))
                        )
                    )
                )
            ) | with_entries(select(.value | length > 0)))
        else . end
    ' "$settings_file" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$settings_file"
        chmod 600 "$settings_file"
        log_success "Hooks whitelisted (patterns: $include_list)"
        return 0
    else
        rm -f "$tmp_file"
        log_warn "Failed to filter hooks - JSON parsing error"
        return 1
    fi
}

#===============================================================================
# MCP Server Whitelisting
#
# Filters ~/.claude.json to keep only MCP servers whose key name
# exactly matches an entry in the include list.
#
# MCP structure in .claude.json:
#   {
#     "mcpServers": {
#       "context7": { ... },
#       "chrome-devtools": { ... }
#     }
#   }
#===============================================================================

filter_claude_mcp_servers() {
    local config_file="${HOME}/.claude.json"
    local include_list="${KAPSIS_CLAUDE_MCP_INCLUDE:-}"

    if [[ -z "$include_list" ]]; then
        log_debug "No MCP whitelist configured - all servers pass through"
        return 0
    fi

    if [[ ! -f "$config_file" ]]; then
        log_debug "No .claude.json found - nothing to filter"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - cannot filter MCP servers"
        return 1
    fi

    # Convert comma-separated list to JSON array for jq
    local servers_json
    servers_json=$(echo "$include_list" | tr ',' '\n' | jq -R . | jq -s .)
    log_debug "MCP server whitelist: $servers_json"

    local tmp_file
    tmp_file=$(mktemp)

    # Keep only MCP servers whose key matches the whitelist
    if jq --argjson servers "$servers_json" '
        if .mcpServers then
            .mcpServers |= with_entries(
                select(.key as $k | $servers | any(. == $k))
            )
        else . end
    ' "$config_file" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$config_file"
        chmod 600 "$config_file"
        log_success "MCP servers whitelisted (servers: $include_list)"
        return 0
    else
        rm -f "$tmp_file"
        log_warn "Failed to filter MCP servers - JSON parsing error"
        return 1
    fi
}

#===============================================================================
# Entry Point
#===============================================================================

filter_claude_agent_config() {
    local agent_type="${KAPSIS_AGENT_TYPE:-}"

    # Only filter for Claude-related agents
    case "$agent_type" in
        claude|claude-cli|claude-code) ;;
        *)
            log_debug "Agent type '$agent_type' - skipping Claude config filtering"
            return 0
            ;;
    esac

    # Check if any filtering is configured
    if [[ -z "${KAPSIS_CLAUDE_HOOKS_INCLUDE:-}" ]] && [[ -z "${KAPSIS_CLAUDE_MCP_INCLUDE:-}" ]]; then
        log_debug "No Claude config filtering configured"
        return 0
    fi

    log_info "Applying Claude config whitelist filters..."

    # Filter hooks (non-fatal)
    filter_claude_hooks || log_warn "Hook filtering had errors (continuing)"

    # Filter MCP servers (non-fatal)
    filter_claude_mcp_servers || log_warn "MCP server filtering had errors (continuing)"

    return 0
}
