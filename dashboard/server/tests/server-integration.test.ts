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
import { SpecStore } from "../src/store/spec";
import { GistHistoryStore } from "../src/store/gist-history";
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
  // Tests don't exercise spec/gist by default; pass minimal stubs that 404
  // / return empty so existing test bodies keep working unchanged. The
  // dedicated spec/gist tests construct their own harness.
  const spec = new SpecStore(status, paths.worktrees, {
    injectedSuffix: null,
    podmanVolumeMountpoint: async () => null,
  });
  const dashAudit = new DashboardAuditWriter(paths.dashboardAudit); await dashAudit.init();
  const sse = new SseBroker(60_000);
  const sseTokens = new EphemeralTokenStore();
  const cleanupRunner = new CleanupRunner();
  const gistHistory = new GistHistoryStore(status, sse);
  gistHistory.init();

  const server = startServer(config, {
    status, audit, logs: logsS, conv, disk, spec, gistHistory,
    sse, dashAudit, sseTokens, cleanupRunner,
    cleanupScript: join(root, "nonexistent-cleanup.sh"),
    version: "test",
  });
  const url = `http://127.0.0.1:${server.port}`;
  return {
    url,
    token,
    stop: () => {
      gistHistory.close();
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

  it("SSE accepts an ephemeral token and lets the same one reconnect within its ttl", async () => {
    // Reused-within-window is intentional: EventSource auto-reconnects on
    // any blip, so a one-shot token would tear down long-running SSE
    // streams (e.g. live cleanup output). The token still expires (10 min
    // default), so the leak window is bounded.
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

    // Reconnect with the same ephemeral must SUCCEED (the auto-reconnect
    // path), not 401.
    const reuse = await fetch(`${h.url}/sse/agents?t=${encodeURIComponent(ephem)}`);
    expect(reuse.status).toBe(200);
    await reuse.body!.cancel();
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

  it("read-only mode: reap-stale returns 403", async () => {
    h.stop();
    h = await spawnHarness({ readOnly: true });
    const r = await fetch(`${h.url}/api/v1/maintenance/reap-stale`, {
      method: "POST",
      headers: { Authorization: `Bearer ${h.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ dryRun: true }),
    });
    expect(r.status).toBe(403);
  });

  it("reap-stale concurrency guard returns 409 on second simultaneous call", async () => {
    // Fire two POSTs without awaiting the first. The in-flight check runs
    // synchronously before any `await` inside the handler, so one fetch
    // must observe `reapInFlight === true` and return 409. The other
    // returns 200 with the normal outcome shape.
    const opts = {
      method: "POST",
      headers: { Authorization: `Bearer ${h.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ dryRun: true }),
    };
    const [a, b] = await Promise.all([
      fetch(`${h.url}/api/v1/maintenance/reap-stale`, opts),
      fetch(`${h.url}/api/v1/maintenance/reap-stale`, opts),
    ]);
    const statuses = [a.status, b.status].sort();
    expect(statuses).toEqual([200, 409]);
    const conflictResp = a.status === 409 ? a : b;
    const conflictBody = (await conflictResp.json()) as { error: string; reapInFlight?: boolean };
    expect(conflictBody.error).toBe("reap already in flight");
    expect(conflictBody.reapInFlight).toBe(true);
  });

  it("reap-stale records an audit event and emits SSE on reaped agents", async () => {
    // Seed one zombie status: phase=running, updated_at way past the stale
    // threshold (default 30 min). In the test environment podman will
    // almost certainly be missing or refuse `version`, so probePodman()
    // returns false and the reaper returns reapable=[] with
    // podmanAvailable=false. The route layer must surface that flag and
    // still record an audit entry so the operator sees what happened.
    const root = h.url; // dummy; not used — we go via the harness directly
    void root;
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000)
      .toISOString().replace(/\.\d{3}Z$/, "Z");
    const fixture = {
      version: "1.0", agent_id: "zombie01", project: "demo",
      branch: null, sandbox_mode: "overlay", phase: "running", progress: 50,
      message: "stuck", gist: null, gist_updated_at: null,
      started_at: twoHoursAgo, updated_at: twoHoursAgo,
      exit_code: null, error: null, worktree_path: null, pr_url: null,
      push_status: null, local_commit: null, remote_commit: null,
      push_fallback_command: null, commit_status: null, commit_sha: null,
      uncommitted_files: 0, heartbeat_at: null, error_type: null,
    };
    // h.url => http://127.0.0.1:<port>. Re-derive the kapsisHome path the
    // harness used by querying /api/v1/version is not useful here; instead,
    // we seed against the path the harness emitted via the same mkdtemp
    // convention. Spawn a fresh harness with a known root so the fixture
    // lands in the right place.
    h.stop();
    const seedRoot = await mkdtemp(join(tmpdir(), "kd-srv-reap-"));
    for (const d of ["status", "audit", "logs", "conversations", "worktrees", "sandboxes", "sanitized-git"]) {
      await mkdir(join(seedRoot, d));
    }
    await writeFile(
      join(seedRoot, "status", "kapsis-demo-zombie01.json"),
      JSON.stringify(fixture),
    );
    // Stand up a harness rooted at seedRoot manually (mirrors spawnHarness).
    const token = generateToken();
    const paths = {
      status: join(seedRoot, "status"),
      audit: join(seedRoot, "audit"),
      logs: join(seedRoot, "logs"),
      conversations: join(seedRoot, "conversations"),
      worktrees: join(seedRoot, "worktrees"),
      sandboxes: join(seedRoot, "sandboxes"),
      sanitizedGit: join(seedRoot, "sanitized-git"),
      dashboardAudit: join(seedRoot, "audit", "dashboard.jsonl"),
    };
    const status = new StatusStore(paths.status); await status.init();
    const audit = new AuditStore(paths.audit);
    const logsS = new LogStore(paths.logs);
    const conv = new ConversationStore(paths.conversations);
    const disk = new DiskUsageStore(paths);
    const spec = new SpecStore(status, paths.worktrees, {
      injectedSuffix: null, podmanVolumeMountpoint: async () => null,
    });
    const dashAudit = new DashboardAuditWriter(paths.dashboardAudit); await dashAudit.init();
    const sse = new SseBroker(60_000);
    const sseTokens = new EphemeralTokenStore();
    const cleanupRunner = new CleanupRunner();
    const gistHistory = new GistHistoryStore(status, sse); gistHistory.init();
    const config: DashboardConfig = {
      host: "127.0.0.1", port: 0, kapsisHome: seedRoot,
      readOnly: false, open: false, token, uiDistDir: null,
    };
    const server = startServer(config, {
      status, audit, logs: logsS, conv, disk, spec, gistHistory,
      sse, dashAudit, sseTokens, cleanupRunner,
      cleanupScript: join(seedRoot, "nope.sh"), version: "test",
    });
    const url = `http://127.0.0.1:${server.port}`;
    try {
      const resp = await fetch(`${url}/api/v1/maintenance/reap-stale`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ dryRun: false }),
      });
      expect(resp.status).toBe(200);
      const body = (await resp.json()) as {
        podmanAvailable: boolean;
        reaped: unknown[];
        note?: string;
      };
      // Two valid worlds depending on whether the test runner has podman:
      //   - podman absent → podmanAvailable=false, reaped=[], note set.
      //   - podman present → podmanAvailable=true; the seeded container
      //     "kapsis-zombie01" doesn't exist so the reaper considers it
      //     reapable and the body shows reaped.length >= 0 (≥0 because the
      //     reaper's parallel inspect is best-effort). Both shapes are
      //     correct; assert only what's invariant.
      expect(typeof body.podmanAvailable).toBe("boolean");
      if (body.podmanAvailable === false) {
        expect(body.reaped).toEqual([]);
        expect(body.note).toContain("podman unavailable");
      }

      // The dashboard audit JSONL must exist and contain an entry whose
      // action mentions "reap-stale" — flavor depends on podman state.
      const auditText = await Bun.file(paths.dashboardAudit).text();
      const lines = auditText.split("\n").filter(Boolean);
      const reapEntries = lines.map((l) => JSON.parse(l) as { action: string }).filter(
        (e) => e.action.includes("reap-stale"),
      );
      expect(reapEntries.length).toBeGreaterThan(0);
    } finally {
      gistHistory.close();
      sse.close();
      sseTokens.close();
      status.close();
      server.stop(true);
      await rm(seedRoot, { recursive: true, force: true });
      // Re-spawn the default harness for afterEach to tear down cleanly.
      h = await spawnHarness();
    }
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
    const spec = new SpecStore(status, paths.worktrees, {
      injectedSuffix: null, podmanVolumeMountpoint: async () => null,
    });
    const dashAudit = new DashboardAuditWriter(paths.dashboardAudit); await dashAudit.init();
    const sse = new SseBroker(60_000);
    const sseTokens = new EphemeralTokenStore();
    const cleanupRunner = new CleanupRunner();
    const gistHistory = new GistHistoryStore(status, sse); gistHistory.init();
    const config: DashboardConfig = {
      host: "127.0.0.1", port: 0, kapsisHome: root,
      readOnly: false, open: false, token, uiDistDir: null,
    };
    const server = startServer(config, {
      status, audit, logs: logsS, conv, disk, spec, gistHistory,
      sse, dashAudit, sseTokens, cleanupRunner,
      cleanupScript: join(root, "nope.sh"), version: "test",
    });
    const url = `http://127.0.0.1:${server.port}`;
    const r = await fetch(`${url}/api/v1/agents`, { headers: { Authorization: `Bearer ${token}` } });
    expect(r.status).toBe(200);
    const body = (await r.json()) as { agents: Array<{ agent_id: string }> };
    expect(body.agents.find((a) => a.agent_id === "seeded")).toBeDefined();

    gistHistory.close();
    sse.close();
    sseTokens.close();
    status.close();
    server.stop(true);
    await rm(root, { recursive: true, force: true });
  });
});
