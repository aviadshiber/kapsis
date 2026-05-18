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

  r.post("/api/v1/maintenance/cleanup", async (req) => {
    if (config.readOnly) return errorResponse(403, "dashboard is read-only");
    const body = await safeJson(req);
    const targets = (Array.isArray(body.targets) ? body.targets : []) as CleanupTarget[];
    const dryRun = body.dryRun !== false;
    try {
      const { runId, argv } = cleanupRunner.start(targets, { dryRun, scriptPath: cleanupScript });
      // Audit + SSE-disk-invalidate are wired via a one-shot listener on
      // the runner itself; they fire whether or not any SSE client is
      // connected.
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

  // Returns a snapshot of the run's current state — works mid-run AND
  // after completion (during the 5-min retention window). This is the
  // UI's polling fallback when its SSE connection drops.
  r.get("/api/v1/maintenance/runs/:runId", (_req, params) => {
    const runId = p(params, "runId");
    const snap = cleanupRunner.snapshot(runId);
    if (!snap) return errorResponse(404, "run not found or expired", { runId });
    return json(snap);
  });

  // SSE: streams the live log of a cleanup run. The listener is
  // unsubscribed when the client disconnects (stream cancel) so we don't
  // leak per-connection listeners on the runner.
  r.get("/sse/maintenance/:runId", (_req, params) => {
    const runId = p(params, "runId");
    const topic = `maintenance:${runId}`;
    const snapBeforeSubscribe = cleanupRunner.snapshot(runId);
    if (!snapBeforeSubscribe) return errorResponse(404, "run not found or expired", { runId });

    const response = sse.subscribe([topic]);

    // Attach a per-connection listener that republishes runner events into
    // the topic. We need to schedule the backlog replay AFTER the client's
    // ReadableStream.start fires (which lazily registers the client with
    // the broker), otherwise the first events go to nobody. setTimeout 0
    // yields the microtask queue so the start callback (which runs when
    // the consumer begins reading the body) can register first.
    let unsubscribe: (() => void) | null = null;
    queueMicrotask(() => {
      const sub = cleanupRunner.subscribe(runId, (ev) => {
        sse.publish(topic, { event: ev.kind, data: ev });
      });
      if (!sub) return;
      unsubscribe = sub.unsubscribe;
      // Replay backlog so a subscriber that connected after the script
      // already emitted lines still sees them.
      for (const ev of sub.backlog) {
        sse.publish(topic, { event: ev.kind, data: ev });
      }
      if (sub.done) {
        // Run already finished — schedule cleanup after the in-flight
        // events flush so the client gets the final exit event before
        // we tear down.
        setTimeout(() => unsubscribe?.(), 500);
      }
    });
    // Bun.serve doesn't expose a client-disconnect signal here directly,
    // so we rely on the broker dropping the client when its
    // controller.enqueue throws (the next publish after disconnect).
    // We add a safety timeout: if the run has been done for >30s and the
    // listener is still attached, drop it.
    const watchdog = setInterval(() => {
      const cur = cleanupRunner.snapshot(runId);
      if (!cur || (cur.done && Date.now() - (cur.startedAt + (cur.durationMs ?? 0)) > 30_000)) {
        unsubscribe?.();
        clearInterval(watchdog);
      }
    }, 5_000);
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
