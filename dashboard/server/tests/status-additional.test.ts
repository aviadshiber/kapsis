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
    // fs.watch latency varies a lot on macOS CI runners — FSEvents
    // coalescing has been observed past 1s, and on loaded runners
    // (parallel matrix jobs, virtualized hosts) the delete event has
    // missed the previous 5s window. Underlying happy-path budget is
    // ~300ms (fs.watch) + 50ms (debounce) + 200ms (drop-grace) = ~550ms.
    // Poll for up to 25s so a slow runner doesn't trip the test, and
    // raise the per-test timeout to 30s (the third arg to `it()`) so
    // the poll budget can actually run to completion instead of being
    // truncated at Bun's default 5s test timeout.
    const deadlineMs = Date.now() + 25_000;
    while (!drops.includes("kapsis-demo-drop1.json") && Date.now() < deadlineMs) {
      await Bun.sleep(100);
    }
    expect(drops).toContain("kapsis-demo-drop1.json");
    expect(store.get("drop1")).toBeUndefined();
  }, 30_000);

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
