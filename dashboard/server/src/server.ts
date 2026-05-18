import { buildRouter, type Deps } from "./routes";
import { errorResponse, json } from "./http";
import { extractBearer, verifyToken } from "./auth";
import type { DashboardConfig } from "./config";
import { log } from "./logger";
import { uiBundle } from "./ui-bundle";
import type { EphemeralTokenStore } from "./sse-tokens";

const PUBLIC_API_PATHS = new Set(["/healthz", "/api/v1/version"]);

const SECURITY_HEADERS: Record<string, string> = {
  // Defeat clickjacking — once authenticated, an attacker frame must not be
  // able to trigger Kill/Cleanup buttons by clickjacking. frame-ancestors
  // covers modern browsers; X-Frame-Options remains for legacy.
  "X-Frame-Options": "DENY",
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
};

function withSecurityHeaders(res: Response): Response {
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
    if (!res.headers.has(k)) res.headers.set(k, v);
  }
  return res;
}

function requiresBearer(pathname: string): boolean {
  if (PUBLIC_API_PATHS.has(pathname)) return false;
  // SSE endpoints have their own ephemeral-token gate (see authorizeSse) so
  // that the long-lived bearer never appears in URLs. Everything else under
  // /api/ requires the bearer.
  if (pathname.startsWith("/sse/")) return false;
  return pathname.startsWith("/api/");
}

function authorizeSse(req: Request, sseTokens: EphemeralTokenStore, longLived: string | null): boolean {
  // Prefer a one-shot ephemeral token from POST /api/v1/sse-token.
  const url = new URL(req.url);
  const ephemeral = url.searchParams.get("t");
  if (ephemeral && sseTokens.consume(ephemeral)) return true;
  // Fall back to the bearer header — works for fetch-based EventSource
  // polyfills and curl, but standard browser EventSource cannot send custom
  // headers, so the UI path always uses the ephemeral.
  if (longLived && verifyToken(longLived, extractBearer(req))) return true;
  return false;
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
      if (req.method === "OPTIONS") return withSecurityHeaders(new Response(null, { status: 204 }));

      if (requiresBearer(url.pathname)) {
        if (!config.token || !verifyToken(config.token, extractBearer(req))) {
          return withSecurityHeaders(errorResponse(401, "unauthorized"));
        }
      } else if (url.pathname.startsWith("/sse/")) {
        if (!authorizeSse(req, deps.sseTokens, config.token)) {
          return withSecurityHeaders(errorResponse(401, "unauthorized"));
        }
      }

      try {
        const matched = await router.dispatch(req);
        if (matched) return withSecurityHeaders(matched);
      } catch (e) {
        log.error("handler crashed", { url: url.pathname, err: String(e) });
        return withSecurityHeaders(errorResponse(500, "internal error"));
      }

      // SPA fallback for non-API GETs.
      if (req.method === "GET" && !url.pathname.startsWith("/api") && !url.pathname.startsWith("/sse")) {
        const asset = await serveAsset(config.uiDistDir, url.pathname);
        if (asset) return withSecurityHeaders(asset);
      }

      return withSecurityHeaders(json({ error: "not found", path: url.pathname }, 404));
    },
    error: (e) => {
      log.error("bun serve error", { err: String(e) });
      return withSecurityHeaders(errorResponse(500, "internal error"));
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
    const safe = sanitizeDistPath(rel);
    if (safe !== null) {
      const file = Bun.file(`${distDir}/${safe}`);
      if (await file.exists()) {
        return new Response(file, { headers: { "cache-control": "no-store" } });
      }
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

/** Reject any path containing a `..` segment, encoded traversal, NUL, or backslash. */
export function sanitizeDistPath(rel: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(rel);
  } catch {
    return null;
  }
  if (decoded.includes("\0") || decoded.includes("\\")) return null;
  const parts = decoded.replace(/^\/+/, "").split("/");
  for (const p of parts) {
    if (p === "" || p === "." || p === "..") return null;
  }
  return parts.join("/");
}
