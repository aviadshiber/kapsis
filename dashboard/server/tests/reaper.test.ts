import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile, readFile, chmod, stat, symlink, readdir, lstat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  probePodman,
  scanForStaleAgents,
  reapStaleAgents,
  STALE_THRESHOLD_MS,
} from "../src/control/reaper";

/**
 * The reaper relies on `podman inspect` to distinguish "container missing"
 * (reapable) from "container still alive but silent" (skip). The test env is
 * expected to have podman installed (the codebase ships with Kapsis), but we
 * defensively skip the real-podman tests if it's not on PATH so the suite
 * stays portable.
 */
const ORIGINAL_PATH = process.env.PATH;

// Always use a non-conflicting fixture id format. Random per-test so even
// parallel runs against the same Podman socket can't collide with a real
// container named `kapsis-<id>`. Lowercase alnum, ≥3 chars to match the
// agent-id validator (^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$).
function randomAgentId(prefix = "fix"): string {
  const r = Math.random().toString(36).slice(2, 10);
  return `${prefix}${r}`;
}

function isoNow(offsetMs = 0): string {
  // status.sh strips milliseconds (".000Z" → "Z"); match the format the
  // reaper itself writes so round-trip tests don't trip on shape mismatch.
  return new Date(Date.now() + offsetMs).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function statusFixture(overrides: Partial<Record<string, unknown>> = {}): string {
  return JSON.stringify({
    version: "1.0",
    agent_id: overrides.agent_id ?? "abc123",
    project: overrides.project ?? "demo",
    branch: "main",
    sandbox_mode: "overlay",
    phase: overrides.phase ?? "running",
    progress: 50,
    message: "running",
    gist: null,
    gist_updated_at: null,
    started_at: isoNow(-3_600_000),
    updated_at: overrides.updated_at ?? isoNow(-60_000),
    exit_code: null,
    error: null,
    worktree_path: null,
    pr_url: null,
    push_status: null,
    local_commit: null,
    remote_commit: null,
    push_fallback_command: null,
    commit_status: null,
    commit_sha: null,
    uncommitted_files: 0,
    heartbeat_at: null,
    error_type: null,
    ...overrides,
  });
}

/** Convenience: write `kapsis-<project>-<id>.json` into statusDir. */
async function writeStatus(
  statusDir: string,
  project: string,
  agentId: string,
  overrides: Partial<Record<string, unknown>> = {},
): Promise<string> {
  const file = `kapsis-${project}-${agentId}.json`;
  const path = join(statusDir, file);
  await writeFile(
    path,
    statusFixture({ project, agent_id: agentId, ...overrides }),
    { mode: 0o600 },
  );
  return path;
}

describe("reaper", () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-reaper-"));
  });

  afterEach(async () => {
    // Always restore PATH so PATH-clobber tests can't leak.
    if (ORIGINAL_PATH === undefined) delete process.env.PATH;
    else process.env.PATH = ORIGINAL_PATH;
    // Restore mode in case a test chmodded it read-only (otherwise rm fails).
    try { await chmod(dir, 0o755); } catch { /* */ }
    await rm(dir, { recursive: true, force: true });
  });

  describe("probePodman", () => {
    it("probes successfully against a real podman binary", async () => {
      const ok = await probePodman();
      // If the test env unexpectedly lacks podman, surface that as a skip
      // rather than a hard failure — the other tests will skip accordingly.
      if (!ok) {
        console.warn("probePodman returned false; test env likely lacks podman");
        return;
      }
      expect(ok).toBe(true);
    });

    it("returns false when podman is not on PATH", async () => {
      process.env.PATH = "/nonexistent";
      const ok = await probePodman();
      expect(ok).toBe(false);
    });
  });

  describe("scanForStaleAgents", () => {
    it("returns empty plan and podmanAvailable=true when statusDir is missing", async () => {
      const plan = await scanForStaleAgents(join(dir, "does-not-exist"));
      expect(plan.candidates).toEqual([]);
      expect(plan.reapable).toEqual([]);
      // PATH is intact in this test, so podman should be available.
      expect(plan.podmanAvailable).toBe(true);
    });

    it("returns empty plan when no files match kapsis-*-* pattern", async () => {
      await writeFile(join(dir, "not-a-status.json"), "{}", { mode: 0o600 });
      await writeFile(join(dir, "kapsis-no-id.json"), "{}", { mode: 0o600 });
      await writeFile(join(dir, "other-file.txt"), "hi", { mode: 0o600 });
      const plan = await scanForStaleAgents(dir);
      expect(plan.candidates).toEqual([]);
      expect(plan.reapable).toEqual([]);
    });

    it("excludes complete-phase files even if very old", async () => {
      // 10 days old, but phase=complete → not a candidate.
      await writeStatus(dir, "demo", randomAgentId(), {
        phase: "complete",
        updated_at: isoNow(-10 * 24 * 60 * 60_000),
      });
      const plan = await scanForStaleAgents(dir);
      expect(plan.candidates).toEqual([]);
    });

    it("excludes fresh files (within threshold)", async () => {
      await writeStatus(dir, "demo", randomAgentId(), {
        phase: "running",
        updated_at: isoNow(-5 * 60_000),
      });
      const plan = await scanForStaleAgents(dir);
      expect(plan.candidates).toEqual([]);
    });

    it("includes stale non-complete files", async () => {
      const id = randomAgentId();
      await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: isoNow(-2 * 60 * 60_000), // 2 hours
      });
      const plan = await scanForStaleAgents(dir);
      expect(plan.candidates.length).toBe(1);
      expect(plan.candidates[0]!.agentId).toBe(id);
      expect(plan.candidates[0]!.phase).toBe("running");
      // Container is absent (random id never existed), so it must be reapable
      // — provided podman is on PATH for this test.
      if (plan.podmanAvailable) {
        expect(plan.reapable.length).toBe(1);
        expect(plan.reapable[0]!.agentId).toBe(id);
      }
    });

    it("skips files with malformed JSON without throwing", async () => {
      const id = randomAgentId();
      await writeFile(
        join(dir, `kapsis-demo-${id}.json`),
        "{this is not valid json",
        { mode: 0o600 },
      );
      const plan = await scanForStaleAgents(dir);
      expect(plan.candidates).toEqual([]);
    });

    it("skips files with invalid agent_id", async () => {
      // Empty agent_id, then path-traversal-like id — both must be rejected
      // by scanning (the file is still named with a valid filename, but the
      // status' agent_id field is what the reaper uses for podman inspect).
      const id1 = randomAgentId("bad1");
      const id2 = randomAgentId("bad2");
      await writeStatus(dir, "demo", id1, {
        agent_id: "",
        updated_at: isoNow(-2 * 60 * 60_000),
        phase: "running",
      });
      await writeStatus(dir, "demo", id2, {
        agent_id: "../etc/passwd",
        updated_at: isoNow(-2 * 60 * 60_000),
        phase: "running",
      });
      const plan = await scanForStaleAgents(dir);
      // Both files have invalid agent_id values; reaper must not list them
      // as candidates (or, at minimum, must not have a non-null containerState).
      const badCandidates = plan.candidates.filter(
        (c) => c.agentId === "" || c.agentId === "../etc/passwd",
      );
      expect(badCandidates).toEqual([]);
    });

    it("skips files with malformed updated_at", async () => {
      const id = randomAgentId();
      await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: "not-an-iso-string",
      });
      const plan = await scanForStaleAgents(dir);
      expect(plan.candidates).toEqual([]);
    });

    it("respects custom thresholdMs", async () => {
      const id = randomAgentId();
      // 12 minutes old: excluded by the default 30-min threshold, but
      // included by a 10-min custom threshold.
      await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: isoNow(-12 * 60_000),
      });
      const planDefault = await scanForStaleAgents(dir);
      expect(planDefault.candidates).toEqual([]);

      const planCustom = await scanForStaleAgents(dir, 10 * 60_000);
      expect(planCustom.candidates.length).toBe(1);
      expect(planCustom.candidates[0]!.agentId).toBe(id);
    });

    it("respects podmanAvailable=false fallback (reapable=[])", async () => {
      process.env.PATH = "/nonexistent";
      const id = randomAgentId();
      await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: isoNow(-2 * 60 * 60_000),
      });
      const plan = await scanForStaleAgents(dir);
      expect(plan.podmanAvailable).toBe(false);
      // Candidate is still detected by JSON+age, but we can't confirm
      // the container is dead without podman → don't reap.
      expect(plan.candidates.length).toBe(1);
      expect(plan.reapable).toEqual([]);
    });

    it("skips symlinked status files during scan", async () => {
      const id = randomAgentId();
      // Write the real file outside statusDir, then symlink it into statusDir.
      const externalDir = await mkdtemp(join(tmpdir(), "kd-reaper-ext-"));
      try {
        const realFile = join(externalDir, `kapsis-demo-${id}.json`);
        await writeFile(realFile, statusFixture({
          project: "demo",
          agent_id: id,
          phase: "running",
          updated_at: isoNow(-2 * 60 * 60_000),
        }), { mode: 0o600 });
        const linkPath = join(dir, `kapsis-demo-${id}.json`);
        await symlink(realFile, linkPath);
        // Sanity: lstat confirms the link exists.
        const ls = await lstat(linkPath);
        expect(ls.isSymbolicLink()).toBe(true);

        const plan = await scanForStaleAgents(dir);
        const matched = plan.candidates.filter((c) => c.agentId === id);
        expect(matched).toEqual([]);
      } finally {
        await rm(externalDir, { recursive: true, force: true });
      }
    });
  });

  describe("reapStaleAgents — dryRun", () => {
    it("does not modify or unlink any file", async () => {
      const ids = [randomAgentId(), randomAgentId(), randomAgentId()];
      const paths: string[] = [];
      const originals: string[] = [];
      for (const id of ids) {
        const p = await writeStatus(dir, "demo", id, {
          phase: "running",
          updated_at: isoNow(-2 * 60 * 60_000),
        });
        paths.push(p);
        originals.push(await readFile(p, "utf8"));
      }

      const out = await reapStaleAgents(dir, { dryRun: true });
      expect(out.dryRun).toBe(true);

      // All files still on disk, content byte-identical.
      for (let i = 0; i < paths.length; i++) {
        const st = await stat(paths[i]!);
        expect(st.isFile()).toBe(true);
        const after = await readFile(paths[i]!, "utf8");
        expect(after).toBe(originals[i]!);
      }
    });

    it("returns the same shape as execute (reaped[] populated with would-be candidates)", async () => {
      const id = randomAgentId();
      await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: isoNow(-2 * 60 * 60_000),
      });
      const out = await reapStaleAgents(dir, { dryRun: true });
      expect(out.dryRun).toBe(true);
      expect(Array.isArray(out.reaped)).toBe(true);
      expect(Array.isArray(out.skipped)).toBe(true);
      expect(Array.isArray(out.errors)).toBe(true);
      expect(typeof out.scanned).toBe("number");
      expect(typeof out.podmanAvailable).toBe("boolean");
      if (out.podmanAvailable) {
        // The would-be reaped set is the candidate we wrote.
        expect(out.reaped.length).toBe(1);
        expect(out.reaped[0]!.agentId).toBe(id);
      }
    });
  });

  describe("reapStaleAgents — execute", () => {
    it("rewrites status to phase=complete + error_type=zombie + unlinks file", async () => {
      const id = randomAgentId();
      const path = await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: isoNow(-2 * 60 * 60_000),
      });

      const out = await reapStaleAgents(dir, { dryRun: false });
      if (!out.podmanAvailable) {
        console.warn("podman not available; reap will not touch files");
        return;
      }
      // After a successful reap the file is gone.
      await expect(stat(path)).rejects.toThrow();
      expect(out.reaped.length).toBe(1);
      expect(out.reaped[0]!.agentId).toBe(id);
    });

    it("execute is parallel-safe for distinct files", async () => {
      const ids = [
        randomAgentId(), randomAgentId(), randomAgentId(),
        randomAgentId(), randomAgentId(),
      ];
      for (const id of ids) {
        await writeStatus(dir, "demo", id, {
          phase: "running",
          updated_at: isoNow(-2 * 60 * 60_000),
        });
      }

      const out = await reapStaleAgents(dir, { dryRun: false });
      if (!out.podmanAvailable) {
        console.warn("podman not available; skip parallel-safe assertion");
        return;
      }
      expect(out.errors).toEqual([]);
      expect(out.reaped.length).toBe(5);
      const remaining = (await readdir(dir)).filter((f) => f.startsWith("kapsis-"));
      expect(remaining).toEqual([]);
    });

    it("execute with podman down does NOT reap anything", async () => {
      process.env.PATH = "/nonexistent";
      const ids = [randomAgentId(), randomAgentId(), randomAgentId()];
      const paths: string[] = [];
      for (const id of ids) {
        paths.push(await writeStatus(dir, "demo", id, {
          phase: "running",
          updated_at: isoNow(-2 * 60 * 60_000),
        }));
      }
      const out = await reapStaleAgents(dir, { dryRun: false });
      expect(out.podmanAvailable).toBe(false);
      expect(out.reaped).toEqual([]);
      // All files still on disk unchanged.
      for (const p of paths) {
        const st = await stat(p);
        expect(st.isFile()).toBe(true);
      }
    });

    it("execute rejects symlinked status files (does not follow)", async () => {
      const id = randomAgentId();
      const externalDir = await mkdtemp(join(tmpdir(), "kd-reaper-ext2-"));
      try {
        const realFile = join(externalDir, `kapsis-demo-${id}.json`);
        const originalContent = statusFixture({
          project: "demo",
          agent_id: id,
          phase: "running",
          updated_at: isoNow(-2 * 60 * 60_000),
        });
        await writeFile(realFile, originalContent, { mode: 0o600 });
        // Symlink into statusDir. Also write a real stale fixture to ensure
        // execute does something so the test isn't a no-op.
        await symlink(realFile, join(dir, `kapsis-demo-${id}.json`));
        const realId = randomAgentId();
        await writeStatus(dir, "demo", realId, {
          phase: "running",
          updated_at: isoNow(-2 * 60 * 60_000),
        });

        const out = await reapStaleAgents(dir, { dryRun: false });
        if (!out.podmanAvailable) return;

        // The symlink's target must NOT have been rewritten. Compare bytes.
        const after = await readFile(realFile, "utf8");
        expect(after).toBe(originalContent);

        // If the reaper saw the symlink at all, it must have recorded an error
        // mentioning "symlink"; if it never saw it (filtered at scan time),
        // errors[] can be empty. Either is acceptable.
        const symErr = out.errors.find((e) => e.file.includes(id));
        if (symErr) {
          expect(symErr.err.toLowerCase()).toContain("symlink");
        }
      } finally {
        await rm(externalDir, { recursive: true, force: true });
      }
    });

    it("writeFile success + unlink failure: file has zombie content, agent IS in reaped[]", async () => {
      const id = randomAgentId();
      const path = await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: isoNow(-2 * 60 * 60_000),
      });
      // chmod dir to 0o555 so writeFile (which truncates an existing file the
      // user already owns) still succeeds, but unlink (which needs write+exec
      // on the parent dir) fails with EACCES.
      await chmod(dir, 0o555);

      const out = await reapStaleAgents(dir, { dryRun: false });
      // Restore so the test can read+clean.
      await chmod(dir, 0o755);

      if (!out.podmanAvailable) return;

      // File should still exist (unlink failed) but its content should be the
      // zombie-rewritten form (writeFile succeeded).
      const after = await readFile(path, "utf8");
      const parsed = JSON.parse(after);
      expect(parsed.phase).toBe("complete");
      expect(parsed.error_type).toBe("zombie");
      // Per the split try/catch best-effort-unlink contract: the agent is
      // counted as reaped because the terminal-state rewrite landed.
      expect(out.reaped.some((c) => c.agentId === id)).toBe(true);
    });

    it("errors[] entries contain no absolute paths", async () => {
      // Induce an error by writing a stale fixture, then making the file
      // unreadable AFTER scan but before reap — easiest path: chmod dir
      // 0o555 so unlink fails. Any error message must use only the basename.
      const id = randomAgentId();
      await writeStatus(dir, "demo", id, {
        phase: "running",
        updated_at: isoNow(-2 * 60 * 60_000),
      });
      await chmod(dir, 0o555);
      const out = await reapStaleAgents(dir, { dryRun: false });
      await chmod(dir, 0o755);

      // Either an error was recorded (then check its message) or unlink
      // succeeded anyway (no error to check — skip the assertion).
      for (const e of out.errors) {
        expect(e.err).not.toContain("/Users/");
        expect(e.err).not.toContain("/tmp/");
        expect(e.err).not.toContain("/private/");
      }
    });
  });

  describe("scanned count", () => {
    it("reports candidate count, not total files in statusDir", async () => {
      // 5 complete-phase files (not candidates because phase=complete) +
      // 2 stale fixtures that ARE candidates.
      for (let i = 0; i < 5; i++) {
        await writeStatus(dir, "demo", randomAgentId("done"), {
          phase: "complete",
          updated_at: isoNow(-10 * 60 * 60_000),
          exit_code: 0,
        });
      }
      const staleIds = [randomAgentId("stale"), randomAgentId("stale")];
      for (const id of staleIds) {
        await writeStatus(dir, "demo", id, {
          phase: "running",
          updated_at: isoNow(-2 * 60 * 60_000),
        });
      }

      const out = await reapStaleAgents(dir, { dryRun: true });
      expect(out.scanned).toBe(2);
    });
  });

  describe("constants", () => {
    it("exports STALE_THRESHOLD_MS = 30 minutes", () => {
      expect(STALE_THRESHOLD_MS).toBe(30 * 60_000);
    });
  });
});
