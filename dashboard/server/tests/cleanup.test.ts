import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, writeFile, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runCleanup, buildArgv, type CleanupTarget } from "../src/control/cleanup";

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

describe("buildArgv", () => {
  it("uses --force (the script's actual yes flag), NOT --yes", () => {
    const argv = buildArgv("/x.sh", ["worktrees"], false);
    expect(argv).toContain("--force");
    expect(argv).not.toContain("--yes");
  });

  it("emits --dry-run when dryRun=true", () => {
    expect(buildArgv("/x.sh", ["worktrees"], true)).toContain("--dry-run");
  });

  it("omits --dry-run when dryRun=false", () => {
    expect(buildArgv("/x.sh", ["worktrees"], false)).not.toContain("--dry-run");
  });

  it("maps selective targets to their --<target> flag", () => {
    expect(buildArgv("/x.sh", ["worktrees", "volumes", "images", "logs"], false))
      .toEqual(["/x.sh", "--worktrees", "--volumes", "--images", "--logs", "--force"]);
  });

  it("maps prune-dangling to --prune-dangling", () => {
    expect(buildArgv("/x.sh", ["prune-dangling"], false))
      .toEqual(["/x.sh", "--prune-dangling", "--force"]);
  });

  it("stale-state runs the script bare (no per-target flag)", () => {
    // The real kapsis-cleanup.sh, when invoked with no target flags, runs its
    // default block (worktrees + sandboxes + status + sanitized-git + audit +
    // conversations). The dashboard surfaces this as a single "stale-state"
    // target so users can clean those categories without a separate flag for
    // each (the script doesn't expose them individually).
    expect(buildArgv("/x.sh", ["stale-state"], false))
      .toEqual(["/x.sh", "--force"]);
    expect(buildArgv("/x.sh", ["stale-state"], true))
      .toEqual(["/x.sh", "--dry-run", "--force"]);
  });

  it("rejects mixing stale-state with selective targets", () => {
    // Adding a selective flag suppresses the script's default block, which
    // would silently mean stale-state did nothing — better to fail loudly.
    expect(() => buildArgv("/x.sh", ["stale-state", "worktrees"], false))
      .toThrow(/cannot be combined/);
  });

  it("throws on an empty target list", () => {
    expect(() => buildArgv("/x.sh", [], false)).toThrow(/no valid cleanup targets/);
  });

  it("filters out unknown targets and still runs valid ones", () => {
    const argv = buildArgv("/x.sh", ["worktrees", "notreal" as CleanupTarget], false);
    expect(argv).toContain("--worktrees");
    expect(argv).not.toContain("--notreal");
  });
});

describe("runCleanup", () => {
  it("invokes the script with the correct argv and captures stdout", async () => {
    const r = await runCleanup(["worktrees"], { dryRun: true, scriptPath });
    expect(r.exitCode).toBe(0);
    expect(r.dryRun).toBe(true);
    expect(r.argv).toContain("--worktrees");
    expect(r.argv).toContain("--dry-run");
    expect(r.argv).toContain("--force");
    expect(r.stdout).toContain("arg=--worktrees");
    expect(r.stdout).toContain("arg=--dry-run");
    expect(r.stdout).toContain("arg=--force");
  });

  it("captures non-zero exit codes", async () => {
    const bad = join(dir, "fails.sh");
    await writeFile(bad, "#!/usr/bin/env bash\necho oops >&2\nexit 7\n", { mode: 0o755 });
    await chmod(bad, 0o755);
    const r = await runCleanup(["worktrees"], { dryRun: true, scriptPath: bad });
    expect(r.ok).toBe(false);
    expect(r.exitCode).toBe(7);
    expect(r.stderr).toBe("oops");
  });

  it("rejects empty target lists at runtime", async () => {
    await expect(runCleanup([], { dryRun: true, scriptPath })).rejects.toThrow(/no valid/);
  });
});
