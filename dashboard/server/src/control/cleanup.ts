import { log } from "../logger";

export type CleanupTarget =
  | "status"
  | "worktrees"
  | "sandboxes"
  | "sanitized-git"
  | "volumes"
  | "images"
  | "audit"
  | "conversations"
  | "logs"
  | "containers";

export interface CleanupResult {
  ok: boolean;
  dryRun: boolean;
  targets: CleanupTarget[];
  stdout: string;
  stderr: string;
  exitCode: number;
}

const ALLOWED: ReadonlySet<CleanupTarget> = new Set([
  "status", "worktrees", "sandboxes", "sanitized-git",
  "volumes", "images", "audit", "conversations", "logs", "containers",
]);

function targetToFlag(t: CleanupTarget): string {
  return `--${t}`;
}

export async function runCleanup(targets: CleanupTarget[], opts: { dryRun: boolean; scriptPath: string }): Promise<CleanupResult> {
  const filtered = targets.filter((t) => ALLOWED.has(t));
  if (filtered.length === 0) {
    throw new Error("no valid cleanup targets");
  }
  const argv = [opts.scriptPath, ...(opts.dryRun ? ["--dry-run"] : []), ...filtered.map(targetToFlag), "--yes"];
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
    targets: filtered,
    stdout: stdout.trim(),
    stderr: stderr.trim(),
    exitCode,
  };
}
