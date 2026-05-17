import { Router, json, errorResponse, type RouteParams } from "./http";
import type { DashboardConfig } from "./config";
import type { StatusStore } from "./store/status";
import type { AuditStore } from "./store/audit";
import type { LogStore } from "./store/logs";
import type { ConversationStore } from "./store/conversations";
import type { DiskUsageStore } from "./store/disk";
import { computeHealth } from "./store/health";
import { inspectContainer, containerStats } from "./store/container";
import { killAgent } from "./control/kill";
import { runCleanup, type CleanupTarget } from "./control/cleanup";
import type { DashboardAuditWriter } from "./control/audit-writer";
import type { SseBroker } from "./sse";

export interface Deps {
  config: DashboardConfig;
  status: StatusStore;
  audit: AuditStore;
  logs: LogStore;
  conv: ConversationStore;
  disk: DiskUsageStore;
  sse: SseBroker;
  dashAudit: DashboardAuditWriter;
  cleanupScript: string;
  version: string;
}

function p(params: RouteParams, name: string): string {
  const v = params[name];
  if (v === undefined) throw new Error(`route compile bug: missing param ${name}`);
  return v;
}

export function buildRouter(deps: Deps): Router {
  const r = new Router();
  const { config, status, audit, logs, conv, disk, sse, dashAudit, cleanupScript, version } = deps;

  r.get("/healthz", () => json({ ok: true }));
  r.get("/api/v1/version", () => json({ version, readOnly: config.readOnly }));

  r.get("/api/v1/agents", () => json({ agents: status.list() }));

  r.get("/api/v1/agents/:id", async (_req, params) => {
    const id = p(params, "id");
    const s = status.get(id);
    if (!s) return errorResponse(404, "agent not found", { agentId: id });
    const [health, container] = await Promise.all([
      computeHealth(s, logs),
      inspectContainer(id),
    ]);
    const stats = container.exists && container.state === "running" ? await containerStats(id) : null;
    return json({ status: s, health, container, stats });
  });

  r.get("/api/v1/agents/:id/logs", async (req, params) => {
    const id = p(params, "id");
    const u = new URL(req.url);
    const since = Number(u.searchParams.get("since") ?? "0") || 0;
    const max = Math.min(Number(u.searchParams.get("max") ?? "0") || 0, 1024 * 1024);
    const chunk = await logs.read(id, since, max || undefined);
    return json(chunk);
  });

  r.get("/api/v1/agents/:id/audit", async (req, params) => {
    const id = p(params, "id");
    const u = new URL(req.url);
    const eventType = u.searchParams.get("type") ?? undefined;
    const since = u.searchParams.get("since");
    const events = await audit.query({
      agentId: id,
      eventType,
      sinceSeq: since !== null ? Number(since) : undefined,
      limit: 5000,
    });
    const files = await audit.listFiles(id);
    const chains = await Promise.all(files.map((f) => audit.verifyFile(f)));
    return json({ events, files: files.map((f, i) => ({ file: f, chain: chains[i] })) });
  });

  r.get("/api/v1/agents/:id/conversation", async (_req, params) => {
    const id = p(params, "id");
    return json(await conv.describe(id));
  });

  r.get("/api/v1/agents/:id/conversation/:name", async (_req, params) => {
    const id = p(params, "id");
    const name = p(params, "name");
    const body = await conv.readFile(id, name);
    if (body === null) return errorResponse(404, "conversation file not found or too large");
    return new Response(body, { headers: { "content-type": "text/plain; charset=utf-8" } });
  });

  r.get("/api/v1/disk/usage", async () => json({ entries: await disk.snapshot() }));

  r.get("/sse/agents", () => sse.subscribe(["agents"]));
  r.get("/sse/agents/:id/logs", (_req, params) => sse.subscribe([`logs:${p(params, "id")}`]));
  r.get("/sse/agents/:id/audit", (_req, params) => sse.subscribe([`audit:${p(params, "id")}`]));
  r.get("/sse/disk", () => sse.subscribe(["disk"]));

  r.post("/api/v1/agents/:id/kill", async (req, params) => {
    if (config.readOnly) return errorResponse(403, "dashboard is read-only");
    const id = p(params, "id");
    const body = await safeJson(req);
    const signal = body.signal === "KILL" ? "KILL" : "TERM";
    const result = await killAgent(id, { signal });
    await dashAudit.record("dashboard", "kill", `agent:${id}`, {
      signal,
      exitCode: result.exitCode,
      containerMissing: result.containerMissing ?? false,
      stderr: result.stderr.slice(0, 500),
    });
    sse.publish("agents", { event: "agent-killed", data: { id, signal, ok: result.ok, containerMissing: result.containerMissing ?? false } });
    return json(result, result.ok ? 200 : 502);
  });

  r.post("/api/v1/maintenance/cleanup", async (req) => {
    if (config.readOnly) return errorResponse(403, "dashboard is read-only");
    const body = await safeJson(req);
    const targets = (Array.isArray(body.targets) ? body.targets : []) as CleanupTarget[];
    const dryRun = body.dryRun !== false;
    try {
      const result = await runCleanup(targets, { dryRun, scriptPath: cleanupScript });
      await dashAudit.record("dashboard", dryRun ? "cleanup-preview" : "cleanup-execute", `targets:${targets.join(",")}`, { exitCode: result.exitCode });
      if (!dryRun) sse.publish("disk", { event: "disk-changed", data: { reason: "cleanup", targets } });
      return json(result);
    } catch (e) {
      return errorResponse(400, String(e));
    }
  });

  return r;
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
