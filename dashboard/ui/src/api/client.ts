/**
 * Typed API client for kapsis-dashboard.
 *
 * Auth model:
 * - The long-lived bearer token is read once from the URL fragment
 *   (#token=…), stashed in sessionStorage, and stripped from the visible URL
 *   on first load. The fragment is preferred because the browser never sends
 *   it in any network request — so it can't leak via referer / proxy / logs.
 * - All /api/* requests carry the bearer in the Authorization header.
 * - SSE endpoints can't accept custom headers (EventSource limitation), so
 *   we mint a short-lived (~60s) one-shot ephemeral token via
 *   POST /api/v1/sse-token and pass it as ?t=<ephemeral>. The long-lived
 *   bearer never appears in any URL.
 */
import type {
  AgentStatus, AgentHealth, ContainerInfo, ContainerStats,
  LogChunk, AuditEvent, AuditChainStatus, ConversationEntry, DiskUsageEntry,
  KillResultWire, SpecResponse, GistEntry,
} from "../types";

function readToken(): string {
  if (typeof window === "undefined") return "";
  const cached = sessionStorage.getItem("kd_token");
  if (cached) return cached;
  const hash = window.location.hash.replace(/^#/, "");
  const params = new URLSearchParams(hash);
  const t = params.get("token") ?? "";
  if (t) {
    sessionStorage.setItem("kd_token", t);
    history.replaceState(null, "", window.location.pathname + window.location.search);
  }
  return t;
}

const token = readToken();

export function hasToken(): boolean {
  return token.length > 0;
}

export class ApiError extends Error {
  constructor(public status: number, message: string, public body?: unknown) {
    super(message);
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const init: RequestInit = {
    method,
    headers: {
      "Authorization": `Bearer ${token}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  };
  const res = await fetch(path, init);
  if (!res.ok) {
    let detail: unknown;
    try { detail = await res.json(); } catch { /* ignore */ }
    throw new ApiError(res.status, `${method} ${path} → ${res.status}`, detail);
  }
  return res.json() as Promise<T>;
}

export const api = {
  version: () => request<{ version: string; readOnly: boolean }>("GET", "/api/v1/version"),
  agents: () => request<{ agents: AgentStatus[] }>("GET", "/api/v1/agents"),
  agent: (id: string) => request<{
    status: AgentStatus;
    health: AgentHealth;
    container: ContainerInfo | null;
    stats: ContainerStats | null;
  }>("GET", `/api/v1/agents/${encodeURIComponent(id)}`),
  logs: (id: string, since = 0) => request<LogChunk>(
    "GET", `/api/v1/agents/${encodeURIComponent(id)}/logs?since=${since}`,
  ),
  audit: (id: string) => request<{
    events: AuditEvent[];
    files: Array<{ file: string; chain: AuditChainStatus }>;
  }>("GET", `/api/v1/agents/${encodeURIComponent(id)}/audit`),
  conversation: (id: string) => request<ConversationEntry>(
    "GET", `/api/v1/agents/${encodeURIComponent(id)}/conversation`,
  ),
  spec: (id: string) => request<SpecResponse>(
    "GET", `/api/v1/agents/${encodeURIComponent(id)}/spec`,
  ),
  gistHistory: (id: string) => request<{ entries: GistEntry[] }>(
    "GET", `/api/v1/agents/${encodeURIComponent(id)}/gist-history`,
  ),
  disk: () => request<{ entries: DiskUsageEntry[] }>("GET", "/api/v1/disk/usage"),
  kill: (id: string, signal: "TERM" | "KILL" = "TERM") =>
    request<KillResultWire>("POST", `/api/v1/agents/${encodeURIComponent(id)}/kill`, { signal }),
  /**
   * Kicks off a cleanup. Returns immediately with a `runId`; the caller
   * subscribes to `/sse/maintenance/<runId>` to stream the live log.
   */
  cleanupStart: (targets: string[], dryRun: boolean) =>
    request<{ runId: string; argv: string[]; dryRun: boolean; targets: string[]; accepted: true }>(
      "POST", "/api/v1/maintenance/cleanup", { targets, dryRun },
    ),
  /**
   * Mid-run snapshot — works while the script is still running AND after
   * completion. The UI polls this every 2s as a safety net so a dropped
   * SSE stream doesn't leave the spinner spinning forever.
   */
  cleanupSnapshot: (runId: string) =>
    request<{
      runId: string;
      argv: string[];
      startedAt: number;
      done: boolean;
      exitCode: number | null;
      durationMs: number | null;
      lines: Array<{ kind: "stdout" | "stderr"; line: string }>;
    }>("GET", `/api/v1/maintenance/runs/${encodeURIComponent(runId)}`),
  /**
   * Find or reap status files where the agent claims to be running but its
   * container is gone (Mac sleep / podman restart / terminal close killed
   * it without writing a final "complete" status). The script's own status
   * cleanup deliberately skips non-complete files, so these otherwise pile
   * up forever.
   */
  reapStale: (dryRun: boolean) =>
    request<{
      scanned: number;
      reaped: Array<{ agentId: string; project: string; file: string; phase: string; updatedAt: string; ageMs: number; containerState: string | null }>;
      skipped: Array<{ agentId: string; project: string; phase: string; updatedAt: string; containerState: string | null }>;
      errors: Array<{ file: string; err: string }>;
      dryRun: boolean;
    }>("POST", "/api/v1/maintenance/reap-stale", { dryRun }),
  mintSseToken: () => request<{ token: string; ttlMs: number }>("POST", "/api/v1/sse-token"),
};

/**
 * Open an EventSource for an SSE endpoint, fetching a fresh ephemeral
 * token first so the long-lived bearer never appears in the URL.
 */
export async function sseEphemeral(path: string): Promise<EventSource> {
  const { token: ephemeral } = await api.mintSseToken();
  return new EventSource(`${path}?t=${encodeURIComponent(ephemeral)}`);
}
