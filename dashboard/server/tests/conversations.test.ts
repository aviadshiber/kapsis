import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, writeFile, rm, symlink, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConversationStore } from "../src/store/conversations";

describe("ConversationStore", () => {
  let dir: string;
  let store: ConversationStore;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-conv-"));
    store = new ConversationStore(dir);
  });

  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  it("returns empty=true when the agent's dir is missing", async () => {
    const desc = await store.describe("ghost");
    expect(desc).toEqual({ agentId: "ghost", files: [], totalBytes: 0, empty: true });
  });

  it("lists files with size and mtime", async () => {
    await mkdir(join(dir, "abc"));
    await writeFile(join(dir, "abc", "transcript.md"), "# hi");
    const desc = await store.describe("abc");
    expect(desc.empty).toBe(false);
    expect(desc.files.length).toBe(1);
    expect(desc.files[0]!.name).toBe("transcript.md");
    expect(desc.files[0]!.size).toBe(4);
  });

  it("readFile returns the body for a normal name", async () => {
    await mkdir(join(dir, "abc"));
    await writeFile(join(dir, "abc", "t.md"), "hello");
    const body = await store.readFile("abc", "t.md");
    expect(body).toBe("hello");
  });

  it("rejects path traversal via /", async () => {
    await mkdir(join(dir, "abc"));
    await writeFile(join(dir, "outside.txt"), "secret");
    const body = await store.readFile("abc", "../outside.txt");
    expect(body).toBeNull();
  });

  it("rejects path traversal via ..", async () => {
    await mkdir(join(dir, "abc"));
    const body = await store.readFile("abc", "..hidden");
    // Names with embedded ".." are rejected by the includes("..") guard.
    expect(body).toBeNull();
  });

  it("rejects hidden files", async () => {
    await mkdir(join(dir, "abc"));
    await writeFile(join(dir, "abc", ".secret"), "x");
    const body = await store.readFile("abc", ".secret");
    expect(body).toBeNull();
  });

  it("rejects files larger than the cap", async () => {
    await mkdir(join(dir, "abc"));
    await writeFile(join(dir, "abc", "big"), "x".repeat(2048));
    const body = await store.readFile("abc", "big", 1024);
    expect(body).toBeNull();
  });
});

