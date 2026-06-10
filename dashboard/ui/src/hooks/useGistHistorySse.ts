import { useEffect, useRef } from "react";
import { sseEphemeral } from "../api/client";
import type { GistEntry } from "../types";

/**
 * Subscribes to `/sse/agents/<id>/gist-history` and forwards each
 * gist-appended event to onAppend. Closes the stream on unmount or when
 * `agentId` changes — without this guard, switching between agents would
 * leak EventSource connections.
 *
 * EventSource cannot send custom headers, so the bearer token is converted
 * into an ephemeral one-shot token by sseEphemeral first. That keeps the
 * long-lived bearer out of any URL Bun.serve might log.
 */
export function useGistHistorySse(agentId: string, onAppend: (entry: GistEntry) => void): void {
  const handlerRef = useRef(onAppend);
  handlerRef.current = onAppend;

  useEffect(() => {
    if (!agentId) return;
    let alive = true;
    let stream: EventSource | null = null;
    void (async () => {
      try {
        const s = await sseEphemeral(`/sse/agents/${encodeURIComponent(agentId)}/gist-history`);
        if (!alive) { s.close(); return; }
        stream = s;
        // Named event — addEventListener, not onmessage. SSE events that
        // carry an `event:` field do NOT fire the default onmessage handler.
        s.addEventListener("gist-appended", (ev: MessageEvent) => {
          try {
            const entry = JSON.parse(ev.data) as GistEntry;
            handlerRef.current(entry);
          } catch { /* malformed; ignore */ }
        });
      } catch (e) {
        console.warn("gist-history SSE disabled:", e);
      }
    })();
    return () => { alive = false; stream?.close(); };
  }, [agentId]);
}
