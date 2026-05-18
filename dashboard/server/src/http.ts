/** Params is keyed only by names declared in the route pattern; values are always present. */
export interface RouteParams { [k: string]: string }

export type Handler = (req: Request, params: RouteParams) => Response | Promise<Response>;

export type Route = {
  method: string;
  pattern: string;
  handler: Handler;
};

type CompiledRoute = Route & {
  regex: RegExp;
  paramNames: string[];
};

export class Router {
  private routes: CompiledRoute[] = [];

  add(method: string, pattern: string, handler: Handler): void {
    const paramNames: string[] = [];
    const regexSrc = pattern
      .replace(/\/$/, "")
      .replace(/[.+*?^${}()|[\]\\]/g, "\\$&")
      .replace(/:([a-zA-Z_][a-zA-Z0-9_]*)/g, (_m, name) => {
        paramNames.push(name);
        return "([^/]+)";
      });
    this.routes.push({
      method: method.toUpperCase(),
      pattern,
      handler,
      regex: new RegExp(`^${regexSrc}/?$`),
      paramNames,
    });
  }

  get(p: string, h: Handler) { this.add("GET", p, h); }
  post(p: string, h: Handler) { this.add("POST", p, h); }
  del(p: string, h: Handler) { this.add("DELETE", p, h); }

  async dispatch(req: Request): Promise<Response | null> {
    const url = new URL(req.url);
    const path = url.pathname.replace(/\/$/, "") || "/";
    for (const r of this.routes) {
      if (r.method !== req.method) continue;
      const m = path.match(r.regex);
      if (!m) continue;
      const params: RouteParams = {};
      r.paramNames.forEach((n, i) => { params[n] = decodeURIComponent(m[i + 1] ?? ""); });
      return r.handler(req, params);
    }
    return null;
  }
}

export function json(data: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...extra },
  });
}

export function errorResponse(status: number, message: string, details?: Record<string, unknown>): Response {
  return json({ error: message, ...details }, status);
}

export function noContent(): Response {
  return new Response(null, { status: 204 });
}
