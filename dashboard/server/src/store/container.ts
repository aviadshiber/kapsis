import { log } from "../logger";

export interface ContainerInfo {
  name: string;
  exists: boolean;
  state: string | null;
  startedAt: string | null;
  image: string | null;
  pid: number | null;
  exitCode: number | null;
}

export interface ContainerStats {
  cpuPercent: number | null;
  memBytes: number | null;
  memLimitBytes: number | null;
}

function containerName(agentId: string): string {
  return `kapsis-${agentId}`;
}

export async function inspectContainer(agentId: string): Promise<ContainerInfo> {
  const name = containerName(agentId);
  try {
    const proc = Bun.spawn(["podman", "inspect", "--format=json", name], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = await new Response(proc.stdout).text();
    const code = await proc.exited;
    if (code !== 0) {
      return { name, exists: false, state: null, startedAt: null, image: null, pid: null, exitCode: null };
    }
    const arr = JSON.parse(out) as Array<{
      State?: { Status?: string; StartedAt?: string; Pid?: number; ExitCode?: number };
      ImageName?: string;
      Image?: string;
    }>;
    const c = arr[0];
    return {
      name,
      exists: true,
      state: c?.State?.Status ?? null,
      startedAt: c?.State?.StartedAt ?? null,
      image: c?.ImageName ?? c?.Image ?? null,
      pid: c?.State?.Pid ?? null,
      exitCode: c?.State?.ExitCode ?? null,
    };
  } catch (e) {
    log.debug("podman inspect failed", { agentId, err: String(e) });
    return { name, exists: false, state: null, startedAt: null, image: null, pid: null, exitCode: null };
  }
}

export async function containerStats(agentId: string): Promise<ContainerStats> {
  const name = containerName(agentId);
  try {
    const proc = Bun.spawn(
      ["podman", "stats", "--no-stream", "--format=json", name],
      { stdout: "pipe", stderr: "pipe" },
    );
    const out = await new Response(proc.stdout).text();
    const code = await proc.exited;
    if (code !== 0) return { cpuPercent: null, memBytes: null, memLimitBytes: null };
    const arr = JSON.parse(out) as Array<{
      cpu_percent?: string | number;
      mem_usage_bytes?: number;
      mem_limit_bytes?: number;
      MemUsage?: number;
      MemLimit?: number;
      CPU?: string;
    }>;
    const c = arr[0];
    const cpuRaw = c?.cpu_percent ?? c?.CPU;
    const cpu = typeof cpuRaw === "number" ? cpuRaw : parseFloat(String(cpuRaw ?? "").replace("%", "")) || null;
    return {
      cpuPercent: Number.isFinite(cpu) ? (cpu as number) : null,
      memBytes: c?.mem_usage_bytes ?? c?.MemUsage ?? null,
      memLimitBytes: c?.mem_limit_bytes ?? c?.MemLimit ?? null,
    };
  } catch {
    return { cpuPercent: null, memBytes: null, memLimitBytes: null };
  }
}
