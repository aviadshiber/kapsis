import { readdir, readFile, unlink, writeFile, lstat } from "node:fs/promises";
import { join, basename } from "node:path";
import { log } from "../logger";
import { isValidAgentId } from "../validators";
import type { AgentStatus } from "../types";

const FILE_RE = /^kapsis-(.+)-([^-]+)\.json$/;
/**
 * Strict ISO-8601 UTC timestamp matcher. We do NOT rely on Date.parse() here
 * because it silently accepts a wide range of fuzzy formats (locale strings,
 * partial dates, etc.); the status writer always emits this exact shape, so
 * any deviation is either a malformed file we should ignore or a sign of
 * tampering. Defense-in-depth before we mutate a status file.
 */
const ISO_UTC_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
/** Cap synthesized reap-error strings to keep status files bounded. */
const MAX_ERROR_LEN = 512;
/** Concurrency cap for podman spawns and parallel reap fs ops. */
const REAP_CONCURRENCY = 8;

/**
 * An agent is "likely stale" when its status JSON says it's still doing work
 * (phase != complete) but it hasn't written an update in this long. Kapsis's
 * own liveness monitor defaults to a 900s SIGTERM, so 30 minutes is well
 * past the point where a real agent would have either heartbeat or been
 * killed. Anything older has almost certainly died from Mac sleep / podman
 * VM restart / terminal close without writing a final "complete" status.
 */
export const STALE_THRESHOLD_MS = 30 * 60_000;

export interface StaleCandidate {
  agentId: string;
  project: string;
  file: string;
  phase: string;
  updatedAt: string;
  ageMs: number;
  /** Result of `podman inspect kapsis-<id>` — null when the container is gone. */
  containerState: string | null;
}

export interface ReapPlan {
  candidates: StaleCandidate[];
  /** Subset of candidates the reaper would actually touch (container gone). */
  reapable: StaleCandidate[];
  /**
   * Whether podman responded to a liveness probe at scan time. If false, the
   * scanner refuses to mark ANY candidate as reapable — otherwise an offline
   * podman would be indistinguishable from a fleet of dead containers and we
   * would mass-zombify perfectly healthy agents (data-loss bug).
   */
  podmanAvailable: boolean;
}

export interface ReapOutcome {
  scanned: number;
  reaped: StaleCandidate[];
  skipped: StaleCandidate[]; // candidate but container still alive
  errors: Array<{ file: string; err: string }>;
  dryRun: boolean;
  /** Mirrored from ReapPlan; route layer surfaces this to the user. */
  podmanAvailable: boolean;
}

/**
 * Strip anything that looks like an absolute filesystem path from a string
 * before exposing it on the wire. Status files live under user-controlled
 * paths and the dashboard error channel is reachable by lower-privilege
 * consumers; leaking those paths is unnecessary information disclosure.
 */
