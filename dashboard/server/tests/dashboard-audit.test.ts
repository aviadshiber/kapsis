import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { DashboardAuditWriter } from "../src/control/audit-writer";

describe("DashboardAuditWriter", () => {
  let dir: string;
  let file: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-dash-"));
    file = join(dir, "dashboard.jsonl");
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("writes a hash-chained sequence", async () => {
    const w = new DashboardAuditWriter(file);
    const a = await w.record("dashboard", "kill", "agent:abc", { signal: "TERM" });
    const b = await w.record("dashboard", "cleanup-execute", "targets:logs", { exitCode: 0 });
    expect(a.seq).toBe(0);
    expect(b.seq).toBe(1);
    expect(b.prev_hash).toBe(a.hash);

    const text = await readFile(file, "utf8");
    const lines = text.split("\n").filter(Boolean);
    expect(lines.length).toBe(2);
    const aParsed = JSON.parse(lines[0]!);
    expect(aParsed.hash).toBe(a.hash);
  });

  it("recovers the chain across restart", async () => {
    const w1 = new DashboardAuditWriter(file);
    const a = await w1.record("dashboard", "x", "y", {});
    const w2 = new DashboardAuditWriter(file);
    const b = await w2.record("dashboard", "x", "y", {});
    expect(b.seq).toBe(1);
    expect(b.prev_hash).toBe(a.hash);
  });

  it("hash matches the same formula used by readers", async () => {
    const w = new DashboardAuditWriter(file);
    const ev = await w.record("dashboard", "kill", "agent:abc", { signal: "TERM" });
    const input = `${ev.prev_hash}${ev.seq}${ev.timestamp}${ev.actor}${ev.action}${ev.target}${JSON.stringify(ev.detail)}`;
    const expected = createHash("sha256").update(input).digest("hex");
    expect(ev.hash).toBe(expected);
  });
});
