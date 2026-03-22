#!/usr/bin/env bash
#===============================================================================
# inject-lsp-config.sh - Inject LSP server configuration into agent settings
#
# Transforms Kapsis YAML lsp_servers config into agent-specific LSP configuration.
# Currently supports Claude Code (native lspServers in settings.local.json).
# Other agents log a warning with guidance.
#
# This runs INSIDE the container after CoW overlay setup (files are writable)
# and after config filtering, but BEFORE hook injection.
#
# Environment:
#   KAPSIS_LSP_SERVERS_JSON  - JSON object of LSP server definitions from YAML config
#   KAPSIS_AGENT_TYPE        - Agent type (claude-cli, codex-cli, gemini-cli, etc.)
#
# Usage: Called automatically by entrypoint.sh
#        source inject-lsp-config.sh && inject_lsp_config
#===============================================================================

# Source guard
[[ -n "${_KAPSIS_INJECT_LSP_CONFIG_LOADED:-}" ]] && return 0
_KAPSIS_INJECT_LSP_CONFIG_LOADED=1

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
# Claude Code LSP Injection
#
# Injects lspServers into ~/.claude/settings.local.json (same file used for
# status hook injection). Uses jq merge to preserve existing content.
#
# Kapsis YAML format:
#   lsp_servers:
#     server-name:
#       command: "binary-name"
#       args: ["--stdio"]
#       languages:
#         language_id: [".ext1", ".ext2"]
#       env: {KEY: "value"}
#       initialization_options: {key: value}
#       settings: {key: value}
#
# Claude Code format (settings.local.json):
#   {
#     "lspServers": {
#       "server-name": {
#         "command": "binary-name",
#         "args": ["--stdio"],
#         "extensionToLanguage": {".ext1": "language_id", ".ext2": "language_id"},
#         "env": {"KEY": "value"},
#         "initializationOptions": {key: value},
#         "settings": {key: value}
#       }
#     }
#   }
#===============================================================================

inject_claude_lsp_servers() {
    local lsp_json="${KAPSIS_LSP_SERVERS_JSON:-}"
    local settings_dir="${HOME}/.claude"
    local settings_local="${settings_dir}/settings.local.json"

    if [[ -z "$lsp_json" || "$lsp_json" == "{}" ]]; then
        log_debug "No LSP servers configured"
        return 0
    fi

    # Ensure directory exists
    mkdir -p "$settings_dir"

    # Create base file if missing
    if [[ ! -f "$settings_local" ]]; then
        echo '{}' > "$settings_local"
        log_debug "Created empty settings.local.json"
    fi

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - cannot inject LSP config"
        return 1
    fi

    # Validate JSON input
    if ! printf '%s' "$lsp_json" | jq empty 2>/dev/null; then
        log_warn "Invalid LSP servers JSON - skipping injection"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)

    # Transform Kapsis format to Claude Code format and merge into settings
    # Key transformation: languages {lang_id: [exts]} → extensionToLanguage {ext: lang_id}
    if jq --argjson servers "$lsp_json" '
        .lspServers = ($servers | to_entries | map({
            key: .key,
            value: (
                .value | {
                    command,
                    args: (.args // null),
                    env: (.env // null),
                    initializationOptions: (.initialization_options // null),
                    settings: (.settings // null),
                    extensionToLanguage: (
                        .languages | to_entries | map(
                            .key as $lang | .value[] | {key: ., value: $lang}
                        ) | from_entries
                    )
                } | with_entries(select(.value != null))
            )
        }) | from_entries)
    ' "$settings_local" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$settings_local"
        chmod 600 "$settings_local"

        # Log which servers were injected
        local server_names
        server_names=$(echo "$lsp_json" | jq -r 'keys | join(", ")' 2>/dev/null || echo "unknown")
        log_success "LSP servers injected into settings.local.json: $server_names"
        return 0
    else
        rm -f "$tmp_file"
        log_warn "Failed to inject LSP config - JSON transformation error"
        return 1
    fi
}

#===============================================================================
# Entry Point
#===============================================================================

inject_lsp_config() {
    local lsp_json="${KAPSIS_LSP_SERVERS_JSON:-}"
    local agent_type="${KAPSIS_AGENT_TYPE:-}"

    # Nothing to do if no LSP config
    if [[ -z "$lsp_json" || "$lsp_json" == "{}" ]]; then
        log_debug "No LSP server configuration provided"
        return 0
    fi

    log_info "Injecting LSP server configuration..."

    case "$agent_type" in
        claude|claude-cli|claude-code)
            inject_claude_lsp_servers
            ;;
        *)
            log_warn "LSP server config is not natively supported for agent '$agent_type'." \
                "The LSP binaries are available as CLI commands." \
                "For native LSP integration, open a feature request with the agent vendor."
            return 0
            ;;
    esac
}
