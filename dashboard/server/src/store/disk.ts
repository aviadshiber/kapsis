import { lstat, readdir } from "node:fs/promises";
import { join } from "node:path";
import type { KapsisPaths } from "../config";
import type { DiskUsageEntry } from "../types";
import { log } from "../logger";

const TIMEOUT_MS = 10_000;
const CACHE_TTL_MS = 30_000;

async function dirSize(path: string): Promise<{ bytes: number; items: number }> {
  let bytes = 0;
  let items = 0;
  const stack = [path];
  const deadline = Date.now() + TIMEOUT_MS;
  while (stack.length > 0) {
    if (Date.now() > deadline) {
      log.warn("dirSize timed out", { path });
      break;
    }
    const cur = stack.pop()!;
    let entries: string[];
    try { entries = await readdir(cur); } catch { continue; }
    for (const name of entries) {
      const child = join(cur, name);
      // Use lstat (not stat) so we don't follow symlinks. A hostile container
      // could plant a symlink inside a podman volume mountpoint that points
      // back to $HOME or /, which would otherwise blow our scan budget and
      // expose unrelated file metadata.
      let st;
      try { st = await lstat(child); } catch { continue; }
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) stack.push(child);
      else if (st.isFile()) {
        bytes += st.size;
        items++;
      }
    }
  }
  return { bytes, items };
}

async function podmanVolumes(): Promise<DiskUsageEntry> {
  try {
    const proc = Bun.spawn(["podman", "volume", "ls", "--filter", "name=kapsis-", "--format", "{{.Name}}\t{{.Mountpoint}}"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    const mounts: string[] = [];
    for (const line of out.split("\n")) {
      const [, mp] = line.split("\t");
      if (mp) mounts.push(mp);
    }
    // Parallel walk — was serial before, doubled wall-clock for users with
    // many per-agent volumes.
    const sizes = await Promise.all(mounts.map((mp) => dirSize(mp)));
    let bytes = 0;
    let items = 0;
    for (const s of sizes) { bytes += s.bytes; items += s.items; }
    return { category: "podman-volumes", bytes, items };
  } catch (e) {
    log.warn("podman volume scan failed", { err: String(e) });
    return { category: "podman-volumes", bytes: 0, items: 0 };
  }
}

async function podmanImages(): Promise<DiskUsageEntry> {
  try {
    const proc = Bun.spawn(["podman", "images", "--filter", "reference=kapsis-*", "--format", "{{.Size}}"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    let bytes = 0;
    let items = 0;
    for (const raw of out.split("\n")) {
      const line = raw.trim();
      if (!line) continue;
      items++;
      bytes += parsePodmanSize(line);
    }
    return { category: "podman-images", bytes, items };
  } catch (e) {
    log.warn("podman image scan failed", { err: String(e) });
    return { category: "podman-images", bytes: 0, items: 0 };
  }
}

export function parsePodmanSize(s: string): number {
  // podman emits sizes like "1.2GB", "512MB", "12.3kB"
  const m = s.match(/^([\d.]+)\s*([kKmMgGtT]?)B?$/);
  if (!m) return 0;
  const n = parseFloat(m[1]!);
  const unit = m[2]!.toLowerCase();
  const mult = unit === "k" ? 1024 : unit === "m" ? 1024 ** 2 : unit === "g" ? 1024 ** 3 : unit === "t" ? 1024 ** 4 : 1;
  return Math.round(n * mult);
}

export class DiskUsageStore {
  private cache: { value: DiskUsageEntry[]; at: number } | null = null;
  private inFlight: Promise<DiskUsageEntry[]> | null = null;

  constructor(private paths: KapsisPaths) {}

  invalidate(): void {
    this.cache = null;
  }

  async snapshot(): Promise<DiskUsageEntry[]> {
    if (this.cache && Date.now() - this.cache.at < CACHE_TTL_MS) {
      return this.cache.value;
    }
    if (this.inFlight) return this.inFlight;
    this.inFlight = this.computeSnapshot().finally(() => { this.inFlight = null; });
    return this.inFlight;
  }

  private async computeSnapshot(): Promise<DiskUsageEntry[]> {
    const dirs: Array<[string, string]> = [
      ["status", this.paths.status],
      ["audit", this.paths.audit],
      ["logs", this.paths.logs],
      ["conversations", this.paths.conversations],
      ["worktrees", this.paths.worktrees],
      ["sandboxes", this.paths.sandboxes],
      ["sanitized-git", this.paths.sanitizedGit],
    ];
    const results = await Promise.all(dirs.map(async ([cat, dir]) => {
      const { bytes, items } = await dirSize(dir);
      return { category: cat, bytes, items };
    }));
    const [volumes, images] = await Promise.all([podmanVolumes(), podmanImages()]);
    const snapshot = [...results, volumes, images];
    this.cache = { value: snapshot, at: Date.now() };
    return snapshot;
  }
}
