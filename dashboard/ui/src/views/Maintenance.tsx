import { useEffect, useRef, useState } from "react";
import { api, sseEphemeral } from "../api/client";
import { ConfirmModal } from "../components/ConfirmModal";

/**
 * The targets exposed here map 1:1 to flags actually supported by
 * scripts/kapsis-cleanup.sh. The "stale-state" target runs the script bare,
 * which invokes its default-bundle block (worktrees + sandboxes + status +
 * sanitized-git + audit + conversations).
 */
const TARGETS = [
  {
    id: "stale-state",
    label: "Stale state",
    help: "Cleans worktrees, sandboxes, completed status files, sanitized-git mirrors, expired audit JSONL, and old conversation dirs in one pass (script default bundle).",
  },
  { id: "worktrees", label: "Worktrees only", help: "Removes git worktrees from completed agents (--worktrees)." },
  { id: "volumes", label: "Podman volumes", help: "Removes per-agent named volumes. Forces dependency re-download." },
  { id: "images", label: "Podman images", help: "Removes unused kapsis-* container images." },
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

// Strip ANSI escape sequences from script output before rendering.
function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-9;]*m/g, "");
}

function elapsed(startedAt: number): string {
  const s = (Date.now() - startedAt) / 1000;
  if (s < 60) return `${s.toFixed(1)}s`;
  const m = Math.floor(s / 60);
  return `${m}m ${(s - m * 60).toFixed(0)}s`;
}

export function Maintenance({ readOnly }: Props) {
  const [confirmTarget, setConfirmTarget] = useState<{ id: string; dryRun: boolean } | null>(null);
  const [running, setRunning] = useState<RunningState | null>(null);
  const [tick, setTick] = useState(0); // forces a re-render once per second so elapsed updates
  const streamRef = useRef<EventSource | null>(null);

  // Re-render the running card every second so the elapsed timer ticks
  // without re-fetching anything.
  useEffect(() => {
    if (!running || running.exitCode !== null) return;
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, [running]);

  async function startRun(target: string, dryRun: boolean) {
    if (running && running.exitCode === null) return; // a run is in flight
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

    // Open the live log stream.
    try {
      const stream = await sseEphemeral(`/sse/maintenance/${encodeURIComponent(r.runId)}`);
      streamRef.current = stream;
      stream.addEventListener("stdout", (ev: MessageEvent) => {
        try {
          const payload = JSON.parse(ev.data) as { line: string };
          setRunning((prev) => prev ? { ...prev, lines: [...prev.lines, stripAnsi(payload.line)] } : prev);
        } catch { /* ignore */ }
      });
      stream.addEventListener("stderr", (ev: MessageEvent) => {
        try {
          const payload = JSON.parse(ev.data) as { line: string };
          setRunning((prev) => prev ? { ...prev, lines: [...prev.lines, `[stderr] ${stripAnsi(payload.line)}`] } : prev);
        } catch { /* ignore */ }
      });
      stream.addEventListener("exit", (ev: MessageEvent) => {
        try {
          const payload = JSON.parse(ev.data) as { exitCode: number };
          setRunning((prev) => prev ? { ...prev, exitCode: payload.exitCode } : prev);
        } catch { /* ignore */ }
        stream.close();
      });
      stream.onerror = () => {
        // Stream broke — try to fetch the final result so the UI still
        // shows the exit code instead of "running forever".
        api.cleanupResult(r.runId)
          .then((res) => setRunning((prev) => prev ? { ...prev, exitCode: res.exitCode } : prev))
          .catch(() => { /* run not found / expired */ });
        stream.close();
      };
    } catch (e) {
      setRunning((prev) => prev ? { ...prev, lines: [...prev.lines, `SSE error: ${String(e)}`], exitCode: -1 } : prev);
    }
  }

  function clearOutput() {
    streamRef.current?.close();
    streamRef.current = null;
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
        <code> --dry-run</code> so nothing is touched; Execute runs for real. Output streams live.
      </p>
      <div className="cards">
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

      {running && (
        <section style={{ marginTop: 24 }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 12, marginBottom: 8 }}>
            <h3 style={{ margin: 0 }}>
              {running.dryRun ? "Preview" : "Execute"}: {running.target}
            </h3>
            {running.exitCode === null ? (
              <span className="pill pending">
                <span className="spinner" aria-hidden /> running · {elapsed(running.startedAt)} · {tick /* trigger re-render */ ? "" : ""}
              </span>
            ) : (
              <span className={`pill ${running.exitCode === 0 ? "complete" : "failed"}`}>
                exit {running.exitCode} · {elapsed(running.startedAt)}
              </span>
            )}
            <div style={{ flex: 1 }} />
            <button onClick={clearOutput} disabled={running.exitCode === null}>Clear</button>
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
    </div>
  );
}
