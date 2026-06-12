import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { StatusStore } from "../src/store/status";

const fixture = (overrides: Partial<Record<string, unknown>> = {}) => JSON.stringify({
  version: "1.0",
  agent_id: "abc123",
  project: "demo",
  branch: "main",
  sandbox_mode: "overlay",
  phase: "running",
  progress: 50,
  message: "running",
  gist: null,
  gist_updated_at: null,
  started_at: "2026-05-17T10:00:00Z",
  updated_at: "2026-05-17T10:01:00Z",
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
  ...overrides,
});

describe("StatusStore", () => {
  let dir: string;
  let store: StatusStore;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-status-"));
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "kapsis-demo-abc123.json"), fixture(), { mode: 0o600 });
    await writeFile(join(dir, "kapsis-demo-zzz999.json"), fixture({ agent_id: "zzz999", project: "demo", phase: "complete", exit_code: 0, started_at: "2026-05-17T09:00:00Z" }));
    store = new StatusStore(dir);
    await store.init();
  });

  afterEach(async () => {
    store.close();
    await rm(dir, { recursive: true, force: true });
  });

  it("lists all statuses sorted newest first", () => {
    const list = store.list();
    expect(list.length).toBe(2);
    expect(list[0]!.agent_id).toBe("abc123");
    expect(list[1]!.agent_id).toBe("zzz999");
  });

  it("looks up by agent id", () => {
    expect(store.get("abc123")?.phase).toBe("running");
    expect(store.get("missing")).toBeUndefined();
  });

  it("invokes onChange when a file is added", async () => {
    const seen: string[] = [];
    store.onChange((s) => { if (s) seen.push(s.agent_id); });
    await writeFile(join(dir, "kapsis-demo-new001.json"), fixture({ agent_id: "new001" }));
    // fs.watch on macOS can take several seconds to deliver the first event
    // under test load (observed >4s on busy CI runners). Generous deadline
    // plus an explicit test timeout to keep the test reliable.
    for (let i = 0; i < 240 && !seen.includes("new001"); i++) await Bun.sleep(50);
    expect(seen).toContain("new001");
  }, 20000);
});
