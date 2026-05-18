import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../src/server";
import { generateToken } from "../src/auth";
import type { DashboardConfig } from "../src/config";
import { StatusStore } from "../src/store/status";
import { AuditStore } from "../src/store/audit";
import { LogStore } from "../src/store/logs";
import { ConversationStore } from "../src/store/conversations";
import { DiskUsageStore } from "../src/store/disk";
import { DashboardAuditWriter } from "../src/control/audit-writer";
import { SseBroker } from "../src/sse";
import { EphemeralTokenStore } from "../src/sse-tokens";
import { CleanupRunner } from "../src/control/cleanup";

interface Harness {
  url: string;
  token: string;
  stop: () => void;
}

async function spawnHarness(opts: { readOnly?: boolean } = {}): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "kd-srv-"));
  for (const d of ["status", "audit", "logs", "conversations", "worktrees", "sandboxes", "sanitized-git"]) {
    await mkdir(join(root, d));
  }
  const token = generateToken();
  const config: DashboardConfig = {
    host: "127.0.0.1",
    port: 0,
    kapsisHome: root,
    readOnly: opts.readOnly ?? false,
    open: false,
    token,
    uiDistDir: null,
  };
  const paths = {
    status: join(root, "status"),
    audit: join(root, "audit"),
    logs: join(root, "logs"),
    conversations: join(root, "conversations"),
    worktrees: join(root, "worktrees"),
    sandboxes: join(root, "sandboxes"),
    sanitizedGit: join(root, "sanitized-git"),
    dashboardAudit: join(root, "audit", "dashboard.jsonl"),
  };
  const status = new StatusStore(paths.status); await status.init();
  const audit = new AuditStore(paths.audit);
  const logsS = new LogStore(paths.logs);
  const conv = new ConversationStore(paths.conversations);
  const disk = new DiskUsageStore(paths);
  const dashAudit = new DashboardAuditWriter(paths.dashboardAudit); await dashAudit.init();
  const sse = new SseBroker(60_000);
  const sseTokens = new EphemeralTokenStore();
  const cleanupRunner = new CleanupRunner();

  const server = startServer(config, {
    status, audit, logs: logsS, conv, disk, sse, dashAudit, sseTokens, cleanupRunner,
    cleanupScript: join(root, "nonexistent-cleanup.sh"),
    version: "test",
  });
  const url = `http://127.0.0.1:${server.port}`;
  return {
    url,
    token,
    stop: () => {
      sse.close();
      sseTokens.close();
      status.close();
      server.stop(true);
      void rm(root, { recursive: true, force: true });
    },
  };
}

