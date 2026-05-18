import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { StatusStore } from "../src/store/status";
import { SpecStore, splitInjectedSuffix } from "../src/store/spec";
import { SPEC_MAX_BYTES } from "../src/types";

const ISO = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

function statusFixture(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    version: "1.0",
    agent_id: "abc123",
    project: "demo",
    branch: "main",
    sandbox_mode: "worktree",
    phase: "running",
    progress: 50,
    message: "running",
    gist: null,
    gist_updated_at: null,
    started_at: ISO(),
    updated_at: ISO(),
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

interface Env {
  root: string;
  statusDir: string;
  worktreesRoot: string;
  status: StatusStore | null;
  cleanup: () => Promise<void>;
}

/**
 * Set up tmpdir + status dir + worktrees root. The StatusStore is created
 * lazily by publishStatus so its initial directory scan always picks up
 * the fixture — bypassing macOS FSEvents flake where fs.watch can take
 * seconds to register and miss new files on a freshly-created tmpdir.
 */
async function setupEnv(): Promise<Env> {
  const root = await mkdtemp(join(tmpdir(), "spec-test-"));
  const statusDir = join(root, "status");
  const worktreesRoot = join(root, "worktrees");
  await mkdir(statusDir);
  await mkdir(worktreesRoot);
  const env: Env = {
    root, statusDir, worktreesRoot, status: null,
    cleanup: async () => {
      env.status?.close();
      await rm(root, { recursive: true, force: true });
    },
  };
  return env;
}

async function writeWorktreeSpec(worktreesRoot: string, name: string, content: string): Promise<string> {
  const wt = join(worktreesRoot, name);
  await mkdir(join(wt, ".kapsis"), { recursive: true });
  await writeFile(join(wt, ".kapsis", "task-spec-with-progress.md"), content);
  return wt;
}

/**
 * Pre-write a status JSON, then (re)boot env.status so the initial
 * directory scan picks up the new fixture. Use this exactly once per test;
 * subsequent calls will close the previous StatusStore first.
 *
 * This avoids fs.watch flake on macOS — init()'s directory scan is
 * deterministic, while waiting for FSEvents on a fresh tmpdir is not.
 */
async function publishStatus(env: Env, project: string, agentId: string, overrides: Record<string, unknown>): Promise<void> {
  await writeFile(
    join(env.statusDir, `kapsis-${project}-${agentId}.json`),
    statusFixture({ project, agent_id: agentId, ...overrides }),
  );
  env.status?.close();
  const s = new StatusStore(env.statusDir);
  await s.init();
  env.status = s;
}

/** Bootstrap an empty StatusStore for tests that don't publish anything. */
async function bootEmptyStatusStore(env: Env): Promise<void> {
  if (env.status) return;
  const s = new StatusStore(env.statusDir);
  await s.init();
  env.status = s;
}

describe("splitInjectedSuffix", () => {
  it("returns full text and null suffix when expectedSuffix is null", () => {
    const raw = "## My task\n\nDo a thing.";
    const r = splitInjectedSuffix(raw, null);
    expect(r.spec).toBe(raw);
    expect(r.injectedInstructions).toBeNull();
  });

  it("strips the exact suffix when present (no trailing newline)", () => {
    const suffix = "## Progress Reporting\nUpdate progress.json.";
    const user = "## My task\n\nDo a thing.";
    const raw = `${user}\n\n\n${suffix}`;
    const r = splitInjectedSuffix(raw, suffix);
    expect(r.spec).toBe(user);
    expect(r.injectedInstructions).toBe(suffix);
  });

  it("strips the exact suffix when followed by a trailing newline", () => {
    const suffix = "## Progress\nUpdate.";
    const user = "## My task";
    const raw = `${user}\n\n\n${suffix}\n`;
    const r = splitInjectedSuffix(raw, suffix);
    expect(r.spec).toBe(user);
    expect(r.injectedInstructions).toBe(suffix);
  });

  it("does not strip when suffix is not an exact match", () => {
    const suffix = "## Progress\nUpdate.";
    const raw = `## My task\n\n\n## Progress\nNot the same.`;
    const r = splitInjectedSuffix(raw, suffix);
    expect(r.spec).toBe(raw);
    expect(r.injectedInstructions).toBeNull();
  });

  it("does not match a heuristic in the middle of the file", () => {
    const suffix = "## Progress\nUpdate.";
    const raw = `Header\n\n\n${suffix}\n\nMore text after.`;
    const r = splitInjectedSuffix(raw, suffix);
    expect(r.injectedInstructions).toBeNull();
    expect(r.spec).toBe(raw);
  });
});

describe("SpecStore.read — worktree path", () => {
  let env: Env;
  beforeEach(async () => { env = await setupEnv(); });
  afterEach(async () => { await env.cleanup(); });

  it("returns 404 when agent unknown", async () => {
    await bootEmptyStatusStore(env);
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    expect(await store.read("noexist")).toBeNull();
  });

  it("returns 404 when worktree_path is null and no volume mount", async () => {
    await publishStatus(env, "demo", "abc123", { worktree_path: null });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    expect(await store.read("abc123")).toBeNull();
  });

  it("reads a worktree spec and splits the injected suffix", async () => {
    const suffix = "## Progress\nUpdate progress.json.";
    const user = "## Bug DEV-42\n\nFix the foo bar.";
    const wt = await writeWorktreeSpec(env.worktreesRoot, "demo-abc123", `${user}\n\n\n${suffix}`);
    await publishStatus(env, "demo", "abc123", { worktree_path: wt });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: suffix,
      podmanVolumeMountpoint: async () => null,
    });
    const r = await store.read("abc123");
    expect(r).not.toBeNull();
    expect(r!.spec).toBe(user);
    expect(r!.injectedInstructions).toBe(suffix);
    expect(r!.source).toBe("worktree");
    expect(r!.truncated).toBe(false);
  });

  it("returns the raw file (no split) when injectedSuffix is null", async () => {
    const content = "## Just a task";
    const wt = await writeWorktreeSpec(env.worktreesRoot, "demo-abc123", content);
    await publishStatus(env, "demo", "abc123", { worktree_path: wt });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    const r = await store.read("abc123");
    expect(r!.spec).toBe(content);
    expect(r!.injectedInstructions).toBeNull();
  });

  it("rejects worktree_path outside the worktrees root (path traversal)", async () => {
    // Try to read /etc/passwd by setting worktree_path to /etc.
    await publishStatus(env, "demo", "abc123", { worktree_path: "/etc" });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    expect(await store.read("abc123")).toBeNull();
  });

  it("rejects a similarly-prefixed sibling path (boundary check)", async () => {
    // worktreesRoot is "<root>/worktrees"; a sibling "<root>/worktreesEvil"
    // must not pass the isInside check.
    const evil = join(env.root, "worktreesEvil");
    await mkdir(join(evil, ".kapsis"), { recursive: true });
    await writeFile(join(evil, ".kapsis", "task-spec-with-progress.md"), "leaked");
    await publishStatus(env, "demo", "abc123", { worktree_path: evil });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    expect(await store.read("abc123")).toBeNull();
  });

  it("rejects a symlinked spec file (CWE-59 follow-symlink defense)", async () => {
    const wt = join(env.worktreesRoot, "demo-abc123");
    await mkdir(join(wt, ".kapsis"), { recursive: true });
    // Real target outside the worktrees tree.
    const realTarget = join(env.root, "secret.md");
    await writeFile(realTarget, "SECRET");
    await symlink(realTarget, join(wt, ".kapsis", "task-spec-with-progress.md"));
    await publishStatus(env, "demo", "abc123", { worktree_path: wt });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    expect(await store.read("abc123")).toBeNull();
  });

  it("returns 404 when the worktree exists but .kapsis/ does not", async () => {
    const wt = join(env.worktreesRoot, "demo-abc123");
    await mkdir(wt, { recursive: true });
    await publishStatus(env, "demo", "abc123", { worktree_path: wt });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    expect(await store.read("abc123")).toBeNull();
  });

  it("truncates spec content over the size cap", async () => {
    const cap = 256;
    // 3x cap of repeating 'a' so we definitely exceed.
    const big = "a".repeat(cap * 3);
    const wt = await writeWorktreeSpec(env.worktreesRoot, "demo-abc123", big);
    await publishStatus(env, "demo", "abc123", { worktree_path: wt });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
      maxBytes: cap,
    });
    const r = await store.read("abc123");
    expect(r).not.toBeNull();
    expect(r!.truncated).toBe(true);
    expect(r!.sizeBytes).toBe(cap * 3);
    expect(r!.spec.length).toBeLessThanOrEqual(cap);
  });
});

