import { describe, it, expect } from "bun:test";
import { Router, json, errorResponse } from "../src/http";

function mk(method: string, path: string, opts: RequestInit = {}): Request {
  return new Request(`http://x${path}`, { method, ...opts });
}

describe("Router", () => {
  it("dispatches static GET routes", async () => {
    const r = new Router();
    r.get("/healthz", () => json({ ok: true }));
    const res = await r.dispatch(mk("GET", "/healthz"));
    expect(res).not.toBeNull();
    expect(await res!.json()).toEqual({ ok: true });
  });

  it("extracts a single :param", async () => {
    const r = new Router();
    r.get("/agents/:id", (_req, params) => json({ id: params["id"] }));
    const res = await r.dispatch(mk("GET", "/agents/abc-123"));
    expect(await res!.json()).toEqual({ id: "abc-123" });
  });

  it("extracts multiple :params in order", async () => {
    const r = new Router();
    r.get("/agents/:id/conv/:name", (_req, p) => json({ id: p["id"], name: p["name"] }));
    const res = await r.dispatch(mk("GET", "/agents/aa/conv/transcript.md"));
    expect(await res!.json()).toEqual({ id: "aa", name: "transcript.md" });
  });

  it("URL-decodes params", async () => {
    const r = new Router();
    r.get("/agents/:id", (_req, params) => json({ id: params["id"] }));
    const res = await r.dispatch(mk("GET", "/agents/a%2Fb"));
    expect(await res!.json()).toEqual({ id: "a/b" });
  });

  it("returns null when no route matches", async () => {
    const r = new Router();
    r.get("/healthz", () => json({ ok: true }));
    const res = await r.dispatch(mk("GET", "/missing"));
    expect(res).toBeNull();
  });

  it("distinguishes methods", async () => {
    const r = new Router();
    r.get("/x", () => json({ method: "GET" }));
    r.post("/x", () => json({ method: "POST" }));
    const a = await r.dispatch(mk("GET", "/x"));
    const b = await r.dispatch(mk("POST", "/x"));
    expect(await a!.json()).toEqual({ method: "GET" });
    expect(await b!.json()).toEqual({ method: "POST" });
  });

  it("treats trailing slash as equivalent", async () => {
    const r = new Router();
    r.get("/x", () => json({ ok: true }));
    const res = await r.dispatch(mk("GET", "/x/"));
    expect(res).not.toBeNull();
  });

  it("passes through query string without matching it", async () => {
    const r = new Router();
    r.get("/x", (req) => json({ q: new URL(req.url).searchParams.get("a") }));
    const res = await r.dispatch(mk("GET", "/x?a=1"));
    expect(await res!.json()).toEqual({ q: "1" });
  });

  it("errorResponse returns JSON body", async () => {
    const res = errorResponse(400, "bad", { hint: "ok" });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "bad", hint: "ok" });
  });
});
