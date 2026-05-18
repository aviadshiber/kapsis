import { json, errorResponse, type RouteParams, type Router } from "../http";
import type { DashboardConfig } from "../config";
import type { SseBroker } from "../sse";
import type { DashboardAuditWriter } from "../control/audit-writer";
import type { DiskUsageStore } from "../store/disk";
import { CleanupRunner, type CleanupTarget } from "../control/cleanup";
import { basename } from "node:path";

interface MaintenanceDeps {
  config: DashboardConfig;
  cleanupScript: string;
  sse: SseBroker;
  dashAudit: DashboardAuditWriter;
  disk: DiskUsageStore;
  cleanupRunner: CleanupRunner;
}

function sanitizeError(e: unknown): string {
  const raw = String(e);
  return raw.replace(/(?:\/[^\s'":]+)+/g, (m) => basename(m));
}

function p(params: RouteParams, name: string): string {
  const v = params[name];
  if (v === undefined) throw new Error(`route compile bug: missing param ${name}`);
  return v;
}

export function registerMaintenanceRoutes(r: Router, deps: MaintenanceDeps): void {
  const { config, sse, dashAudit, disk, cleanupScript, cleanupRunner } = deps;

  // Kicks off a cleanup run and returns IMMEDIATELY with a runId. The UI
  // subscribes to /sse/maintenance/:runId to stream stdout/stderr live so
  // the browser doesn't appear frozen during the ~30s that a stale-state
  // preview takes to walk every worktree dir.
  r.post("/api/v1/maintenance/cleanup", async (req) => {
    if (config.readOnly) return errorResponse(403, "dashboard is read-only");
    const body = await safeJson(req);
    const targets = (Array.isArray(body.targets) ? body.targets : []) as CleanupTarget[];
    const dryRun = body.dryRun !== false;
    try {
      const { runId, argv } = cleanupRunner.start(targets, { dryRun, scriptPath: cleanupScript });
      // Audit and SSE-fanout happen when the run completes (subscribed via
      // a listener); the POST returns immediately.
      const sub = cleanupRunner.subscribe(runId, async (ev) => {
        if (ev.kind !== "exit") return;
        await dashAudit.record(
          "dashboard",
          dryRun ? "cleanup-preview" : "cleanup-execute",
          `targets:${targets.join(",")};runId:${runId}`,
          { exitCode: ev.exitCode, durationMs: ev.durationMs },
        );
        if (!dryRun) {
          disk.invalidate();
          sse.publish("disk", { event: "disk-changed", data: { reason: "cleanup", targets } });
        }
        sub?.unsubscribe();
      });
      return json({ runId, argv, dryRun, targets, accepted: true }, 202);
    } catch (e) {
      return errorResponse(400, sanitizeError(e));
    }
  });

  // Returns the final result of a run (for late-arriving consumers and the
  // UI's "fetch on tab focus" path). 404 if the run wasn't found (expired
  // after the 5-minute retention window or never started).
  r.get("/api/v1/maintenance/runs/:runId", (_req, params) => {
    const runId = p(params, "runId");
    const result = cleanupRunner.result(runId);
    if (!result) return errorResponse(404, "run not found", { runId });
    return json(result);
  });

  // SSE: streams the live log of a cleanup run. The handler subscribes
  // to the runner, replays the backlog into the topic, attaches an
  // ongoing publisher for new events, and closes the stream after the
  // exit event arrives.
  r.get("/sse/maintenance/:runId", (_req, params) => {
    const runId = p(params, "runId");
    const topic = `maintenance:${runId}`;
    const response = sse.subscribe([topic]);
    const sub = cleanupRunner.subscribe(runId, (ev) => {
      sse.publish(topic, { event: ev.kind, data: ev });
    });
    if (!sub) {
      // Run doesn't exist — close the stream gracefully so EventSource sees
      // an EOF and the UI can switch back to the static result endpoint.
      return errorResponse(404, "run not found", { runId });
    }
    // Replay backlog so a subscriber that connects after a few lines
    // already landed still sees the start event + everything since.
    for (const ev of sub.backlog) {
      sse.publish(topic, { event: ev.kind, data: ev });
    }
    if (sub.done) {
      // Already finished: schedule unsubscribe so the listener doesn't leak.
      setTimeout(() => sub.unsubscribe(), 100);
    }
    return response;
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