describe("SpecStore.read — volume fallback", () => {
  let env: Env;
  beforeEach(async () => { env = await setupEnv(); });
  afterEach(async () => { await env.cleanup(); });

  it("falls back to volume mountpoint when worktree spec is absent", async () => {
    // No worktree spec on disk.
    await publishStatus(env, "demo", "abc123", { worktree_path: null });
    // Create a fake volume mountpoint dir with a spec file in it.
    const mountpoint = join(env.root, "vol-mount");
    await mkdir(mountpoint, { recursive: true });
    await writeFile(join(mountpoint, "task-spec-with-progress.md"), "## From volume");

    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async (name) => {
        expect(name).toBe("kapsis-abc123-status");
        return mountpoint;
      },
    });
    const r = await store.read("abc123");
    expect(r).not.toBeNull();
    expect(r!.spec).toBe("## From volume");
    expect(r!.source).toBe("volume:kapsis-abc123-status");
  });

  it("does NOT fall back to volume when worktree spec exists (per-agent worktree wins)", async () => {
    const wt = await writeWorktreeSpec(env.worktreesRoot, "demo-abc123", "## From worktree");
    await publishStatus(env, "demo", "abc123", { worktree_path: wt });

    const mountpoint = join(env.root, "vol-mount");
    await mkdir(mountpoint, { recursive: true });
    await writeFile(join(mountpoint, "task-spec-with-progress.md"), "## From volume (NOT THIS)");

    let volumeCalled = false;
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => { volumeCalled = true; return mountpoint; },
    });
    const r = await store.read("abc123");
    expect(r!.spec).toBe("## From worktree");
    expect(r!.source).toBe("worktree");
    expect(volumeCalled).toBe(false);
  });

  it("rejects a symlink at the volume mountpoint path", async () => {
    await publishStatus(env, "demo", "abc123", { worktree_path: null });
    const mountpoint = join(env.root, "vol-mount");
    await mkdir(mountpoint, { recursive: true });
    const target = join(env.root, "elsewhere.md");
    await writeFile(target, "secret");
    await symlink(target, join(mountpoint, "task-spec-with-progress.md"));

    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => mountpoint,
    });
    expect(await store.read("abc123")).toBeNull();
  });

  it("returns null when podman volume inspect returns null", async () => {
    await publishStatus(env, "demo", "abc123", { worktree_path: null });
    const store = new SpecStore(env.status!, env.worktreesRoot, {
      injectedSuffix: null,
      podmanVolumeMountpoint: async () => null,
    });
    expect(await store.read("abc123")).toBeNull();
  });
});

describe("SPEC_MAX_BYTES default", () => {
  it("is 256 KB", () => {
    expect(SPEC_MAX_BYTES).toBe(256 * 1024);
  });
});
