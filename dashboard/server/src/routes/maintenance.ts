import { json, errorResponse, type Router } from "../http";
import type { DashboardConfig } from "../config";
import type { SseBroker } from "../sse";
import type { DashboardAuditWriter } from "../control/audit-writer";
import type { DiskUsageStore } from "../store/disk";
import { runCleanup, type CleanupTarget } from "../control/cleanup";
import { basename } from "node:path";

interface MaintenanceDeps {
  config: DashboardConfig;
  cleanupScript: string;
  sse: SseBroker;
  dashAudit: DashboardAuditWriter;
  disk: DiskUsageStore;
}

/**
 * Strip absolute filesystem paths from error messages before returning them
 * to the client. The cleanup script path lives in $HOME and the original
 * stderr/Error.message would leak it (e.g. ENOENT spilling
 * "/Users/foo/git/kapsis/scripts/kapsis-cleanup.sh"). Keep just the basename.
 */
function sanitizeError(e: unknown): string {
  const raw = String(e);
  return raw.replace(/(?:\/[^\s'":]+)+/g, (m) => basename(m));
}

export function registerMaintenanceRoutes(r: Router, deps: MaintenanceDeps): void {
  const { config, sse, dashAudit, disk, cleanupScript } = deps;

  r.post("/api/v1/maintenance/cleanup", async (req) => {
    if (config.readOnly) return errorResponse(403, "dashboard is read-only");
    const body = await safeJson(req);
    const targets = (Array.isArray(body.targets) ? body.targets : []) as CleanupTarget[];
    const dryRun = body.dryRun !== false;
    try {
      const result = await runCleanup(targets, { dryRun, scriptPath: cleanupScript });
      await dashAudit.record(
        "dashboard",
        dryRun ? "cleanup-preview" : "cleanup-execute",
        `targets:${targets.join(",")}`,
        { exitCode: result.exitCode },
      );
      if (!dryRun) {
        // Disk snapshot is stale after a real cleanup.
        disk.invalidate();
        sse.publish("disk", { event: "disk-changed", data: { reason: "cleanup", targets } });
      }
      return json(result);
    } catch (e) {
      return errorResponse(400, sanitizeError(e));
    }
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
