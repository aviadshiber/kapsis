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
  | "stale-state"     // bare invocation → worktrees + sandboxes + status + sanitized-git + audit + conversations
  | "worktrees"       // --worktrees alone (selective)
  | "volumes"         // --volumes
  | "images"          // --images
  | "containers"      // --containers
  | "logs"            // --logs
  | "ssh-cache"       // --ssh-cache
  | "branches"        // --branches
  | "all";            // --all (everything, with confirm prompt in script — see SCRIPT_NEEDS_FORCE)

export interface CleanupResult {
  ok: boolean;
  dryRun: boolean;
  targets: CleanupTarget[];
  argv: string[];
  stdout: string;
  stderr: string;
  exitCode: number;
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

/**
 * Build the argv passed to kapsis-cleanup.sh for a given set of targets.
 *
 * Special cases:
 *
 * - "stale-state": runs the script with no per-target flags (just --dry-run
 *   and --force as needed). The script's bare-invocation path then cleans
 *   the bundled default categories. Mixing "stale-state" with any selective
 *   target is rejected because the selective flag would suppress the
 *   default block.
 * - "all": invoked alone (selective flag set), which the script handles by
 *   cleaning every category including the default bundle.
 *
 * The script's "yes" equivalent is --force, not --yes — make sure to use it.
 */
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

export async function runCleanup(targets: CleanupTarget[], opts: { dryRun: boolean; scriptPath: string }): Promise<CleanupResult> {
  const argv = buildArgv(opts.scriptPath, targets, opts.dryRun);
  log.info("control: cleanup", { argv });
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
  };
}
