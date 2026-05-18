import { randomBytes } from "node:crypto";
import { log } from "../logger";

/**
 * Cleanup targets recognized by the dashboard. Each target maps to the way
 * `scripts/kapsis-cleanup.sh` actually exposes that work:
 *
 * - "selective" targets each have a `--<target>` flag and run that category alone
 * - "default-bundle" targets (status, sandboxes, sanitized-git, audit,
 *   conversations) have NO selective flag in the script — they're cleaned
 *   together when the script is invoked with no target flags at all. We
 *   surface them in the UI as one combined "Stale state" target that runs
 *   the script bare so it executes its default behavior.
 */
export type CleanupTarget =
  | "stale-state"
  | "worktrees"
  | "volumes"
  | "images"
  | "containers"
  | "logs"
  | "ssh-cache"
  | "branches"
  | "all";

export interface CleanupResult {
  ok: boolean;
  dryRun: boolean;
  targets: CleanupTarget[];
  argv: string[];
  stdout: string;
  stderr: string;
  exitCode: number;
  /** Wall-clock ms from spawn to exit. */
  durationMs: number;
}

const TARGET_TO_FLAG: Record<Exclude<CleanupTarget, "stale-state">, string> = {
  worktrees: "--worktrees",
  volumes: "--volumes",
  images: "--images",
  containers: "--containers",
  logs: "--logs",
  "ssh-cache": "--ssh-cache",
  branches: "--branches",
  all: "--all",
};

const ALLOWED: ReadonlySet<CleanupTarget> = new Set(
  Object.keys(TARGET_TO_FLAG).concat("stale-state") as CleanupTarget[],
);

export function buildArgv(scriptPath: string, targets: CleanupTarget[], dryRun: boolean): string[] {
  const filtered = targets.filter((t) => ALLOWED.has(t));
  if (filtered.length === 0) {
    throw new Error("no valid cleanup targets");
  }
  if (filtered.includes("stale-state") && filtered.some((t) => t !== "stale-state")) {
    throw new Error(
      "stale-state cleanup runs the default bundle and cannot be combined with selective targets; submit it on its own",
    );
  }
  const flags: string[] = [];
  for (const t of filtered) {
    if (t === "stale-state") continue;        // bare invocation
    flags.push(TARGET_TO_FLAG[t]);
  }
  const argv = [scriptPath];
  if (dryRun) argv.push("--dry-run");
  argv.push(...flags);
  // --force is the script's "skip confirm" flag (not --yes). Required for
  // --volumes (it prompts) and harmless elsewhere.
  argv.push("--force");
  return argv;
}

/** One-shot cleanup runner. Used by tests and the non-streaming legacy path. */
export async function runCleanup(targets: CleanupTarget[], opts: { dryRun: boolean; scriptPath: string }): Promise<CleanupResult> {
  const argv = buildArgv(opts.scriptPath, targets, opts.dryRun);
  log.info("control: cleanup", { argv });
  const startedAt = Date.now();
  const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  return {
    ok: exitCode === 0,
    dryRun: opts.dryRun,
    targets: targets.filter((t) => ALLOWED.has(t)),
    argv,
    stdout: stdout.trim(),
    stderr: stderr.trim(),
    exitCode,
    durationMs: Date.now() - startedAt,
  };
}

export type CleanupRunEvent =
  | { kind: "started"; runId: string; argv: string[]; startedAt: number }
  | { kind: "stdout"; runId: string; line: string }
  | { kind: "stderr"; runId: string; line: string }
  | { kind: "exit"; runId: string; exitCode: number; durationMs: number };

/**
 * Tracks running cleanup invocations so the dashboard can stream their
 * output to the UI over SSE. POST /api/v1/maintenance/cleanup returns a
 * runId immediately and starts the job; the UI subscribes to
 * /sse/maintenance/:runId and renders the line stream in real time. This
 * replaces the old "click → freeze for 30s while the script walks
 * /worktrees → see all the output at once" pattern.
 */
export class CleanupRunner {
  // Per-run buffers so a subscriber that connects mid-run still gets the
  // backlog of lines emitted before they tuned in.
  private runs = new Map<string, {
    argv: string[];
    startedAt: number;
    buffer: CleanupRunEvent[];
    done: boolean;
    listeners: Set<(ev: CleanupRunEvent) => void>;
    result?: CleanupResult;
  }>();

