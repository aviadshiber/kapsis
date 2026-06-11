import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, writeFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DiskUsageStore, parsePodmanSize } from "../src/store/disk";

describe("parsePodmanSize", () => {
  it.each([
    ["1B", 1],
    ["512B", 512],
    ["1.5kB", Math.round(1.5 * 1024)],
    ["2MB", 2 * 1024 ** 2],
    ["3.2GB", Math.round(3.2 * 1024 ** 3)],
    ["0.5TB", Math.round(0.5 * 1024 ** 4)],
    ["junk", 0],
    ["", 0],
  ] as Array<[string, number]>)("parses %p as %p bytes", (input, want) => {
    expect(parsePodmanSize(input)).toBe(want);
  });
});

describe("DiskUsageStore", () => {
  let root: string;
  let store: DiskUsageStore;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "kd-disk-"));
    for (const d of ["status", "audit", "logs", "conversations", "worktrees", "sandboxes", "sanitized-git", "snapshots"]) {
      await mkdir(join(root, d));
    }
    await writeFile(join(root, "status", "kapsis-p-a.json"), "{}");
    await writeFile(join(root, "logs", "kapsis-a.log"), "hello world\n");
    store = new DiskUsageStore({
      status: join(root, "status"),
      audit: join(root, "audit"),
      logs: join(root, "logs"),
      conversations: join(root, "conversations"),
      worktrees: join(root, "worktrees"),
      sandboxes: join(root, "sandboxes"),
      sanitizedGit: join(root, "sanitized-git"),
      snapshots: join(root, "snapshots"),
      specs: join(root, "specs"),
      dashboardAudit: join(root, "audit", "dashboard.jsonl"),
    });
  });

  afterEach(async () => { await rm(root, { recursive: true, force: true }); });

  it("aggregates sizes across categories", async () => {
    const entries = await store.snapshot();
    const status = entries.find((e) => e.category === "status")!;
    expect(status.items).toBe(1);
    expect(status.bytes).toBeGreaterThan(0);
    const logs = entries.find((e) => e.category === "logs")!;
    expect(logs.items).toBe(1);
    expect(logs.bytes).toBe(12);
  });

  it("caches the snapshot and returns the same array within the TTL", async () => {
    const a = await store.snapshot();
    await writeFile(join(root, "logs", "kapsis-b.log"), "x");
    const b = await store.snapshot();
    // Same reference — proves we hit the cache.
    expect(b).toBe(a);
  });

  it("invalidate() forces a fresh scan", async () => {
    const a = await store.snapshot();
    await writeFile(join(root, "logs", "kapsis-b.log"), "x");
    store.invalidate();
    const b = await store.snapshot();
    const aLogs = a.find((e) => e.category === "logs")!;
    const bLogs = b.find((e) => e.category === "logs")!;
    expect(bLogs.items).toBe(aLogs.items + 1);
  });

  it("does NOT follow symlinks into other directories", async () => {
    // Plant a symlink in worktrees that points back to the OS tmpdir.
    // Without lstat, dirSize would walk into tmp and either time out or
    // wildly over-report bytes.
    await symlink(tmpdir(), join(root, "worktrees", "escape"));
    store.invalidate();
    const entries = await store.snapshot();
    const wt = entries.find((e) => e.category === "worktrees")!;
    // Symlink itself is not counted as a file, and we don't descend through it.
    expect(wt.items).toBe(0);
    expect(wt.bytes).toBe(0);
  });
});
