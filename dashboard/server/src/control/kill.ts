import { mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { log } from "../logger";

export interface KillResult {
  ok: boolean;
  signal: "TERM" | "KILL";
  stdout: string;
  stderr: string;
  exitCode: number;
  // True when `podman kill` failed because the container no longer exists.
  // The caller should treat this as a successful no-op rather than a server
  // error — the kill is unnecessary because the container has already exited
  // (typical for very stale agents whose status.json was never finalized).
  containerMissing?: boolean;
}

// Keep this in sync with src/validators.ts AGENT_ID_PATTERN. We don't import
// from validators to keep this module dependency-free (it's also used from
// tests that don't want to pull in http.ts via the validators import chain).
const AGENT_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$/;
const CONTAINER_MISSING_RE = /no (?:such )?container/i;

export function isContainerMissingStderr(stderr: string): boolean {
  return CONTAINER_MISSING_RE.test(stderr);
}

export function killMarkerPath(agentId: string): string {
  const dir = process.env.KAPSIS_STATUS_DIR ?? join(homedir(), ".kapsis", "status");
  return join(dir, `${agentId}.kill-requested`);
}

// Drop a marker file the host-side launch-agent post-container handler reads
// to distinguish a user-initiated kill from a real mount failure or agent
// crash. Without this, every dashboard SIGTERM tears down the container and
// the entrypoint's mount probe records `mount_failure` as the terminal error.
export async function writeKillMarker(agentId: string, signal: "TERM" | "KILL"): Promise<void> {
  if (!AGENT_ID_RE.test(agentId)) {
    throw new Error(`invalid agent id: ${agentId}`);
  }
  const marker = killMarkerPath(agentId);
  try {
    await mkdir(join(marker, ".."), { recursive: true });
    const payload = JSON.stringify({
      requested_at: new Date().toISOString(),
      source: "dashboard",
      signal,
    }) + "\n";
    await writeFile(marker, payload, { encoding: "utf8" });
  } catch (e) {
    log.warn("kill marker write failed (proceeding with podman kill anyway)", { agentId, err: String(e) });
  }
}

export async function killAgent(agentId: string, opts: { signal?: "TERM" | "KILL"; backend?: "podman" | "k8s" } = {}): Promise<KillResult> {
  if (!AGENT_ID_RE.test(agentId)) {
    throw new Error(`invalid agent id: ${agentId}`);
  }
  const signal = opts.signal ?? "TERM";
  const backend = opts.backend ?? "podman";
  const containerName = `kapsis-${agentId}`;

  if (backend === "k8s") {
    return run(["kubectl", "delete", "agentrequest", containerName, "--ignore-not-found=true"]);
  }

  await writeKillMarker(agentId, signal);
  const result = await run(["podman", "kill", "--signal", signal, containerName]);

  if (!result.ok && isContainerMissingStderr(result.stderr)) {
    result.containerMissing = true;
    result.ok = true;
  }
  return result;
}

async function run(argv: string[]): Promise<KillResult> {
  log.info("control: running", { argv });
  const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  const signal = (argv.includes("--signal") ? argv[argv.indexOf("--signal") + 1] : "TERM") as "TERM" | "KILL";
  return { ok: exitCode === 0, signal, stdout: stdout.trim(), stderr: stderr.trim(), exitCode };
}
