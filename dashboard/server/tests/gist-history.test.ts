import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { StatusStore } from "../src/store/status";
import { GistHistoryStore } from "../src/store/gist-history";
import { SseBroker } from "../src/sse";
import type { AgentStatus } from "../src/types";

const ISO = (offsetMs = 0): string =>
  new Date(Date.now() + offsetMs).toISOString().replace(/\.\d{3}Z$/, "Z");

function statusFixture(overrides: Partial<AgentStatus> = {}): AgentStatus {
  return {
    version: "1.0",
    agent_id: "abc123",
    project: "demo",
    branch: "main",
    sandbox_mode: "worktree",
    phase: "running",
    progress: 50,
    message: "running",
    gist: null,
    gist_updated_at: null,
    started_at: ISO(),
    updated_at: ISO(),
    exit_code: null,
    error: null,
    worktree_path: null,
    pr_url: null,
    push_status: null,
    local_commit: null,
    remote_commit: null,
    push_fallback_command: null,
    commit_status: null,
    commit_sha: null,
    uncommitted_files: 0,
    heartbeat_at: null,
    error_type: null,
    machine_provider: null,
    ...overrides,
  };
}

interface Env {
  root: string;
  status: StatusStore;
  sse: SseBroker;
  cleanup: () => Promise<void>;
}

async function setupEnv(): Promise<Env> {
  const root = await mkdtemp(join(tmpdir(), "gist-test-"));
  const statusDir = join(root, "status");
  await mkdir(statusDir);
  const status = new StatusStore(statusDir);
  await status.init();
  const sse = new SseBroker(60_000);
  return {
    root, status, sse,
    cleanup: async () => {
      sse.close();
      status.close();
      await rm(root, { recursive: true, force: true });
    },
  };
}

describe("GistHistoryStore.ingest", () => {
  let env: Env;
  beforeEach(async () => { env = await setupEnv(); });
  afterEach(async () => { await env.cleanup(); });

  it("appends on first gist value", () => {
    const h = new GistHistoryStore(env.status, env.sse);
    const ts = ISO();
    const entry = h.ingest(statusFixture({ gist: "Reading file", gist_updated_at: ts }));
    expect(entry).toEqual({ at: ts, gist: "Reading file" });
    expect(h.get("abc123")).toEqual([{ at: ts, gist: "Reading file" }]);
  });

  it("dedups identical consecutive gists", () => {
    const h = new GistHistoryStore(env.status, env.sse);
    const ts1 = ISO();
    const ts2 = ISO(1000);
    expect(h.ingest(statusFixture({ gist: "Reading file", gist_updated_at: ts1 }))).not.toBeNull();
    expect(h.ingest(statusFixture({ gist: "Reading file", gist_updated_at: ts2 }))).toBeNull();
    expect(h.get("abc123")).toHaveLength(1);
  });

  it("appends when gist text changes", () => {
    const h = new GistHistoryStore(env.status, env.sse);
    h.ingest(statusFixture({ gist: "Reading file", gist_updated_at: ISO() }));
    h.ingest(statusFixture({ gist: "Running tests", gist_updated_at: ISO(1000) }));
    const entries = h.get("abc123");
    expect(entries).toHaveLength(2);
    // Newest first.
    expect(entries[0]!.gist).toBe("Running tests");
    expect(entries[1]!.gist).toBe("Reading file");
  });

  it("ignores null/empty gist values", () => {
    const h = new GistHistoryStore(env.status, env.sse);
    expect(h.ingest(statusFixture({ gist: null, gist_updated_at: ISO() }))).toBeNull();
    expect(h.ingest(statusFixture({ gist: "", gist_updated_at: ISO() }))).toBeNull();
    expect(h.get("abc123")).toEqual([]);
  });

  it("evicts oldest entries when ring fills (LRU by insertion order)", () => {
    const h = new GistHistoryStore(env.status, env.sse, 3);
    for (let i = 1; i <= 5; i++) {
      h.ingest(statusFixture({ gist: `gist-${i}`, gist_updated_at: ISO(i * 1000) }));
    }
    const entries = h.get("abc123");
    expect(entries).toHaveLength(3);
    // Newest at index 0.
    expect(entries.map((e) => e.gist)).toEqual(["gist-5", "gist-4", "gist-3"]);
  });

  it("tracks history per-agent independently", () => {
    const h = new GistHistoryStore(env.status, env.sse);
    h.ingest(statusFixture({ agent_id: "agent1", gist: "A1 task", gist_updated_at: ISO() }));
    h.ingest(statusFixture({ agent_id: "agent2", gist: "A2 task", gist_updated_at: ISO() }));
    expect(h.get("agent1").map((e) => e.gist)).toEqual(["A1 task"]);
    expect(h.get("agent2").map((e) => e.gist)).toEqual(["A2 task"]);
  });

  it("falls back to status.updated_at when gist_updated_at is null", () => {
    const h = new GistHistoryStore(env.status, env.sse);
    const at = ISO();
    h.ingest(statusFixture({ gist: "Some activity", gist_updated_at: null, updated_at: at }));
    expect(h.get("abc123")).toEqual([{ at, gist: "Some activity" }]);
  });
});

