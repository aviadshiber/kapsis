import type { AgentHealth, AgentStatus, HealthRule, HealthState } from "../types";
import { inspectContainer, type ContainerInfo } from "./container";
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

export function heartbeatRule(s: AgentStatus): HealthRule {
  const age = ageSec(s.heartbeat_at);
  if (age === null) {
    return { name: "heartbeat", state: "unknown", detail: "no heartbeat field — liveness monitor disabled or pre-heartbeat agent" };
  }
  if (age < 60) return { name: "heartbeat", state: "healthy", detail: `heartbeat ${age.toFixed(0)}s ago` };
  if (age < 300) return { name: "heartbeat", state: "degraded", detail: `heartbeat ${age.toFixed(0)}s ago (>60s)` };
  return { name: "heartbeat", state: "stalled", detail: `heartbeat ${age.toFixed(0)}s ago (>300s)` };
}

export function updatedAtRule(s: AgentStatus): HealthRule {
  const age = ageSec(s.updated_at);
  if (age === null) return { name: "updated_at", state: "unknown", detail: "no updated_at" };
  if (age < 120) return { name: "updated_at", state: "healthy", detail: `last update ${age.toFixed(0)}s ago` };
  if (age < 600) return { name: "updated_at", state: "degraded", detail: `last update ${age.toFixed(0)}s ago (>2m)` };
  return { name: "updated_at", state: "stalled", detail: `last update ${age.toFixed(0)}s ago (>10m)` };
}

export function terminalRule(s: AgentStatus): HealthRule | null {
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

export function containerRule(s: AgentStatus, info: ContainerInfo | null): HealthRule {
  if (s.phase === "complete") {
    return { name: "container", state: "healthy", detail: "agent complete — container not expected" };
  }
  if (!info || !info.exists) {
    const name = info?.name ?? `kapsis-${s.agent_id}`;
    return { name: "container", state: "stalled", detail: `container ${name} missing while phase=${s.phase}` };
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

/** Parse the tail buffer once; produce both mount-probe and liveness-skip verdicts. */
export function tailRules(lines: string[]): { mount: HealthRule; liveness: HealthRule } {
  let mountFailed = false;
  let softCount = 0;
  let hardCount = 0;
  for (const line of lines) {
    if (line.includes("KAPSIS_MOUNT_FAILURE:")) mountFailed = true;
    if (line.includes("api_soft_skip")) softCount++;
    if (line.includes("api_hard_skip")) hardCount++;
  }
  const mount: HealthRule = mountFailed
    ? { name: "mount-probe", state: "failed", detail: "KAPSIS_MOUNT_FAILURE sentinel in log" }
    : { name: "mount-probe", state: "healthy", detail: "no mount-failure sentinel in recent log" };
  let liveness: HealthRule;
  if (hardCount > 0) {
    liveness = { name: "liveness-skip", state: "stalled", detail: `${hardCount} api_hard_skip events in recent log` };
  } else if (softCount > 0) {
    liveness = { name: "liveness-skip", state: "degraded", detail: `${softCount} api_soft_skip events in recent log` };
  } else {
    liveness = { name: "liveness-skip", state: "healthy", detail: "no skip events" };
  }
  return { mount, liveness };
}

export async function computeHealth(
  s: AgentStatus,
  logs: LogStore,
  prefetchedContainer?: ContainerInfo | null,
): Promise<AgentHealth> {
  const terminal = terminalRule(s);
  // If terminal, only use the terminal verdict (other signals are stale).
  if (terminal) {
    return {
      state: terminal.state,
      rules: [terminal, heartbeatRule(s), updatedAtRule(s)],
      sparkline: [],
    };
  }
  // Fetch container info once (cached in container.ts) unless caller already has it.
  const containerInfo = prefetchedContainer ?? await inspectContainer(s.agent_id);
  // Coalesce the log tail — both mount-probe and liveness-skip need the same
  // ~64 KiB window, so read it once and let rules walk the lines.
  const size = await logs.size(s.agent_id);
  let mount: HealthRule;
  let liveness: HealthRule;
  if (size === 0) {
    mount = { name: "mount-probe", state: "unknown", detail: "no log" };
    liveness = { name: "liveness-skip", state: "unknown", detail: "no log" };
  } else {
    const startAt = Math.max(0, size - 64 * 1024);
    const chunk = await logs.read(s.agent_id, startAt);
    ({ mount, liveness } = tailRules(chunk.lines));
  }
  const container = containerRule(s, containerInfo);
  const rules: HealthRule[] = [heartbeatRule(s), updatedAtRule(s), container, mount, liveness];
  const state = worst(rules.map((r) => r.state));
  return { state, rules, sparkline: [] };
}
