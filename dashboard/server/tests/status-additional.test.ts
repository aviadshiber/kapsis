import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile, unlink, symlink } from "node:fs/promises";
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
    // Short reconcile interval so the periodic safety net catches a dropped
    // fs.watch event within the test budget. macOS FSEvents can drop the
    // unlink event entirely under CI load (previous 25s poll on fs.watch
    // alone wasn't reliable). The reconcile loop closes the gap deterministically.
    store = new StatusStore(dir, { reconcileIntervalMs: 250 });
    await store.init();

    const drops: string[] = [];
    store.onChange((s, file) => { if (s === null) drops.push(file); });

    await unlink(path);
    // Wait up to 5s. Budget: fs.watch path (~300ms + 50ms debounce + 200ms
    // grace = ~550ms) or reconcile fallback (≤250ms tick + 200ms grace ≈
    // 450ms). 5s is generous for both paths even on loaded macOS runners.
    const deadlineMs = Date.now() + 5_000;
    while (!drops.includes("kapsis-demo-drop1.json") && Date.now() < deadlineMs) {
      await Bun.sleep(50);
    }
    expect(drops).toContain("kapsis-demo-drop1.json");
    expect(store.get("drop1")).toBeUndefined();
  }, 10_000);

  it("get(agentId) is O(1) via the secondary index (sanity check it returns)", async () => {
    for (let i = 0; i < 100; i++) {
      await writeFile(join(dir, `kapsis-demo-id${i}.json`), fixture({ agent_id: `id${i}` }));
    }
    store = new StatusStore(dir);
    await store.init();
    expect(store.get("id42")?.agent_id).toBe("id42");
    expect(store.get("nope")).toBeUndefined();
  });

  it("reconcile() catches deletes even with fs.watch disabled (safety net path)", async () => {
    // Direct exercise of the reconcile path, independent of any fs.watch
    // event firing. Regression anchor for the periodic safety net we added
    // to handle FSEvents drops on macOS CI runners under load.
    const path = join(dir, "kapsis-demo-orphan.json");
    await writeFile(path, fixture({ agent_id: "orphan" }));
    // reconcileIntervalMs=0 disables the periodic timer so we drive
    // reconcile() manually and prove the contract without depending on
    // wall-clock timing.
    store = new StatusStore(dir, { reconcileIntervalMs: 0 });
    await store.init();
    expect(store.get("orphan")?.agent_id).toBe("orphan");

    const drops: string[] = [];
    store.onChange((s, file) => { if (s === null) drops.push(file); });

    await unlink(path);
    await store.reconcile();
    // dropOneSoon uses a 200ms grace; wait it out deterministically.
    await Bun.sleep(300);

    expect(drops).toContain("kapsis-demo-orphan.json");
    expect(store.get("orphan")).toBeUndefined();
  });

  it("reconcile() picks up files missed by fs.watch (create path)", async () => {
    store = new StatusStore(dir, { reconcileIntervalMs: 0 });
    await store.init();
    expect(store.get("late")).toBeUndefined();

    const updates: string[] = [];
    store.onChange((s, file) => { if (s !== null) updates.push(file); });

    // Write the file AFTER fs.watch has been started, then run reconcile.
    // On a real CI runner where the fs.watch event was dropped, reconcile
    // is what brings the new file into cache.
    await writeFile(join(dir, "kapsis-demo-late.json"), fixture({ agent_id: "late" }));
    await store.reconcile();

    expect(store.get("late")?.agent_id).toBe("late");
    expect(updates).toContain("kapsis-demo-late.json");
  });

  it("reconcile() picks up content updates missed by fs.watch (stale-update path)", async () => {
    // Regression for the gap the previous reconcile design left open: a file
    // already in cache that gets MODIFIED on disk (not created, not deleted),
    // with the fs.watch modify event dropped. Reconcile must notice the new
    // content and notify listeners. Earlier behavior only checked membership
    // (cache.has vs onDisk.has) and silently kept the stale entry.
    const path = join(dir, "kapsis-demo-stale.json");
    await writeFile(path, fixture({ agent_id: "stale", updated_at: "2026-05-17T10:00:00Z" }));
    store = new StatusStore(dir, { reconcileIntervalMs: 0 });
    await store.init();
    expect(store.get("stale")?.updated_at).toBe("2026-05-17T10:00:00Z");

    const updates: { file: string; updated_at: string }[] = [];
    store.onChange((s, file) => {
      if (s !== null) updates.push({ file, updated_at: s.updated_at });
    });

    // Rewrite the file with a newer updated_at. fs.watch may or may not
    // fire; reconcile must catch it either way.
    await writeFile(path, fixture({ agent_id: "stale", updated_at: "2026-05-17T11:00:00Z" }));
    await store.reconcile();

    expect(store.get("stale")?.updated_at).toBe("2026-05-17T11:00:00Z");
    expect(updates.some((u) => u.file === "kapsis-demo-stale.json" && u.updated_at === "2026-05-17T11:00:00Z"))
      .toBe(true);
  });

  it("reconcile() rejects symlinked status files (defense-in-depth parity with reaper)", async () => {
    // A status file replaced with a symlink to another readable file
    // (worst case: /etc/passwd) could leak unrelated content through the
    // dashboard if reads followed the symlink. status files are produced
    // by kapsis via atomic mv, never as symlinks, so the rejection here
    // closes the surface without false positives.
    const target = join(dir, "secret-target");
    await writeFile(target, "ROOT_SECRETS_DO_NOT_LEAK");
    const symPath = join(dir, "kapsis-demo-symlinked.json");
    await symlink(target, symPath);

    store = new StatusStore(dir, { reconcileIntervalMs: 0 });
    await store.init();

    // The symlinked file matches FILE_RE but must NOT be in cache.
    expect(store.get("symlinked")).toBeUndefined();

    // And a reconcile pass must not change that.
    await store.reconcile();
    expect(store.get("symlinked")).toBeUndefined();
  });
});
