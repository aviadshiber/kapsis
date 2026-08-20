import { useEffect, useRef, useState } from "react";
import { api, sseEphemeral } from "../api/client";
import { ConfirmModal } from "../components/ConfirmModal";

const TARGETS = [
  {
    id: "stale-state",
    label: "Stale state",
    help: "Cleans worktrees, sandboxes, completed status files, sanitized-git mirrors, expired audit JSONL, and old conversation dirs in one pass (script default bundle).",
  },
  { id: "worktrees", label: "Worktrees only", help: "Removes git worktrees from completed agents (--worktrees)." },
  { id: "volumes", label: "Podman volumes", help: "Removes per-agent named volumes. Forces dependency re-download." },
  { id: "images", label: "Podman images", help: "Removes unused kapsis-* container images." },
  { id: "prune-dangling", label: "Dangling layers", help: "Prunes only dangling (<none>:<none>) build layers — cheap, in-use-safe, recommended for cron/housekeepers." },
  { id: "containers", label: "Podman containers", help: "Removes exited or wedged kapsis-* containers." },
  { id: "logs", label: "Launcher logs", help: "Removes rotated ~/.kapsis/logs/*.log files." },
  { id: "ssh-cache", label: "SSH cache", help: "Removes cached SSH known_hosts entries used by the launcher." },
  { id: "branches", label: "Stale branches", help: "Prunes local branches that no longer have a remote." },
];

interface Props {
  readOnly: boolean;
}

interface RunningState {
  target: string;
  runId: string;
  argv: string[];
  dryRun: boolean;
  startedAt: number;
  lines: string[];
  exitCode: number | null;
}

function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-9;]*m/g, "");
}

function elapsed(startedAt: number): string {
  const s = (Date.now() - startedAt) / 1000;
  if (s < 60) return `${s.toFixed(1)}s`;
  const m = Math.floor(s / 60);
  return `${m}m ${(s - m * 60).toFixed(0)}s`;
}

type ReapData = Awaited<ReturnType<typeof api.reapStale>>;

interface ReapState {
  loading: boolean;
  preview: ReapData | null;
  result: ReapData | null;
  confirming: boolean;
}

/**
 * Renders either the in-card 1-line summary or the bottom-of-page detail
 * table for a reap preview/result. Both views share the exact same
 * data-extraction pattern (prefer result over preview, treat result as
 * "happened" vs. preview as "would happen"), so they live in one component
 * to keep the two displays consistent.
 */
