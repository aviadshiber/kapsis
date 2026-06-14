import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api/client";
import type { AgentHealth, AgentStatus, AuditChainStatus, AuditEvent, ContainerInfo, ContainerStats, ConversationEntry, GistEntry, LogChunk, SpecResponse } from "../types";
import { StatusPill } from "../components/StatusPill";
import { ProgressBar } from "../components/ProgressBar";
import { HealthDot } from "../components/HealthDot";
import { ConfirmModal } from "../components/ConfirmModal";
import { useAgentSseListener } from "../hooks/useAgentSseListener";
import { useGistHistorySse } from "../hooks/useGistHistorySse";

type Tab = "overview" | "spec" | "logs" | "activity" | "audit" | "conversation" | "container";

const TAB_ORDER: Tab[] = ["overview", "spec", "logs", "activity", "audit", "conversation", "container"];

interface Props {
  agentId: string;
  readOnly: boolean;
  onBack: () => void;
}

interface Detail {
  status: AgentStatus;
  health: AgentHealth;
  container: ContainerInfo | null;
  stats: ContainerStats | null;
}

export function AgentDetail({ agentId, readOnly, onBack }: Props) {
  const [data, setDataState] = useState<Detail | null>(null);
  const [tab, setTab] = useState<Tab>("overview");
  const [showKill, setShowKill] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // Mirrors the latest loaded status so SSE handler closures can read the
  // current project without re-binding the listener on every render. Short
  // hex agent ids can collide across projects (e.g. `abc123` may exist in
  // both "products" and "helm-charts"), so the agent-reaped match must be
  // project-scoped.
  const statusRef = useRef<AgentStatus | null>(null);
  const aliveRef = useRef(true);

  // Wrapped setter that keeps statusRef in sync with whatever the view
  // currently believes is "the loaded status".
  const setData = useCallback((d: Detail | null) => {
    statusRef.current = d?.status ?? null;
    setDataState(d);
  }, []);

  const load = useCallback(() => {
    return api.agent(agentId)
      .then((d) => { if (aliveRef.current) setData(d); })
      .catch((e) => { if (aliveRef.current) setErr(String(e)); });
  }, [agentId, setData]);

  useEffect(() => {
    aliveRef.current = true;
    void load();
    return () => { aliveRef.current = false; };
  }, [load]);

  const onAgentChanged = useCallback((status: AgentStatus | null) => {
    if (status?.agent_id === agentId && status.project === statusRef.current?.project) {
      void load();
    } else if (status?.agent_id === agentId && statusRef.current === null) {
      // Initial load hasn't completed yet — still refetch so we don't miss the first update.
      void load();
    }
  }, [agentId, load]);

  const onAgentReaped = useCallback((reapedId: string, reapedProject: string) => {
    if (reapedId === agentId && statusRef.current?.project === reapedProject) {
      void load();
    }
  }, [agentId, load]);

  useAgentSseListener({ onAgentChanged, onAgentReaped });

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
        {TAB_ORDER.map((t) => (
          <span key={t} className={`tab ${tab === t ? "active" : ""}`} onClick={() => setTab(t)}>
            {t[0]!.toUpperCase() + t.slice(1)}
          </span>
        ))}
      </div>

      {tab === "overview" && <OverviewTab status={status} health={health} />}
      {tab === "spec" && <SpecTab agentId={agentId} />}
      {tab === "logs" && <LogsTab agentId={agentId} phase={status.phase} />}
      {tab === "activity" && <ActivityTab agentId={agentId} />}
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
        <h3>Current activity</h3>
        {status.gist ? (
          <>
            <div className="value" style={{ fontSize: 14 }}>{status.gist}</div>
            <div className="sub">{status.gist_updated_at ? formatRelative(status.gist_updated_at) : "—"}</div>
          </>
        ) : (
          <div className="sub">No activity recorded yet — wait for the first tool call.</div>
        )}
      </div>
      <div className="card">
        <h3>Branch & Commit</h3>
        <div className="value" style={{ fontSize: 14 }}>{status.branch ?? "—"}</div>
        <div className="sub">
          commit: <code>{status.commit_sha?.slice(0, 8) ?? "—"}</code> ({status.commit_status ?? "n/a"})
          <br />push: {status.push_status ?? "n/a"}
          {(status.stripped_injections ?? 0) > 0 && (
            <>
              <br />stripped injections: {status.stripped_injections} file(s)
            </>
          )}
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

function LogsTab({ agentId, phase }: { agentId: string; phase: string }) {
  const [chunk, setChunk] = useState<LogChunk | null>(null);
  const [follow, setFollow] = useState(true);

  // Completed agents never grow their log, so poll-every-1.5s wastes work.
  // Use 1.5s when the agent is live, 30s when it's done.
  const pollIntervalMs = phase === "complete" ? 30_000 : 1500;

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
    const id = setInterval(() => { if (follow) void poll(); }, pollIntervalMs);
    return () => { alive = false; clearInterval(id); };
  }, [agentId, follow, pollIntervalMs]);

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
        No conversation transcript captured for this agent yet. Kapsis writes transcript.txt (the captured container output) here when the agent session ends — an empty directory usually means the agent is still running or produced no output.
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

/**
 * Renders the user's original task spec. The server returns user spec and
 * Kapsis-injected progress-reporting suffix split apart; we render the
 * user portion as a safe markdown-like fallback and hide the injected
 * portion behind a disclosure so the operator's eyes stay on what they
 * actually wrote.
 *
 * We intentionally do NOT pull in react-markdown for this v1. The spec is
 * trusted (the operator wrote it for themselves) but we still render it as
 * `<pre>`-formatted text so no surprises around inline HTML, links, or
 * embedded scripts can land in the UI. A future iteration can swap in a
 * sanitized markdown renderer; for now, monospaced readable text is the
 * lowest-risk presentation and is what most operators do `cat spec.md`
 * to read anyway.
 */