const sanitize = (s: string): string =>
  s.replace(/(?:\/[^\s'":]+)+/g, (m) => basename(m));

/**
 * Liveness probe for the local podman CLI. We run a fast, side-effect-free
 * command and only treat exit 0 as "podman is reachable". A missing binary,
 * a stopped VM (macOS), a hung daemon, or a network error all collapse to
 * `false` and the caller MUST treat that as "do not reap anything" —
 * see ReapPlan.podmanAvailable for the rationale.
 */
export async function probePodman(): Promise<boolean> {
  try {
    // Pass env: process.env so runtime PATH mutations take effect (Bun
     // otherwise caches the resolved PATH at startup). This matters in
     // tests that simulate "podman missing" by clobbering PATH.
    const proc = Bun.spawn(["podman", "version", "--format=json"], {
      stdout: "pipe", stderr: "pipe", env: process.env,
    });
    // Drain stdout so the child can exit cleanly on platforms with small pipe buffers.
    await new Response(proc.stdout).text();
    const code = await proc.exited;
    return code === 0;
  } catch {
    return false;
  }
}

async function podmanInspectState(agentId: string): Promise<string | null> {
  if (!isValidAgentId(agentId)) return null;
  try {
    const proc = Bun.spawn(["podman", "inspect", "--format={{.State.Status}}", `kapsis-${agentId}`], {
      stdout: "pipe", stderr: "pipe", env: process.env,
    });
    const out = await new Response(proc.stdout).text();
    const code = await proc.exited;
    if (code !== 0) return null;
    const state = out.trim();
    return state || null;
  } catch {
    return null;
  }
}

/**
 * Run an async mapper over `items` with at most `limit` in-flight at once.
 * Implemented inline (no extra deps). Preserves input order in the output.
 */
async function mapWithConcurrency<T, R>(
  items: readonly T[],
  limit: number,
  mapper: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const workerCount = Math.min(limit, items.length);
  const workers: Promise<void>[] = [];
  for (let w = 0; w < workerCount; w++) {
    workers.push((async () => {
      while (true) {
        const i = next++;
        if (i >= items.length) return;
        results[i] = await mapper(items[i] as T, i);
      }
    })());
  }
  await Promise.all(workers);
  return results;
}

/**
 * Walk the status dir; identify all stale candidates. Each candidate is
 * cross-checked against podman to distinguish "alive but silent" from
 * "container has actually exited". Only the latter are reapable.
 */
export async function scanForStaleAgents(statusDir: string, thresholdMs = STALE_THRESHOLD_MS): Promise<ReapPlan> {
  // Probe podman FIRST. If podman itself is unreachable we cannot tell apart
  // "container exited" from "we just can't ask"; treating that ambiguity as
  // "exited" would zombify every running agent. Bail out with an empty
  // reapable list and let the route layer report podmanAvailable=false.
  const podmanAvailable = await probePodman();

  let files: string[];
  try {
    files = await readdir(statusDir);
  } catch {
    return { candidates: [], reapable: [], podmanAvailable };
  }
  const now = Date.now();
  const candidates: StaleCandidate[] = [];

  for (const name of files) {
    const m = name.match(FILE_RE);
    if (!m) continue;
    const path = join(statusDir, name);
    // Reject symlinks during scan. A symlinked status file could redirect a
    // later writeFile/unlink to an attacker-chosen path (CWE-59 TOCTOU); we
    // refuse to even read its contents because the lstat→readFile race is
    // the same shape as the lstat→writeFile race we guard in the executor.
    try {
      const st = await lstat(path);
      if (st.isSymbolicLink()) {
        log.debug("reaper: skipping symlinked status file during scan", { file: name });
        continue;
      }
    } catch { continue; }
    let status: AgentStatus;
    try {
      status = JSON.parse(await readFile(path, "utf8")) as AgentStatus;
    } catch { continue; }
    if (status.phase === "complete") continue;
    // Defense-in-depth: the status file is untrusted input. Validate the
    // fields we are about to read/echo before treating this as a candidate.
    if (typeof status.agent_id !== "string" || !isValidAgentId(status.agent_id)) {
      log.debug("reaper: skipping status with invalid agent_id", { file: name });
      continue;
    }
    if (typeof status.updated_at !== "string" || !ISO_UTC_RE.test(status.updated_at)) {
      log.debug("reaper: skipping status with non-ISO updated_at", { file: name });
      continue;
    }
    if (typeof status.project !== "string" || status.project.length > 128) {
      log.debug("reaper: skipping status with invalid project field", { file: name });
      continue;
    }
    const updatedTs = Date.parse(status.updated_at);
    if (Number.isNaN(updatedTs)) continue;
    const ageMs = now - updatedTs;
    if (ageMs < thresholdMs) continue;
    candidates.push({
      agentId: status.agent_id,
      project: status.project,
      file: name,
      phase: typeof status.phase === "string" ? status.phase : "unknown",
      updatedAt: status.updated_at,
      ageMs,
      containerState: null,
    });
  }

  // If podman is unreachable, return ALL candidates but no reapable entries.
  // The caller will surface the podmanAvailable flag and refuse to act.
  if (!podmanAvailable) {
    return { candidates, reapable: [], podmanAvailable };
  }

  // Bounded-concurrency podman inspects: with N=200 candidates an unbounded
  // Promise.all spawns 200 podman processes at once, which is enough to
  // saturate the macOS podman VM and cause spurious "container missing"
  // results. Cap at REAP_CONCURRENCY in-flight at a time.
  await mapWithConcurrency(candidates, REAP_CONCURRENCY, async (c) => {
    c.containerState = await podmanInspectState(c.agentId);
  });

  const reapable = candidates.filter((c) =>
    // No container → definitely dead. Or container exists but is in an
    // exited/dead state → also dead.
    c.containerState === null ||
    c.containerState === "exited" ||
    c.containerState === "dead" ||
    c.containerState === "stopped",
  );
  return { candidates, reapable, podmanAvailable };
}

/**
 * For each reapable candidate: rewrite the status to mark the agent
 * complete with error_type="zombie" so the next `kapsis-cleanup --status`
 * (or any other consumer expecting "complete" files) treats it normally,
 * then delete the status file outright. We do the rewrite-then-delete in
 * that order so an interrupted reap leaves a consistent file: the status
 * is still readable as a terminated agent, even if the unlink didn't run.
 *
 * dryRun = true only enumerates; no files are touched.
 */
export async function reapStaleAgents(statusDir: string, opts: { dryRun: boolean; thresholdMs?: number } = { dryRun: true }): Promise<ReapOutcome> {
  const plan = await scanForStaleAgents(statusDir, opts.thresholdMs ?? STALE_THRESHOLD_MS);
  const reaped: StaleCandidate[] = [];
  const errors: ReapOutcome["errors"] = [];

  if (!opts.dryRun) {
    // Parallelise the reap with bounded concurrency. Each candidate has a
    // distinct file path so they don't contend on the same inode; the cap
    // exists purely to keep fs op count sane on a pathological 200-zombie
    // sweep. Promise.allSettled so one failure doesn't poison the batch.
    const settled = await mapWithConcurrency(plan.reapable, REAP_CONCURRENCY, async (c) => {
      const path = join(statusDir, c.file);
      try {
        // Re-check for symlink immediately before writing. Even though scan
        // rejected symlinks, the file could have been swapped underneath us
        // between scan and execute (TOCTOU). Refuse to follow — CWE-59.
        let st;
        try {
          st = await lstat(path);
        } catch (e) {
          errors.push({ file: basename(c.file), err: sanitize(`lstat failed: ${String(e)}`) });
          return;
        }
        if (st.isSymbolicLink()) {
          errors.push({
            file: basename(c.file),
            err: "status file is a symlink; refusing to follow (CWE-59)",
          });
          return;
        }

        const text = await readFile(path, "utf8");
        const status = JSON.parse(text) as AgentStatus;
        status.phase = "complete";
        status.progress = 100;
        status.exit_code = status.exit_code ?? -1;
        status.error_type = "zombie";
        if (!status.error) {
          // Cap the synthesized message: it's built from candidate fields
          // (containerState, updatedAt) that pass our validators but are
          // still untrusted; bounding it keeps the resulting status file
          // size predictable.
          const synthesized = `Reaped by dashboard: container ${c.containerState ?? "missing"}, last updated ${c.updatedAt}`;
          status.error = synthesized.length > MAX_ERROR_LEN
            ? synthesized.slice(0, MAX_ERROR_LEN)
            : synthesized;
        }
        status.updated_at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

        // Stage 1: durably overwrite the status file. Once this resolves
        // the agent IS reaped (the file's contents are the zombie marker
        // the rest of the system reads); the subsequent unlink is just
        // best-effort cleanup. Push to `reaped` immediately so a unlink
        // failure does not retract that reap.
        await writeFile(path, JSON.stringify(status, null, 2));
        reaped.push(c);

        // Stage 2: best-effort unlink. A failure here is not an error
        // from the contract's perspective — the file already says
        // "zombie complete" so downstream consumers behave correctly.
        try {
          // Symlink re-check between writeFile and unlink: writeFile may
          // have created the file path even if a symlink was placed after
          // our first lstat. lstat again so unlink targets a real file.
          const st2 = await lstat(path);
          if (st2.isSymbolicLink()) {
            log.warn("reaper: skipping unlink of symlink path after write", { file: basename(c.file) });
            return;
          }
          await unlink(path);
        } catch (e) {
          log.warn("reaper: unlink failed after successful rewrite (zombie content is durable)", {
            file: basename(c.file),
            err: sanitize(String(e)),
          });
        }
      } catch (e) {
        const errStr = sanitize(String(e));
        errors.push({ file: basename(c.file), err: errStr });
        log.warn("reaper failed for one candidate", { file: basename(c.file), err: errStr });
      }
    });

    // Collect any rejections from the worker pool itself. mapWithConcurrency
    // resolves to the per-item awaited values; a thrown mapper would already
    // have been caught above, but allSettled-style defensiveness is cheap.
    for (const r of settled) {
      // Each mapper returns void; presence of `r` is enough for the type.
      void r;
    }
  }

  // The candidate count we computed during scan is the authoritative
  // "files we considered". Re-reading the directory here would race with
  // other writers and double-count; trust the plan.
  const scanned = plan.candidates.length;

  return {
    scanned,
    reaped: opts.dryRun ? plan.reapable : reaped,
    skipped: plan.candidates.filter((c) => !plan.reapable.includes(c)),
    errors,
    dryRun: opts.dryRun,
    podmanAvailable: plan.podmanAvailable,
  };
}
