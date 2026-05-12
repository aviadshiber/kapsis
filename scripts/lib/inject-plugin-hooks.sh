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
# Empty/unset input  → "[]" (= no filter, allow all host-enabled).
# Corrupted input    → exits with code 2 (fail-closed: refuse to inject anything
# rather than silently widening the trust boundary). The bad value is NOT
# logged to avoid leaking misconfigured secrets through audit logs.
_parse_whitelist() {
    local raw="${KAPSIS_PLUGIN_WHITELIST:-}"
    if [[ -z "$raw" ]]; then
        printf '[]'
        return 0
    fi
    if printf '%s' "$raw" | jq -e 'type == "array" and all(.[]?; type == "string")' &>/dev/null; then
        printf '%s' "$raw"
    else
        log_warn "KAPSIS_PLUGIN_WHITELIST is set but not a JSON array of strings (length=${#raw}) — refusing to inject plugin hooks (fail-closed)"
        return 2
    fi
}

# Resolve the plugins cache prefix that installPaths must live under, with
# symlinks fully resolved. Used to gate untrusted installPath strings from
# installed_plugins.json — defense against an agent rewriting that registry to
# point a whitelisted plugin id at attacker-controlled bytes.
_plugins_cache_prefix() {
    local prefix="${HOME}/.claude/plugins"
    # realpath -m: don't require the path to exist; just normalize it.
    if command -v realpath &>/dev/null; then
        realpath -m "$prefix" 2>/dev/null || printf '%s' "$prefix"
    else
        printf '%s' "$prefix"
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

    # Symlink defense: settings_local + the read-only inputs must be regular
    # files. A symlinked settings_local could redirect our writes outside the
    # agent's $HOME, and a symlinked installed_plugins.json could feed us
    # attacker-chosen content from an unexpected location.
    local f
    for f in "$settings_local" "$plugins_file" "$user_settings"; do
        if [[ -L "$f" ]]; then
            log_warn "Refusing to inject plugin hooks: $f is a symlink"
            return 1
        fi
    done

    # settings.local.json should already exist (inject-status-hooks.sh ran first),
    # but be defensive — create empty if missing.
    mkdir -p "$settings_dir"
    if [[ ! -f "$settings_local" ]]; then
        echo '{}' > "$settings_local"
        log_debug "Created empty settings.local.json (inject-status-hooks.sh should have run first)"
    fi

    # Normalize whitelist. _parse_whitelist exits 2 on corrupted input — propagate
    # so the caller surfaces it rather than silently allowing all plugins.
    local whitelist_json
    if ! whitelist_json=$(_parse_whitelist); then
        return 1
    fi
    local whitelist_empty=true
    [[ "$whitelist_json" != "[]" ]] && whitelist_empty=false

    # Read host enabledPlugins (default empty object if file missing or key absent)
    local enabled_plugins_json='{}'
    if [[ -f "$user_settings" ]]; then
        enabled_plugins_json=$(jq -c '.enabledPlugins // {}' "$user_settings" 2>/dev/null || echo '{}')
    fi

    # Trusted prefix every installPath must live under (defense vs. attacker
    # rewriting installed_plugins.json to point a whitelisted id at /tmp/evil).
    local plugins_prefix
    plugins_prefix=$(_plugins_cache_prefix)

    # Build candidate list: plugins that pass ALL filters.
    # Returns: [{"id": "plugin@m", "installPath": "/path"}, ...]
    # Filter 1: host enabledPlugins[id] == true
    # Filter 2: whitelist is empty OR id matches a whitelist entry EXACTLY
    #          (uses any(. == .key) — NOT `inside()`, which would do substring
    #          matching on strings and let "a@b" pass a whitelist of
    #          ["alpha@beta"]).
    # Schema defense: .value must be a non-empty array with a non-null
    # installPath (matches installed_plugins.json v2 shape).
    local candidates_json
    if ! candidates_json=$(jq -c \
        --argjson whitelist "$whitelist_json" \
        --argjson enabled "$enabled_plugins_json" \
        '
        (.plugins // {})
        | to_entries
        | map(select(
            ($enabled[.key] == true)
            and (($whitelist | length) == 0
                 or (.key as $k | $whitelist | any(. == $k)))
            and ((.value | type) == "array")
            and ((.value | length) > 0)
            and ((.value[0].installPath // null) != null)
            and ((.value[0].installPath | type) == "string")
        ))
        | map({id: .key, installPath: .value[0].installPath})
        ' "$plugins_file" 2>/dev/null); then
        log_warn "Failed to parse installed_plugins.json — skipping plugin hook injection"
        return 1
    fi

    # Audit: enumerate host-enabled plugins that were filtered out by the
    # whitelist, so operators can spot "I installed plugin X on the host but
    # it's not appearing in the bot" without having to diff configs.
    if ! $whitelist_empty; then
        local rejected_ids
        rejected_ids=$(jq -r \
            --argjson whitelist "$whitelist_json" \
            --argjson enabled "$enabled_plugins_json" \
            '
            (.plugins // {})
            | to_entries
            | map(select(($enabled[.key] == true)
                         and ((.key as $k | $whitelist | any(. == $k)) | not)))
            | map(.key)
            | join(", ")
            ' "$plugins_file" 2>/dev/null || echo '')
        if [[ -n "$rejected_ids" ]]; then
            log_info "Plugin whitelist rejected: ${rejected_ids}"
        fi
    fi

    local candidate_count
    candidate_count=$(printf '%s' "$candidates_json" | jq 'length')

    if (( candidate_count == 0 )); then
        log_info "No plugin hooks to inject (host-enabled & whitelisted: 0)"
        return 0
    fi

    # Single jq call to unpack {id, installPath} pairs — avoids 2*N forks when
    # iterating large whitelists.
    local merged_count=0
    local plugin_id install_path hooks_file
    while IFS=$'\t' read -r plugin_id install_path; do
        [[ -z "$plugin_id" ]] && continue

        # installPath containment check (defense vs. installed_plugins.json
        # tampering). The plugin id has passed the whitelist already; the
        # bytes the hooks will load from MUST live under the trusted cache
        # prefix. realpath -m normalizes ".." and symlinks before the prefix
        # comparison so we can't be tricked by a path like
        # /home/dev/.claude/plugins/../../../tmp/evil.
        local resolved_path
        if command -v realpath &>/dev/null; then
            resolved_path=$(realpath -m "$install_path" 2>/dev/null || printf '%s' "$install_path")
        else
            resolved_path="$install_path"
        fi
        case "$resolved_path" in
            "$plugins_prefix"/*)
                ;;
            *)
                log_warn "Plugin ${plugin_id}: installPath outside ${plugins_prefix} (${resolved_path}) — refusing"
                continue
                ;;
        esac

        hooks_file="${install_path}/hooks/hooks.json"

        if [[ ! -f "$hooks_file" ]]; then
            log_debug "Plugin ${plugin_id} has no hooks/hooks.json at ${install_path} — skipping"
            continue
        fi

        # Validate plugin hooks.json shape before merging
        if ! jq -e '.hooks | type == "object"' "$hooks_file" &>/dev/null; then
            log_warn "Plugin ${plugin_id}: hooks.json is missing top-level 'hooks' object — skipping"
            continue
        fi

        # Merge with command-level dedup. For each event/group/hook:
        # - Substitute ${CLAUDE_PLUGIN_ROOT} -> install_path in command strings.
        #   (Only this token is substituted; other ${...} refs like $HOME are
        #   left intact for the shell to expand at hook execution time.)
        # - For each individual hook command, if it already exists anywhere
        #   under that event in settings.local.json OR earlier in this same
        #   merge pass, drop it. This catches both cross-plugin and
        #   intra-plugin (same command in two of a plugin's own groups)
        #   duplicates in a single run.
        # - If the substituted plugin_group still has at least one hook left,
        #   append the group (preserving its matcher) to settings.local.json.
        # Emits {settings: <merged>, plugin_hook_count: N} so the caller gets
        # both values without a follow-up jq fork.
        local tmp_file plugin_hook_count
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
            | ([$plugin_hooks | to_entries[] | .value[] | .hooks | length] | add // 0) as $plugin_hook_count
            | .hooks //= {}
            | reduce ($plugin_hooks | keys[]) as $event (.;
                .hooks[$event] //= []
                # Snapshot every command already registered under this event
                # at the START of processing the event, then track ADDITIONAL
                # commands appended during this pass inside the reduce so two
                # groups of the same plugin sharing a command also dedupe.
                | ([.hooks[$event][]? | .hooks[]? | .command] | unique) as $existing_cmds
                | reduce ($plugin_hooks[$event][] | subst_root($plugin_root)) as $plugin_group (.;
                    ([.hooks[$event][]? | .hooks[]? | .command] | unique) as $current_cmds
                    | ($plugin_group
                        | .hooks //= []
                        | .hooks |= map(select((.command // "") as $c
                            | ($existing_cmds | index($c) | not)
                            and ($current_cmds | index($c) | not)))
                      ) as $filtered
                    | if ($filtered.hooks | length) > 0
                      then .hooks[$event] += [$filtered]
                      else .
                      end
                )
            )
            | {settings: ., plugin_hook_count: $plugin_hook_count}
            ' \
            "$settings_local" > "$tmp_file" 2>/dev/null; then
            # Split combined result into settings (atomic mv) + count (log)
            plugin_hook_count=$(jq -r '.plugin_hook_count' "$tmp_file")
            jq -c '.settings' "$tmp_file" > "${tmp_file}.settings" \
                && mv "${tmp_file}.settings" "$settings_local"
            rm -f "$tmp_file"
            chmod 600 "$settings_local"
            log_info "Loaded plugin ${plugin_id} (plugin_hooks=${plugin_hook_count}, root=${install_path})"
            merged_count=$((merged_count + 1))
        else
            rm -f "$tmp_file"
            log_warn "Plugin ${plugin_id}: jq merge failed — skipping (other plugins still processed)"
        fi
    done < <(printf '%s' "$candidates_json" | jq -r '.[] | "\(.id)\t\(.installPath)"')

    log_success "Plugin hook injection complete (merged ${merged_count}/${candidate_count})"
    return 0
}
