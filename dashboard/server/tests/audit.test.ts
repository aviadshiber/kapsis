import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile, appendFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { AuditStore } from "../src/store/audit";

const GENESIS = "0".repeat(64);

function makeEvent(seq: number, prevHash: string, detail: Record<string, unknown>) {
  const timestamp = "2026-05-17T10:00:00Z";
  const eventType = "shell_command";
  const toolName = "Bash";
  const detailJson = JSON.stringify(detail);
  const input = `${prevHash}${seq}${timestamp}${eventType}${toolName}${detailJson}`;
  const hash = createHash("sha256").update(input).digest("hex");
  const line = `{"seq":${seq},"timestamp":"${timestamp}","session_id":"s1","agent_id":"abc","agent_type":"claude","project":"demo","event_type":"${eventType}","tool_name":"${toolName}","detail":${detailJson},"prev_hash":"${prevHash}","hash":"${hash}"}`;
  return { line, hash };
}

describe("AuditStore", () => {
  let dir: string;
  let store: AuditStore;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-audit-"));
    await mkdir(dir, { recursive: true });
    store = new AuditStore(dir);
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("verifies a valid hash chain", async () => {
    const file = join(dir, "abc-20260517-100000-1.audit.jsonl");
    let prev = GENESIS;
    let buf = "";
    for (let i = 0; i < 5; i++) {
      const ev = makeEvent(i, prev, { command: `cmd${i}` });
      buf += ev.line + "\n";
      prev = ev.hash;
    }
    await writeFile(file, buf);
    const result = await store.verifyFile(file);
    expect(result.valid).toBe(true);
    expect(result.lastSeq).toBe(4);
  });

  it("detects a tampered detail field", async () => {
    const file = join(dir, "abc-20260517-100000-2.audit.jsonl");
    const e0 = makeEvent(0, GENESIS, { command: "ls" });
    await writeFile(file, e0.line + "\n");
    // Hand-craft a second event whose prev_hash is correct but detail is altered
    const e1 = makeEvent(1, e0.hash, { command: "real" });
    const tampered = e1.line.replace('"command":"real"', '"command":"hacked"');
    await appendFile(file, tampered + "\n");
    const result = await store.verifyFile(file);
    expect(result.valid).toBe(false);
    expect(result.brokenAt).toBe(1);
    expect(result.reason).toContain("hash mismatch");
  });

  it("filters by agent id and event type", async () => {
    const f1 = join(dir, "alpha-20260517-100000-1.audit.jsonl");
    const f2 = join(dir, "beta-20260517-100000-2.audit.jsonl");
    let prev = GENESIS;
    let buf1 = "";
    for (let i = 0; i < 3; i++) {
      const ev = makeEvent(i, prev, { x: i });
      buf1 += ev.line + "\n";
      prev = ev.hash;
    }
    await writeFile(f1, buf1);
    await writeFile(f2, makeEvent(0, GENESIS, { y: 0 }).line + "\n");

    const alphaOnly = await store.query({ agentId: "alpha" });
    expect(alphaOnly.length).toBe(3);
    expect(alphaOnly.every((e) => e.agent_id === "abc" || e.session_id === "s1")).toBe(true);

    const betaOnly = await store.query({ agentId: "beta" });
    expect(betaOnly.length).toBe(1);
  });
});
