import { useState } from "react";
import { api } from "../api/client";
import { ConfirmModal } from "../components/ConfirmModal";

/**
 * The targets exposed here map 1:1 to flags actually supported by
 * scripts/kapsis-cleanup.sh. The "stale-state" target runs the script bare,
 * which invokes its default-bundle block (worktrees + sandboxes + status +
 * sanitized-git + audit + conversations). Per-category selective cleanup of
 * those five sub-categories is not exposed by the underlying script, so the
 * dashboard groups them under one card.
 */
const TARGETS = [
  {
    id: "stale-state",
    label: "Stale state",
    help: "Cleans worktrees, sandboxes, completed status files, sanitized-git mirrors, expired audit JSONL, and old conversation dirs in one pass (script default bundle).",
  },
  { id: "worktrees", label: "Worktrees only", help: "Removes git worktrees from completed agents (kapsis-cleanup --worktrees)." },
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

interface PreviewState {
  target: string;
  stdout: string;
  argv: string[];
}

export function Maintenance({ readOnly }: Props) {
  const [preview, setPreview] = useState<PreviewState | null>(null);
  const [confirmTarget, setConfirmTarget] = useState<string | null>(null);
  const [running, setRunning] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);

  async function doPreview(target: string) {
    setRunning(target);
    try {
      const r = await api.cleanup([target], true);
      const argv = (r as unknown as { argv?: string[] }).argv ?? [];
      const out = r.stdout || (r.ok ? "(no items would be removed)" : `(script exited ${r.exitCode})\n${r.stderr}`);
      setPreview({ target, stdout: out, argv });
    } finally {
      setRunning(null);
    }
  }

  async function doExecute(target: string) {
    setRunning(target);
    try {
      const r = await api.cleanup([target], false);
      setResult(`${target}: exit ${r.exitCode}\n\n${r.stdout}\n${r.stderr}`);
      setPreview(null);
    } finally {
      setRunning(null);
      setConfirmTarget(null);
    }
  }

  return (
    <div>
      <h2 style={{ marginTop: 0 }}>Maintenance</h2>
      {readOnly && <div className="banner">Dashboard is read-only — cleanup is disabled.</div>}
      <p style={{ color: "var(--fg-muted)", marginTop: 0 }}>
        Each card wraps a specific flag of <code>scripts/kapsis-cleanup.sh</code>. Preview runs the script with
        <code> --dry-run</code>; Execute runs it for real.
      </p>
      <div className="cards">
        {TARGETS.map((t) => (
          <div className="card" key={t.id}>
            <h3>{t.label}</h3>
            <div className="sub" style={{ minHeight: 32 }}>{t.help}</div>
            <div style={{ marginTop: 12, display: "flex", gap: 8 }}>
              <button onClick={() => doPreview(t.id)} disabled={running !== null}>Preview</button>
              <button className="danger" onClick={() => setConfirmTarget(t.id)} disabled={readOnly || running !== null}>Execute</button>
            </div>
          </div>
        ))}
      </div>
      {preview && (
        <section style={{ marginTop: 24 }}>
          <h3>Preview: {preview.target}</h3>
          {preview.argv.length > 0 && (
            <div style={{ color: "var(--fg-muted)", fontSize: 12, marginBottom: 4 }}>
              argv: <code>{preview.argv.join(" ")}</code>
            </div>
          )}
          <pre>{preview.stdout}</pre>
        </section>
      )}
      {result && (
        <section style={{ marginTop: 24 }}>
          <h3>Result</h3>
          <pre>{result}</pre>
        </section>
      )}
      {confirmTarget && (
        <ConfirmModal
          title={`Execute cleanup: ${confirmTarget}?`}
          prompt="This will permanently remove the items listed in the preview. Run a preview first if you haven't."
          challenge="cleanup"
          destructive
          confirmLabel="Execute"
          onCancel={() => setConfirmTarget(null)}
          onConfirm={() => doExecute(confirmTarget)}
        />
      )}
    </div>
  );
}
