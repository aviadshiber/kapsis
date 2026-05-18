import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, rm, writeFile, appendFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LogStore } from "../src/store/logs";

describe("LogStore", () => {
  let dir: string;
  let store: LogStore;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-logs-"));
    store = new LogStore(dir);
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("returns empty chunk when log missing", async () => {
    const c = await store.read("missing", 0);
    expect(c.lines).toEqual([]);
    expect(c.size).toBe(0);
  });

  it("returns lines and advances offset", async () => {
    const p = join(dir, "kapsis-abc.log");
    await writeFile(p, "line one\nline two\npartial");
    const c = await store.read("abc", 0);
    expect(c.lines).toEqual(["line one", "line two"]);
    expect(c.nextOffset).toBeLessThan(c.size); // partial line excluded

    await appendFile(p, " continued\nline four\n");
    const c2 = await store.read("abc", c.nextOffset);
    expect(c2.lines).toEqual(["partial continued", "line four"]);
  });

  it("restarts from 0 after a rotation (offset > size)", async () => {
    const p = join(dir, "kapsis-abc.log");
    await writeFile(p, "tiny\n");
    const c = await store.read("abc", 9999);
    expect(c.nextOffset).toBeLessThanOrEqual(5);
    expect(c.lines).toEqual(["tiny"]);
  });
});
