#!/usr/bin/env bash
# inject-status-hooks.sh - Inject Kapsis status hooks into agent settings
#
# This script injects Kapsis status tracking hooks into AI agent configurations.
# It runs inside the container after CoW setup, so modifications don't affect
# the host configuration.
#
# Supported agents:
#   - Claude Code: ~/.claude/settings.json (JSON, merged by Claude)
#   - Codex CLI: ~/.codex/config.yaml (YAML, merged hooks section)
#   - Gemini CLI: ~/.gemini/hooks/*.sh (Shell scripts in hooks directory)
#
# Usage: Called automatically by entrypoint.sh for supported agents
#        Or call directly: ./inject-status-hooks.sh [agent-type]
#        Or render the gist preamble standalone (used by entrypoint.sh to
#        append it onto the injected task spec in overlay mode):
#          ./inject-status-hooks.sh --render-gist-instructions
#        Honours $KAPSIS_GIST_FILE for placeholder substitution.
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
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { :; }
    log_success() { echo "[OK] $*"; }
fi

# Source shared constants for gist injection sentinels (Issue #391).
# The markers are defined in constants.sh as the single source of truth so
# inject_gist_instructions() and strip_kapsis_injections() stay in sync.
if [[ -f "${KAPSIS_LIB:-/opt/kapsis/lib}/constants.sh" ]]; then
    # shellcheck source=constants.sh
    source "${KAPSIS_LIB:-/opt/kapsis/lib}/constants.sh"
fi
# Inline fallback when constants.sh is not available (e.g. unit tests running
# against the source tree without a full install). NOT readonly so a later
# `source constants.sh` can take ownership without a "readonly variable" error.
if [[ -z "${KAPSIS_GIST_MARKER_BEGIN:-}" ]]; then
    KAPSIS_GIST_MARKER_BEGIN="<!-- KAPSIS_GIST_BEGIN -->"
    KAPSIS_GIST_MARKER_END="<!-- KAPSIS_GIST_END -->"
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
    local settings_local="${settings_dir}/settings.json"

    # Ensure directory exists
    mkdir -p "$settings_dir"

    # Create base file if missing
    if [[ ! -f "$settings_local" ]]; then
        echo '{}' > "$settings_local"
        chmod 600 "$settings_local"
        log_debug "Created empty settings.json"
    fi

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - cannot inject Claude hooks"
        return 1
    fi

    # Inject hooks using jq (merge, don't overwrite)
    local tmp_file
    tmp_file=$(mktemp)

    # Determine whether to inject gist hook (opt-in, file must exist and be executable)
    local GIST_HOOK="${KAPSIS_HOOK_DIR}/kapsis-gist-hook.sh"
    local inject_gist="${KAPSIS_INJECT_GIST:-false}"
    if [[ "$inject_gist" == "true" && ! -x "$GIST_HOOK" ]]; then
        log_error "Gist hook not found or not executable: $GIST_HOOK -- KAPSIS_INJECT_GIST=true but gist hook will NOT be injected"
        inject_gist="false"
    fi

    # Attribution: only merge when the env vars are defined (set — including the
    # empty string, which is a valid "disable" per Claude Code's spec). When
    # unset, leave any existing user-configured attribution untouched.
    local attr_commit_set="false"
    local attr_pr_set="false"
    [[ -n "${KAPSIS_ATTRIBUTION_COMMIT+x}" ]] && attr_commit_set="true"
    [[ -n "${KAPSIS_ATTRIBUTION_PR+x}" ]] && attr_pr_set="true"

    if jq \
        --arg status_hook "$STATUS_HOOK" \
        --arg stop_hook "$STOP_HOOK" \
        --arg gist_hook "$GIST_HOOK" \
        --arg inject_gist "$inject_gist" \
        --arg attr_commit "${KAPSIS_ATTRIBUTION_COMMIT:-}" \
        --arg attr_pr "${KAPSIS_ATTRIBUTION_PR:-}" \
        --arg attr_commit_set "$attr_commit_set" \
        --arg attr_pr_set "$attr_pr_set" \
        '
        # Ensure hooks object exists
        .hooks //= {} |

        # Ensure PostToolUse array exists
        .hooks.PostToolUse //= [] |

        # Add gist hook to PostToolUse FIRST if KAPSIS_INJECT_GIST=true and not already present.
        # Gist must fire before the status hook so that status_read_gist_file() reads the
        # current gist (not the previous one).
        if $inject_gist == "true" then
            if ([.hooks.PostToolUse[].hooks[]? | select(.command == $gist_hook)] | length) == 0 then
                .hooks.PostToolUse += [{
                    "matcher": "*",
                    "hooks": [{"type": "command", "command": $gist_hook, "timeout": 10}]
                }]
            else . end
        else . end |

        # Add status hook to PostToolUse after gist hook if not already present
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
        else . end |

        # Attribution: Kapsis writes Claude Code native attribution templates.
        # Empty string is valid ("hide attribution" per Claude Code spec).
        if $attr_commit_set == "true" then
            .attribution //= {} |
            .attribution.commit = $attr_commit
        else . end |
        if $attr_pr_set == "true" then
            .attribution //= {} |
            .attribution.pr = $attr_pr
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

    # Check if yq is available (required dependency)
    if ! command -v yq &>/dev/null; then
        log_error "yq is required but not installed - cannot inject Codex hooks"
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
# Gist Instructions (All Agents)
#===============================================================================

