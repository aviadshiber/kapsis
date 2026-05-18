import { memo, useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../api/client";
import { STALE_AGENT_THRESHOLD_MS, type AgentStatus } from "../types";
import { StatusPill } from "../components/StatusPill";
import { ProgressBar } from "../components/ProgressBar";
import { HealthDot } from "../components/HealthDot";
import { useAgentSseListener } from "../hooks/useAgentSseListener";

interface Props {
  onSelect: (agentId: string) => void;
}

type Filter = "all" | "running" | "stale" | "complete" | "failed";

function isLikelyStale(s: AgentStatus): boolean {
  if (s.phase === "complete") return false;
  const updated = Date.parse(s.updated_at);
  if (Number.isNaN(updated)) return false;
  return Date.now() - updated > STALE_AGENT_THRESHOLD_MS;
}

function classify(s: AgentStatus): "running" | "stale" | "complete" | "failed" {
  if (s.phase !== "complete") return isLikelyStale(s) ? "stale" : "running";
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
  const cls = classify(a);
  const healthState =
    cls === "stale" ? "stalled" :
    cls === "complete" ? "healthy" :
    cls === "failed" ? "failed" : "unknown";
  return (
    <tr onClick={() => onSelect(a.agent_id)}>
      <td><HealthDot state={healthState} title={cls === "stale" ? "Likely stale — no update in 30+ minutes" : healthState} /></td>
      <td><strong>{a.project}</strong></td>
      <td><code>{a.agent_id}</code></td>
      <td>
        {cls === "stale"
          ? <span className="pill stale" title={`phase=${a.phase}, no update in 30+ min`}>STALE</span>
          : <StatusPill status={a} />}
      </td>
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

  useEffect(() => {
    let alive = true;
    api.agents().then(({ agents }) => { if (alive) setAgents(agents); });
    return () => { alive = false; };
  }, []);

  const onAgentChanged = useCallback((status: AgentStatus | null, file?: string) => {
    if (status) {
      setAgents((prev) => {
        const i = prev.findIndex((a) => a.agent_id === status.agent_id && a.project === status.project);
        if (i === -1) return [status, ...prev];
        const copy = prev.slice();
        copy[i] = status;
        return copy;
      });
    } else if (file) {
      // status=null + file = the watcher noticed a file was deleted.
      // Filename pattern: kapsis-<project>-<agent_id>.json
      // The greedy `(.+)` is load-bearing: it lets dashed project names
      // like "helm-charts" match correctly. With a non-greedy `(.+?)` the
      // filename "kapsis-helm-charts-abc123.json" would parse project as
      // "helm" and agent_id as "charts-abc123" (the trailing `([^-]+)`
      // anchors the agent_id, so greediness on the project side wins).
      const m = file.match(/^kapsis-(.+)-([^-]+)\.json$/);
      if (m) {
        const [, project, agentId] = m;
        setAgents((prev) => prev.filter((a) => !(a.project === project && a.agent_id === agentId)));
      }
    }
  }, []);

  const onAgentReaped = useCallback((agentId: string, project: string) => {
    setAgents((prev) => prev.filter((a) => !(a.project === project && a.agent_id === agentId)));
  }, []);

  useAgentSseListener({ onAgentChanged, onAgentReaped });

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
          <option value="stale">Stale (likely dead)</option>
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
