import { readdir, readFile, unlink, writeFile, stat } from "node:fs/promises";
import { join, basename } from "node:path";
import { log } from "../logger";
import { isValidAgentId } from "../validators";
import type { AgentStatus } from "../types";

const FILE_RE = /^kapsis-(.+)-([^-]+)\.json$/;
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
}

async function podmanInspectState(agentId: string): Promise<string | null> {
  if (!isValidAgentId(agentId)) return null;
  try {
    const proc = Bun.spawn(["podman", "inspect", "--format={{.State.Status}}", `kapsis-${agentId}`], {
      stdout: "pipe", stderr: "pipe",
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
 * Walk the status dir; identify all stale candidates. Each candidate is
 * cross-checked against podman to distinguish "alive but silent" from
 * "container has actually exited". Only the latter are reapable.
 */
export async function scanForStaleAgents(statusDir: string, thresholdMs = STALE_THRESHOLD_MS): Promise<ReapPlan> {
  let files: string[];
  try {
    files = await readdir(statusDir);
  } catch {
    return { candidates: [], reapable: [] };
  }
  const now = Date.now();
  const candidates: StaleCandidate[] = [];

  for (const name of files) {
    const m = name.match(FILE_RE);
    if (!m) continue;
    const path = join(statusDir, name);
    let status: AgentStatus;
    try {
      status = JSON.parse(await readFile(path, "utf8")) as AgentStatus;
    } catch { continue; }
    if (status.phase === "complete") continue;
    const updatedTs = Date.parse(status.updated_at);
    if (Number.isNaN(updatedTs)) continue;
    const ageMs = now - updatedTs;
    if (ageMs < thresholdMs) continue;
    candidates.push({
      agentId: status.agent_id,
      project: status.project,
      file: name,
      phase: status.phase,
      updatedAt: status.updated_at,
      ageMs,
      containerState: null,
    });
  }

  // Parallel podman inspects — bounded by the candidate count, which is
  // already small (typically <50 even on heavy machines).
  await Promise.all(candidates.map(async (c) => {
    c.containerState = await podmanInspectState(c.agentId);
  }));

  const reapable = candidates.filter((c) =>
    // No container → definitely dead. Or container exists but is in an
    // exited/dead state → also dead.
    c.containerState === null ||
    c.containerState === "exited" ||
    c.containerState === "dead" ||
    c.containerState === "stopped",
  );
  return { candidates, reapable };
}

export interface ReapOutcome {
  scanned: number;
  reaped: StaleCandidate[];
  skipped: StaleCandidate[]; // candidate but container still alive
  errors: Array<{ file: string; err: string }>;
  dryRun: boolean;
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
    for (const c of plan.reapable) {
      const path = join(statusDir, c.file);
      try {
        const text = await readFile(path, "utf8");
        const status = JSON.parse(text) as AgentStatus;
        status.phase = "complete";
        status.progress = 100;
        status.exit_code = status.exit_code ?? -1;
        status.error_type = "zombie";
        status.error = status.error ?? `Reaped by dashboard: container ${c.containerState ?? "missing"}, last updated ${c.updatedAt}`;
        status.updated_at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
        // Best-effort terminal-state rewrite first; unlink second so an
        // interrupted reap leaves a coherent file.
        await writeFile(path, JSON.stringify(status, null, 2));
        await unlink(path);
        reaped.push(c);
      } catch (e) {
        errors.push({ file: c.file, err: String(e) });
        log.warn("reaper failed for one candidate", { file: c.file, err: String(e) });
      }
    }
  }

  // Verify total count for the wire reporter (some files may have been
  // deleted out from under us during the scan).
  let scanned = plan.candidates.length;
  try { scanned = (await readdir(statusDir)).filter((f) => FILE_RE.test(f)).length; } catch { /* */ }
  void stat;

  return {
    scanned,
    reaped: opts.dryRun ? plan.reapable : reaped,
    skipped: plan.candidates.filter((c) => !plan.reapable.includes(c)),
    errors,
    dryRun: opts.dryRun,
  };
}
