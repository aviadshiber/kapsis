import { readFile, lstat, access } from "node:fs/promises";
import { constants as fsConst } from "node:fs";
import { join, resolve, sep } from "node:path";
import { log } from "../logger";
import { isValidAgentId } from "../validators";
import type { StatusStore } from "./status";
import { SPEC_MAX_BYTES, type SpecResponse } from "../types";

/** Filename `entrypoint.sh:1383` writes into either the worktree or the named volume. */
const SPEC_FILENAME = "task-spec-with-progress.md";

/**
 * The injected suffix is appended by entrypoint.sh with the literal sequence
 * `<original>\n\n\n<progress-instructions.md contents>`. We use the verbatim
 * text of progress-instructions.md (loaded once at construction time) to
 * detect and strip exactly that suffix — never a heuristic match — so any
 * agent that happens to write its own prose containing the word "Progress"
 * is not accidentally cropped.
 */
const PROGRESS_INSTRUCTIONS_RELATIVE = "lib/progress-instructions.md";

interface SpecStoreOpts {
  /** Optional injected-instructions text. When undefined the splitter no-ops. */
  injectedSuffix?: string | null;
  /**
   * Override `podman volume inspect`. Exposed for tests so they don't shell
   * out to a real podman binary. Returns the mountpoint path or null.
   */
  podmanVolumeMountpoint?: (volumeName: string) => Promise<string | null>;
  /** Cap. Default = SPEC_MAX_BYTES. Exposed for tests. */
  maxBytes?: number;
}

export class SpecStore {
  private readonly statusStore: StatusStore;
  private readonly worktreesRoot: string;
  private readonly injectedSuffix: string | null;
  private readonly podmanVolumeMountpoint: (volumeName: string) => Promise<string | null>;
  private readonly maxBytes: number;

  constructor(statusStore: StatusStore, worktreesRoot: string, opts: SpecStoreOpts = {}) {
    this.statusStore = statusStore;
    // Realpath-free resolve — we don't follow symlinks; we just want a clean
    // absolute baseline to compare against later. Resolving here also makes
    // the "isInside" check tolerant of trailing slashes the caller may pass.
    this.worktreesRoot = resolve(worktreesRoot);
    this.injectedSuffix = opts.injectedSuffix ?? null;
    this.podmanVolumeMountpoint = opts.podmanVolumeMountpoint ?? defaultPodmanVolumeMountpoint;
    this.maxBytes = opts.maxBytes ?? SPEC_MAX_BYTES;
  }

  /**
   * Resolve the spec for one agent, applying the safety rails described in
   * the design doc. Returns null when no spec was found anywhere it's safe
   * to read from — callers should respond 404.
   */
  async read(agentId: string): Promise<SpecResponse | null> {
    if (!isValidAgentId(agentId)) return null;

    const status = this.statusStore.get(agentId);
    if (!status) return null;

    // Path A: the per-agent worktree. Preferred because it's per-agent on
    // disk and uniquely attributable to this agent.
    if (status.worktree_path) {
      const fromWorktree = await this.readWorktreeSpec(status.worktree_path);
      if (fromWorktree) return fromWorktree;
    }

    // Path B: the per-agent named volume. Required for overlay-mode agents
    // where the worktree is read-only and the spec lives in the named
    // volume Kapsis allocates for status.
    const fromVolume = await this.readVolumeSpec(agentId);
    if (fromVolume) return fromVolume;

    return null;
  }

  /**
   * Read the spec from `<worktree>/.kapsis/task-spec-with-progress.md`. The
   * worktree_path is treated as untrusted input (it's a string in
   * status.json, which the user can hand-edit), so we enforce:
   *  - resolved path stays under the dashboard's configured worktrees root,
   *  - resolved path is not a symlink (CWE-59 — same defense as reaper.ts),
   *  - file size ≤ maxBytes (with truncation flag if exceeded).
   */
  private async readWorktreeSpec(worktreePath: string): Promise<SpecResponse | null> {
    const wt = resolve(worktreePath);
    if (!isInside(wt, this.worktreesRoot)) {
      log.debug("spec: worktree_path outside worktrees root, refusing", {
        worktreesRoot: this.worktreesRoot,
      });
      return null;
    }
    const specPath = join(wt, ".kapsis", SPEC_FILENAME);
    return this.readSpecFromPath(specPath, "worktree");
  }

  /**
   * Read the spec from `kapsis-<agent_id>-status` named volume. We call out
   * to `podman volume inspect` (overridable for tests) to learn the
   * mountpoint, then read with the same symlink + size defenses.
   */
  private async readVolumeSpec(agentId: string): Promise<SpecResponse | null> {
    const volume = `kapsis-${agentId}-status`;
    const mountpoint = await this.podmanVolumeMountpoint(volume);
    if (!mountpoint) return null;
    const specPath = join(mountpoint, SPEC_FILENAME);
    return this.readSpecFromPath(specPath, `volume:${volume}`);
  }

