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
   `gemini -s docker`) predate the current CLIs (pinned images: codex 0.151.0, gemini 0.57.0)
   and are wrong.
4. **Two disconnected config schemas.** `command:`/`auth:` in `configs/agents/*.yaml` are
   inert (build never reads them; launch reads `configs/*.yaml`). We reconcile the minimum
   and defer full unification.

## Verified facts (host probes, real installed binaries)

- **Headless + OAuth works for both** (exit 0, no API key present):
  - `codex exec "PROMPT"` — provider openai, uses `~/.codex/auth.json`.
  - `gemini -p "PROMPT" --approval-mode yolo --skip-trust` — uses `~/.gemini/oauth_creds.json`.
    `--skip-trust` (or `GEMINI_CLI_TRUST_WORKSPACE=true`) is required in untrusted dirs.
- **In-container sandbox nesting:** `codex exec --dangerously-bypass-approvals-and-sandbox`
  is documented by OpenAI as the sanctioned mode for "an isolated CI runner or container."
  It is not merely convenient here — codex's own sandbox uses **bubblewrap + seccomp**, which
  needs to create user namespaces; a hardened outer container (dropped caps + seccomp, like
  kapsis) will often prevent bubblewrap from initializing at all, so codex's inner sandbox
  would *break*, not just be redundant. The container is the sole isolation layer (see Security).
- **Auth location override:** codex honors `CODEX_HOME` and reads auth from `$CODEX_HOME/auth.json`
  independently of `config.toml`, so `--ignore-user-config` drops config-file injection without
  affecting auth. Gemini reads `~/.gemini`.
- **Command/version note:** the exact invocations were verified in-container against the pinned
  npm builds **codex 0.151.0** and **gemini 0.57.0** (the images build these), in both open and
  filtered network modes. (Host Homebrew binaries were 0.150.1 / 0.54.4 — used only for the
  initial headless probe.)

## Design