// Side-channel artifacts (Issue #430, defect 3): response-<id>.md,
// decisions-<id>.json, debug-<id>.log written directly under statusDir.
describe("ConversationStore artifacts", () => {
  let convDir: string;
  let statusDir: string;
  let store: ConversationStore;

  beforeEach(async () => {
    convDir = await mkdtemp(join(tmpdir(), "kd-conv-"));
    statusDir = await mkdtemp(join(tmpdir(), "kd-status-"));
    store = new ConversationStore(convDir, statusDir);
  });

  afterEach(async () => {
    await rm(convDir, { recursive: true, force: true });
    await rm(statusDir, { recursive: true, force: true });
  });

  it("returns [] when no artifacts exist for the agent", async () => {
    const entries = await store.listArtifacts("abc123");
    expect(entries).toEqual([]);
  });

  it("returns [] when statusDir was not provided (older wiring)", async () => {
    const noStatusStore = new ConversationStore(convDir);
    await writeFile(join(convDir, "response-abc123.md"), "hi"); // wrong dir on purpose
    const entries = await noStatusStore.listArtifacts("abc123");
    expect(entries).toEqual([]);
  });

  it("lists exactly the whitelisted artifacts present for the agent", async () => {
    await writeFile(join(statusDir, "response-abc123.md"), "# Final answer");
    await writeFile(join(statusDir, "decisions-abc123.json"), "{}");
    await writeFile(join(statusDir, "debug-abc123.log"), "debug line");
    // Unrelated file and a different agent's artifact must not leak in.
    await writeFile(join(statusDir, "kapsis-proj-abc123.json"), "{}");
    await writeFile(join(statusDir, "response-other456.md"), "not mine");

    const entries = await store.listArtifacts("abc123");
    const names = entries.map((e) => e.name).sort();
    expect(names).toEqual(["debug-abc123.log", "decisions-abc123.json", "response-abc123.md"]);
    const kinds = entries.map((e) => e.kind).sort();
    expect(kinds).toEqual(["debug", "decisions", "response"]);
    for (const e of entries) {
      expect(e.size).toBeGreaterThan(0);
      expect(typeof e.mtime).toBe("string");
    }
  });

  it("readArtifact returns content for an exact whitelisted match", async () => {
    await writeFile(join(statusDir, "response-abc123.md"), "# Final answer");
    const body = await store.readArtifact("abc123", "response-abc123.md");
    expect(body).toBe("# Final answer");
  });

  it("readArtifact rejects a filename that doesn't belong to this agent id", async () => {
    await writeFile(join(statusDir, "response-other456.md"), "not mine");
    const body = await store.readArtifact("abc123", "response-other456.md");
    expect(body).toBeNull();
  });

  it("readArtifact rejects a non-whitelisted basename even if it exists on disk", async () => {
    await writeFile(join(statusDir, "kapsis-proj-abc123.json"), "{}");
    const body = await store.readArtifact("abc123", "kapsis-proj-abc123.json");
    expect(body).toBeNull();
  });

  it("readArtifact rejects path traversal via ../ in the name", async () => {
    // Guard rejects on the name shape alone (isUnsafeName), before any stat
    // — no need to actually plant a file outside statusDir to prove this.
    const body = await store.readArtifact("abc123", "../outside.txt");
    expect(body).toBeNull();
  });

  it("readArtifact rejects a leading-dot name", async () => {
    const body = await store.readArtifact("abc123", ".response-abc123.md");
    expect(body).toBeNull();
  });

  it("listArtifacts rejects an unsafe agent id (traversal guard applies to both params)", async () => {
    await writeFile(join(statusDir, "response-abc123.md"), "hi");
    const entries = await store.listArtifacts("../abc123");
    expect(entries).toEqual([]);
  });

  it("rejects a symlink planted at a whitelisted basename (listArtifacts and readArtifact)", async () => {
    // statusDir is a read-write bind mount into the container on Linux, so
    // a hostile agent could plant `ln -s <secret> response-<id>.md` hoping
    // the dashboard reads through it. listArtifacts must not list it
    // (lstat sees a symlink) and readArtifact must not read it (O_NOFOLLOW
    // makes the open itself fail).
    const secret = join(convDir, "secret.txt");
    await writeFile(secret, "top secret");
    await symlink(secret, join(statusDir, "response-abc123.md"));

    const entries = await store.listArtifacts("abc123");
    expect(entries).toEqual([]);
    const body = await store.readArtifact("abc123", "response-abc123.md");
    expect(body).toBeNull();
  });

  it("readArtifact rejects an artifact over the default 5MB cap", async () => {
    const oversized = "x".repeat(5 * 1024 * 1024 + 1);
    await writeFile(join(statusDir, "response-abc123.md"), oversized);
    const body = await store.readArtifact("abc123", "response-abc123.md");
    expect(body).toBeNull();
    // Sanity: a small artifact in the same store is still served.
    await writeFile(join(statusDir, "decisions-abc123.json"), "{}");
    expect(await store.readArtifact("abc123", "decisions-abc123.json")).toBe("{}");
  });

  it("recognizes every artifact pattern documented in status-sync.sh (drift guard)", async () => {
    // The bash side documents its legitimate side-channel basenames as
    // backtick-quoted `<kind>-<id>.<ext>` patterns in the whitelist comment
    // of scripts/lib/status-sync.sh. Extract them and assert each one is
    // recognized by ARTIFACT_KINDS (behaviorally, via listArtifacts), so a
    // pattern added or renamed on the bash side without a matching TS
    // change fails this test. (`kapsis-<project>-<id>.json` intentionally
    // doesn't match — it's a status file, not a side-channel artifact.)
    const bashPath = new URL("../../../scripts/lib/status-sync.sh", import.meta.url).pathname;
    const src = await readFile(bashPath, "utf8");
    const matches = [...src.matchAll(/`([a-z]+)-<id>\.([a-z]+)`/g)];
    expect(matches.length).toBeGreaterThanOrEqual(3);

    const agentId = "parity1";
    const expected = new Map<string, string>(); // name -> kind (= prefix)
    for (const m of matches) {
      const prefix = m[1]!;
      const suffix = m[2]!;
      const name = `${prefix}-${agentId}.${suffix}`;
      if (expected.has(name)) continue;
      expected.set(name, prefix);
      await writeFile(join(statusDir, name), "x");
    }
    const entries = await store.listArtifacts(agentId);
    for (const [name, kind] of expected) {
      const match = entries.find((e) => e.name === name);
      expect(match).toBeDefined();
      expect(match!.kind).toBe(kind as "response" | "decisions" | "debug");
    }
  });

  it("whitelist regex matches the exact example basenames status-sync.sh:92 documents", () => {
    // Shared-fixture parity check (guardrail: no drift between the bash
    // whitelist in scripts/lib/status-sync.sh and this TS whitelist). We
    // can't literally share a regex across languages, so this test pins
    // the three canonical example names from the bash comment and asserts
    // this store treats them as legitimate artifacts for their agent id.
    const agentId = "a1b2c3";
    const examples: Array<[string, "response" | "decisions" | "debug"]> = [
      [`response-${agentId}.md`, "response"],
      [`decisions-${agentId}.json`, "decisions"],
      [`debug-${agentId}.log`, "debug"],
    ];
    return Promise.all(examples.map(async ([name, kind]) => {
      await writeFile(join(statusDir, name), "x");
      const entries = await store.listArtifacts(agentId);
      const match = entries.find((e) => e.name === name);
      expect(match).toBeDefined();
      expect(match!.kind).toBe(kind);
    }));
  });
});

// Sanity: readFile() itself is unaffected by the new optional statusDir arg.
describe("ConversationStore backward compatibility", () => {
  it("readFile still works when constructed with only convDir", async () => {
    const dir = await mkdtemp(join(tmpdir(), "kd-conv-compat-"));
    try {
      const store = new ConversationStore(dir);
      await mkdir(join(dir, "abc"));
      await writeFile(join(dir, "abc", "t.md"), "hello");
      expect(await store.readFile("abc", "t.md")).toBe("hello");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
