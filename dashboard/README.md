# Kapsis Dashboard

Local web dashboard for the Kapsis agent sandbox. Consumes `~/.kapsis/` state
(status, audit, logs, conversations) and exposes lifecycle controls.

See [`docs/DASHBOARD.md`](../docs/DASHBOARD.md) for user docs.

## Layout

| Path | Purpose |
|---|---|
| `server/` | Bun + TypeScript HTTP server (compiled to a single binary) |
| `ui/` | Vite + React + TypeScript SPA (built and embedded into the server binary) |

## Dev

```bash
cd dashboard
bun install
bun run dev                       # parallel: server (watch) + ui (vite dev, proxy → server)
```

Open `http://127.0.0.1:5173`. Vite dev server proxies `/api` and `/sse` to the
server on `:7777`. The bearer token is printed when the server starts.

## Build

```bash
bun run compile                   # single binary for the current platform → bin/kapsis-dashboard
bun run compile:darwin-arm64      # cross-compile for a specific target
```

## Test

```bash
bun test
bun run typecheck
```