#-------------------------------------------------------------------------------
# Render the gist-instructions.md template with the live $KAPSIS_GIST_FILE
# value substituted for the @@KAPSIS_GIST_FILE@@ placeholder. Prints the
# rendered text to stdout. Shared between workspace-side injection (CLAUDE.md /
# AGENTS.md) and task-spec injection (overlay mode).
#-------------------------------------------------------------------------------
render_gist_instructions() {
    local template="${1:-${KAPSIS_LIB:-/opt/kapsis/lib}/gist-instructions.md}"
    local gist_file="${KAPSIS_GIST_FILE:-/workspace/.kapsis/gist.txt}"

    if [[ ! -f "$template" ]]; then
        return 1
    fi

    # Use index()-based splitting rather than gsub() so neither the path nor
    # the placeholder is parsed for special characters (gsub's replacement
    # parser would consume `&` and `\`; awk's `-v` would consume `\s`, `\n`,
    # ...). Pass the path via ENVIRON to skip -v's escape processing too.
    # Today the only callers set paths like /kapsis-status/gist.txt — this
    # keeps the helper safe for any future caller without an escape audit.
    KAPSIS_GIST_FILE_RENDER="$gist_file" awk '
        BEGIN { gf = ENVIRON["KAPSIS_GIST_FILE_RENDER"]; needle = "@@KAPSIS_GIST_FILE@@"; nlen = length(needle) }
        {
            out = ""; line = $0
            while ((pos = index(line, needle)) > 0) {
                out = out substr(line, 1, pos - 1) gf
                line = substr(line, pos + nlen)
            }
            print out line
        }
    ' "$template"
}

inject_gist_instructions() {
    # Requires opt-in via config (default: false for safe rollout)
    if [[ "${KAPSIS_INJECT_GIST:-false}" != "true" ]]; then
        log_debug "Gist injection disabled (set agent.inject_gist: true to enable)"
        return 0
    fi

    # In overlay mode the workspace is read-only by design. Skip workspace-side
    # writes entirely; the agent gets gist guidance via the injected task spec
    # (see inject_progress_instructions in entrypoint.sh). Mirrors the existing
    # overlay short-circuit pattern.
    if [[ "${KAPSIS_SANDBOX_MODE:-}" == "overlay" ]]; then
        log_info "Skipping gist instructions injection (overlay mode — read-only workspace)"
        return 0
    fi

    local workspace="${KAPSIS_WORKSPACE:-/workspace}"
    local kapsis_dir="${workspace}/.kapsis"
    local gist_instructions="${KAPSIS_LIB:-/opt/kapsis/lib}/gist-instructions.md"

    # Create .kapsis directory in workspace (where gist.txt will be written)
    if ! mkdir -p "$kapsis_dir" 2>/dev/null; then
        log_warn "Could not create $kapsis_dir -- skipping gist injection"
        return 0
    fi

    # Only inject if gist instructions file exists
    if [[ ! -f "$gist_instructions" ]]; then
        log_warn "Gist instructions file not found: $gist_instructions -- gist feature will not work"
        return 0
    fi

    log_info "Injecting gist instructions (workspace: $workspace)"

    local injected=false
    local rendered
    rendered=$(render_gist_instructions "$gist_instructions") || {
        log_warn "Failed to render gist instructions -- skipping"
        return 0
    }

    # Append to CLAUDE.md if it exists (for Claude Code).
    # Wrapped in HTML-comment sentinels (KAPSIS_GIST_MARKER_BEGIN/END from
    # constants.sh) so post-container-git.sh can strip the block before
    # staging — keeping gist instructions session-local (Issue #391).
    # Idempotency is keyed on the sentinel marker, not the rendered prose,
    # so user content that merely mentions the gist never suppresses injection.
    local claude_md="${workspace}/CLAUDE.md"
    if [[ -f "$claude_md" ]]; then
        if [[ ! -w "$claude_md" ]]; then
            log_warn "$claude_md is not writable -- skipping gist append"
        elif ! grep -qF "$KAPSIS_GIST_MARKER_BEGIN" "$claude_md" 2>/dev/null; then
            {
                echo ""
                echo "$KAPSIS_GIST_MARKER_BEGIN"
                echo ""
                echo "$rendered"
                echo ""
                echo "$KAPSIS_GIST_MARKER_END"
            } >> "$claude_md"
            log_debug "Gist instructions appended to $claude_md"
            injected=true
        fi
    fi

    # Append to AGENTS.md if it exists (for Gemini CLI, Codex CLI)
    local agents_md="${workspace}/AGENTS.md"
    if [[ -f "$agents_md" ]]; then
        if [[ ! -w "$agents_md" ]]; then
            log_warn "$agents_md is not writable -- skipping gist append"
        elif ! grep -qF "$KAPSIS_GIST_MARKER_BEGIN" "$agents_md" 2>/dev/null; then
            {
                echo ""
                echo "$KAPSIS_GIST_MARKER_BEGIN"
                echo ""
                echo "$rendered"
                echo ""
                echo "$KAPSIS_GIST_MARKER_END"
            } >> "$agents_md"
            log_debug "Gist instructions appended to $agents_md"
            injected=true
        fi
    fi

    # Always create .kapsis/README.md as fallback for agents that explore workspace
    local kapsis_readme="${kapsis_dir}/README.md"
    if [[ ! -f "$kapsis_readme" ]]; then
        if printf '%s\n' "$rendered" > "$kapsis_readme" 2>/dev/null; then
            log_debug "Gist instructions placed in $kapsis_readme"
            injected=true
        else
            log_warn "Could not write $kapsis_readme -- skipping"
        fi
    fi

    if [[ "$injected" == "true" ]]; then
        log_success "Gist instructions injected for all agents"
    else
        log_debug "Gist instructions already present"
    fi
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

    # Inject gist instructions (works for all agents)
    inject_gist_instructions

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
    case "${1:-}" in
        --render-gist-instructions)
            shift
            render_gist_instructions "$@"
            ;;
        *)
            inject_kapsis_hooks "$@"
            ;;
    esac
fi
