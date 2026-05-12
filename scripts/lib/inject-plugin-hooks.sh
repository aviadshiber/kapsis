#!/usr/bin/env bash
#===============================================================================
# inject-plugin-hooks.sh - Inject Claude Code plugin hooks into agent settings
#
# Kapsis bypasses Claude Code's native plugin loader (which only runs in
# interactive mode). To make plugins like deeperdive-java-linter actually fire
# inside a Kapsis container, this script enumerates host-enabled plugins and
# merges their hooks/hooks.json into ~/.claude/settings.local.json — alongside
# Kapsis's own status/gist hooks injected by inject-status-hooks.sh.
#
# Filters (both must pass):
#   1. Host-enabled: plugin id present with value `true` in
#      ~/.claude/settings.json::enabledPlugins.
#   2. Whitelist (optional): if KAPSIS_PLUGIN_WHITELIST is a non-empty JSON
#      array, the plugin id must be in it. If unset or empty, allow all
#      host-enabled plugins (default).
#
# ${CLAUDE_PLUGIN_ROOT} placeholder in each plugin's command strings is
# substituted with the plugin's rewritten installPath at merge time, since
# Kapsis is bypassing the loader that would otherwise set that env var
# per-hook at execution time.
#
# Usage:
#   Called from entrypoint.sh::setup_status_tracking AFTER inject-status-hooks.sh
#   so Kapsis hooks (gist → status) sit before plugin hooks in PostToolUse.
#
# Requires (must run AFTER):
#   - rewrite-plugin-paths.sh (installed_plugins.json paths must be container-correct)
#   - inject-status-hooks.sh   (settings.local.json must already exist with Kapsis hooks)
#
# Environment:
#   KAPSIS_INSTALL_PLUGINS   - "true" to activate (gate; falsy = no-op)
#   KAPSIS_PLUGIN_WHITELIST  - JSON array of plugin ids (e.g. ["foo@m","bar@m"]);
#                              empty/unset = allow all host-enabled plugins
#   KAPSIS_HOME              - Kapsis installation directory (default /opt/kapsis)
#   HOME                     - Container user home (settings live under $HOME/.claude)
#===============================================================================

set -euo pipefail

# Source guard
[[ -n "${_KAPSIS_INJECT_PLUGIN_HOOKS_LOADED:-}" ]] && return 0
_KAPSIS_INJECT_PLUGIN_HOOKS_LOADED=1

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

#===============================================================================
# Plugin Hook Injection
#===============================================================================

# Substitute ${CLAUDE_PLUGIN_ROOT} in plugin hook commands with the plugin's
# concrete installPath. Used inline via jq's --arg, not as a shell function.

# Parse the whitelist env var into a normalized JSON array string.
# Empty/unset/invalid input is normalized to "[]" (= no filter, allow all).
_parse_whitelist() {
    local raw="${KAPSIS_PLUGIN_WHITELIST:-}"
    if [[ -z "$raw" ]]; then
        printf '[]'
        return 0
    fi
    if printf '%s' "$raw" | jq -e 'type == "array"' &>/dev/null; then
        printf '%s' "$raw"
    else
        log_warn "KAPSIS_PLUGIN_WHITELIST is not a JSON array (got: ${raw:0:60}...) — treating as empty (allow all host-enabled)"
        printf '[]'
    fi
}