describe("GistHistoryStore.drop", () => {
  let env: Env;
  beforeEach(async () => { env = await setupEnv(); });
  afterEach(async () => { await env.cleanup(); });

  it("clears history and lastSeen for the agent", () => {
    const h = new GistHistoryStore(env.status, env.sse);
    h.ingest(statusFixture({ gist: "Step 1", gist_updated_at: ISO() }));
    expect(h.get("abc123")).toHaveLength(1);

    h.drop("abc123");
    expect(h.get("abc123")).toEqual([]);

    // After drop, lastSeen is cleared too — same gist text re-appends.
    h.ingest(statusFixture({ gist: "Step 1", gist_updated_at: ISO() }));
    expect(h.get("abc123")).toHaveLength(1);
  });
});

describe("GistHistoryStore.init from StatusStore", () => {
  let env: Env;
  beforeEach(async () => { env = await setupEnv(); });
  afterEach(async () => { await env.cleanup(); });

  it("seeds existing statuses on init", async () => {
    // Pre-write a status with a gist BEFORE init.
    const path = join(env.root, "status", "kapsis-demo-zzz999.json");
    await writeFile(path, JSON.stringify(statusFixture({
      agent_id: "zzz999", project: "demo", gist: "Pre-existing activity", gist_updated_at: ISO(),
    })));
    // Re-init StatusStore so it picks up the new file.
    const status2 = new StatusStore(join(env.root, "status"));
    await status2.init();
    try {
      const h = new GistHistoryStore(status2, env.sse);
      h.init();
      expect(h.get("zzz999").map((e) => e.gist)).toEqual(["Pre-existing activity"]);
      h.close();
    } finally {
      status2.close();
    }
  });

  it("appends on subsequent StatusStore change events", async () => {
    const h = new GistHistoryStore(env.status, env.sse);
    h.init();
    const path = join(env.root, "status", "kapsis-demo-qqq111.json");
    await writeFile(path, JSON.stringify(statusFixture({
      agent_id: "qqq111", project: "demo", gist: "First", gist_updated_at: ISO(),
    })));
    // Wait for debounce + watch + propagate. fs.watch delivery on macOS can
    // exceed bun's 5s default test timeout under CI load, so poll longer and
    // give the test an explicit timeout.
    for (let i = 0; i < 240; i++) {
      if (h.get("qqq111").length > 0) break;
      await Bun.sleep(50);
    }
    expect(h.get("qqq111").map((e) => e.gist)).toEqual(["First"]);
    h.close();
  }, 20000);
});

describe("GistHistoryStore SSE publication", () => {
  let env: Env;
  beforeEach(async () => { env = await setupEnv(); });
  afterEach(async () => { await env.cleanup(); });

  it("publishes gist-appended events to the per-agent topic", () => {
    const published: Array<{ topic: string; ev: { event?: string; data: unknown } }> = [];
    const fakeSse = {
      publish: (topic: string, ev: { event?: string; data: unknown }) => {
        published.push({ topic, ev });
      },
    } as unknown as SseBroker;
    const h = new GistHistoryStore(env.status, fakeSse);
    h.ingest(statusFixture({ gist: "Step 1", gist_updated_at: ISO() }));
    expect(published).toHaveLength(1);
    expect(published[0]!.topic).toBe("gist-history:abc123");
    expect(published[0]!.ev.event).toBe("gist-appended");
  });

  it("does not publish when ingest dedups", () => {
    const published: Array<{ topic: string; ev: { event?: string; data: unknown } }> = [];
    const fakeSse = {
      publish: (topic: string, ev: { event?: string; data: unknown }) => {
        published.push({ topic, ev });
      },
    } as unknown as SseBroker;
    const h = new GistHistoryStore(env.status, fakeSse);
    h.ingest(statusFixture({ gist: "Step 1", gist_updated_at: ISO() }));
    h.ingest(statusFixture({ gist: "Step 1", gist_updated_at: ISO(1000) }));
    expect(published).toHaveLength(1);
  });
});
