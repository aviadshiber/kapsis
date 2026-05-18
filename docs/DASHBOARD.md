# Kapsis Dashboard

Local web dashboard for the Kapsis agent sandbox. Surfaces agent status, audit logs,
conversation transcripts, per-agent health, disk usage, and lifecycle controls (kill,
maintenance/cleanup) from a single self-contained binary.

## Quickstart

```bash
# Install kapsis-dashboard (ships with the Kapsis package).
kapsis-dashboard --open

# Or from source:
cd dashboard
bun install
bun run compile
./bin/kapsis-dashboard --open
```

The dashboard prints a bearer token to stdout and opens
`http://127.0.0.1:7777/#token=<token>` in your default browser. The token lives in the
URL fragment (after `#`) so it never reaches server logs or proxies, and the UI strips
it from the visible URL after first load.

## Security model

| Property | Default |
|---|---|
| Bind address | `127.0.0.1` only (override requires `--allow-non-localhost`, which prints a loud warning) |
| Auth | random bearer token, **hidden** in stdout by default — only the URL with `#token=…` fragment is printed |
| SSE auth | one-shot ephemeral token minted via `POST /api/v1/sse-token` (the bearer-gated mint endpoint); the long-lived bearer never appears in any URL |
| Read-only mode | off (`--read-only` to disable destructive endpoints) |
| Destructive actions | require a typed challenge (agent id for kill, the word `cleanup` for cleanup) |
| Dashboard actions | recorded to `~/.kapsis/audit/dashboard.jsonl` (always on, hash-chained, chain verified on startup) |
| Security headers | `X-Frame-Options: DENY` + CSP `frame-ancestors 'none'` + `Referrer-Policy: no-referrer` + `X-Content-Type-Options: nosniff` on every response |

The dashboard refuses cross-origin requests and does not set CORS headers. There is no
session cookie — every `/api/*` request carries the bearer in the `Authorization`
header. SSE connections (`/sse/*`) use an ephemeral one-shot token in `?t=…` because
the EventSource API cannot send custom headers; the long-lived bearer is never put
into a URL.

**Token visibility:** the bearer is masked in stdout (`Xa1b2…cdef`) unless you pass
`--show-token` or set `KAPSIS_DASHBOARD_SHOW_TOKEN=true`. The full URL — including the
`#token=…` fragment — is still printed so you can paste it into a browser; browsers
never transmit URL fragments in network requests.

**Audit on startup:** when the dashboard restarts and finds an existing
`~/.kapsis/audit/dashboard.jsonl`, it verifies the entire hash chain before extending
it. If the chain is broken (tampering / partial write / disk corruption) the writer
records a `chain-break-detected` event so a viewer can see exactly where the audit gap
began.

## Audit consumption

Agent audit logging in Kapsis defaults to **off** (`KAPSIS_AUDIT_ENABLED=false`). The
dashboard's Audit tab will be empty until you enable it:

```bash
export KAPSIS_AUDIT_ENABLED=true
# Add to your shell rc to persist.
```

Dashboard-initiated actions (kill, cleanup) are always recorded to
`~/.kapsis/audit/dashboard.jsonl` regardless of the agent audit toggle. The chain uses
the same hash format as `scripts/lib/audit.sh`:

```
hash = sha256(prev_hash + seq + timestamp + actor + action + target + detail_json)
```

## CLI flags

| Flag | Default | Notes |
|---|---|---|
| `--port` | `7777` | HTTP port |
| `--host` | `127.0.0.1` | Bind address. Non-loopback requires `--allow-non-localhost`. |
| `--allow-non-localhost` | off | Required (and warns loudly) when `--host` is not 127.0.0.1 / localhost / ::1. Exposes destructive endpoints to the network behind only the bearer token. Prefer SSH port forwarding. |
| `--kapsis-home` | `$KAPSIS_HOME` or `~/.kapsis` | Root of Kapsis state |
| `--read-only` | off | Disable destructive endpoints |
| `--open` | off | Open the URL in the default browser at startup |
| `--token` | random | Use a fixed bearer token |
| `--show-token` | off | Print the bearer token to stdout (also `KAPSIS_DASHBOARD_SHOW_TOKEN=true`) |
| `--ui-dist` | embedded | Serve a Vite-built UI bundle from a path (dev override) |
| `--cleanup-script` | auto | Path to `scripts/kapsis-cleanup.sh` |

Environment:
- `KAPSIS_DASHBOARD_LOG_LEVEL=debug` for verbose logs.
- `KAPSIS_HOME` overrides the state root.
- `KAPSIS_DASHBOARD_SHOW_TOKEN=true` equivalent to `--show-token`.

## Agent health visualization

The Overview tab and the agent list both surface a composite health state derived
purely from existing signals — no new instrumentation:

| Signal | Source | Healthy | Degraded | Stalled / Failed |
|---|---|---|---|---|
| Heartbeat | `status.heartbeat_at` | < 60s | 60–300s | > 300s |
| `updated_at` cadence | `status.updated_at` | < 2 min | 2–10 min | > 10 min |
| Container state | `podman inspect kapsis-<id>` | `running` | `paused` | exited/dead/missing |
| Liveness skip | log keywords (`api_soft_skip` / `api_hard_skip`) | 0 | soft | hard |
| Mount probe | `KAPSIS_MOUNT_FAILURE:` sentinel in log | absent | — | present → Failed |
| Terminal state | `phase=complete` + `exit_code` | 0 | `agent_partial` | mount_failure / non-zero |

