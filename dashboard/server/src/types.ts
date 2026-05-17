/**
 * TypeScript mirror of the status JSON schema produced by scripts/lib/status.sh.
 *
 * IMPORTANT: This type is part of the Dashboard Sync Rule (see CLAUDE.md).
 * If you change scripts/lib/status.sh, you MUST update this type in the same PR.
 * CI enforces this via dashboard-sync.yml.
 */
export interface AgentStatus {
  version: string;
  agent_id: string;
  project: string;
  branch: string | null;
  sandbox_mode: "overlay" | "worktree" | string;
  phase:
    | "initializing"
    | "preparing"
    | "starting"
    | "running"
    | "committing"
    | "pushing"
    | "complete"
    | string;
  progress: number;
  message: string;
  gist: string | null;
  gist_updated_at: string | null;
  started_at: string;
  updated_at: string;
  exit_code: number | null;
  error: string | null;
  worktree_path: string | null;
  pr_url: string | null;
  push_status: "success" | "failed" | "skipped" | "unverified" | null;
  local_commit: string | null;
  remote_commit: string | null;
  push_fallback_command: string | null;
  commit_status: "success" | "failed" | "uncommitted" | "no_changes" | null;
  commit_sha: string | null;
  uncommitted_files: number;
  heartbeat_at: string | null;
  error_type:
    | "agent_failure"
    | "agent_partial"
    | "commit_failure"
    | "push_failure"
    | "mount_failure"
    | null;
}

export type AgentKey = { project: string; agentId: string };

export interface AuditEvent {
  seq: number;
  timestamp: string;
  session_id: string;
  agent_id: string;
  agent_type: string;
  project: string;
  event_type: string;
  tool_name: string;
  detail: unknown;
  prev_hash: string;
  hash: string;
}

export type HealthState = "healthy" | "degraded" | "stalled" | "failed" | "unknown";

export interface HealthRule {
  name: string;
  state: HealthState;
  detail: string;
}

export interface AgentHealth {
  state: HealthState;
  rules: HealthRule[];
  /** [{ts: ISO8601, count: number}], 60-minute sparkline of updated_at events */
  sparkline: Array<{ ts: string; count: number }>;
}

export interface DiskUsageEntry {
  category: string;
  bytes: number;
  items: number;
}

export interface DashboardAuditEvent {
  seq: number;
  timestamp: string;
  actor: string;
  action: string;
  target: string;
  detail: Record<string, unknown>;
  prev_hash: string;
  hash: string;
}
