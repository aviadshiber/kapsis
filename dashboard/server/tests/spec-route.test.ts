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

async function spawnHarness(opts: { injectedSuffix?: string | null; volumeMountpoint?: string | null } = {}): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "kd-spec-route-"));
  for (const d of ["status", "audit", "logs", "conversations", "worktrees", "sandboxes", "sanitized-git", "specs"]) {
    await mkdir(join(root, d));
  }
  const token = generateToken();
  const config: DashboardConfig = {
    host: "127.0.0.1", port: 0, kapsisHome: root, readOnly: false,
    open: false, token, uiDistDir: null,
  };
  const paths = {
    status: join(root, "status"), audit: join(root, "audit"), logs: join(root, "logs"),
    conversations: join(root, "conversations"), worktrees: join(root, "worktrees"),
    sandboxes: join(root, "sandboxes"), sanitizedGit: join(root, "sanitized-git"), specs: join(root, "specs"),
    dashboardAudit: join(root, "audit", "dashboard.jsonl"),
  };
  const status = new StatusStore(paths.status); await status.init();
  const audit = new AuditStore(paths.audit);
  const logsS = new LogStore(paths.logs);
  const conv = new ConversationStore(paths.conversations);
  const disk = new DiskUsageStore(paths);
  const spec = new SpecStore(status, paths.specs, paths.worktrees, {
    injectedSuffix: opts.injectedSuffix ?? null,
    podmanVolumeMountpoint: async () => opts.volumeMountpoint ?? null,
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
    cleanupScript: join(root, "nonexistent-cleanup.sh"), version: "test",
  });
  return {
    url: `http://127.0.0.1:${server.port}`, token,
    stop: () => {
      gistHistory.close(); sse.close(); sseTokens.close(); status.close();
      server.stop(true);
      void rm(root, { recursive: true, force: true });
    },
  };
}

const ISO = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

function statusJson(project: string, agentId: string, worktreePath: string | null, gist: string | null = null): string {
  return JSON.stringify({
    version: "1.0", agent_id: agentId, project, branch: "main", sandbox_mode: "worktree",
    phase: "running", progress: 50, message: "running", gist, gist_updated_at: gist ? ISO() : null,
    started_at: ISO(), updated_at: ISO(), exit_code: null, error: null,
    worktree_path: worktreePath, pr_url: null, push_status: null,
    local_commit: null, remote_commit: null, push_fallback_command: null,
    commit_status: null, commit_sha: null, uncommitted_files: 0,
    heartbeat_at: null, error_type: null,
  });
}

describe("GET /api/v1/agents/:id/spec", () => {
  let h: Harness;
  afterEach(() => { h?.stop(); });

  it("requires bearer token", async () => {
    h = await spawnHarness();
    const r = await fetch(`${h.url}/api/v1/agents/abc123/spec`);
    expect(r.status).toBe(401);
  });

  it("returns 400 on invalid agent id", async () => {
    h = await spawnHarness();
    const r = await fetch(`${h.url}/api/v1/agents/..%2Fevil/spec`, {
      headers: { Authorization: `Bearer ${h.token}` },
    });
    expect(r.status).toBe(400);
  });

  it("returns 404 when agent is unknown", async () => {
    h = await spawnHarness();
    const r = await fetch(`${h.url}/api/v1/agents/abc123/spec`, {
      headers: { Authorization: `Bearer ${h.token}` },
    });
    expect(r.status).toBe(404);
  });

  // 200-with-real-spec covered by the e2e describe below — it needs access
  // to the tmpdir to seed fixtures, which spawnHarness intentionally hides.
});

describe("GET /api/v1/agents/:id/spec — end-to-end with on-disk fixtures", () => {
  it("returns spec with source=worktree", async () => {
    // We need access to the tmpdir to seed fixtures, so reimplement harness inline.
    const root = await mkdtemp(join(tmpdir(), "kd-spec-e2e-"));
    for (const d of ["status", "audit", "logs", "conversations", "worktrees", "sandboxes", "sanitized-git", "specs"]) {
      await mkdir(join(root, d));
    }
    const token = generateToken();
    const config: DashboardConfig = {
      host: "127.0.0.1", port: 0, kapsisHome: root, readOnly: false,
      open: false, token, uiDistDir: null,
    };
    const paths = {
      status: join(root, "status"), audit: join(root, "audit"), logs: join(root, "logs"),
      conversations: join(root, "conversations"), worktrees: join(root, "worktrees"),
      sandboxes: join(root, "sandboxes"), sanitizedGit: join(root, "sanitized-git"), specs: join(root, "specs"),
      dashboardAudit: join(root, "audit", "dashboard.jsonl"),
    };
    // Seed the worktree spec file before SpecStore is created.
    const wt = join(paths.worktrees, "demo-abc123");
    await mkdir(join(wt, ".kapsis"), { recursive: true });
    const userSpec = "## DEV-42\n\nFix the foo.";
    await writeFile(join(wt, ".kapsis", "task-spec-with-progress.md"), userSpec);
    // Seed status pointing at that worktree.
    await writeFile(join(paths.status, "kapsis-demo-abc123.json"), statusJson("demo", "abc123", wt));

    const status = new StatusStore(paths.status); await status.init();
    const audit = new AuditStore(paths.audit);
    const logsS = new LogStore(paths.logs);
    const conv = new ConversationStore(paths.conversations);
    const disk = new DiskUsageStore(paths);
    const spec = new SpecStore(status, paths.specs, paths.worktrees, {
      injectedSuffix: null, podmanVolumeMountpoint: async () => null,
    });
    const dashAudit = new DashboardAuditWriter(paths.dashboardAudit); await dashAudit.init();
    const sse = new SseBroker(60_000);
    const sseTokens = new EphemeralTokenStore();
    const cleanupRunner = new CleanupRunner();
    const gistHistory = new GistHistoryStore(status, sse); gistHistory.init();
    const server = startServer(config, {
      status, audit, logs: logsS, conv, disk, spec, gistHistory,
      sse, dashAudit, sseTokens, cleanupRunner,
      cleanupScript: join(root, "nonexistent-cleanup.sh"), version: "test",
    });
    try {
      const url = `http://127.0.0.1:${server.port}`;
      const r = await fetch(`${url}/api/v1/agents/abc123/spec`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      expect(r.status).toBe(200);
      const body = (await r.json()) as {
        spec: string; injectedInstructions: string | null;
        source: string; truncated: boolean;
      };
      expect(body.spec).toBe(userSpec);
      expect(body.injectedInstructions).toBeNull();
      expect(body.source).toBe("worktree");
      expect(body.truncated).toBe(false);
    } finally {
      gistHistory.close(); sse.close(); sseTokens.close(); status.close();
      server.stop(true);
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("GET /api/v1/agents/:id/gist-history", () => {
  it("requires bearer", async () => {
    const h = await spawnHarness();
    try {
      const r = await fetch(`${h.url}/api/v1/agents/abc123/gist-history`);
      expect(r.status).toBe(401);
    } finally { h.stop(); }
  });

  it("returns empty array for unknown agent", async () => {
    const h = await spawnHarness();
    try {
      const r = await fetch(`${h.url}/api/v1/agents/abc123/gist-history`, {
        headers: { Authorization: `Bearer ${h.token}` },
      });
      expect(r.status).toBe(200);
      const body = (await r.json()) as { entries: unknown[] };
      expect(body.entries).toEqual([]);
    } finally { h.stop(); }
  });
});
