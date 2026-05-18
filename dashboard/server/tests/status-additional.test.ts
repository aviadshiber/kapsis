import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile, unlink } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { StatusStore } from "../src/store/status";

const fixture = (over: Record<string, unknown> = {}) => JSON.stringify({
  version: "1.0", agent_id: "abc123", project: "demo",
  branch: "main", sandbox_mode: "overlay", phase: "running", progress: 50,
  message: "running", gist: null, gist_updated_at: null,
  started_at: "2026-05-17T10:00:00Z", updated_at: "2026-05-17T10:01:00Z",
  exit_code: null, error: null, worktree_path: null, pr_url: null,
  push_status: null, local_commit: null, remote_commit: null,
  push_fallback_command: null, commit_status: null, commit_sha: null,
  uncommitted_files: 0, heartbeat_at: null, error_type: null,
  ...over,
});

describe("StatusStore — gap coverage", () => {
  let dir: string;
  let store: StatusStore;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-status2-"));
    await mkdir(dir, { recursive: true });
  });

  afterEach(async () => {
    store?.close();
    await rm(dir, { recursive: true, force: true });
  });

  it("silently drops malformed JSON without polluting the cache", async () => {
    await writeFile(join(dir, "kapsis-demo-bad1.json"), "{ this is not valid");
    await writeFile(join(dir, "kapsis-demo-good1.json"), fixture({ agent_id: "good1" }));
    store = new StatusStore(dir);
    await store.init();
    const list = store.list();
    expect(list.length).toBe(1);
    expect(list[0]!.agent_id).toBe("good1");
    expect(store.get("good1")).toBeDefined();
  });

  it("notifies listeners with null when a file is deleted (after grace period)", async () => {
    const path = join(dir, "kapsis-demo-drop1.json");
    await writeFile(path, fixture({ agent_id: "drop1" }));
    store = new StatusStore(dir);
    await store.init();

    const drops: string[] = [];
    store.onChange((s, file) => { if (s === null) drops.push(file); });

    await unlink(path);
    // Poll until the drop fires or 4000 ms elapse.  fs.watch on macOS can
    // take several seconds to deliver the first event under test load
    // (per status.test.ts comment and CI evidence).  80 × 50 ms = 4000 ms
    // matches the budget used by the write-event test in status.test.ts.
    for (let i = 0; i < 80 && !drops.includes("kapsis-demo-drop1.json"); i++) {
      await Bun.sleep(50);
    }
    expect(drops).toContain("kapsis-demo-drop1.json");
    expect(store.get("drop1")).toBeUndefined();
  });

  it("get(agentId) is O(1) via the secondary index (sanity check it returns)", async () => {
    for (let i = 0; i < 100; i++) {
      await writeFile(join(dir, `kapsis-demo-id${i}.json`), fixture({ agent_id: `id${i}` }));
    }
    store = new StatusStore(dir);
    await store.init();
    expect(store.get("id42")?.agent_id).toBe("id42");
    expect(store.get("nope")).toBeUndefined();
  });
});