# Inject hooks from all host-enabled (and whitelisted) plugins into
# ~/.claude/settings.local.json.
inject_plugin_hooks() {
    # Gate: opt-in
    if [[ "${KAPSIS_INSTALL_PLUGINS:-false}" != "true" ]]; then
        log_debug "Plugin hook injection disabled (set agent.install_plugins: true to enable)"
        return 0
    fi

    local settings_dir="${HOME}/.claude"
    local settings_local="${settings_dir}/settings.local.json"
    local plugins_file="${settings_dir}/plugins/installed_plugins.json"
    local user_settings="${settings_dir}/settings.json"

    # jq is mandatory
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - cannot inject plugin hooks"
        return 1
    fi

    # Nothing to do if no plugin registry
    if [[ ! -f "$plugins_file" ]]; then
        log_debug "No installed_plugins.json — no plugins to inject"
        return 0
    fi

    # settings.local.json should already exist (inject-status-hooks.sh ran first),
    # but be defensive — create empty if missing.
    mkdir -p "$settings_dir"
    if [[ ! -f "$settings_local" ]]; then
        echo '{}' > "$settings_local"
        log_debug "Created empty settings.local.json (inject-status-hooks.sh should have run first)"
    fi

    # Normalize whitelist
    local whitelist_json
    whitelist_json=$(_parse_whitelist)
    local whitelist_count
    whitelist_count=$(printf '%s' "$whitelist_json" | jq 'length')

    # Read host enabledPlugins (default empty object if file missing or key absent)
    local enabled_plugins_json='{}'
    if [[ -f "$user_settings" ]]; then
        enabled_plugins_json=$(jq -c '.enabledPlugins // {}' "$user_settings" 2>/dev/null || echo '{}')
    fi

    # Build candidate list: plugins that pass BOTH filters.
    # Returns: [{"id": "plugin@m", "installPath": "/path"}, ...]
    # Filter 1: host enabledPlugins[id] == true
    # Filter 2: whitelist is empty OR id is in whitelist (single-element subset test)
    local candidates_json
    if ! candidates_json=$(jq -c \
        --argjson whitelist "$whitelist_json" \
        --argjson enabled "$enabled_plugins_json" \
        '
        (.plugins // {})
        | to_entries
        | map(select(
            ($enabled[.key] == true)
            and (($whitelist | length) == 0 or ([.key] | inside($whitelist)))
            and ((.value | type) == "array")
            and ((.value | length) > 0)
            and (.value[0].installPath != null)
        ))
        | map({id: .key, installPath: .value[0].installPath})
        ' "$plugins_file" 2>/dev/null); then
        log_warn "Failed to parse installed_plugins.json — skipping plugin hook injection"
        return 1
    fi

    local candidate_count
    candidate_count=$(printf '%s' "$candidates_json" | jq 'length')

    # Audit: log plugins host-enabled but rejected by whitelist
    if (( whitelist_count > 0 )); then
        local rejected_ids
        rejected_ids=$(jq -r \
            --argjson whitelist "$whitelist_json" \
            --argjson enabled "$enabled_plugins_json" \
            '
            (.plugins // {})
            | to_entries
            | map(select(($enabled[.key] == true) and ([.key] | inside($whitelist) | not)))
            | map(.key)
            | join(", ")
            ' "$plugins_file" 2>/dev/null || echo '')
        if [[ -n "$rejected_ids" ]]; then
            log_info "Plugin whitelist rejected: ${rejected_ids}"
        fi
    fi

    if (( candidate_count == 0 )); then
        log_info "No plugin hooks to inject (host-enabled & whitelisted: 0)"
        return 0
    fi

    # Iterate candidates and merge each one's hooks/hooks.json
    local merged_count=0
    local i
    for (( i = 0; i < candidate_count; i++ )); do
        local plugin_id install_path hooks_file
        plugin_id=$(printf '%s' "$candidates_json" | jq -r ".[$i].id")
        install_path=$(printf '%s' "$candidates_json" | jq -r ".[$i].installPath")
        hooks_file="${install_path}/hooks/hooks.json"

        if [[ ! -f "$hooks_file" ]]; then
            log_debug "Plugin ${plugin_id} has no hooks/hooks.json at ${install_path} — skipping"
            continue
        fi

        # Validate plugin hooks.json before merging
        if ! jq -e '.hooks | type == "object"' "$hooks_file" &>/dev/null; then
            log_warn "Plugin ${plugin_id}: hooks.json is missing top-level 'hooks' object — skipping"
            continue
        fi

        # Merge with command-level dedup. For each event/group/hook:
        # - Substitute ${CLAUDE_PLUGIN_ROOT} -> install_path in command strings.
        # - For each individual hook command, if it already exists anywhere
        #   under that event in settings.local.json, drop it.
        # - If the substituted plugin_group still has at least one hook left,
        #   append the group (preserving its matcher) to settings.local.json.
        local tmp_file
        tmp_file=$(mktemp)
        if jq \
            --slurpfile plugin_data "$hooks_file" \
            --arg plugin_root "$install_path" \
            '
            def subst_root($root):
                walk(
                    if type == "string"
                    then gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $root)
                    else . end
                );

            ($plugin_data[0].hooks // {}) as $plugin_hooks
            | .hooks //= {}
            | reduce ($plugin_hooks | keys[]) as $event (.;
                .hooks[$event] //= []
                | ([.hooks[$event][]? | .hooks[]? | .command] | unique) as $existing_cmds
                | reduce ($plugin_hooks[$event][] | subst_root($plugin_root)) as $plugin_group (.;
                    ($plugin_group
                        | .hooks //= []
                        | .hooks |= map(select((.command // "") as $c | $existing_cmds | index($c) | not))
                    ) as $filtered
                    | if ($filtered.hooks | length) > 0
                      then .hooks[$event] += [$filtered]
                      else .
                      end
                )
            )
            ' \
            "$settings_local" > "$tmp_file" 2>/dev/null; then
            mv "$tmp_file" "$settings_local"
            chmod 600 "$settings_local"
            local hook_count
            hook_count=$(jq '[.hooks | to_entries[] | .value[] | .hooks | length] | add // 0' "$hooks_file")
            log_info "Loaded plugin ${plugin_id} (hooks=${hook_count}, root=${install_path})"
            merged_count=$((merged_count + 1))
        else
            rm -f "$tmp_file"
            log_warn "Plugin ${plugin_id}: jq merge failed — skipping (other plugins still processed)"
        fi
    done

    log_success "Plugin hook injection complete (merged ${merged_count}/${candidate_count})"
    return 0
}