  start(targets: CleanupTarget[], opts: { dryRun: boolean; scriptPath: string }): { runId: string; argv: string[] } {
    const argv = buildArgv(opts.scriptPath, targets, opts.dryRun);
    const runId = randomBytes(8).toString("hex");
    const startedAt = Date.now();
    const state = {
      argv, startedAt,
      buffer: [] as CleanupRunEvent[],
      done: false,
      listeners: new Set<(ev: CleanupRunEvent) => void>(),
      result: undefined as CleanupResult | undefined,
    };
    this.runs.set(runId, state);

    const startEv: CleanupRunEvent = { kind: "started", runId, argv, startedAt };
    state.buffer.push(startEv);

    log.info("control: cleanup (streaming)", { argv, runId });

    // Spawn + pipe stdout/stderr through a line splitter into the broker.
    void (async () => {
      const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe" });
      const stdoutP = pumpLines(proc.stdout, (line) => this.emit(runId, { kind: "stdout", runId, line }));
      const stderrP = pumpLines(proc.stderr, (line) => this.emit(runId, { kind: "stderr", runId, line }));
      const [exitCode] = await Promise.all([proc.exited, stdoutP, stderrP]);
      const durationMs = Date.now() - startedAt;
      const exitEv: CleanupRunEvent = { kind: "exit", runId, exitCode, durationMs };
      state.result = {
        ok: exitCode === 0,
        dryRun: opts.dryRun,
        targets: targets.filter((t) => ALLOWED.has(t)),
        argv,
        stdout: state.buffer.filter((e) => e.kind === "stdout").map((e) => (e as { line: string }).line).join("\n"),
        stderr: state.buffer.filter((e) => e.kind === "stderr").map((e) => (e as { line: string }).line).join("\n"),
        exitCode,
        durationMs,
      };
      state.done = true;
      this.emit(runId, exitEv);
      // Keep the buffer around for ~5 minutes so reload-after-completion
      // still shows the result.
      setTimeout(() => this.runs.delete(runId), 5 * 60 * 1000);
    })();

    return { runId, argv };
  }

  /**
   * Subscribe to a run. Returns the buffered backlog immediately plus a
   * listener that gets every subsequent event. Caller is expected to handle
   * `done = true` plus the final "exit" event to know when to close the
   * SSE stream.
   */
  subscribe(runId: string, listener: (ev: CleanupRunEvent) => void): { backlog: CleanupRunEvent[]; done: boolean; unsubscribe: () => void } | null {
    const state = this.runs.get(runId);
    if (!state) return null;
    state.listeners.add(listener);
    return {
      backlog: [...state.buffer],
      done: state.done,
      unsubscribe: () => state.listeners.delete(listener),
    };
  }

  /**
   * Snapshot of a run's current state — works mid-run too. The UI polls
   * this as a fallback when its SSE connection drops so a transient
   * network blip doesn't leave the user staring at a fake "still running"
   * indicator forever.
   */
  snapshot(runId: string): {
    runId: string;
    argv: string[];
    startedAt: number;
    done: boolean;
    exitCode: number | null;
    durationMs: number | null;
    lines: Array<{ kind: "stdout" | "stderr"; line: string }>;
  } | null {
    const state = this.runs.get(runId);
    if (!state) return null;
    const lines: Array<{ kind: "stdout" | "stderr"; line: string }> = [];
    for (const ev of state.buffer) {
      if (ev.kind === "stdout" || ev.kind === "stderr") lines.push({ kind: ev.kind, line: ev.line });
    }
    return {
      runId,
      argv: state.argv,
      startedAt: state.startedAt,
      done: state.done,
      exitCode: state.result?.exitCode ?? null,
      durationMs: state.result?.durationMs ?? null,
      lines,
    };
  }

  private emit(runId: string, ev: CleanupRunEvent): void {
    const state = this.runs.get(runId);
    if (!state) return;
    state.buffer.push(ev);
    for (const fn of state.listeners) {
      try { fn(ev); } catch (e) { log.warn("cleanup listener crash", { err: String(e) }); }
    }
  }
}

async function pumpLines(stream: ReadableStream<Uint8Array>, onLine: (line: string) => void): Promise<void> {
  const reader = stream.getReader();
  const dec = new TextDecoder();
  let carry = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      carry += dec.decode(value, { stream: true });
      const parts = carry.split("\n");
      carry = parts.pop() ?? "";
      for (const p of parts) onLine(p);
    }
    if (carry) onLine(carry);
  } finally {
    try { reader.releaseLock(); } catch { /* */ }
  }
}
