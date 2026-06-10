# Claude Code plugin support

Claude Code's `--print` / headless mode does **not** load plugins from settings as interactive mode would. The reason Kapsis needs its own plugin-hook injection step is that the container starts from a CoW-filtered subset of `~/.claude/` and runs without the interactive trust dialog plugins rely on at first install, so the loader sees an environment in which the host's plugin hooks are not auto-registered into the active hook chain. This page describes the opt-in mechanism Kapsis provides to bring **plugin hooks** back into the container.

## What gets loaded

For each user-installed Claude Code plugin that passes both filters below, Kapsis merges that plugin's `hooks/hooks.json` into `~/.claude/settings.json` **inside the container**, with `${CLAUDE_PLUGIN_ROOT}` substituted to the plugin's container-side installPath. This places plugin hooks next to Kapsis's own status/gist hooks in the same merged hook chain.

The two filters:

1. **Host-enabled.** The plugin id must be `true` in the host's `~/.claude/settings.json::enabledPlugins`. If you've disabled a plugin on the host, it stays off in the container — there is no override.
2. **Whitelist (optional).** If `agent.plugin_whitelist` is set in the kapsis YAML config and non-empty, the plugin id must be in it. If unset or `[]`, this check is a no-op (allow all host-enabled plugins).

Both filters must pass.

## Configuration

```yaml
agent:
  type: claude-cli

  # Master switch — default true for claude/claude-cli/claude-code agents,
  # false for everything else.
  install_plugins: true

  # OPTIONAL whitelist. Plugin ids match the keys in
  # ~/.claude/plugins/installed_plugins.json::plugins, which use the
  # `<plugin>@<marketplace>` form.
  #
  # Unset or [] = allow all host-enabled plugins (the default).
  plugin_whitelist:
    - "deeperdive-java-linter@deeperdive"
    - "deeperdive-java-code-quality@deeperdive"
```

YAML keys are plumbed to in-container env vars by `launch-agent.sh`:

| YAML key | Env var | Default |
|---|---|---|
| `agent.install_plugins` | `KAPSIS_INSTALL_PLUGINS` (`true`/`false`) | `true` for claude-cli, `false` otherwise |
| `agent.plugin_whitelist` | `KAPSIS_PLUGIN_WHITELIST` (JSON-encoded array) | `[]` (allow all) |

### Why a whitelist?

The host typically has many plugins installed. Loading all of them into every agent container silently widens the trust boundary — any hook on `PostToolUse` runs on every tool call the agent makes. The whitelist lets operators (especially for unattended bots) restrict the in-container plugin surface to a vetted set, regardless of what's installed on the host.

For interactive `kapsis ...` runs from a developer's own machine, leaving the whitelist unset (allow all host-enabled plugins) is usually the right default.

### Runtime override

`KAPSIS_PLUGIN_WHITELIST` can also be passed via the kapsis CLI's `--env` / through the launching shell — useful for one-off experiments without editing YAML. Same JSON-array format.

## `${CLAUDE_PLUGIN_ROOT}` substitution

Plugin hook commands typically look like:

```json
{
  "type": "command",
  "command": "${CLAUDE_PLUGIN_ROOT}/scripts/ensure-lsp.sh",
  "timeout": 60
}
```

Claude Code's own plugin loader would expand `${CLAUDE_PLUGIN_ROOT}` per-hook at execution time. Since Kapsis bypasses that loader, **`inject-plugin-hooks.sh` substitutes the placeholder at merge time** with the plugin's already-rewritten installPath (see `rewrite-plugin-paths.sh`). What lands in `settings.json` is a fully concrete command string — no env var dependency, no late binding.

**Only `${CLAUDE_PLUGIN_ROOT}` is substituted by Kapsis.** Other `${...}` references (e.g. `${HOME}`, `${CLAUDE_PROJECT_DIR}`, `$PATH`) are left intact for the shell to expand at hook execution time. If you author a plugin that needs an env var beyond `${CLAUDE_PLUGIN_ROOT}`, ensure it's exported into the agent's environment via the Kapsis YAML config or the user's `~/.claude/settings.json` `env` block — the substitution layer here only handles the one canonical plugin-root token.

Multiple `${CLAUDE_PLUGIN_ROOT}` occurrences in a single command are all replaced (verified by `test_multiple_plugin_root_occurrences`).

## Order of operations

Inside the container, the boot sequence is:

1. `rewrite-plugin-paths.sh` — rewrite host paths in `installed_plugins.json` → container paths.
2. `inject-status-hooks.sh::inject_claude_hooks` — write Kapsis status/gist/stop hooks into `~/.claude/settings.json`.
3. `inject-plugin-hooks.sh::inject_plugin_hooks` — append filtered plugin hooks into the same file.

