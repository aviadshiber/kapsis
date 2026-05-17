// Mirror of dashboard/server/src/types.ts for the UI's typed fetch wrapper.
// Kept manually in sync; server is the source of truth.

export interface AgentStatus {
  version: string;
  agent_id: string;
  project: string;
  branch: string | null;
  sandbox_mode: string;
  phase: string;
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
  push_status: string | null;
  local_commit: string | null;
  remote_commit: string | null;
  push_fallback_command: string | null;
  commit_status: string | null;
  commit_sha: string | null;
  uncommitted_files: number;
  heartbeat_at: string | null;
  error_type: string | null;
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
  sparkline: Array<{ ts: string; count: number }>;
}

export interface ContainerInfo {
  name: string;
  exists: boolean;
  state: string | null;
  startedAt: string | null;
  image: string | null;
  pid: number | null;
  exitCode: number | null;
}

export interface ContainerStats {
  cpuPercent: number | null;
  memBytes: number | null;
  memLimitBytes: number | null;
}

export interface LogChunk {
  agentId: string;
  bytesRead: number;
  nextOffset: number;
  size: number;
  lines: string[];
  truncated: boolean;
}

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

export interface AuditChainStatus {
  valid: boolean;
  lastSeq: number;
  lastHash: string;
  brokenAt: number | null;
  reason: string | null;
}

export interface ConversationEntry {
  agentId: string;
  files: Array<{ name: string; size: number; mtime: string }>;
  totalBytes: number;
  empty: boolean;
}

export interface DiskUsageEntry {
  category: string;
  bytes: number;
  items: number;
}
