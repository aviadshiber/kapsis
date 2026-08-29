# Codex & Gemini as first-class sandboxed agent providers

**Goal:** Make `codex` (OpenAI) and `gemini` (Google) launchable as sandboxed kapsis
agents the same way `claude` is today — `kapsis <repo> --agent codex` / `--agent gemini`
authenticate, run the task in the container, commit/push, and exit cleanly. This unlocks
using them as fallbacks and for multi-agent orchestration from the Slack bot (later phase).

**Status:** design + Phase 1/2 implementation (this branch). Bot fallback = separate follow-on.

---

## Background: what already works vs. what's missing

The launch path is already provider-agnostic: `parse_config` reads each config's
`.agent.command` and runs it generically (`bash -c "$AGENT_COMMAND"` → `exec "$@"` in
entrypoint), agent-type detection covers claude/codex/gemini/aider, and per-provider
status-hook adapters exist (`scripts/hooks/agent-adapters/{codex,gemini}-adapter.sh`).
`build-agent-image.sh <name>` already builds `kapsis-<name>:latest` from
`configs/agents/<name>.yaml` (`.install.npm/.pip/.script`).

The gaps that make codex/gemini non-launchable end-to-end:

1. **Image binding.** Launch configs (`configs/*.yaml`) carry no `image:` section, so
   `parse_config` leaves `IMAGE_NAME=kapsis-sandbox` — `--agent codex` runs in the base
   sandbox with no codex binary. And `configs/gemini.yaml` does not exist at all, so
   `--agent gemini` errors "Unknown agent".
2. **Auth.** `configs/codex.yaml` is `OPENAI_API_KEY`-passthrough only; gemini is unwired.
   The real auth on this host is **OAuth/subscription session files** (no API keys):
   `~/.codex/auth.json` (ChatGPT login), `~/.gemini/oauth_creds.json` +
   `google_accounts.json` + `google_account_id` (Google login).
3. **Stale commands.** The shipped commands (`codex --approval-mode full-auto`,
   `gemini -s docker`) predate the installed CLIs (codex 0.150.1, gemini 0.54.4) and are wrong.
4. **Two disconnected config schemas.** `command:`/`auth:` in `configs/agents/*.yaml` are
   inert (build never reads them; launch reads `configs/*.yaml`). We reconcile the minimum
   and defer full unification.

## Verified facts (host probes, real installed binaries)

- **Headless + OAuth works for both** (exit 0, no API key present):
  - `codex exec "PROMPT"` — provider openai, uses `~/.codex/auth.json`.
  - `gemini -p "PROMPT" --approval-mode yolo --skip-trust` — uses `~/.gemini/oauth_creds.json`.
    `--skip-trust` (or `GEMINI_CLI_TRUST_WORKSPACE=true`) is required in untrusted dirs.
- **In-container sandbox nesting:** `codex exec --dangerously-bypass-approvals-and-sandbox`
  is documented "solely for environments that are externally sandboxed" — the kapsis
  container. Prevents codex's landlock/seccomp from failing to nest inside the container.
- **Auth location override:** codex honors `CODEX_HOME`; gemini reads `~/.gemini`.

## Design

### Auth injection — reuse the existing stage-and-copy path (no new code)
`filesystem.include` already snapshots host files, mounts them read-only into
`/kapsis-staging`, and the entrypoint **copies them into the container `$HOME` as writable
copies** (discarded at container exit). This gives exactly what OAuth needs: a *writable*
copy so the CLI can refresh its access token mid-run, and *minimal files only* — never the
whole `~/.codex`/`~/.gemini` (which hold history, sqlite, other agents' state).

- codex `filesystem.include`: `~/.codex/auth.json`, `~/.codex/config.toml`
- gemini `filesystem.include`: `~/.gemini/oauth_creds.json`, `~/.gemini/google_accounts.json`,
  `~/.gemini/google_account_id`, `~/.gemini/settings.json`

### Verified command strings (baked into the launch configs)
- codex: `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$(cat "${KAPSIS_INJECTED_TASK_SPEC:-/task-spec.md}")"`
- gemini: `gemini --approval-mode yolo --skip-trust -p "$(cat "${KAPSIS_INJECTED_TASK_SPEC:-/task-spec.md}")"`

### Image binding
Add an `image:` block (`name: kapsis-codex-cli` / `kapsis-gemini-cli`, `tag: latest`) to
each launch config so `parse_config` selects the provider image.

---

## Phase 1 — codex end-to-end (prove one provider before fanning out)
1. Fix `configs/agents/codex-cli.yaml`: pin npm version, drop stale `command:`/`auth:`
   assumptions (or annotate as build-only), keep `install.npm: @openai/codex@<pin>`.
2. Build `kapsis-codex-cli:latest` via `build-agent-image.sh codex-cli --profile full-stack`;
   verify the npm binary's `--help`/auth *inside the image* (npm build ≠ host Homebrew build).
3. Rewrite `configs/codex.yaml`: add `image:`, correct `agent.command`, narrow
   `filesystem.include` to the two OAuth files, set `agent.type: codex-cli`.
4. Smoke test (no mocks): `launch-agent.sh <trivial-repo> --agent codex --task "..."` →
   authenticates, completes, exits 0. Confirm status/gist actually fired (not just exit 0).
5. Add tests: codex shortcut resolves to the codex image; config parse asserts image+command.

## Phase 2 — gemini (mostly a copy of Phase 1)
1. Fix `configs/agents/gemini-cli.yaml` (pin `@google/gemini-cli@<pin>`).
2. Build `kapsis-gemini-cli:latest`.
3. Create `configs/gemini.yaml` (image, command, OAuth-file include, `agent.type: gemini-cli`).
4. Add `gemini` to the `--agent` help/error lists in `launch-agent.sh`.
5. Smoke test in-container; add gemini shortcut test (currently absent).

## Cross-cutting
- **KNOWN GAP (status-hook adapters target stale interfaces — deferred to the bot phase).**
  `inject_codex_hooks` writes `~/.codex/config.yaml`, but codex 0.151 reads `~/.codex/hooks.json`;
  gemini 0.57 manages hooks via `gemini hooks`. So the status-hook pipeline (and therefore
  `gist.txt` monitoring) currently does **not** fire for codex/gemini — verified: the
  `.kapsis/progress.json` seen in smoke runs is the agent following injected *text*
  instructions, not the hook. This is a silent no-op, not a crash: agent execution,
  auth, and git workflow are unaffected. Fixing the adapters to the current interfaces
  is required for the bot phase (which depends on `gist.txt`) and is tracked there.
- Docs: reconcile CONFIG-REFERENCE / STATUS-TRACKING / ARCHITECTURE / BUILD-CONFIGURATION
  to reflect real launch-time readiness; add this providers doc.
- CHANGELOG entry.

## Deferred (explicitly out of scope for this branch)
- Full `configs/agents/` ↔ `configs/` schema unification.
- Bot provider-selection + **provider fallback** (extend `model_fallback_chain` →
  `provider_fallback_chain`) and multi-agent orchestration — separate follow-on, fallback first.
- API-key auth path (not used here; OAuth-file injection is the supported path).
