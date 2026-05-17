import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, writeFile, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runCleanup, type CleanupTarget } from "../src/control/cleanup";

let scriptPath: string;
let dir: string;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "kd-cleanup-"));
  scriptPath = join(dir, "fake-cleanup.sh");
  // Echo back the argv so tests can assert on the flags we passed.
  await writeFile(
    scriptPath,
    "#!/usr/bin/env bash\nfor a in \"$@\"; do echo \"arg=$a\"; done\nexit 0\n",
    { mode: 0o755 },
  );
  await chmod(scriptPath, 0o755);
});

afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

describe("runCleanup", () => {
  it("passes --dry-run, target flags, and --yes through to the script", async () => {
    const r = await runCleanup(["status", "logs"], { dryRun: true, scriptPath });
    expect(r.exitCode).toBe(0);
    expect(r.dryRun).toBe(true);
    expect(r.stdout).toContain("arg=--dry-run");
    expect(r.stdout).toContain("arg=--status");
    expect(r.stdout).toContain("arg=--logs");
    expect(r.stdout).toContain("arg=--yes");
  });

  it("filters invalid targets and still runs valid ones", async () => {
    const r = await runCleanup(["status", "notreal" as CleanupTarget], { dryRun: true, scriptPath });
    expect(r.exitCode).toBe(0);
    expect(r.targets).toEqual(["status"]);
    expect(r.stdout).toContain("arg=--status");
    expect(r.stdout).not.toContain("arg=--notreal");
  });

  it("throws when no valid targets remain after filtering", async () => {
    await expect(runCleanup(["bogus" as CleanupTarget], { dryRun: true, scriptPath })).rejects.toThrow(/no valid/);
  });

  it("omits --dry-run when dryRun=false", async () => {
    const r = await runCleanup(["status"], { dryRun: false, scriptPath });
    expect(r.stdout).not.toContain("arg=--dry-run");
    expect(r.stdout).toContain("arg=--status");
  });

  it("captures non-zero exit codes", async () => {
    const bad = join(dir, "fails.sh");
    await writeFile(bad, "#!/usr/bin/env bash\necho oops >&2\nexit 7\n", { mode: 0o755 });
    await chmod(bad, 0o755);
    const r = await runCleanup(["status"], { dryRun: true, scriptPath: bad });
    expect(r.ok).toBe(false);
    expect(r.exitCode).toBe(7);
    expect(r.stderr).toBe("oops");
  });
});
