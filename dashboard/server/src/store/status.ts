import { readdir, readFile, watch } from "node:fs/promises";
import { join, basename } from "node:path";
import type { FSWatcher } from "node:fs";
import { log } from "../logger";
import type { AgentStatus } from "../types";

const FILE_RE = /^kapsis-(.+)-([^-]+)\.json$/;

export type StatusListener = (status: AgentStatus | null, file: string) => void;

export class StatusStore {
  private cache = new Map<string, AgentStatus>();
  private listeners = new Set<StatusListener>();
  private watcher: AbortController | null = null;

  constructor(private statusDir: string) {}

  async init(): Promise<void> {
    await this.refreshAll();
    this.startWatch();
  }

  close(): void {
    this.watcher?.abort();
    this.watcher = null;
    this.listeners.clear();
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
    for (const s of this.cache.values()) {
      if (s.agent_id === agentId) return s;
    }
    return undefined;
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
    for (const f of files) {
      if (f.startsWith(".") || !f.endsWith(".json")) continue;
      await this.refreshOne(join(this.statusDir, f));
    }
  }

  private async refreshOne(path: string): Promise<void> {
    const file = basename(path);
    if (!FILE_RE.test(file)) return;
    try {
      const buf = await readFile(path, "utf8");
      const status = JSON.parse(buf) as AgentStatus;
      this.cache.set(file, status);
      for (const fn of this.listeners) fn(status, file);
    } catch (e) {
      // Atomic mv via temp file occasionally races; ignore single-shot read errors.
      log.debug("status read race", { path, err: String(e) });
    }
  }

  private async dropOne(file: string): Promise<void> {
    if (this.cache.delete(file)) {
      for (const fn of this.listeners) fn(null, file);
    }
  }

  private startWatch(): void {
    this.watcher = new AbortController();
    (async () => {
      try {
        const events = watch(this.statusDir, { signal: this.watcher!.signal });
        let pending: ReturnType<typeof setTimeout> | null = null;
        for await (const ev of events) {
          if (!ev.filename) continue;
          const file = ev.filename;
          if (file.startsWith(".") || !file.endsWith(".json")) continue;
          if (pending) clearTimeout(pending);
          pending = setTimeout(() => {
            void this.refreshOne(join(this.statusDir, file)).then(async () => {
              const f = Bun.file(join(this.statusDir, file));
              if (!(await f.exists())) await this.dropOne(file);
            });
          }, 50);
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
