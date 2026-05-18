import { readdir, readFile, watch } from "node:fs/promises";
import { join, basename } from "node:path";
import type { FSWatcher } from "node:fs";
import { log } from "../logger";
import type { AgentStatus } from "../types";

const FILE_RE = /^kapsis-(.+)-([^-]+)\.json$/;
const DEBOUNCE_MS = 50;
// Atomic rename briefly removes the destination file before the new one
// appears. Wait this long before treating a "file vanished" event as a real
// delete; otherwise the UI flickers every time status.sh writes.
const DROP_GRACE_MS = 200;

export type StatusListener = (status: AgentStatus | null, file: string) => void;

export class StatusStore {
  private cache = new Map<string, AgentStatus>();
  private byAgentId = new Map<string, AgentStatus>();
  private listeners = new Set<StatusListener>();
  private watcher: AbortController | null = null;
  private debounce = new Map<string, ReturnType<typeof setTimeout>>();
  private dropTimers = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(private statusDir: string) {}

  async init(): Promise<void> {
    await this.refreshAll();
    this.startWatch();
  }

  close(): void {
    this.watcher?.abort();
    this.watcher = null;
    this.listeners.clear();
    for (const t of this.debounce.values()) clearTimeout(t);
    this.debounce.clear();
    for (const t of this.dropTimers.values()) clearTimeout(t);
    this.dropTimers.clear();
  }

  onChange(fn: StatusListener): () => void {
    this.listeners.add(fn);
    return () => { this.listeners.delete(fn); };
  }

  list(): AgentStatus[] {
    return [...this.cache.values()].sort(
      (a, b) => Date.parse(b.started_at) - Date.parse(a.started_at),
    );
  }

  get(agentId: string): AgentStatus | undefined {
    return this.byAgentId.get(agentId);
  }

  filePathFor(project: string, agentId: string): string {
    return join(this.statusDir, `kapsis-${project}-${agentId}.json`);
  }

  private async refreshAll(): Promise<void> {
    let files: string[];
    try {
      files = await readdir(this.statusDir);
    } catch (e) {
      log.warn("status dir not readable", { dir: this.statusDir, err: String(e) });
      return;
    }
    const candidates = files.filter((f) => !f.startsWith(".") && f.endsWith(".json"));
    // Parallel reads — 249+ files would otherwise serialize boot.
    await Promise.all(candidates.map((f) => this.refreshOne(join(this.statusDir, f))));
  }

  private async refreshOne(path: string): Promise<void> {
    const file = basename(path);
    if (!FILE_RE.test(file)) return;
    try {
      const buf = await readFile(path, "utf8");
      const status = JSON.parse(buf) as AgentStatus;
      const prev = this.cache.get(file);
      this.cache.set(file, status);
      this.byAgentId.set(status.agent_id, status);
      // If a drop was pending (the file briefly vanished during atomic
      // rename), cancel it — the file is back.
      const pendingDrop = this.dropTimers.get(file);
      if (pendingDrop) {
        clearTimeout(pendingDrop);
        this.dropTimers.delete(file);
      }
      // Only notify on genuine changes to avoid SSE churn during boot scan.
      if (!prev || prev.updated_at !== status.updated_at || prev.phase !== status.phase) {
        for (const fn of this.listeners) fn(status, file);
      }
    } catch (e) {
      // Atomic mv via temp file occasionally races; ignore single-shot read errors.
      log.debug("status read race", { path, err: String(e) });
    }
  }

  private dropOneSoon(file: string): void {
    // Schedule a delete after a grace period; if refreshOne sees the file
    // come back in that window, it cancels the timer.
    if (this.dropTimers.has(file)) return;
    const t = setTimeout(() => {
      this.dropTimers.delete(file);
      const prev = this.cache.get(file);
      if (this.cache.delete(file)) {
        if (prev) this.byAgentId.delete(prev.agent_id);
        for (const fn of this.listeners) fn(null, file);
      }
    }, DROP_GRACE_MS);
    this.dropTimers.set(file, t);
  }

  private startWatch(): void {
    this.watcher = new AbortController();
    (async () => {
      try {
        const events = watch(this.statusDir, { signal: this.watcher!.signal });
        for await (const ev of events) {
          if (!ev.filename) continue;
          const file = ev.filename;
          if (file.startsWith(".") || !file.endsWith(".json")) continue;
          // Per-file debounce so simultaneous bursts on different files
          // don't lose any but the last filename's refresh.
          const existing = this.debounce.get(file);
          if (existing) clearTimeout(existing);
          const t = setTimeout(() => {
            this.debounce.delete(file);
            void this.refreshOne(join(this.statusDir, file)).then(async () => {
              const f = Bun.file(join(this.statusDir, file));
              if (!(await f.exists())) this.dropOneSoon(file);
            });
          }, DEBOUNCE_MS);
          this.debounce.set(file, t);
        }
      } catch (e) {
        if ((e as { name?: string }).name !== "AbortError") {
          log.error("status watcher crashed", { err: String(e) });
        }
      }
    })();
  }
}

export type { FSWatcher };
