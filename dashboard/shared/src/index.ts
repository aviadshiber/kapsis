/**
 * Shared wire types between dashboard server and UI. Single source of truth
 * for everything sent over /api/* and /sse/*.
 *
 * IMPORTANT: This file is part of the Dashboard Sync Rule (see CLAUDE.md).
 * If you change scripts/lib/status.sh, you MUST update the AgentStatus
 * interface here in the same PR. CI enforces this via dashboard-sync.yml.
 */

/** Threshold past which a non-complete agent is considered stale / likely dead. */
export const STALE_AGENT_THRESHOLD_MS = 30 * 60_000;

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
    | "killed"
    | "zombie"
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

export interface AuditChainStatus {
  valid: boolean;
  lastSeq: number;
  lastHash: string;
  brokenAt: number | null;
  reason: string | null;
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

export interface KillResultWire {
  ok: boolean;
  signal: "TERM" | "KILL" | string;
  stdout: string;
  stderr: string;
  exitCode: number;
  containerMissing?: boolean;
}

export interface CleanupResultWire {
  ok: boolean;
  dryRun: boolean;
  targets: string[];
  argv: string[];
  stdout: string;
  stderr: string;
  exitCode: number;
}

/** Cap matches `SPEC_MAX_BYTES` in dashboard/server/src/store/spec.ts. */
export const SPEC_MAX_BYTES = 256 * 1024;

/** Maximum gist-history entries retained per agent in the server ring buffer. */
export const GIST_HISTORY_MAX_PER_AGENT = 200;

export interface SpecResponse {
  /** The user-authored portion of the spec (the injected Kapsis suffix is stripped). */
  spec: string;
  /** The Kapsis progress-instruction suffix that was stripped, or null when nothing was stripped. */
  injectedInstructions: string | null;
  /**
   * Where the spec was read from. `worktree` is the per-agent canonical
   * location; `volume:<name>` is the named-volume fallback used by
   * overlay-mode agents whose worktree is read-only.
   */
  source: "worktree" | string;
  /** Length of the raw on-disk file before splitting/truncation. */
  sizeBytes: number;
  /** True when the on-disk file exceeded `SPEC_MAX_BYTES` and was truncated. */
  truncated: boolean;
}

export interface GistEntry {
  /** ISO-8601 UTC timestamp of the gist transition. */
  at: string;
  /** Gist text at that moment (the new value, not the prior one). */
  gist: string;
}
