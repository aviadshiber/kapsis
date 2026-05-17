import { buildRouter, type Deps } from "./routes";
import { errorResponse, json } from "./http";
import { extractBearer, verifyToken } from "./auth";
import type { DashboardConfig } from "./config";
import { log } from "./logger";
import { uiBundle } from "./ui-bundle";

const PUBLIC_API_PATHS = new Set(["/healthz", "/api/v1/version"]);

function requiresAuth(pathname: string): boolean {
  if (PUBLIC_API_PATHS.has(pathname)) return false;
  // Static SPA assets are public; only API and SSE channels carry data.
  // Browsers strip URL fragments before sending requests, so the SPA shell
  // must be loadable without a bearer — it reads the token from `#token=…`
  // on the client and forwards it in subsequent fetches.
  return pathname.startsWith("/api/") || pathname.startsWith("/sse/");
}

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

      if (requiresAuth(url.pathname)) {
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
  // 1. Embedded bundle (compiled binary path).
  const embeddedPath = uiBundle[pathname] ?? uiBundle["/"];
  if (uiBundle[pathname]) {
    return new Response(Bun.file(uiBundle[pathname]!), { headers: { "cache-control": "no-store" } });
  }

  // 2. --ui-dist override (dev path).
  if (distDir) {
    const rel = pathname === "/" ? "/index.html" : pathname;
    const safe = rel.replace(/^\/+/, "").replace(/\.\.+/g, "");
    const file = Bun.file(`${distDir}/${safe}`);
    if (await file.exists()) {
      return new Response(file, { headers: { "cache-control": "no-store" } });
    }
    const index = Bun.file(`${distDir}/index.html`);
    if (await index.exists()) {
      return new Response(index, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
    }
  }

  // 3. SPA fallback to embedded index.html for client-side routes.
  if (embeddedPath && pathname !== "/") {
    return new Response(Bun.file(embeddedPath), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
  }
  return null;
}
