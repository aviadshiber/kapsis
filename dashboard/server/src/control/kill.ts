import { log } from "../logger";

export interface KillResult {
  ok: boolean;
  signal: "TERM" | "KILL";
  stdout: string;
  stderr: string;
  exitCode: number;
}

const AGENT_ID_RE = /^[a-zA-Z0-9-]{3,32}$/;

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
  return run(["podman", "kill", "--signal", signal, containerName]);
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
