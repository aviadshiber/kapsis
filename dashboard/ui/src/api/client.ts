/**
 * Typed API client for kapsis-dashboard.
 *
 * Token is read once from the URL fragment (`#token=…`) on first load. The
 * fragment is preferred because it never reaches server logs or proxies.
 */

function readToken(): string {
  if (typeof window === "undefined") return "";
  const cached = sessionStorage.getItem("kd_token");
  if (cached) return cached;
  const hash = window.location.hash.replace(/^#/, "");
  const params = new URLSearchParams(hash);
  const t = params.get("token") ?? "";
  if (t) {
    sessionStorage.setItem("kd_token", t);
    // Strip the token from the visible URL.
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
  agents: () => request<{ agents: import("../types").AgentStatus[] }>("GET", "/api/v1/agents"),
  agent: (id: string) => request<{
    status: import("../types").AgentStatus;
    health: import("../types").AgentHealth;
    container: import("../types").ContainerInfo;
    stats: import("../types").ContainerStats | null;
  }>("GET", `/api/v1/agents/${encodeURIComponent(id)}`),
  logs: (id: string, since = 0) => request<import("../types").LogChunk>(
    "GET", `/api/v1/agents/${encodeURIComponent(id)}/logs?since=${since}`,
  ),
  audit: (id: string) => request<{
    events: import("../types").AuditEvent[];
    files: Array<{ file: string; chain: import("../types").AuditChainStatus }>;
  }>("GET", `/api/v1/agents/${encodeURIComponent(id)}/audit`),
  conversation: (id: string) => request<import("../types").ConversationEntry>(
    "GET", `/api/v1/agents/${encodeURIComponent(id)}/conversation`,
  ),
  disk: () => request<{ entries: import("../types").DiskUsageEntry[] }>("GET", "/api/v1/disk/usage"),
  kill: (id: string, signal: "TERM" | "KILL" = "TERM") =>
    request<{ ok: boolean; signal: string; stdout: string; stderr: string; exitCode: number }>(
      "POST", `/api/v1/agents/${encodeURIComponent(id)}/kill`, { signal },
    ),
  cleanup: (targets: string[], dryRun: boolean) =>
    request<{ ok: boolean; dryRun: boolean; stdout: string; stderr: string; exitCode: number }>(
      "POST", "/api/v1/maintenance/cleanup", { targets, dryRun },
    ),
};

export function sse(path: string): EventSource {
  return new EventSource(`${path}?token=${encodeURIComponent(token)}`);
}
