import { readdir, readFile, watch, lstat } from "node:fs/promises";
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
// Backstop reconcile cadence. fs.watch on macOS FSEvents can drop events
// under load (parallel matrix CI runners, virtualized hosts), leaving a
// finished agent's status file deleted on disk but still present in the
// cache. A periodic directory rescan catches the gap. 30s is cheap (one
// readdir per tick) and bounds the worst-case dashboard staleness.
const DEFAULT_RECONCILE_INTERVAL_MS = 30_000;

export type StatusListener = (status: AgentStatus | null, file: string) => void;

export interface StatusStoreOptions {
  /**
   * How often to rescan the status directory as a safety net against dropped
   * fs.watch events. Defaults to 30s. Tests use a much shorter value so the
   * reconcile loop closes the gap within the test timeout.
   *
   * Set to 0 to disable reconciliation entirely (useful for tests that want
   * to assert pure fs.watch behavior).
   */
  reconcileIntervalMs?: number;
}

export class StatusStore {
  private cache = new Map<string, AgentStatus>();
  private byAgentId = new Map<string, AgentStatus>();
  private listeners = new Set<StatusListener>();
  private watcher: AbortController | null = null;
  private debounce = new Map<string, ReturnType<typeof setTimeout>>();
  private dropTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private reconcileTimer: ReturnType<typeof setInterval> | null = null;
  private reconcileIntervalMs: number;

  constructor(private statusDir: string, opts: StatusStoreOptions = {}) {
    this.reconcileIntervalMs = opts.reconcileIntervalMs ?? DEFAULT_RECONCILE_INTERVAL_MS;
  }

  async init(): Promise<void> {
    await this.refreshAll();
    this.startWatch();
    this.startReconcile();
  }

  close(): void {
    this.watcher?.abort();
    this.watcher = null;
    if (this.reconcileTimer) {
      clearInterval(this.reconcileTimer);
      this.reconcileTimer = null;
    }
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
      // Symlink guard (defense in depth, parity with reaper.ts:170-172). A
      // symlinked status file could redirect reads to an arbitrary path the
      // dashboard process can reach (e.g. /etc/passwd via a kapsis-*-*.json
      // symlink). status files are produced by kapsis itself via atomic mv,
      // never as symlinks; rejecting them here closes the surface even if
      // the status dir's permissions ever weaken.
      const st = await lstat(path);
      if (st.isSymbolicLink()) {
        log.debug("status: skipping symlinked file", { file });
        return;
      }
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
      // lstat ENOENT also lands here (file vanished between readdir and lstat).
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

  private startReconcile(): void {
    if (this.reconcileIntervalMs <= 0) return;
    this.reconcileTimer = setInterval(() => {
      void this.reconcile().catch((e: unknown) => {
        log.warn("status reconcile failed", { err: String(e) });
      });
    }, this.reconcileIntervalMs);
    // Don't keep the event loop alive for the timer alone — when the server
    // shuts down (e.g. via SIGTERM), Bun should be free to exit even if
    // close() wasn't explicitly called.
    if (typeof (this.reconcileTimer as { unref?: () => void }).unref === "function") {
      (this.reconcileTimer as unknown as { unref: () => void }).unref();
    }
  }

  /**
   * Compare on-disk directory contents to cache and reconcile gaps.
   *
   * - Files in cache but missing on disk → dropOneSoon (notifies listeners
   *   with null after the same grace period an fs.watch-driven delete uses).
   * - Files on disk but missing from cache → refreshOne (notifies listeners
   *   with the loaded status).
   * - Files on disk AND in cache → refreshOne. refreshOne's diff check
   *   (`!prev || prev.updated_at !== status.updated_at || prev.phase !==
   *   status.phase`) suppresses no-op notifications when content is
   *   unchanged, but catches the case where fs.watch dropped a modify
   *   event (file still on disk, content changed since last refresh).
   *
   * Exposed via the periodic interval started in `startReconcile()` as a
   * safety net against dropped fs.watch events (macOS FSEvents under load).
   * Also useful in tests that want to force a synchronous reconciliation.
   */
  async reconcile(): Promise<void> {
    let files: string[];
    try {
      files = await readdir(this.statusDir);
    } catch {
      return; // Directory transiently missing; refreshAll handles full failures.
    }
    const onDisk = files.filter((f) => !f.startsWith(".") && f.endsWith(".json"));
    const onDiskSet = new Set(onDisk);
    // Deletes missed by fs.watch — schedule drop with the same grace period
    // an atomic-rename write would use, so a concurrent write that just
    // happened to land between readdir and the reconcile tick doesn't
    // produce a spurious null notification.
    for (const file of this.cache.keys()) {
      if (!onDiskSet.has(file)) this.dropOneSoon(file);
    }
    // Refresh every on-disk file in parallel — same shape as refreshAll on
    // boot. Covers BOTH creates and stale-updates missed by fs.watch (the
    // diff check inside refreshOne suppresses notifications when content
    // is unchanged, so unchanged cache entries are zero-overhead beyond
    // one stat+read per tick).
    await Promise.all(onDisk.map((f) => this.refreshOne(join(this.statusDir, f))));
  }
}

export type { FSWatcher };
