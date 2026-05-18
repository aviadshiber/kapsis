import type { AgentStatus } from "../types";

function classify(s: AgentStatus): "running" | "complete" | "failed" | "pending" {
  if (s.phase === "complete") return (s.exit_code ?? 0) === 0 ? "complete" : "failed";
  if (s.phase === "initializing" || s.phase === "preparing" || s.phase === "starting") return "pending";
  return "running";
}

export function StatusPill({ status }: { status: AgentStatus }) {
  const cls = classify(status);
  return <span className={`pill ${cls}`}>{status.phase}</span>;
}
