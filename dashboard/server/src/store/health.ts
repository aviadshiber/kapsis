import type { AgentHealth, AgentStatus, HealthRule, HealthState } from "../types";
import { inspectContainer } from "./container";
import { LogStore } from "./logs";

const WORST_RANK: Record<HealthState, number> = {
  healthy: 0,
  unknown: 1,
  degraded: 2,
  stalled: 3,
  failed: 4,
};

function worst(states: HealthState[]): HealthState {
  return states.reduce<HealthState>((acc, s) => (WORST_RANK[s] > WORST_RANK[acc] ? s : acc), "healthy");
}

function ageSec(iso: string | null): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  return Math.max(0, (Date.now() - t) / 1000);
}

function heartbeatRule(s: AgentStatus): HealthRule {
  const age = ageSec(s.heartbeat_at);
  if (age === null) {
    return { name: "heartbeat", state: "unknown", detail: "no heartbeat field — liveness monitor disabled or pre-heartbeat agent" };
  }
  if (age < 60) return { name: "heartbeat", state: "healthy", detail: `heartbeat ${age.toFixed(0)}s ago` };
  if (age < 300) return { name: "heartbeat", state: "degraded", detail: `heartbeat ${age.toFixed(0)}s ago (>60s)` };
  return { name: "heartbeat", state: "stalled", detail: `heartbeat ${age.toFixed(0)}s ago (>300s)` };
}

function updatedAtRule(s: AgentStatus): HealthRule {
  const age = ageSec(s.updated_at);
  if (age === null) return { name: "updated_at", state: "unknown", detail: "no updated_at" };
  if (age < 120) return { name: "updated_at", state: "healthy", detail: `last update ${age.toFixed(0)}s ago` };
  if (age < 600) return { name: "updated_at", state: "degraded", detail: `last update ${age.toFixed(0)}s ago (>2m)` };
  return { name: "updated_at", state: "stalled", detail: `last update ${age.toFixed(0)}s ago (>10m)` };
}

function terminalRule(s: AgentStatus): HealthRule | null {
  if (s.phase !== "complete") return null;
  if (s.exit_code === 0) return { name: "terminal", state: "healthy", detail: "exit 0" };
  if (s.error_type === "agent_partial") {
    return { name: "terminal", state: "degraded", detail: "agent_partial: container failed but work was committed" };
  }
  if (s.error_type === "mount_failure") {
    return { name: "terminal", state: "failed", detail: s.error ?? "mount failure" };
  }
  return { name: "terminal", state: "failed", detail: s.error ?? `exit ${s.exit_code ?? "?"}` };
}

async function containerRule(s: AgentStatus): Promise<HealthRule> {
  // Only check container state when agent is supposed to be running.
  if (s.phase === "complete") {
    return { name: "container", state: "healthy", detail: "agent complete — container not expected" };
  }
  const info = await inspectContainer(s.agent_id);
  if (!info.exists) {
    return { name: "container", state: "stalled", detail: `container ${info.name} missing while phase=${s.phase}` };
  }
  switch (info.state) {
    case "running":
      return { name: "container", state: "healthy", detail: "running" };
    case "paused":
      return { name: "container", state: "degraded", detail: "paused" };
    case "exited":
    case "dead":
    case "stopped":
      return { name: "container", state: "stalled", detail: `container ${info.state}` };
    default:
      return { name: "container", state: "unknown", detail: `state=${info.state ?? "?"}` };
  }
}

async function mountProbeRule(logs: LogStore, agentId: string): Promise<HealthRule> {
  // Look at the tail of the log for KAPSIS_MOUNT_FAILURE: sentinel.
  const size = await logs.size(agentId);
  if (size === 0) return { name: "mount-probe", state: "unknown", detail: "no log" };
  const startAt = Math.max(0, size - 64 * 1024);
  const chunk = await logs.read(agentId, startAt);
  for (const line of chunk.lines) {
    if (line.includes("KAPSIS_MOUNT_FAILURE:")) {
      return { name: "mount-probe", state: "failed", detail: "KAPSIS_MOUNT_FAILURE sentinel in log" };
    }
  }
  return { name: "mount-probe", state: "healthy", detail: "no mount-failure sentinel in recent log" };
}

async function livenessSkipRule(logs: LogStore, agentId: string): Promise<HealthRule> {
  const size = await logs.size(agentId);
  if (size === 0) return { name: "liveness-skip", state: "unknown", detail: "no log" };
  const startAt = Math.max(0, size - 64 * 1024);
  const chunk = await logs.read(agentId, startAt);
  let softCount = 0;
  let hardCount = 0;
  for (const line of chunk.lines) {
    if (line.includes("api_soft_skip")) softCount++;
    if (line.includes("api_hard_skip")) hardCount++;
  }
  if (hardCount > 0) return { name: "liveness-skip", state: "stalled", detail: `${hardCount} api_hard_skip events in recent log` };
  if (softCount > 0) return { name: "liveness-skip", state: "degraded", detail: `${softCount} api_soft_skip events in recent log` };
  return { name: "liveness-skip", state: "healthy", detail: "no skip events" };
}

export async function computeHealth(s: AgentStatus, logs: LogStore): Promise<AgentHealth> {
  const terminal = terminalRule(s);
  // If terminal, only use the terminal verdict (other signals are stale).
  if (terminal) {
    return {
      state: terminal.state,
      rules: [terminal, heartbeatRule(s), updatedAtRule(s)],
      sparkline: [],
    };
  }
  const [container, mount, liveness] = await Promise.all([
    containerRule(s),
    mountProbeRule(logs, s.agent_id),
    livenessSkipRule(logs, s.agent_id),
  ]);
  const rules: HealthRule[] = [heartbeatRule(s), updatedAtRule(s), container, mount, liveness];
  const state = worst(rules.map((r) => r.state));
  return { state, rules, sparkline: [] };
}
