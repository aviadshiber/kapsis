import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
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
