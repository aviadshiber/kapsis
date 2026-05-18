import { useEffect, useState } from "react";
import { api } from "../api/client";
import type { DiskUsageEntry } from "../types";

function human(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(1)} ${units[i]}`;
}

export function DiskUsage() {
  const [entries, setEntries] = useState<DiskUsageEntry[] | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const load = async () => {
    setRefreshing(true);
    try {
      const { entries } = await api.disk();
      setEntries(entries);
    } finally {
      setRefreshing(false);
    }
  };
  useEffect(() => { void load(); }, []);

  if (!entries) return <div>Loading disk usage…</div>;
  const total = entries.reduce((s, e) => s + e.bytes, 0);

  return (
    <div>
      <header style={{ display: "flex", alignItems: "baseline", gap: 16, marginBottom: 16 }}>
        <h2 style={{ margin: 0 }}>Disk usage</h2>
        <span style={{ color: "var(--fg-muted)" }}>total {human(total)}</span>
        <div style={{ flex: 1 }} />
        <button onClick={load} disabled={refreshing}>{refreshing ? "Scanning…" : "Refresh"}</button>
      </header>
      <div style={{ display: "flex", height: 24, borderRadius: 6, overflow: "hidden", marginBottom: 16, border: "1px solid var(--border)" }}>
        {entries.map((e) => (
          <div key={e.category} title={`${e.category}: ${human(e.bytes)}`} style={{
            width: `${(e.bytes / total) * 100}%`,
            background: `var(--${["accent", "green", "yellow", "orange", "red", "gray"][Math.abs(hash(e.category)) % 6]})`,
          }} />
        ))}
      </div>
      <table className="table">
        <thead><tr><th>Category</th><th>Items</th><th>Size</th><th>% of total</th></tr></thead>
        <tbody>
          {entries.map((e) => (
            <tr key={e.category}>
              <td><strong>{e.category}</strong></td>
              <td>{e.items.toLocaleString()}</td>
              <td>{human(e.bytes)}</td>
              <td style={{ color: "var(--fg-muted)" }}>{total ? `${((e.bytes / total) * 100).toFixed(1)}%` : "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function hash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return h;
}
