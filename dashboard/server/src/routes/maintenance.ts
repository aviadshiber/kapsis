import { json, errorResponse, type RouteParams, type Router } from "../http";
import type { DashboardConfig } from "../config";
import type { SseBroker } from "../sse";
import type { DashboardAuditWriter } from "../control/audit-writer";
import type { DiskUsageStore } from "../store/disk";
import { CleanupRunner, type CleanupTarget } from "../control/cleanup";
import { reapStaleAgents, STALE_THRESHOLD_MS } from "../control/reaper";
import { basename, join } from "node:path";

interface MaintenanceDeps {
  config: DashboardConfig;
  cleanupScript: string;
  sse: SseBroker;
  dashAudit: DashboardAuditWriter;
  disk: DiskUsageStore;
  cleanupRunner: CleanupRunner;
  kapsisHome: string;
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
  const { config, sse, dashAudit, disk, cleanupScript, cleanupRunner, kapsisHome } = deps;
  const statusDir = join(kapsisHome, "status");

  // In-flight lock for the reaper. Only one reap (preview or execute) may
  // run at a time per server instance. Unlike cleanup we don't need a
  // per-run id — the reaper is fast, synchronous-ish, and has no streaming
  // surface. A second concurrent call gets 409 immediately. The check is
  // synchronous (before any `await`), so Promise.all of two POSTs cannot
  // race past it.
  let reapInFlight = false;

  // Stale-agent reaper — finds status JSONs where the agent claims to be
  // running but is actually dead (Mac sleep / VM restart / terminal close
  // killed it without writing the final "complete" status), verifies the
  // container is gone via `podman inspect`, then marks the status file
  // complete with error_type=zombie and removes it. The script's own
  // clean_status explicitly skips non-complete files, so without this the
  // list of "running" agents grows forever.
  r.post("/api/v1/maintenance/reap-stale", async (req) => {
    if (config.readOnly) return errorResponse(403, "dashboard is read-only");
    if (reapInFlight) {
      return errorResponse(409, "reap already in flight", { reapInFlight: true });
    }
    reapInFlight = true;
    try {
      const body = await safeJson(req);
      const dryRun = body.dryRun !== false;
      const thresholdMs = typeof body.thresholdMs === "number" && body.thresholdMs > 60_000
        ? body.thresholdMs : STALE_THRESHOLD_MS;
      try {
        const outcome = await reapStaleAgents(statusDir, { dryRun, thresholdMs });
        // When podman is unavailable, the reaper deliberately returns
        // `reapable: []` to avoid mass-zombifying live agents during a
        // transient podman outage. The route layer surfaces this to the
        // user via a distinct audit action AND a `note` field in the
        // response body so the UI can render a clear warning instead of
        // silently reporting "0 reaped" (which looks like success).
        const action = !outcome.podmanAvailable
          ? "reap-stale-podman-unavailable"
          : dryRun
            ? "reap-stale-preview"
            : "reap-stale-execute";
        await dashAudit.record(
          "dashboard",
          action,
          `count:${outcome.reaped.length}`,
          {
            scanned: outcome.scanned,
            reaped: outcome.reaped.length,
            skipped: outcome.skipped.length,
            errors: outcome.errors.length,
            thresholdMinutes: Math.round(thresholdMs / 60_000),
            podmanAvailable: outcome.podmanAvailable,
          },
        );
        if (!dryRun && outcome.reaped.length > 0) {
          for (const r of outcome.reaped) {
            sse.publish("agents", { event: "agent-reaped", data: { agentId: r.agentId, project: r.project } });
          }
        }
        if (!outcome.podmanAvailable) {
          return json({
            ...outcome,
            note: "podman unavailable; no agents reaped to avoid mass data loss on a transient outage",
          });
        }
        return json(outcome);
      } catch (e) {
        return errorResponse(400, sanitizeError(e));
      }
    } finally {
      reapInFlight = false;
    }
  });

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
