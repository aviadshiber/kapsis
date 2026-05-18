import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, rm, appendFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DashboardAuditWriter } from "../src/control/audit-writer";

describe("DashboardAuditWriter — concurrency and chain recovery", () => {
  let dir: string;
  let file: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-dash2-"));
    file = join(dir, "dashboard.jsonl");
  });

  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  it("serializes concurrent record() calls into a contiguous chain", async () => {
    const w = new DashboardAuditWriter(file);
    const results = await Promise.all([
      w.record("dashboard", "a", "t", { i: 0 }),
      w.record("dashboard", "a", "t", { i: 1 }),
      w.record("dashboard", "a", "t", { i: 2 }),
      w.record("dashboard", "a", "t", { i: 3 }),
      w.record("dashboard", "a", "t", { i: 4 }),
    ]);
    expect(results.map((r) => r.seq)).toEqual([0, 1, 2, 3, 4]);
    for (let i = 1; i < results.length; i++) {
      expect(results[i]!.prev_hash).toBe(results[i - 1]!.hash);
    }
  });

  it("detects a broken chain on init and continues with a chain-break sentinel", async () => {
    const w = new DashboardAuditWriter(file);
    await w.record("dashboard", "x", "y", { ok: true });
    // Tamper: change the detail of the existing record so the hash no
    // longer matches.
    const text = await Bun.file(file).text();
    const tampered = text.replace('"ok":true', '"ok":false');
    await writeFile(file, tampered);

    const w2 = new DashboardAuditWriter(file);
    await w2.init();
    const stats = w2.stats();
    expect(stats.chainBroken).toBe(true);
    expect(stats.chainBrokenAt).not.toBeNull();

    // The init should have written a chain-break-detected event.
    const after = await Bun.file(file).text();
    expect(after).toContain("chain-break-detected");
  });

  it("concurrent init() calls coalesce", async () => {
    // Pre-seed the file so init does real work.
    const seed = new DashboardAuditWriter(file);
    await seed.record("dashboard", "x", "y", {});
    const w = new DashboardAuditWriter(file);
    await Promise.all([w.init(), w.init(), w.init()]);
    const r = await w.record("dashboard", "x", "y", {});
    expect(r.seq).toBe(1);
  });
});