function SpecTab({ agentId }: { agentId: string }) {
  const [data, setData] = useState<SpecResponse | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [showInjected, setShowInjected] = useState(false);

  useEffect(() => {
    let alive = true;
    setData(null); setErr(null); setShowInjected(false);
    api.spec(agentId)
      .then((r) => { if (alive) setData(r); })
      .catch((e) => {
        if (!alive) return;
        // 404 is expected for "no spec" — render the empty state, not an error banner.
        const status = (e as { status?: number }).status;
        if (status === 404) { setData(null); setErr("__missing__"); return; }
        setErr(String(e));
      });
    return () => { alive = false; };
  }, [agentId]);

  if (err === "__missing__") {
    return (
      <div className="banner">
        No spec found for this agent. The agent was launched without <code>--task</code> /
        <code>--spec</code>, or Kapsis hasn't injected the spec into the worktree yet.
      </div>
    );
  }
  if (err) return <div className="banner">{err}</div>;
  if (!data) return <div>Loading spec…</div>;

  const injectedLineCount = data.injectedInstructions
    ? data.injectedInstructions.split("\n").length
    : 0;

  return (
    <div>
      <div style={{ marginBottom: 12, color: "var(--fg-muted)", fontSize: 12 }}>
        <span>Source: <code>{data.source}</code></span>
        <span style={{ marginLeft: 16 }}>{data.sizeBytes.toLocaleString()} bytes</span>
        {data.truncated && (
          <span style={{ marginLeft: 16, color: "var(--red, #b94a48)" }}>
            ⚠ truncated — showing first 256 KB
          </span>
        )}
      </div>
      <pre className="log-tail" style={{ whiteSpace: "pre-wrap", wordBreak: "break-word" }}>{data.spec}</pre>
      {data.injectedInstructions && (
        <details style={{ marginTop: 12 }} open={showInjected} onToggle={(e) => setShowInjected((e.target as HTMLDetailsElement).open)}>
          <summary style={{ cursor: "pointer", color: "var(--fg-muted)", fontSize: 12 }}>
            {showInjected ? "Hide" : "Show"} Kapsis progress instructions ({injectedLineCount} lines)
          </summary>
          <pre
            className="log-tail"
            style={{ whiteSpace: "pre-wrap", wordBreak: "break-word", marginTop: 8, opacity: 0.7 }}
          >
            {data.injectedInstructions}
          </pre>
        </details>
      )}
    </div>
  );
}

/**
 * Reverse-chronological list of gist activity transitions for one agent.
 *
 * The server keeps an in-memory ring (200 entries max) populated from the
 * existing status watcher. We fetch the snapshot on mount, then subscribe
 * via SSE — every gist-appended event prepends a new entry in O(1).
 *
 * Empty state distinguishes "agent has never made a tool call" from "the
 * dashboard restarted" (history is reseeded from current status on
 * dashboard boot, so a long-running agent at least shows its current gist).
 */
function ActivityTab({ agentId }: { agentId: string }) {
  const [entries, setEntries] = useState<GistEntry[] | null>(null);
  const [follow, setFollow] = useState(true);
  const followRef = useRef(follow);
  followRef.current = follow;

  useEffect(() => {
    let alive = true;
    setEntries(null);
    api.gistHistory(agentId)
      .then((r) => { if (alive) setEntries(r.entries); })
      .catch(() => { if (alive) setEntries([]); });
    return () => { alive = false; };
  }, [agentId]);

  useGistHistorySse(agentId, (entry) => {
    if (!followRef.current) return;
    setEntries((prev) => {
      const next = [entry, ...(prev ?? [])];
      // Server caps at 200; match the cap client-side so a long-lived
      // dashboard doesn't accumulate forever.
      if (next.length > 200) next.length = 200;
      return next;
    });
  });

  if (entries === null) return <div>Loading activity…</div>;
  if (entries.length === 0) {
    return (
      <div className="banner">
        No activity recorded. Gist updates appear once the agent starts making tool calls
        (each PostToolUse hook updates the gist).
      </div>
    );
  }

  return (
    <div>
      <div style={{ marginBottom: 8 }}>
        <label>
          <input type="checkbox" checked={follow} onChange={(e) => setFollow(e.target.checked)} /> follow
        </label>
        <span style={{ marginLeft: 16, color: "var(--fg-muted)" }}>{entries.length} entries</span>
      </div>
      <table className="table">
        <thead><tr><th style={{ width: 200 }}>When</th><th>Activity</th></tr></thead>
        <tbody>
          {entries.map((e, i) => (
            <tr key={`${e.at}-${i}`}>
              <td style={{ color: "var(--fg-muted)", fontFamily: "var(--mono)", fontSize: 12 }}>
                {formatRelative(e.at)}
              </td>
              <td>{e.gist}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/**
 * Best-effort "Xs / Xm / Xh ago" formatter. Tolerates a missing timestamp
 * (renders "—") so a malformed status field never crashes the row.
 */
function formatRelative(iso: string): string {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "—";
  const diff = Math.max(0, Date.now() - t);
  const s = Math.floor(diff / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  return `${d}d ago`;
}

function ContainerTab({ container, stats }: { container: ContainerInfo | null; stats: ContainerStats | null }) {
  if (!container) {
    return <div className="banner">Container inspect skipped — agent is complete, so the container is not expected to be running.</div>;
  }
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
