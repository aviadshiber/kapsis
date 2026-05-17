import { useEffect, useState } from "react";
import { api, sse } from "../api/client";
import type { AgentHealth, AgentStatus, AuditChainStatus, AuditEvent, ContainerInfo, ContainerStats, ConversationEntry, LogChunk } from "../types";
import { StatusPill } from "../components/StatusPill";
import { ProgressBar } from "../components/ProgressBar";
import { HealthDot } from "../components/HealthDot";
import { ConfirmModal } from "../components/ConfirmModal";

type Tab = "overview" | "logs" | "audit" | "conversation" | "container";

interface Props {
  agentId: string;
  readOnly: boolean;
  onBack: () => void;
}

interface Detail {
  status: AgentStatus;
  health: AgentHealth;
  container: ContainerInfo;
  stats: ContainerStats | null;
}

export function AgentDetail({ agentId, readOnly, onBack }: Props) {
  const [data, setData] = useState<Detail | null>(null);
  const [tab, setTab] = useState<Tab>("overview");
  const [showKill, setShowKill] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    const load = () => api.agent(agentId).then((d) => { if (alive) setData(d); }).catch((e) => setErr(String(e)));
    load();
    const id = setInterval(load, 4000);
    return () => { alive = false; clearInterval(id); };
  }, [agentId]);

  if (err) return <div className="banner">{err}</div>;
  if (!data) return <div>Loading…</div>;

  const { status, health, container, stats } = data;

  return (
    <div>
      {notice && (
        <div className="banner" style={{ marginBottom: 12, display: "flex", alignItems: "center", gap: 12 }}>
          <span style={{ flex: 1 }}>{notice}</span>
          <button onClick={() => setNotice(null)}>Dismiss</button>
        </div>
      )}
      <header style={{ display: "flex", alignItems: "baseline", gap: 12, marginBottom: 16 }}>
        <button onClick={onBack}>← Back</button>
        <h2 style={{ margin: 0 }}><code>{status.project}</code> / <code>{status.agent_id}</code></h2>
        <StatusPill status={status} />
        <HealthDot state={health.state} title={`health: ${health.state}`} />
        <div style={{ flex: 1 }} />
        {!readOnly && status.phase !== "complete" && (
          <button className="danger" onClick={() => setShowKill(true)}>Kill</button>
        )}
      </header>

      <div className="tabs">
        {(["overview", "logs", "audit", "conversation", "container"] as Tab[]).map((t) => (
          <span key={t} className={`tab ${tab === t ? "active" : ""}`} onClick={() => setTab(t)}>
            {t[0]!.toUpperCase() + t.slice(1)}
          </span>
        ))}
      </div>

      {tab === "overview" && <OverviewTab status={status} health={health} />}
      {tab === "logs" && <LogsTab agentId={agentId} />}
      {tab === "audit" && <AuditTab agentId={agentId} />}
      {tab === "conversation" && <ConversationTab agentId={agentId} />}
      {tab === "container" && <ContainerTab container={container} stats={stats} />}

      {showKill && (
        <ConfirmModal
          title={`Kill agent ${agentId}?`}
          prompt="SIGTERM is sent to the container. The agent will not get a chance to push changes — but anything already committed will remain on its branch."
          challenge={agentId}
          destructive
          confirmLabel="Kill"
          onCancel={() => setShowKill(false)}
          onConfirm={async () => {
            const r = await api.kill(agentId, "TERM");
            setShowKill(false);
            if (r.containerMissing) {
              setNotice(`Container kapsis-${agentId} was already gone — kill was a no-op. The status file may be stale; nothing to terminate.`);
            }
            const d = await api.agent(agentId);
            setData(d);
          }}
        />
      )}
    </div>
  );
}

function OverviewTab({ status, health }: { status: AgentStatus; health: AgentHealth }) {
  return (
    <div className="cards">
      <div className="card">
        <h3>Phase</h3>
        <div className="value"><StatusPill status={status} /></div>
        <div className="sub">{status.message}</div>
        <div style={{ marginTop: 8 }}><ProgressBar value={status.progress} /></div>
      </div>
      <div className="card">
        <h3>Health</h3>
        <div className="value">
          <HealthDot state={health.state} /> {health.state}
        </div>
        <ul style={{ marginTop: 8, paddingLeft: 16, color: "var(--fg-muted)", fontSize: 12 }}>
          {health.rules.map((r) => (
            <li key={r.name}><HealthDot state={r.state} /> <code>{r.name}</code>: {r.detail}</li>
          ))}
        </ul>
      </div>
      <div className="card">
        <h3>Branch & Commit</h3>
        <div className="value" style={{ fontSize: 14 }}>{status.branch ?? "—"}</div>
        <div className="sub">
          commit: <code>{status.commit_sha?.slice(0, 8) ?? "—"}</code> ({status.commit_status ?? "n/a"})
          <br />push: {status.push_status ?? "n/a"}
        </div>
      </div>
      <div className="card">
        <h3>Worktree</h3>
        <div className="sub" style={{ fontFamily: "var(--mono)", wordBreak: "break-all" }}>{status.worktree_path ?? "—"}</div>
      </div>
      {status.push_fallback_command && (
        <div className="card" style={{ gridColumn: "1 / -1" }}>
          <h3>Push fallback</h3>
          <pre style={{ marginTop: 8 }}>{status.push_fallback_command}</pre>
        </div>
      )}
      {status.error && (() => {
        const killed = status.error_type === "killed";
        const color = killed ? "var(--fg-muted)" : "var(--red)";
        const heading = killed ? `Terminated · ${status.error_type}` : `Error · ${status.error_type ?? "unknown"}`;
        return (
          <div className="card" style={{ gridColumn: "1 / -1", borderColor: color }}>
            <h3 style={{ color }}>{heading}</h3>
            <div style={{ marginTop: 8, whiteSpace: "pre-wrap" }}>{status.error}</div>
          </div>
        );
      })()}
    </div>
  );
}

