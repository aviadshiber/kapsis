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
| Bind address | `127.0.0.1` only |
| Auth | random bearer token printed at startup (`--token` to override) |
| Read-only mode | off (`--read-only` to disable destructive endpoints) |
| Destructive actions | require a typed challenge (agent id for kill, the word `cleanup` for cleanup) |
| Dashboard actions | recorded to `~/.kapsis/audit/dashboard.jsonl` (always on, hash-chained) |

The dashboard refuses cross-origin requests and does not set CORS headers. There is no
session cookie — every request carries the bearer in the `Authorization` header (or as
a `?token=` query parameter for `EventSource`, which can't set headers).

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
| `--host` | `127.0.0.1` | Bind address (don't change unless you've thought about it) |
| `--kapsis-home` | `$KAPSIS_HOME` or `~/.kapsis` | Root of Kapsis state |
| `--read-only` | off | Disable destructive endpoints |
| `--open` | off | Open the URL in the default browser at startup |
| `--token` | random | Use a fixed bearer token |
| `--ui-dist` | embedded | Serve a Vite-built UI bundle from a path (dev override) |
| `--cleanup-script` | auto | Path to `scripts/kapsis-cleanup.sh` |

Environment:
- `KAPSIS_DASHBOARD_LOG_LEVEL=debug` for verbose logs.
- `KAPSIS_HOME` overrides the state root.

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
| Overview | status JSON + health | health rules, branch, commit, push, push-fallback command, error |
| Logs | `~/.kapsis/logs/kapsis-<id>.log` | byte-offset tail, follow toggle |
| Audit | `~/.kapsis/audit/<id>-*.jsonl` | hash-chain verification badge per file |
| Conversation | `~/.kapsis/conversations/<id>/` | empty state when transcripts aren't configured |
| Container | `podman inspect` + `podman stats` | live CPU/memory when running |
| Disk usage | `du` of state dirs + `podman volume`/`images` | stacked bar by category |
| Maintenance | `kapsis-cleanup.sh` wrapper | per-target Preview (dry-run) → Execute |

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