`Worst-of-N` aggregation: any one Stalled rule → agent is Stalled; any Failed rule →
Failed. Each rule is shown in the Overview tab with its detail string.

## Tabs

| Tab | Source | Notes |
|---|---|---|
| Agents | `~/.kapsis/status/*.json` (fs.watch) | filter, search, drill-down |
| Overview | status JSON + health | health rules, current activity (gist), branch, commit, push, push-fallback command, error |
| Spec | `<worktree>/.kapsis/task-spec-with-progress.md` or `kapsis-<id>-status` named volume | original `--task`/`--spec` rendered, Kapsis progress-instruction suffix hidden behind disclosure |
| Logs | `~/.kapsis/logs/kapsis-<id>.log` | byte-offset tail, follow toggle |
| Activity | `status.gist` transitions (server-side in-memory ring, 200/agent) | reverse-chronological list; live updates via SSE; cleared on agent reap |
| Audit | `~/.kapsis/audit/<id>-*.jsonl` | hash-chain verification badge per file |
| Conversation | `~/.kapsis/conversations/<id>/` | empty state when transcripts aren't configured |
| Container | `podman inspect` + `podman stats` | live CPU/memory when running |
| Disk usage | `du` of state dirs + `podman volume`/`images` | stacked bar by category |
| Maintenance | `kapsis-cleanup.sh` wrapper | per-target Preview (dry-run) → Execute |

### Spec tab — where the data lives

Kapsis writes the launch spec (your `--task` text or the contents of `--spec <file>`)
to three host-readable locations, tried in order:

- **Persisted at launch** (`${KAPSIS_SPECS_DIR:-~/.kapsis/specs}/<agent_id>.md`):
  written by `scripts/lib/spec-store.sh` immediately after task validation.
  Source-agnostic, present from the first second of the agent's life, and
  unaffected by container-side issues. **Preferred — the dashboard tries
  this first.** Doesn't even require `status.json` to exist.
- **Worktree mode**: `<worktree>/.kapsis/task-spec-with-progress.md` —
  written by entrypoint inside the container. Includes Kapsis's injected
  progress-reporting suffix; the dashboard splits it back out.
- **Overlay mode (Linux)**: the per-agent named volume `kapsis-<agent_id>-status`.
  The dashboard reads it via `podman volume inspect` and a direct file read.

The dashboard intentionally does NOT fall back to the shared
`~/.kapsis/status/task-spec-with-progress.md` host-mirror file because
parallel agents overwrite it; using the volume directly guarantees the
spec belongs to the agent you're looking at.

> **macOS / overlay-mode limitation:** on macOS, Podman volume mountpoints
> live inside the Podman VM (paths like `/var/home/core/...`) and are not
> reachable from the host process the dashboard runs in. Overlay-mode
> agents on macOS will therefore show the "no spec found" empty state on
> the Spec tab even when a spec exists. Worktree mode is unaffected and
> remains the default for most Kapsis profiles.

Empty state ("This agent was launched without --task or --spec, or the
spec hasn't been injected yet") covers the case where neither location
has the spec yet — typically because the agent is still in `initializing`
and `inject_progress_instructions()` has not yet run.

### Activity tab — what counts as a transition

Each PostToolUse event in the agent triggers `scripts/hooks/kapsis-gist-hook.sh`,
which rewrites `status.gist`. The dashboard server's status watcher records
every distinct gist value (de-duplicated against the prior value) into a
per-agent in-memory ring of 200 entries. The ring is reseeded from the
current status on dashboard restart, but historical transitions before
the restart are lost — the agent log file is the durable ground truth.

## Troubleshooting

- **401 on every request** — the bearer token in the URL fragment didn't reach the
  browser. Restart the dashboard, copy the URL printed in stdout (with the
  `#token=...` fragment).
- **Disk usage tab is missing categories** — `dirSize` has a 10s per-directory
  timeout to avoid scanning a huge worktree forever. Repeat scans on large dirs cache
  partial results; check `KAPSIS_DASHBOARD_LOG_LEVEL=debug` for warnings.
- **Container tab shows "not found"** — the container has already exited. Podman
  may have removed it; the dashboard relies on `podman inspect`.
- **Empty Audit tab** — `KAPSIS_AUDIT_ENABLED=true` must be set in the environment
  that launched the agent, not the dashboard.
- **Kill returns 502** — Podman returned non-zero. Check `stderr` in the response.
  Usually means the container already exited.

## Architecture

```
   ┌───────────────┐         ┌──────────────────────┐
   │  ~/.kapsis/   │  watch  │   kapsis-dashboard   │
   │  status/      │ ─────▶  │   (Bun binary)       │
   │  audit/       │         │                      │
   │  logs/        │         │  ┌─────────────┐     │
   │  conv/        │         │  │ store/      │     │
   └───────────────┘         │  │ control/    │     │
                             │  │ sse broker  │     │
   ┌───────────────┐  spawn  │  └──────┬──────┘     │
   │ podman / k8s  │ ◀────── │         │            │
   │ kapsis-cleanup│         │  ┌──────▼──────┐     │
   └───────────────┘         │  │ Bun.serve   │     │
                             │  └──────┬──────┘     │
                             │   embedded UI       │
                             │   (React SPA)       │
                             └─────────────────────┘
```

The dashboard never modifies Kapsis state directly except for appending to
`~/.kapsis/audit/dashboard.jsonl`. All other writes go through existing scripts.
