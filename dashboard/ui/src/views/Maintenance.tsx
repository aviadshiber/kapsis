import { useState } from "react";
import { api } from "../api/client";
import { ConfirmModal } from "../components/ConfirmModal";

const TARGETS = [
  { id: "status", label: "Status files", help: "Removes completed status JSON older than 24h" },
  { id: "worktrees", label: "Worktrees", help: "Removes git worktrees from completed agents" },
  { id: "sandboxes", label: "Sandboxes", help: "Removes overlay sandbox directories" },
  { id: "sanitized-git", label: "Sanitized git", help: "Removes filtered git mirror copies" },
  { id: "volumes", label: "Podman volumes", help: "Removes per-agent named volumes" },
  { id: "images", label: "Podman images", help: "Removes unused kapsis-* images" },
  { id: "audit", label: "Audit logs", help: "Removes audit JSONL older than TTL" },
  { id: "conversations", label: "Conversations", help: "Removes conversation dirs older than TTL" },
  { id: "logs", label: "Logs", help: "Removes rotated launcher logs" },
];

interface Props {
  readOnly: boolean;
}

interface PreviewState {
  target: string;
  stdout: string;
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
      setPreview({ target, stdout: r.stdout || "(no items would be removed)" });
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