function LogsTab({ agentId }: { agentId: string }) {
  const [chunk, setChunk] = useState<LogChunk | null>(null);
  const [follow, setFollow] = useState(true);

  useEffect(() => {
    let alive = true;
    let off = 0;
    let lines: string[] = [];
    const poll = async () => {
      const c = await api.logs(agentId, off);
      if (!alive) return;
      if (c.bytesRead > 0) {
        lines = lines.concat(c.lines).slice(-2000);
        off = c.nextOffset;
        setChunk({ ...c, lines });
      } else {
        setChunk((prev) => prev ?? c);
      }
    };
    poll();
    const id = setInterval(() => { if (follow) void poll(); }, 1500);
    return () => { alive = false; clearInterval(id); };
  }, [agentId, follow]);

  return (
    <div>
      <div style={{ marginBottom: 8 }}>
        <label><input type="checkbox" checked={follow} onChange={(e) => setFollow(e.target.checked)} /> follow</label>
        {chunk && <span style={{ marginLeft: 16, color: "var(--fg-muted)" }}>{chunk.size.toLocaleString()} bytes</span>}
      </div>
      <pre className="log-tail">{chunk?.lines.join("\n") ?? "(no log yet)"}</pre>
    </div>
  );
}

function AuditTab({ agentId }: { agentId: string }) {
  const [data, setData] = useState<{ events: AuditEvent[]; files: Array<{ file: string; chain: AuditChainStatus }> } | null>(null);
  useEffect(() => {
    let alive = true;
    api.audit(agentId).then((d) => { if (alive) setData(d); });
    return () => { alive = false; };
  }, [agentId]);

  if (!data) return <div>Loading audit…</div>;
  if (data.events.length === 0) {
    return (
      <div className="banner">
        No audit events for this agent. Agent audit logging is disabled by default. Enable with{" "}
        <code>export KAPSIS_AUDIT_ENABLED=true</code> in your shell rc, then re-launch the agent.
      </div>
    );
  }

  return (
    <div>
      <div style={{ marginBottom: 12 }}>
        {data.files.map((f) => (
          <span key={f.file} className={`pill ${f.chain.valid ? "complete" : "failed"}`} style={{ marginRight: 6 }} title={f.chain.reason ?? "chain verified"}>
            {f.chain.valid ? "✓" : "✗"} {f.file.split("/").pop()}
          </span>
        ))}
      </div>
      <table className="table">
        <thead><tr><th>Seq</th><th>Time</th><th>Type</th><th>Tool</th><th>Detail</th></tr></thead>
        <tbody>
          {data.events.map((e) => (
            <tr key={`${e.session_id}-${e.seq}`}>
              <td><code>{e.seq}</code></td>
              <td style={{ color: "var(--fg-muted)" }}>{e.timestamp}</td>
              <td>{e.event_type}</td>
              <td><code>{e.tool_name}</code></td>
              <td><code style={{ fontSize: 11 }}>{JSON.stringify(e.detail).slice(0, 200)}</code></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function ConversationTab({ agentId }: { agentId: string }) {
  const [data, setData] = useState<ConversationEntry | null>(null);
  useEffect(() => {
    let alive = true;
    api.conversation(agentId).then((d) => { if (alive) setData(d); });
    return () => { alive = false; };
  }, [agentId]);

  if (!data) return <div>Loading…</div>;
  if (data.empty) {
    return (
      <div className="banner">
        No conversation transcript captured for this agent. Kapsis provisions the directory but only populates it when the agent CLI (Claude Code / Codex) is configured to write transcripts there.
      </div>
    );
  }
  return (
    <table className="table">
      <thead><tr><th>File</th><th>Size</th><th>Modified</th></tr></thead>
      <tbody>
        {data.files.map((f) => (
          <tr key={f.name}>
            <td><code>{f.name}</code></td>
            <td>{f.size.toLocaleString()}</td>
            <td style={{ color: "var(--fg-muted)" }}>{f.mtime}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function ContainerTab({ container, stats }: { container: ContainerInfo; stats: ContainerStats | null }) {
  if (!container.exists) {
    return <div className="banner">No container <code>{container.name}</code> found (likely already exited and cleaned up).</div>;
  }
  return (
    <div className="cards">
      <div className="card">
        <h3>Name</h3>
        <div className="value" style={{ fontSize: 14 }}><code>{container.name}</code></div>
      </div>
      <div className="card">
        <h3>State</h3>
        <div className="value">{container.state ?? "—"}</div>
        <div className="sub">started {container.startedAt ?? "—"}</div>
      </div>
      <div className="card">
        <h3>Image</h3>
        <div className="value" style={{ fontSize: 13 }}><code>{container.image ?? "—"}</code></div>
      </div>
      {stats && (
        <div className="card">
          <h3>CPU / memory</h3>
          <div className="value">{stats.cpuPercent !== null ? `${stats.cpuPercent.toFixed(1)}%` : "—"}</div>
          <div className="sub">
            mem {stats.memBytes !== null ? `${(stats.memBytes / 1024 / 1024).toFixed(0)} MiB` : "—"}
            {stats.memLimitBytes ? ` / ${(stats.memLimitBytes / 1024 / 1024).toFixed(0)} MiB` : ""}
          </div>
        </div>
      )}
    </div>
  );
}
