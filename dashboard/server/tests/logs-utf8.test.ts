import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, writeFile, rm, appendFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LogStore } from "../src/store/logs";

describe("LogStore — UTF-8 boundary safety (regression for the silent-stall bug)", () => {
  let dir: string;
  let store: LogStore;
  let file: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-utf8-"));
    store = new LogStore(dir);
    file = join(dir, "kapsis-utf.log");
  });

  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  it("does not stall when the read window cuts a multi-byte char that has no newline after it", async () => {
    // A 3-byte character (é = c3 a9 in UTF-8) at the very end, no newline.
    // Pre-fix code: decoded into "é", then a U+FFFD replaced the partial
    // bytes, byteLength reported 3 instead of 1-2, offset stalled.
    await writeFile(file, "line1\nlin");                  // first 9 bytes
    await appendFile(file, Buffer.from([0xc3, 0xa9]));    // 2 more bytes — split UTF-8
    // No newline at the end, so we should consume nothing past line1's \n.
    const c1 = await store.read("utf", 0);
    expect(c1.lines).toEqual(["line1"]);
    expect(c1.nextOffset).toBe(6); // "line1\n"

    // Append the closing newline and the rest.
    await appendFile(file, "ing\n");
    const c2 = await store.read("utf", c1.nextOffset);
    expect(c2.lines.length).toBe(1);
    // Whole "lin" + é + "ing" survives across the two reads — this is the
    // regression: before the fix, the é was lost to a U+FFFD substitution
    // and the offset stalled.
    expect(c2.lines[0]).toBe("linéing");
  });

  it("returns empty progress and does not advance when no newline is present in the window", async () => {
    await writeFile(file, "no newline yet");
    const c = await store.read("utf", 0);
    expect(c.lines).toEqual([]);
    expect(c.bytesRead).toBe(0);
    expect(c.nextOffset).toBe(0);
  });

  it("advances correctly when all bytes are pure ASCII (no behavior regression)", async () => {
    await writeFile(file, "a\nb\nc\n");
    const c = await store.read("utf", 0);
    expect(c.lines).toEqual(["a", "b", "c"]);
    expect(c.nextOffset).toBe(6);
  });
});