  private async readSpecFromPath(specPath: string, source: string): Promise<SpecResponse | null> {
    // lstat first — readFile of a symlink would follow it. We refuse to
    // follow because the link target may be an attacker-chosen path the
    // dashboard has no business reading. Same posture the reaper takes.
    let st;
    try {
      st = await lstat(specPath);
    } catch {
      return null;
    }
    if (st.isSymbolicLink()) {
      log.warn("spec: refusing to follow symlinked spec file", { specPath });
      return null;
    }
    if (!st.isFile()) return null;

    // Size cap. Read the (potentially truncated) prefix; mark truncated when
    // the on-disk file would have exceeded the cap so the UI can render a
    // banner instead of pretending the file ends here.
    const sizeBytes = st.size;
    const truncated = sizeBytes > this.maxBytes;
    let raw: string;
    try {
      if (truncated) {
        const handle = await Bun.file(specPath).slice(0, this.maxBytes);
        raw = await handle.text();
      } else {
        raw = await readFile(specPath, "utf8");
      }
    } catch (e) {
      log.debug("spec: read failed", { specPath, err: String(e) });
      return null;
    }

    const { spec, injectedInstructions } = splitInjectedSuffix(raw, this.injectedSuffix);
    return { spec, injectedInstructions, source, sizeBytes, truncated };
  }
}

/**
 * Split the user-spec from the injected progress-instructions suffix.
 *
 * `entrypoint.sh:1386-1391` writes: `<user>\n\n\n<instructions>`. The
 * exact-text match is intentional — we never strip by heuristic, only by
 * verbatim equality against the known suffix text. If the file does not
 * end in `<sep><known suffix>`, we return the whole file as `spec` and
 * `injectedInstructions: null`.
 *
 * `expectedSuffix` is the verbatim content of `progress-instructions.md`
 * loaded once at construction time. When unknown (null), we never split.
 */
export function splitInjectedSuffix(
  raw: string,
  expectedSuffix: string | null,
): { spec: string; injectedInstructions: string | null } {
  if (!expectedSuffix) return { spec: raw, injectedInstructions: null };
  const sep = "\n\n\n";
  const marker = sep + expectedSuffix;
  // The entrypoint writes `cat` output without a trailing newline guarantee;
  // tolerate one optional trailing newline that `> file` would have left.
  if (raw.endsWith(marker)) {
    return {
      spec: raw.slice(0, -marker.length),
      injectedInstructions: expectedSuffix,
    };
  }
  if (raw.endsWith(marker + "\n")) {
    return {
      spec: raw.slice(0, -(marker.length + 1)),
      injectedInstructions: expectedSuffix,
    };
  }
  return { spec: raw, injectedInstructions: null };
}

/**
 * Load the verbatim text of `scripts/lib/progress-instructions.md` from the
 * Kapsis install. Searched in order:
 *   1. $KAPSIS_HOME_DIR/scripts (the env var main.ts also uses for cleanup)
 *   2. $KAPSIS_HOME/scripts (older convention)
 *   3. process.cwd()/scripts
 *   4. caller-provided fallback
 *
 * Returns null when none exist — the splitter then becomes a no-op and the
 * UI shows the full file. That degrades gracefully (no broken splitting,
 * just the suffix is visible to the user) rather than failing the request.
 */
export async function loadProgressInstructions(opts: { fallbackPath?: string } = {}): Promise<string | null> {
  const candidates: string[] = [];
  const envKapsis = process.env.KAPSIS_HOME_DIR;
  if (envKapsis) candidates.push(join(envKapsis, "scripts", PROGRESS_INSTRUCTIONS_RELATIVE));
  const envHome = process.env.KAPSIS_HOME;
  if (envHome) candidates.push(join(envHome, "scripts", PROGRESS_INSTRUCTIONS_RELATIVE));
  candidates.push(join(process.cwd(), "scripts", PROGRESS_INSTRUCTIONS_RELATIVE));
  if (opts.fallbackPath) candidates.push(opts.fallbackPath);

  for (const p of candidates) {
    try {
      await access(p, fsConst.R_OK);
      return await readFile(p, "utf8");
    } catch { /* try next */ }
  }
  return null;
}

/**
 * Invoke `podman volume inspect --format '{{.Mountpoint}}' <name>` and
 * return the mountpoint, or null if podman is unreachable / the volume
 * does not exist. Stays consistent with the reaper's podman invocation
 * pattern (env: process.env so tests can shim PATH).
 */
async function defaultPodmanVolumeMountpoint(volumeName: string): Promise<string | null> {
  try {
    const proc = Bun.spawn(
      ["podman", "volume", "inspect", "--format", "{{.Mountpoint}}", volumeName],
      { stdout: "pipe", stderr: "pipe", env: process.env },
    );
    const out = await new Response(proc.stdout).text();
    const code = await proc.exited;
    if (code !== 0) return null;
    const mountpoint = out.trim();
    return mountpoint || null;
  } catch {
    return null;
  }
}

/**
 * True iff `path` is the same as `parent` or a descendant of it. Uses path
 * separator boundary so `/a/b` is not considered inside `/a/bc`.
 */
function isInside(path: string, parent: string): boolean {
  if (path === parent) return true;
  const withSep = parent.endsWith(sep) ? parent : parent + sep;
  return path.startsWith(withSep);
}