describe("server integration", () => {
  let h: Harness;

  beforeEach(async () => { h = await spawnHarness(); });
  afterEach(() => { h.stop(); });

  it("/healthz is public", async () => {
    const r = await fetch(`${h.url}/healthz`);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true });
  });

  it("/api/v1/version is public", async () => {
    const r = await fetch(`${h.url}/api/v1/version`);
    expect(r.status).toBe(200);
  });

  it("/api/v1/agents requires Authorization header", async () => {
    expect((await fetch(`${h.url}/api/v1/agents`)).status).toBe(401);
    const ok = await fetch(`${h.url}/api/v1/agents`, { headers: { Authorization: `Bearer ${h.token}` } });
    expect(ok.status).toBe(200);
  });

  it("does NOT accept the bearer in a query parameter (closes a security gap)", async () => {
    // Even though the token is valid, the bearer must travel in the header.
    const r = await fetch(`${h.url}/api/v1/agents?token=${encodeURIComponent(h.token)}`);
    expect(r.status).toBe(401);
  });

  it("emits security headers on every response", async () => {
    const r = await fetch(`${h.url}/healthz`);
    expect(r.headers.get("x-frame-options")).toBe("DENY");
    expect(r.headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
    expect(r.headers.get("referrer-policy")).toBe("no-referrer");
    expect(r.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("SSE refuses connection without an ephemeral token", async () => {
    const r = await fetch(`${h.url}/sse/agents`);
    expect(r.status).toBe(401);
  });

  it("SSE accepts a one-shot ephemeral token; second use fails", async () => {
    const minted = await fetch(`${h.url}/api/v1/sse-token`, {
      method: "POST",
      headers: { Authorization: `Bearer ${h.token}` },
    });
    expect(minted.status).toBe(200);
    const { token: ephem } = (await minted.json()) as { token: string };

    const ok = await fetch(`${h.url}/sse/agents?t=${encodeURIComponent(ephem)}`);
    expect(ok.status).toBe(200);
    expect(ok.headers.get("content-type")).toBe("text/event-stream");
    await ok.body!.cancel();

    // Second attempt with the same ephemeral must be rejected (one-shot).
    const reuse = await fetch(`${h.url}/sse/agents?t=${encodeURIComponent(ephem)}`);
    expect(reuse.status).toBe(401);
  });

  it("kill endpoint validates agent id (400 for malformed)", async () => {
    const r = await fetch(`${h.url}/api/v1/agents/..%2Fbad/kill`, {
      method: "POST",
      headers: { Authorization: `Bearer ${h.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(r.status).toBe(400);
  });

  it("read-only mode: kill returns 403", async () => {
    h.stop();
    h = await spawnHarness({ readOnly: true });
    const r = await fetch(`${h.url}/api/v1/agents/abc/kill`, {
      method: "POST",
      headers: { Authorization: `Bearer ${h.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(r.status).toBe(403);
  });

  it("read-only mode: cleanup returns 403", async () => {
    h.stop();
    h = await spawnHarness({ readOnly: true });
    const r = await fetch(`${h.url}/api/v1/maintenance/cleanup`, {
      method: "POST",
      headers: { Authorization: `Bearer ${h.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ targets: ["status"], dryRun: true }),
    });
    expect(r.status).toBe(403);
  });

  it("CORS preflight is denied (no allow-origin returned)", async () => {
    const r = await fetch(`${h.url}/api/v1/agents`, { method: "OPTIONS" });
    expect(r.status).toBe(204);
    expect(r.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("seeds the status store with files written before init", async () => {
    h.stop();
    // Pre-write a status file, then boot.
    const root = await mkdtemp(join(tmpdir(), "kd-srv-seed-"));
    for (const d of ["status", "audit", "logs", "conversations", "worktrees", "sandboxes", "sanitized-git"]) {
      await mkdir(join(root, d));
    }
    const fixture = {
      version: "1.0", agent_id: "seeded", project: "demo",
      branch: null, sandbox_mode: "overlay", phase: "complete", progress: 100,
      message: "ok", gist: null, gist_updated_at: null,
      started_at: "2026-05-17T10:00:00Z", updated_at: "2026-05-17T10:01:00Z",
      exit_code: 0, error: null, worktree_path: null, pr_url: null,
      push_status: null, local_commit: null, remote_commit: null,
      push_fallback_command: null, commit_status: "no_changes", commit_sha: null,
      uncommitted_files: 0, heartbeat_at: null, error_type: null,
    };
    await writeFile(join(root, "status", "kapsis-demo-seeded.json"), JSON.stringify(fixture));

    process.env.KAPSIS_HOME_DIR = root; // not used by harness but harmless
    const token = generateToken();
    const paths = {
      status: join(root, "status"),
      audit: join(root, "audit"),
      logs: join(root, "logs"),
      conversations: join(root, "conversations"),
      worktrees: join(root, "worktrees"),
      sandboxes: join(root, "sandboxes"),
      sanitizedGit: join(root, "sanitized-git"),
      dashboardAudit: join(root, "audit", "dashboard.jsonl"),
    };
    const status = new StatusStore(paths.status); await status.init();
    const audit = new AuditStore(paths.audit);
    const logsS = new LogStore(paths.logs);
    const conv = new ConversationStore(paths.conversations);
    const disk = new DiskUsageStore(paths);
    const dashAudit = new DashboardAuditWriter(paths.dashboardAudit); await dashAudit.init();
    const sse = new SseBroker(60_000);
    const sseTokens = new EphemeralTokenStore();
    const cleanupRunner = new CleanupRunner();
    const config: DashboardConfig = {
      host: "127.0.0.1", port: 0, kapsisHome: root,
      readOnly: false, open: false, token, uiDistDir: null,
    };
    const server = startServer(config, {
      status, audit, logs: logsS, conv, disk, sse, dashAudit, sseTokens, cleanupRunner,
      cleanupScript: join(root, "nope.sh"), version: "test",
    });
    const url = `http://127.0.0.1:${server.port}`;
    const r = await fetch(`${url}/api/v1/agents`, { headers: { Authorization: `Bearer ${token}` } });
    expect(r.status).toBe(200);
    const body = (await r.json()) as { agents: Array<{ agent_id: string }> };
    expect(body.agents.find((a) => a.agent_id === "seeded")).toBeDefined();

    sse.close();
    sseTokens.close();
    status.close();
    server.stop(true);
    await rm(root, { recursive: true, force: true });
  });
});
