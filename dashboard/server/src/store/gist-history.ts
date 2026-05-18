import type { AgentStatus } from "../types";
import { GIST_HISTORY_MAX_PER_AGENT, type GistEntry } from "../types";
import type { StatusStore, StatusListener } from "./status";
import type { SseBroker } from "../sse";

/**
 * In-memory per-agent ring of gist transitions.
 *
 * Why in-memory: the gist is best-effort UX information. A dashboard restart
 * loses the history; the log file on disk is the durable ground truth, and
 * the next gist change re-seeds the ring. Persistence would mean either
 * (a) writing JSONL from this process (extra fs churn, ordering questions)
 * or (b) opting into a Kapsis-side change to have kapsis-gist-hook.sh write
 * a JSONL itself. Neither is justified for v1.
 *
 * Eviction: oldest-first when a per-agent buffer exceeds the cap. The cap
 * is a defensive bound, not a feature — a chatty agent that flips its gist
 * 5,000 times will still only retain the most recent 200. Most agents in
 * practice produce 20–80 transitions.
 *
 * Dedup: only append when the gist string actually changes value. The hook
 * touches status.gist_updated_at frequently even when the gist text is
 * identical; recording those would flood the timeline with noise.
 */
export class GistHistoryStore {
  /** agent_id → reverse-chronological list (newest at index 0). */
  private readonly history = new Map<string, GistEntry[]>();
  /** Last-seen gist text per agent, used for change detection. */
  private readonly lastGist = new Map<string, string>();
  private unsubscribe: (() => void) | null = null;

  constructor(
    private readonly statusStore: StatusStore,
    private readonly sse: SseBroker | null = null,
    private readonly maxPerAgent: number = GIST_HISTORY_MAX_PER_AGENT,
  ) {}

  /**
   * Seed from existing in-store statuses (the StatusStore's initial scan
   * has already populated it before this is called) and subscribe to live
   * changes. Listener is fire-and-forget — exceptions are caught so a buggy
   * future status format never breaks the SSE pipeline.
   */
  init(): void {
    for (const status of this.statusStore.list()) {
      this.ingest(status);
    }
    const listener: StatusListener = (status) => {
      if (!status) return;
      try {
        this.ingest(status);
      } catch { /* swallow — UX-only signal */ }
    };
    this.unsubscribe = this.statusStore.onChange(listener);
  }

  close(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
    this.history.clear();
    this.lastGist.clear();
  }

  /** Return entries for the given agent, newest first. Returns [] when unknown. */
  get(agentId: string): GistEntry[] {
    return [...(this.history.get(agentId) ?? [])];
  }

  /** Drop all state for an agent (called by the reaper when it removes one). */
  drop(agentId: string): void {
    this.history.delete(agentId);
    this.lastGist.delete(agentId);
  }

  /**
   * Examine one status and append a new entry iff the gist text changed
   * from the last seen value for this agent. Used for both init-time
   * seeding and live updates.
   *
   * Visible for testing.
   */
  ingest(status: AgentStatus): GistEntry | null {
    const gist = status.gist;
    if (typeof gist !== "string" || gist.length === 0) return null;
    const at = status.gist_updated_at ?? status.updated_at;
    if (typeof at !== "string") return null;

    const prev = this.lastGist.get(status.agent_id);
    if (prev === gist) return null;
    this.lastGist.set(status.agent_id, gist);

    const entry: GistEntry = { at, gist };
    const ring = this.history.get(status.agent_id) ?? [];
    // Newest-first: unshift, then trim from the tail. Trimming preserves the
    // most recent N — what the UI actually wants to render.
    ring.unshift(entry);
    if (ring.length > this.maxPerAgent) ring.length = this.maxPerAgent;
    this.history.set(status.agent_id, ring);

    if (this.sse) {
      this.sse.publish(`gist-history:${status.agent_id}`, {
        event: "gist-appended",
        data: entry,
      });
    }
    return entry;
  }
}
