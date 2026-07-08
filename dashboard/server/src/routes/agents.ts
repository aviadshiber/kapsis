import { json, errorResponse, type RouteParams, type Router } from "../http";
import type { DashboardConfig } from "../config";
import type { StatusStore } from "../store/status";
import type { AuditStore } from "../store/audit";
import type { LogStore } from "../store/logs";
import type { ConversationStore } from "../store/conversations";
import type { SpecStore } from "../store/spec";
import type { GistHistoryStore } from "../store/gist-history";
import { computeHealth } from "../store/health";
import { inspectContainer, containerStats, invalidateContainerCache } from "../store/container";
import { killAgent } from "../control/kill";
import type { DashboardAuditWriter } from "../control/audit-writer";
import type { SseBroker } from "../sse";
import { requireAgentId } from "../validators";

interface AgentsDeps {
  config: DashboardConfig;
  status: StatusStore;
  audit: AuditStore;
  logs: LogStore;
  conv: ConversationStore;
  spec: SpecStore;
  gistHistory: GistHistoryStore;
  sse: SseBroker;
  dashAudit: DashboardAuditWriter;
}

function p(params: RouteParams, name: string): string {
  const v = params[name];
  if (v === undefined) throw new Error(`route compile bug: missing param ${name}`);
  return v;
}

export function registerAgentRoutes(r: Router, deps: AgentsDeps): void {
  const { config, status, audit, logs, conv, spec, gistHistory, sse, dashAudit } = deps;

  r.get("/api/v1/agents", () => json({ agents: status.list() }));

  r.get("/api/v1/agents/:id", async (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    const s = status.get(id);
    if (!s) return errorResponse(404, "agent not found", { agentId: id });
    // For completed agents we can skip the container inspect entirely since
    // health.ts already short-circuits on `phase === "complete"`. For running
    // agents we fetch once and pass through.
    const isRunning = s.phase !== "complete";
    const container = isRunning ? await inspectContainer(id) : null;
    const [health, stats] = await Promise.all([
      computeHealth(s, logs, container),
      container?.exists && container.state === "running" ? containerStats(id) : Promise.resolve(null),
    ]);
    return json({ status: s, health, container, stats });
  });

  r.get("/api/v1/agents/:id/logs", async (req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    const u = new URL(req.url);
    const since = Number(u.searchParams.get("since") ?? "0") || 0;
    const max = Math.min(Number(u.searchParams.get("max") ?? "0") || 0, 1024 * 1024);
    const chunk = await logs.read(id, since, max || undefined);
    return json(chunk);
  });

  r.get("/api/v1/agents/:id/audit", async (req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    const u = new URL(req.url);
    const eventType = u.searchParams.get("type") ?? undefined;
    const since = u.searchParams.get("since");
    // Single read per file — query and verifyFile both consume the same text.
    const { events, texts } = await audit.queryWithFileTexts({
      agentId: id,
      eventType,
      sinceSeq: since !== null ? Number(since) : undefined,
      limit: 5000,
    });
    const files = await audit.listFiles(id);
    const chains = await Promise.all(files.map((f) => audit.verifyFile(f, texts.get(f))));
    return json({ events, files: files.map((f, i) => ({ file: f, chain: chains[i] })) });
  });

  r.get("/api/v1/agents/:id/spec", async (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    const result = await spec.read(id);
    if (!result) return errorResponse(404, "spec not found", { agentId: id });
    return json(result);
  });

  r.get("/api/v1/agents/:id/gist-history", (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    return json({ entries: gistHistory.get(id) });
  });

  r.get("/sse/agents/:id/gist-history", (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    return sse.subscribe([`gist-history:${id}`]);
  });

  r.get("/api/v1/agents/:id/conversation", async (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    return json(await conv.describe(id));
  });

  r.get("/api/v1/agents/:id/conversation/:name", async (_req, params) => {
    const id = p(params, "id");
    const name = p(params, "name");
    const bad = requireAgentId(id);
    if (bad) return bad;
    const body = await conv.readFile(id, name);
    if (body === null) return errorResponse(404, "conversation file not found or too large");
    return new Response(body, { headers: { "content-type": "text/plain; charset=utf-8" } });
  });

  // Side-channel artifacts (Issue #430, defect 3): response-<id>.md,
  // decisions-<id>.json, debug-<id>.log written directly to the status dir.
  // Follows the same requireAgentId + 404-on-null pattern as the
  // conversation routes above.
  r.get("/api/v1/agents/:id/artifacts", async (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    return json(await conv.listArtifacts(id));
  });

  r.get("/api/v1/agents/:id/artifacts/:name", async (_req, params) => {
    const id = p(params, "id");
    const name = p(params, "name");
    const bad = requireAgentId(id);
    if (bad) return bad;
    const body = await conv.readArtifact(id, name);
    if (body === null) return errorResponse(404, "artifact not found, not whitelisted, or too large");
    return new Response(body, { headers: { "content-type": "text/plain; charset=utf-8" } });
  });

  // SSE endpoints — auth happens in the server layer (ephemeral token).
  r.get("/sse/agents", () => sse.subscribe(["agents"]));
  r.get("/sse/agents/:id/logs", (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    return sse.subscribe([`logs:${id}`]);
  });
  r.get("/sse/agents/:id/audit", (_req, params) => {
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    return sse.subscribe([`audit:${id}`]);
  });
  r.get("/sse/disk", () => sse.subscribe(["disk"]));

  r.post("/api/v1/agents/:id/kill", async (req, params) => {
    if (config.readOnly) return errorResponse(403, "dashboard is read-only");
    const id = p(params, "id");
    const bad = requireAgentId(id);
    if (bad) return bad;
    const body = await safeJson(req);
    const signal = body.signal === "KILL" ? "KILL" : "TERM";
    const result = await killAgent(id, { signal });
    invalidateContainerCache(id);
    await dashAudit.record("dashboard", "kill", `agent:${id}`, {
      signal,
      exitCode: result.exitCode,
      containerMissing: result.containerMissing ?? false,
      stderr: result.stderr.slice(0, 500),
    });
    sse.publish("agents", { event: "agent-killed", data: { id, signal, ok: result.ok, containerMissing: result.containerMissing ?? false } });
    return json(result, result.ok ? 200 : 502);
  });
}

async function safeJson(req: Request): Promise<Record<string, unknown>> {
  try {
    const ct = req.headers.get("content-type") ?? "";
    if (!ct.includes("application/json")) return {};
    return (await req.json()) as Record<string, unknown>;
  } catch {
    return {};
  }
}
