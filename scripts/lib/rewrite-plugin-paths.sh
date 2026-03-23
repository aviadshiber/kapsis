#!/usr/bin/env bash
#===============================================================================
# rewrite-plugin-paths.sh - Rewrite host-absolute paths in plugin registry
#
# Rewrites installPath values in ~/.claude/plugins/installed_plugins.json
# from host-absolute paths to container-relative paths. Without this fix,
# plugins silently fail to load because paths like /Users/foo/.claude/...
# don't exist inside the container where HOME=/home/developer.
#
# This runs INSIDE the container after CoW overlay setup (files are writable)
# and after config filtering, but BEFORE agent execution.
#
# Environment:
#   KAPSIS_HOST_HOME   - The host's HOME directory (e.g., /Users/aviad.s)
#   KAPSIS_AGENT_TYPE  - Agent type (only runs for claude-related types)
#
# Usage: Called automatically by entrypoint.sh
#        source rewrite-plugin-paths.sh && rewrite_plugin_paths
#===============================================================================

# Source guard
[[ -n "${_KAPSIS_REWRITE_PLUGIN_PATHS_LOADED:-}" ]] && return 0
_KAPSIS_REWRITE_PLUGIN_PATHS_LOADED=1

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
# Path Rewriting
#
# Replaces host home prefix in installPath values:
#   /Users/aviad.s/.claude/plugins/cache/...
# becomes:
#   /home/developer/.claude/plugins/cache/...
#
# Only modifies installPath fields inside the plugins object.
# All other fields are left untouched.
#===============================================================================

rewrite_installed_plugin_paths() {
    local plugins_file="${HOME}/.claude/plugins/installed_plugins.json"
    local host_home="${KAPSIS_HOST_HOME:-}"

    if [[ -z "$host_home" ]]; then
        log_debug "KAPSIS_HOST_HOME not set — skipping plugin path rewrite"
        return 0
    fi

    if [[ ! -f "$plugins_file" ]]; then
        log_debug "No installed_plugins.json found — nothing to rewrite"
        return 0
    fi

    # Skip if host home matches container home (no rewrite needed)
    if [[ "$host_home" == "$HOME" ]]; then
        log_debug "Host HOME matches container HOME — no rewrite needed"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_warn "jq not found — cannot rewrite plugin paths"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)

    # Rewrite installPath in every plugin entry:
    # Replace host_home prefix with container $HOME (literal prefix, not regex)
    if jq --arg host_home "$host_home" --arg container_home "$HOME" '
        def rewrite_path:
            if startswith($host_home) then
                ($container_home + .[$host_home | length:])
            else . end;
        if .plugins then
            .plugins |= with_entries(
                .value |= map(
                    if .installPath then
                        .installPath |= rewrite_path
                    else . end
                )
            )
        else . end
    ' "$plugins_file" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$plugins_file"
        chmod 600 "$plugins_file"
        log_success "Plugin paths rewritten: $host_home -> $HOME"
        return 0
    else
        rm -f "$tmp_file"
        log_warn "Failed to rewrite plugin paths — JSON parsing error"
        return 1
    fi
}

#===============================================================================
# Entry Point
#===============================================================================

rewrite_plugin_paths() {
    local agent_type="${KAPSIS_AGENT_TYPE:-}"

    # Only rewrite for Claude-related agents (plugins are a Claude Code feature)
    case "$agent_type" in
        claude|claude-cli|claude-code) ;;
        *)
            log_debug "Agent type '$agent_type' — skipping plugin path rewrite"
            return 0
            ;;
    esac

    log_info "Rewriting plugin paths for container environment..."
    rewrite_installed_plugin_paths || log_warn "Plugin path rewriting had errors (continuing)"

    # Export CLAUDE_HOME so plugins (e.g., deeperdive-marketplace) resolve paths
    # correctly inside the container. Plugins use ${CLAUDE_HOME:-$HOME/.claude}.
    export CLAUDE_HOME="${HOME}/.claude"
    log_debug "CLAUDE_HOME set to $CLAUDE_HOME"

    return 0
}