Kapsis hooks therefore precede plugin hooks within each event's array. This matters for `PostToolUse`: `kapsis-status-hook.sh` reads `/workspace/.kapsis/gist.txt` to populate the status JSON, and `kapsis-gist-hook.sh` writes that file. Plugin hooks that mutate gist.txt would race the status hook otherwise.

## Idempotency

`inject-plugin-hooks.sh` dedupes by command string. Running the injection twice on the same `settings.json` produces byte-identical output. This makes it safe to call from `setup_status_tracking` on every container start, even when re-entering a recovered worktree.

## Failure modes

- **Plugin's `hooks/hooks.json` missing** — silently skipped, debug-logged.
- **`hooks.json` malformed or missing top-level `hooks` object** — logged at WARN, other plugins still processed.
- **Whitelist entry references an uninstalled plugin** — silently skipped (no error).
- **`jq` not installed in image** — logged at WARN, injection aborts gracefully (the agent still runs, just without plugin hooks).
- **`KAPSIS_PLUGIN_WHITELIST` is not a valid JSON array of strings** — **fails closed**. No plugin hooks are injected. The bad value is NOT logged (avoids leaking misconfigured secrets); only its length appears in the WARN. This is a deliberate departure from "fail open" — a corrupted whitelist is treated as "operator intent unknown, refuse everything" rather than "operator wanted no filter, allow all."
- **`installed_plugins.json` / `settings.json` / `settings.json` is a symlink** — refused. Symlinks could redirect writes or fool the merge into reading attacker-chosen content.
- **A plugin's `installPath` resolves outside `$HOME/.claude/plugins/`** — refused (logged at WARN, naming the plugin). Resolution uses `realpath -m` so `..` traversal can't bypass the prefix check. This closes the gap where the plugin id passes the whitelist but the bytes loaded come from an attacker-controlled location.

## Security model

The whitelist gates plugin **ids**. The containment check above gates plugin **bytes**. Both apply:

| Threat | Defense |
|---|---|
| Operator forgot to lock down plugin set in unattended container | `plugin_whitelist` YAML knob |
| Compromised agent rewrites `installed_plugins.json` to use a whitelisted id with attacker-chosen `installPath` | `installPath` prefix-check under `$HOME/.claude/plugins/` after `realpath -m` |
| Compromised agent symlinks `settings.json` to overwrite a host file | Symlink check before merge |
| Whitelist value corrupted in transit or by partial config write | Fail-closed (no plugins injected) |
| Plugin id substring collision (e.g., `"a@b"` matching whitelist `["alpha@beta"]`) | Exact-match via `any(. == .key)` (not jq's `inside()`, which does substring matching on strings) |

These layers together mean: a plugin id reaching the merge step has been (a) explicitly enabled by the operator on the host, AND (b) explicitly listed in the bot's whitelist (when set), AND (c) backed by files inside the trusted plugin cache.

## What is NOT injected

Only **hooks** are merged. The following plugin surfaces are NOT brought in by this mechanism:

- Plugin **skills** (`<installPath>/skills/`) — accessed via `/<plugin>:<skill>` slash commands, normally registered by Claude Code's plugin loader at session start. Not exposed yet.
- Plugin **slash commands** (`<installPath>/commands/`) — same loader path.
- Plugin **agents** (`<installPath>/agents/`).
- Plugin **MCP servers** declared in `.claude-plugin/plugin.json`. Kapsis already accepts `--mcp-config` separately; merging plugin MCPs is a future concern.

If a plugin's hook references its own skills/commands by relative path, that part works because the hook's command is now anchored to the plugin's concrete installPath inside the container.

## Worked example: just `deeperdive-java-linter` in the bot

```yaml
# slack-bot-agent.yaml — keep the in-container plugin surface minimal
agent:
  type: claude-cli
  install_plugins: true
  plugin_whitelist:
    - "deeperdive-java-linter@deeperdive"
```

After container start, `~/.claude/settings.json::hooks.PostToolUse` will contain (in order):

1. Kapsis gist hook (matcher `*`) — if `inject_gist: true`
2. Kapsis status hook (matcher `*`)
3. `deeperdive-java-linter`'s `Edit|Write` matcher with `python3 /home/developer/.claude/plugins/cache/deeperdive/deeperdive-java-linter/1.1.9/hooks/java_linter_reminder.py`
4. `deeperdive-java-linter`'s `Bash` matcher with `bash <installPath>/scripts/verify-after-merge.sh`

Other host-enabled plugins (e.g. `frontend-design`, `frida`, `ghidra`) won't appear because they're not in the whitelist.
