import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { isContainerMissingStderr, killMarkerPath, writeKillMarker } from "../src/control/kill";

const ORIGINAL_STATUS_DIR = process.env.KAPSIS_STATUS_DIR;

describe("kill: container-missing detection", () => {
  it("recognizes podman's 'no such container' message", () => {
    expect(isContainerMissingStderr(`Error: no container with name or ID "kapsis-foo" found: no such container`)).toBe(true);
  });

  it("recognizes the shorter 'no container' variant", () => {
    expect(isContainerMissingStderr("Error: no container with name foo")).toBe(true);
  });

  it("is case-insensitive", () => {
    expect(isContainerMissingStderr("ERROR: NO SUCH CONTAINER")).toBe(true);
  });

  it("ignores unrelated podman errors", () => {
    expect(isContainerMissingStderr("Error: permission denied talking to podman socket")).toBe(false);
    expect(isContainerMissingStderr("")).toBe(false);
  });
});

describe("kill: marker file", () => {
  let statusDir: string;

  beforeEach(async () => {
    statusDir = await mkdtemp(join(tmpdir(), "kd-kill-"));
    process.env.KAPSIS_STATUS_DIR = statusDir;
  });

  afterEach(async () => {
    if (ORIGINAL_STATUS_DIR === undefined) delete process.env.KAPSIS_STATUS_DIR;
    else process.env.KAPSIS_STATUS_DIR = ORIGINAL_STATUS_DIR;
    await rm(statusDir, { recursive: true, force: true });
  });

  it("computes the marker path under KAPSIS_STATUS_DIR", () => {
    expect(killMarkerPath("agent01")).toBe(join(statusDir, "agent01.kill-requested"));
  });

  it("writes a JSON marker with source, signal, and timestamp", async () => {
    await writeKillMarker("agent01", "TERM");
    const marker = killMarkerPath("agent01");
    const st = await stat(marker);
    expect(st.isFile()).toBe(true);
    const body = JSON.parse(await readFile(marker, "utf8"));
    expect(body.source).toBe("dashboard");
    expect(body.signal).toBe("TERM");
    expect(typeof body.requested_at).toBe("string");
    // ISO-8601: 2026-...T...Z
    expect(body.requested_at).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it("records the KILL signal when SIGKILL is requested", async () => {
    await writeKillMarker("agent02", "KILL");
    const body = JSON.parse(await readFile(killMarkerPath("agent02"), "utf8"));
    expect(body.signal).toBe("KILL");
  });

  it("rejects invalid agent ids without writing to disk", async () => {
    await expect(writeKillMarker("../etc/passwd", "TERM")).rejects.toThrow(/invalid agent id/);
    await expect(stat(join(statusDir, "..", "etc", "passwd.kill-requested"))).rejects.toThrow();
  });
});