### Auth injection — reuse the existing stage-and-copy path (no new code)
`filesystem.include` already snapshots host files, mounts them read-only into
`/kapsis-staging`, and the entrypoint **copies them into the container `$HOME` as writable
copies** (discarded at container exit). This gives exactly what OAuth needs: a *writable*
copy so the CLI can refresh its access token mid-run, and *minimal files only* — never the
whole `~/.codex`/`~/.gemini` (which hold history, sqlite, other agents' state).

We inject **only the OAuth session file(s)** — not `config.toml`/`settings.json`, which can
carry MCP-server definitions (with `env` secrets) and hook *commands* (see Security C2):
- codex `filesystem.include`: `~/.codex/auth.json` (config.toml is intentionally excluded;
  the command passes `--ignore-user-config`).
- gemini `filesystem.include`: `~/.gemini/oauth_creds.json`, `~/.gemini/google_accounts.json`,
  `~/.gemini/google_account_id` (settings.json intentionally excluded).

### Verified command strings (baked into the launch configs)
- codex: `codex exec --dangerously-bypass-approvals-and-sandbox --ignore-user-config --skip-git-repo-check "$(cat "${KAPSIS_INJECTED_TASK_SPEC:-/task-spec.md}")"`
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

## Security — mounting OAuth credentials into an agent sandbox

The sandbox exists to *contain* a possibly prompt-injected agent, yet we hand that agent the
user's LLM-provider OAuth session. This is the same trust class as the existing claude flow
(which injects `~/.claude`/`~/.claude.json` + `--dangerously-skip-permissions`), but the
following are worth stating explicitly. A multi-agent ensemble review drove these decisions.

**Threat model.** `auth.json`/`oauth_creds.json` hold live **access + refresh** tokens (long-lived,
refreshable), injected as *writable* copies so the CLI can refresh mid-run. A compromised agent
inside the container can read them. DNS-filtered egress limits *which hosts* it can reach but
**does not** stop exfil *to* an allowlisted host (a legit-looking POST to an allowed API endpoint
carries data out). So the design basis is: assume the token file is readable by the agent, and
minimize both what is injected and where it can be sent.

**Mitigations applied in this PR:**
- **Minimal-file injection.** Only the OAuth session file(s) are mounted — never the whole
  `~/.codex`/`~/.gemini` (history, sqlite, other-agents' state).
- **No config-file injection (C2).** `config.toml` (codex) / `settings.json` (gemini) can carry
  `[mcp_servers]`/`mcpServers` with `env` secrets and hook *commands*. Injecting them would smuggle
  unrelated secrets + execution primitives into a prompt-injectable sandbox. codex uses
  `--ignore-user-config` (auth still reads `CODEX_HOME/auth.json`); gemini simply omits
  `settings.json`. Both verified to still authenticate.
- **Narrow allowlist (C1/H2).** The gemini OAuth token carries broad **`cloud-platform`** scope, so
  a generic Google API host would be an exfil channel usable with the stolen bearer token. The
  gemini allowlist is deliberately restricted to `cloudcode-pa.googleapis.com` (backend) +
  `oauth2.googleapis.com` (refresh); `www.googleapis.com`/`accounts.google.com` are **not**
  allowlisted. codex is scoped to `chatgpt.com`/`api.openai.com`.
- **Host files never mutated.** The stage-and-copy path mounts host files `:ro` into
  `/kapsis-staging` and copies to a writable container `$HOME`, discarded at exit.

**Accepted / documented residual risk:**
- **H1 — single isolation layer.** `--dangerously-bypass-approvals-and-sandbox` (codex) and
  `--approval-mode yolo --skip-trust` (gemini) disable the agents' own approval/sandbox layers,
  leaving the kapsis container as the sole boundary. Required (codex's bubblewrap can't init in a
  hardened container; see Verified facts), but OpenAI's own docs warn the flag lets a malicious
  project "exfiltrate anything inside the container, including credentials." Acceptable only if
  kapsis's isolation is trusted airtight — a stronger claim than "same as claude."
- **H3 — refresh-token lifetime.** The writable token stays valid for the whole run; if exfiltrated
  it outlives the container until the user revokes it.

**Future hardening (deferred, see below):** a host-side token-exchange proxy — the container talks
to a localhost proxy that attaches short-lived tokens (or makes the call itself); refresh tokens
never enter the container. This structurally closes C1/H3 and makes C2 moot.

## Cross-cutting
- **KNOWN GAP (status-hook adapters target stale interfaces — deferred to the bot phase).**
  `inject_codex_hooks` writes `~/.codex/config.yaml`, but codex 0.151 reads `~/.codex/hooks.json`
  (or an inline `[hooks]` table in `config.toml`); gemini 0.57 manages hooks via `settings.json` /
  the `gemini hooks` surface. So the status-hook pipeline (and therefore `gist.txt` monitoring)
  currently does **not** fire for codex/gemini — verified: the `.kapsis/progress.json` seen in
  smoke runs is the agent following injected *text* instructions, not the hook. Silent no-op, not a
  crash: agent execution, auth, and git workflow are unaffected. Fixing the adapters (and the
  existing status-hook tests, which currently assert the stale `config.yaml`/`~/.gemini/hooks`
  interface and will need updating) is required for the bot phase (which depends on `gist.txt`).

## Deferred (explicitly out of scope for this branch)
- Full `configs/agents/` ↔ `configs/` schema unification.
- Bot provider-selection + **provider fallback** (extend `model_fallback_chain` →
  `provider_fallback_chain`) and multi-agent orchestration — separate follow-on, fallback first.
- **Token-exchange proxy** (see Security) — the durable fix for credential blast-radius.
- **Release/distribution:** ✅ done — `release.yml` now builds/pushes/SBOM-signs
  `kapsis-codex-cli`/`kapsis-gemini-cli` to ghcr, so `build-agent-image.sh <agent> --pull`
  works for them. Still deferred: an npm-pin bump workflow modeled on `bump-claude-code.yml`.
- **Fail-fast on missing auth:** a missing OAuth file is currently skipped at debug level → the
  provider launches unauthenticated and fails deep in the run. Add a preflight warn/error when
  neither the session file nor an API key is available.
- **Concurrency sizing:** at `8g/agent` the `kapsis-libkrun` VM (16 GiB) fits only ~2 concurrent
  agents; the bot orchestration phase must cap concurrency or right-size per-provider memory.
- **Cross-run token rotation:** verify whether a provider rotates refresh tokens (the rotated
  token dies with the discarded container copy); if so, the next host run's token could be stale.
- **DNS pinning:** these providers require non-pinned filtered mode — the pinner skips wildcards
  (`*.chatgpt.com`), so `KAPSIS_DNS_PIN_ENABLED=true` would break codex's ChatGPT backend.
- **Gemini tier caveat:** Google deprecated personal "Login with Google" (free/Pro/Ultra) for the
  Gemini CLI on 2026-06-18; only org-backed Code Assist Standard/Enterprise OAuth (this repo's
  case) or `GEMINI_API_KEY` work headless. Google's stated direction is Antigravity CLI.
- API-key auth path (`CODEX_API_KEY`/`GEMINI_API_KEY` passthrough exists as an alternative;
  OAuth-file injection is the primary supported path here).