function ReapPreviewSection({ data, isResult, variant }: {
  data: ReapData;
  isResult: boolean;
  variant: "summary" | "detail";
}) {
  if (variant === "summary") {
    return (
      <div style={{ marginTop: 12, fontSize: 12, color: "var(--fg-muted)" }}>
        {isResult ? "Reaped" : "Would reap"} <strong>{data.reaped.length}</strong> of {data.scanned} stale candidates
        {data.skipped.length > 0 && ` (skipped ${data.skipped.length} — container still alive)`}
        {data.errors.length > 0 && ` · ${data.errors.length} errors`}
      </div>
    );
  }
  return (
    <section style={{ marginTop: 24 }}>
      <h3 style={{ marginTop: 0 }}>
        {isResult ? "Reaped agents" : "Stale agents preview"} ({data.reaped.length})
      </h3>
      {data.reaped.length === 0 ? (
        <div className="banner">No stale agents found — every non-complete status file has a live container.</div>
      ) : (
        <table className="table">
          <thead><tr><th>Project</th><th>Agent</th><th>Phase</th><th>Last update</th><th>Age</th><th>Container</th></tr></thead>
          <tbody>
            {data.reaped.map((row) => (
              <tr key={row.file}>
                <td><strong>{row.project}</strong></td>
                <td><code>{row.agentId}</code></td>
                <td>{row.phase}</td>
                <td style={{ color: "var(--fg-muted)" }}>{new Date(row.updatedAt).toLocaleString()}</td>
                <td>{(row.ageMs / 60_000).toFixed(0)} min</td>
                <td>{row.containerState ?? <em>missing</em>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}

export function Maintenance({ readOnly }: Props) {
  const [confirmTarget, setConfirmTarget] = useState<{ id: string; dryRun: boolean } | null>(null);
  const [running, setRunning] = useState<RunningState | null>(null);
  const [reap, setReap] = useState<ReapState>({ loading: false, preview: null, result: null, confirming: false });
  const [, setTick] = useState(0);
  const streamRef = useRef<EventSource | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  async function previewReap() {
    setReap((s) => ({ ...s, loading: true }));
    try {
      const r = await api.reapStale(true);
      setReap({ loading: false, preview: r, result: null, confirming: false });
    } catch (e) {
      setReap({ loading: false, preview: null, result: null, confirming: false });
      console.error("reap preview failed:", e);
    }
  }
  async function executeReap() {
    setReap((s) => ({ ...s, loading: true, confirming: false }));
    try {
      const r = await api.reapStale(false);
      setReap({ loading: false, preview: null, result: r, confirming: false });
    } catch (e) {
      setReap({ loading: false, preview: null, result: null, confirming: false });
      console.error("reap execute failed:", e);
    }
  }

  // Re-render every second while a run is in flight so the elapsed timer
  // ticks without re-fetching anything.
  useEffect(() => {
    if (!running || running.exitCode !== null) return;
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, [running]);

  // Polling fallback: regardless of whether SSE is working, poll the
  // snapshot endpoint every 2s while a run is in flight. SSE provides the
  // fast path (line-by-line within 100ms); polling guarantees the UI
  // converges to the real state even if the SSE stream dropped silently.
  useEffect(() => {
    if (!running || running.exitCode !== null || !running.runId) return;
    const id = setInterval(async () => {
      try {
        const snap = await api.cleanupSnapshot(running.runId);
        setRunning((prev) => {
          if (!prev || prev.runId !== snap.runId) return prev;
          // Only adopt server-side lines if we have fewer than the server
          // (SSE may have already delivered everything; polling is a
          // safety net, not authoritative).
          const lines = snap.lines.length > prev.lines.length
            ? snap.lines.map((l) => l.kind === "stderr" ? `[stderr] ${stripAnsi(l.line)}` : stripAnsi(l.line))
            : prev.lines;
          return {
            ...prev,
            lines,
            exitCode: snap.done ? (snap.exitCode ?? -1) : prev.exitCode,
          };
        });
      } catch { /* run may have expired — ignore */ }
    }, 2_000);
    pollRef.current = id;
    return () => { clearInterval(id); if (pollRef.current === id) pollRef.current = null; };
  }, [running?.runId, running?.exitCode]);

  async function startRun(target: string, dryRun: boolean) {
    if (running && running.exitCode === null) return;
    streamRef.current?.close();
    streamRef.current = null;
    let r;
    try {
      r = await api.cleanupStart([target], dryRun);
    } catch (e) {
      setRunning({
        target, runId: "", argv: [], dryRun, startedAt: Date.now(),
        lines: [`error: ${String(e)}`], exitCode: -1,
      });
      return;
    }
    const initial: RunningState = {
      target, runId: r.runId, argv: r.argv, dryRun, startedAt: Date.now(),
      lines: [], exitCode: null,
    };
    setRunning(initial);

    try {
      const stream = await sseEphemeral(`/sse/maintenance/${encodeURIComponent(r.runId)}`);
      streamRef.current = stream;
      const onLine = (raw: string, isErr: boolean) => {
        setRunning((prev) => prev && prev.runId === r.runId
          ? { ...prev, lines: [...prev.lines, isErr ? `[stderr] ${stripAnsi(raw)}` : stripAnsi(raw)] }
          : prev,
        );
      };
      stream.addEventListener("stdout", (ev: MessageEvent) => {
        try { onLine((JSON.parse(ev.data) as { line: string }).line, false); } catch { /* */ }
      });
      stream.addEventListener("stderr", (ev: MessageEvent) => {
        try { onLine((JSON.parse(ev.data) as { line: string }).line, true); } catch { /* */ }
      });
      stream.addEventListener("exit", (ev: MessageEvent) => {
        try {
          const payload = JSON.parse(ev.data) as { exitCode: number };
          setRunning((prev) => prev && prev.runId === r.runId ? { ...prev, exitCode: payload.exitCode } : prev);
        } catch { /* */ }
        stream.close();
      });
      stream.onerror = () => {
        // SSE dropped — the polling fallback (see useEffect above) keeps
        // the UI converging to the real state. Just close this socket so
        // the browser doesn't auto-retry indefinitely against a stale URL.
        stream.close();
      };
    } catch (e) {
      setRunning((prev) => prev && prev.runId === r.runId
        ? { ...prev, lines: [...prev.lines, `SSE setup error: ${String(e)} — falling back to polling`] }
        : prev,
      );
    }
  }

  function clearOutput() {
    streamRef.current?.close();
    streamRef.current = null;
    if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
    setRunning(null);
  }

  const isRunning = running !== null && running.exitCode === null;
  const buttonsDisabled = readOnly || isRunning;

  return (
    <div>
      <h2 style={{ marginTop: 0 }}>Maintenance</h2>
      {readOnly && <div className="banner">Dashboard is read-only — cleanup is disabled.</div>}
      <p style={{ color: "var(--fg-muted)", marginTop: 0 }}>
        Each card wraps a specific flag of <code>scripts/kapsis-cleanup.sh</code>. Preview runs with
        <code> --dry-run</code>; Execute runs for real. Output streams live; the UI also polls the
        run's state every 2s as a safety net.
      </p>
      <div className="cards">
        <div className="card" key="reap-stale">
          <h3>Reap stale agents</h3>
          <div className="sub" style={{ minHeight: 32 }}>
            Finds status files where the agent says it's running but its container is gone
            (sleep / crash / terminal closed killed it without writing "complete"). Verifies
            each via <code>podman inspect</code>, marks it complete with
            <code> error_type=zombie</code>, and removes the file.
          </div>
          <div style={{ marginTop: 12, display: "flex", gap: 8 }}>
            <button onClick={previewReap} disabled={readOnly || reap.loading}>
              {reap.loading && !reap.confirming ? "Scanning…" : "Preview"}
            </button>
            <button
              className="danger"
              onClick={() => setReap((s) => ({ ...s, confirming: true }))}
              disabled={readOnly || reap.loading}
            >Reap</button>
          </div>
          {(reap.preview || reap.result) && (
            <ReapPreviewSection
              data={reap.result ?? reap.preview!}
              isResult={reap.result !== null}
              variant="summary"
            />
          )}
        </div>
        {TARGETS.map((t) => (
          <div className="card" key={t.id}>
            <h3>{t.label}</h3>
            <div className="sub" style={{ minHeight: 32 }}>{t.help}</div>
            <div style={{ marginTop: 12, display: "flex", gap: 8 }}>
              <button onClick={() => startRun(t.id, true)} disabled={buttonsDisabled}>
                {isRunning && running?.target === t.id && running.dryRun ? "Previewing…" : "Preview"}
              </button>
              <button
                className="danger"
                onClick={() => setConfirmTarget({ id: t.id, dryRun: false })}
                disabled={buttonsDisabled}
              >
                {isRunning && running?.target === t.id && !running.dryRun ? "Executing…" : "Execute"}
              </button>
            </div>
          </div>
        ))}
      </div>

      {(reap.preview || reap.result) && (
        <ReapPreviewSection
          data={reap.result ?? reap.preview!}
          isResult={reap.result !== null}
          variant="detail"
        />
      )}

      {running && (
        <section
          className={running.exitCode === null
            ? "run-card run-card--running"
            : running.exitCode === 0
              ? "run-card run-card--ok"
              : "run-card run-card--err"}
          style={{ marginTop: 24 }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 8 }}>
            <h3 style={{ margin: 0 }}>
              {running.dryRun ? "Preview" : "Execute"}: {running.target}
            </h3>
            {running.exitCode === null ? (
              <span className="run-status run-status--running">
                <span className="spinner" aria-hidden /> Running · {elapsed(running.startedAt)} · {running.lines.length} lines
              </span>
            ) : running.exitCode === 0 ? (
              <span className="run-status run-status--ok">
                <span className="check" aria-hidden>✓</span> Done · {elapsed(running.startedAt)} · {running.lines.length} lines
              </span>
            ) : (
              <span className="run-status run-status--err">
                <span className="cross" aria-hidden>✗</span> Failed · exit {running.exitCode} · {elapsed(running.startedAt)} · {running.lines.length} lines
              </span>
            )}
            <div style={{ flex: 1 }} />
            <button onClick={clearOutput}>Clear</button>
          </div>
          {running.argv.length > 0 && (
            <div style={{ color: "var(--fg-muted)", fontSize: 12, marginBottom: 4 }}>
              argv: <code>{running.argv.join(" ")}</code>
            </div>
          )}
          <pre className="log-tail" style={{ maxHeight: "50vh" }}>
            {running.lines.length > 0 ? running.lines.join("\n") : (running.exitCode === null ? "(waiting for output…)" : "(no output)")}
          </pre>
        </section>
      )}

      {confirmTarget && (
        <ConfirmModal
          title={`Execute cleanup: ${confirmTarget.id}?`}
          prompt="This will permanently remove the items the script reports. Run a preview first if you haven't."
          challenge="cleanup"
          destructive
          confirmLabel="Execute"
          onCancel={() => setConfirmTarget(null)}
          onConfirm={async () => {
            const t = confirmTarget;
            setConfirmTarget(null);
            await startRun(t.id, false);
          }}
        />
      )}

      {reap.confirming && (
        <ConfirmModal
          title="Reap stale agents?"
          prompt="Each agent whose container has actually exited will be marked complete (error_type=zombie) and its status file removed. Agents whose containers are still alive will be left alone."
          challenge="reap"
          destructive
          confirmLabel="Reap"
          onCancel={() => setReap((s) => ({ ...s, confirming: false }))}
          onConfirm={executeReap}
        />
      )}
    </div>
  );
}
