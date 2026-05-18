import { json } from "../http";
import type { Router } from "../http";
import type { DashboardConfig } from "../config";
import type { EphemeralTokenStore } from "../sse-tokens";

interface MetaDeps {
  config: DashboardConfig;
  version: string;
  sseTokens: EphemeralTokenStore;
}

export function registerMetaRoutes(r: Router, deps: MetaDeps): void {
  r.get("/healthz", () => json({ ok: true }));
  r.get("/api/v1/version", () => json({ version: deps.version, readOnly: deps.config.readOnly }));

  // Mints a one-shot, short-lived token specifically for SSE connections so
  // the long-lived bearer never appears in any URL. Bearer-gated.
  r.post("/api/v1/sse-token", () => {
    const { token, ttlMs } = deps.sseTokens.mint();
    return json({ token, ttlMs });
  });
}
