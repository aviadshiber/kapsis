import { memo, useEffect, useMemo, useRef, useState } from "react";
import { api, sseEphemeral } from "../api/client";
import type { AgentStatus } from "../types";
import { StatusPill } from "../components/StatusPill";
import { ProgressBar } from "../components/ProgressBar";
import { HealthDot } from "../components/HealthDot";

interface Props {
  onSelect: (agentId: string) => void;
}

type Filter = "all" | "running" | "complete" | "failed";

function classify(s: AgentStatus): "running" | "complete" | "failed" {
  if (s.phase !== "complete") return "running";
  return (s.exit_code ?? 0) === 0 ? "complete" : "failed";
}

function duration(s: AgentStatus): string {
  const start = Date.parse(s.started_at);
  const end = s.phase === "complete" ? Date.parse(s.updated_at) : Date.now();
  const sec = Math.max(0, (end - start) / 1000);
  if (sec < 60) return `${Math.round(sec)}s`;
  if (sec < 3600) return `${Math.round(sec / 60)}m`;
  return `${(sec / 3600).toFixed(1)}h`;
}

interface RowProps {
  status: AgentStatus;
  onSelect: (id: string) => void;
}

// Memoized so unrelated SSE updates (other rows changing) don't re-render
// every cell in a 200-row table.
const AgentRow = memo(function AgentRow({ status: a, onSelect }: RowProps) {
  const healthState = a.phase !== "complete" ? "unknown" : (a.exit_code ?? 0) === 0 ? "healthy" : "failed";
  return (
    <tr onClick={() => onSelect(a.agent_id)}>
      <td><HealthDot state={healthState} /></td>
      <td><strong>{a.project}</strong></td>
      <td><code>{a.agent_id}</code></td>
      <td><StatusPill status={a} /></td>
      <td style={{ width: 140 }}><ProgressBar value={a.progress} /></td>
      <td style={{ color: "var(--fg-muted)" }}>{new Date(a.started_at).toLocaleString()}</td>
      <td>{duration(a)}</td>
      <td style={{ color: "var(--fg-muted)" }}>{a.branch ?? "—"}</td>
    </tr>
  );
});

export function AgentList({ onSelect }: Props) {
  const [agents, setAgents] = useState<AgentStatus[]>([]);
  const [filter, setFilter] = useState<Filter>("all");
  const [q, setQ] = useState("");
  const streamRef = useRef<EventSource | null>(null);

  useEffect(() => {
    let alive = true;
    api.agents().then(({ agents }) => { if (alive) setAgents(agents); });
    void (async () => {
      try {
        const stream = await sseEphemeral("/sse/agents");
        if (!alive) { stream.close(); return; }
        streamRef.current = stream;
        stream.onmessage = (ev) => {
          try {
            const msg = JSON.parse(ev.data) as { status?: AgentStatus };
            if (!msg.status) return;
            setAgents((prev) => {
              const i = prev.findIndex((a) => a.agent_id === msg.status!.agent_id && a.project === msg.status!.project);
              if (i === -1) return [msg.status!, ...prev];
              const copy = prev.slice();
              copy[i] = msg.status!;
              return copy;
            });
          } catch { /* heartbeat */ }
        };
      } catch (e) {
        // Token mint failed or SSE unavailable — fall back to no live updates.
        console.warn("SSE disabled:", e);
      }
    })();
    return () => { alive = false; streamRef.current?.close(); };
  }, []);

  const filtered = useMemo(() => {
    return agents.filter((a) => {
      if (filter !== "all" && classify(a) !== filter) return false;
      if (q && !`${a.project} ${a.agent_id} ${a.branch ?? ""}`.toLowerCase().includes(q.toLowerCase())) return false;
      return true;
    });
  }, [agents, filter, q]);

  return (
    <div>
      <header style={{ display: "flex", alignItems: "baseline", gap: 16, marginBottom: 16 }}>
        <h2 style={{ margin: 0 }}>Agents</h2>
        <span style={{ color: "var(--fg-muted)" }}>{filtered.length} / {agents.length}</span>
        <div style={{ flex: 1 }} />
        <select value={filter} onChange={(e) => setFilter(e.target.value as Filter)}>
          <option value="all">All</option>
          <option value="running">Running</option>
          <option value="complete">Complete</option>
          <option value="failed">Failed</option>
        </select>
        <input placeholder="search project / id / branch" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 240 }} />
      </header>
      <table className="table">
        <thead>
          <tr>
            <th></th>
            <th>Project</th>
            <th>Agent</th>
            <th>Phase</th>
            <th>Progress</th>
            <th>Started</th>
            <th>Duration</th>
            <th>Branch</th>
          </tr>
        </thead>
        <tbody>
          {filtered.map((a) => (
            <AgentRow key={`${a.project}-${a.agent_id}`} status={a} onSelect={onSelect} />
          ))}
          {filtered.length === 0 && (
            <tr><td colSpan={8} style={{ textAlign: "center", color: "var(--fg-muted)", padding: 32 }}>No agents match.</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
