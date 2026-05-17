import { buildRouter, type Deps } from "./routes";
import { errorResponse, json } from "./http";
import { extractBearer, verifyToken } from "./auth";
import type { DashboardConfig } from "./config";
import { log } from "./logger";

const PUBLIC_PATHS = new Set(["/healthz", "/api/v1/version"]);

export function startServer(config: DashboardConfig, deps: Omit<Deps, "config">): ReturnType<typeof Bun.serve> {
  const router = buildRouter({ ...deps, config });

  return Bun.serve({
    hostname: config.host,
    port: config.port,
    development: false,
    fetch: async (req) => {
      const url = new URL(req.url);

      // CORS preflight: no cross-origin allowed by default.
      if (req.method === "OPTIONS") return new Response(null, { status: 204 });

      // Public paths bypass auth.
      if (!PUBLIC_PATHS.has(url.pathname)) {
        if (!config.token || !verifyToken(config.token, extractBearer(req))) {
          return errorResponse(401, "unauthorized");
        }
      }

      try {
        const matched = await router.dispatch(req);
        if (matched) return matched;
      } catch (e) {
        log.error("handler crashed", { url: url.pathname, err: String(e) });
        return errorResponse(500, "internal error");
      }

      // SPA fallback for non-API GETs.
      if (req.method === "GET" && !url.pathname.startsWith("/api") && !url.pathname.startsWith("/sse")) {
        const asset = await serveAsset(config.uiDistDir, url.pathname);
        if (asset) return asset;
      }

      return json({ error: "not found", path: url.pathname }, 404);
    },
    error: (e) => {
      log.error("bun serve error", { err: String(e) });
      return errorResponse(500, "internal error");
    },
  });
}

async function serveAsset(distDir: string | null, pathname: string): Promise<Response | null> {
  if (!distDir) return null;
  const rel = pathname === "/" ? "/index.html" : pathname;
  const safe = rel.replace(/^\/+/, "").replace(/\.\.+/g, "");
  const file = Bun.file(`${distDir}/${safe}`);
  if (await file.exists()) {
    return new Response(file, { headers: { "cache-control": "no-store" } });
  }
  // SPA fallback
  const index = Bun.file(`${distDir}/index.html`);
  if (await index.exists()) {
    return new Response(index, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
  }
  return null;
}
