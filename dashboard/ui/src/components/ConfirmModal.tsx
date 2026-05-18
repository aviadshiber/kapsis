import { useState } from "react";

interface Props {
  title: string;
  prompt: string;
  /** If set, user must type this string to confirm. */
  challenge?: string;
  confirmLabel?: string;
  destructive?: boolean;
  onConfirm: () => void | Promise<void>;
  onCancel: () => void;
}

export function ConfirmModal({ title, prompt, challenge, confirmLabel = "Confirm", destructive, onConfirm, onCancel }: Props) {
  const [typed, setTyped] = useState("");
  const [busy, setBusy] = useState(false);
  const blocked = challenge !== undefined && typed !== challenge;

  async function handle() {
    if (blocked) return;
    setBusy(true);
    try { await onConfirm(); } finally { setBusy(false); }
  }

  return (
    <div className="modal-backdrop" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>{title}</h2>
        <p style={{ marginTop: 0, color: "var(--fg-muted)" }}>{prompt}</p>
        {challenge && (
          <>
            <label style={{ display: "block", fontSize: 12, color: "var(--fg-muted)", marginTop: 8 }}>
              Type <code>{challenge}</code> to confirm:
            </label>
            <input
              autoFocus
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              style={{ width: "100%", marginTop: 4 }}
            />
          </>
        )}
        <div className="actions">
          <button onClick={onCancel} disabled={busy}>Cancel</button>
          <button
            className={destructive ? "danger" : "primary"}
            onClick={handle}
            disabled={blocked || busy}
          >{busy ? "..." : confirmLabel}</button>
        </div>
      </div>
    </div>
  );
}
