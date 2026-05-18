import { Router } from "./http";
import type { DashboardConfig } from "./config";
import type { StatusStore } from "./store/status";
import type { AuditStore } from "./store/audit";
import type { LogStore } from "./store/logs";
import type { ConversationStore } from "./store/conversations";
import type { DiskUsageStore } from "./store/disk";
import type { DashboardAuditWriter } from "./control/audit-writer";
import type { CleanupRunner } from "./control/cleanup";
import type { SseBroker } from "./sse";
import type { EphemeralTokenStore } from "./sse-tokens";
import { registerAgentRoutes } from "./routes/agents";
import { registerDiskRoutes } from "./routes/disk";
import { registerMaintenanceRoutes } from "./routes/maintenance";
import { registerMetaRoutes } from "./routes/meta";

export interface Deps {
  config: DashboardConfig;
  status: StatusStore;
  audit: AuditStore;
  logs: LogStore;
  conv: ConversationStore;
  disk: DiskUsageStore;
  sse: SseBroker;
  sseTokens: EphemeralTokenStore;
  dashAudit: DashboardAuditWriter;
  cleanupRunner: CleanupRunner;
  cleanupScript: string;
  version: string;
}

export function buildRouter(deps: Deps): Router {
  const r = new Router();
  registerMetaRoutes(r, { config: deps.config, version: deps.version, sseTokens: deps.sseTokens });
  registerAgentRoutes(r, deps);
  registerDiskRoutes(r, { disk: deps.disk });
  registerMaintenanceRoutes(r, {
    config: deps.config,
    cleanupScript: deps.cleanupScript,
    sse: deps.sse,
    dashAudit: deps.dashAudit,
    disk: deps.disk,
    cleanupRunner: deps.cleanupRunner,
  });
  return r;
}
