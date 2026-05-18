import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile, appendFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { AuditStore } from "../src/store/audit";

const GENESIS = "0".repeat(64);

interface EventOpts {
  seq: number;
  prevHash: string;
  detail: Record<string, unknown>;
  agentId?: string;
  sessionId?: string;
  eventType?: string;
  toolName?: string;
}

function makeEvent(opts: EventOpts) {
  const {
    seq, prevHash, detail,
    agentId = "abc",
    sessionId = "s1",
    eventType = "shell_command",
    toolName = "Bash",
  } = opts;
  const timestamp = "2026-05-17T10:00:00Z";
  const detailJson = JSON.stringify(detail);
  const input = `${prevHash}${seq}${timestamp}${eventType}${toolName}${detailJson}`;
  const hash = createHash("sha256").update(input).digest("hex");
  const line = `{"seq":${seq},"timestamp":"${timestamp}","session_id":"${sessionId}","agent_id":"${agentId}","agent_type":"claude","project":"demo","event_type":"${eventType}","tool_name":"${toolName}","detail":${detailJson},"prev_hash":"${prevHash}","hash":"${hash}"}`;
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
      const ev = makeEvent({ seq: i, prevHash: prev, detail: { command: `cmd${i}` } });
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
    const e0 = makeEvent({ seq: 0, prevHash: GENESIS, detail: { command: "ls" } });
    await writeFile(file, e0.line + "\n");
    // Hand-craft a second event whose prev_hash is correct but detail is altered
    const e1 = makeEvent({ seq: 1, prevHash: e0.hash, detail: { command: "real" } });
    const tampered = e1.line.replace('"command":"real"', '"command":"hacked"');
    await appendFile(file, tampered + "\n");
    const result = await store.verifyFile(file);
    expect(result.valid).toBe(false);
    expect(result.brokenAt).toBe(1);
    expect(result.reason).toContain("hash mismatch");
  });

  it("filters by agent id at the file level and inside event bodies", async () => {
    // Each file's events embed the agent id that matches its filename prefix,
    // so the assertion can verify no cross-agent records bleed through.
    const fAlpha = join(dir, "alpha-20260517-100000-1.audit.jsonl");
    const fBeta = join(dir, "beta-20260517-100000-2.audit.jsonl");
    let prevA = GENESIS;
    let bufA = "";
    for (let i = 0; i < 3; i++) {
      const ev = makeEvent({ seq: i, prevHash: prevA, detail: { x: i }, agentId: "alpha", sessionId: "sa" });
      bufA += ev.line + "\n";
      prevA = ev.hash;
    }
    await writeFile(fAlpha, bufA);
    await writeFile(
      fBeta,
      makeEvent({ seq: 0, prevHash: GENESIS, detail: { y: 0 }, agentId: "beta", sessionId: "sb" }).line + "\n",
    );

    const alphaOnly = await store.query({ agentId: "alpha" });
    expect(alphaOnly.length).toBe(3);
    expect(alphaOnly.every((e) => e.agent_id === "alpha")).toBe(true);
    expect(alphaOnly.some((e) => e.agent_id === "beta")).toBe(false);

    const betaOnly = await store.query({ agentId: "beta" });
    expect(betaOnly.length).toBe(1);
    expect(betaOnly[0]!.agent_id).toBe("beta");
  });

  it("negative control: query for a non-existent agent returns nothing", async () => {
    const fAlpha = join(dir, "alpha-20260517-100000-1.audit.jsonl");
    await writeFile(
      fAlpha,
      makeEvent({ seq: 0, prevHash: GENESIS, detail: { x: 1 }, agentId: "alpha" }).line + "\n",
    );
    const events = await store.query({ agentId: "ghost" });
    expect(events).toEqual([]);
  });

  it("filters by eventType", async () => {
    const f = join(dir, "abc-20260517-100000-1.audit.jsonl");
    let prev = GENESIS;
    let buf = "";
    for (let i = 0; i < 4; i++) {
      const ev = makeEvent({
        seq: i, prevHash: prev, detail: { x: i },
        eventType: i % 2 === 0 ? "shell_command" : "network_activity",
      });
      buf += ev.line + "\n";
      prev = ev.hash;
    }
    await writeFile(f, buf);
    const shellOnly = await store.query({ agentId: "abc", eventType: "shell_command" });
    expect(shellOnly.length).toBe(2);
    expect(shellOnly.every((e) => e.event_type === "shell_command")).toBe(true);
  });

  it("filters by sinceSeq cursor (strictly greater than)", async () => {
    const f = join(dir, "abc-20260517-100000-1.audit.jsonl");
    let prev = GENESIS;
    let buf = "";
    for (let i = 0; i < 5; i++) {
      const ev = makeEvent({ seq: i, prevHash: prev, detail: { x: i } });
      buf += ev.line + "\n";
      prev = ev.hash;
    }
    await writeFile(f, buf);
    const sinceTwo = await store.query({ agentId: "abc", sinceSeq: 2 });
    expect(sinceTwo.map((e) => e.seq)).toEqual([3, 4]);
  });

  it("respects the limit", async () => {
    const f = join(dir, "abc-20260517-100000-1.audit.jsonl");
    let prev = GENESIS;
    let buf = "";
    for (let i = 0; i < 10; i++) {
      const ev = makeEvent({ seq: i, prevHash: prev, detail: { x: i } });
      buf += ev.line + "\n";
      prev = ev.hash;
    }
    await writeFile(f, buf);
    const capped = await store.query({ agentId: "abc", limit: 4 });
    expect(capped.length).toBe(4);
    expect(capped.map((e) => e.seq)).toEqual([0, 1, 2, 3]);
  });
});
