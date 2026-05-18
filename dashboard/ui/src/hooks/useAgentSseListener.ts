import { useEffect, useRef } from "react";
import { sseEphemeral } from "../api/client";
import type { AgentStatus } from "../types";

interface AgentSseHandlers {
  onAgentChanged?: (status: AgentStatus | null, file?: string) => void;
  onAgentReaped?: (agentId: string, project: string) => void;
}

/**
 * Subscribes to /sse/agents and forwards parsed events to the provided
 * handlers. Both views (AgentList, AgentDetail) need exactly this wiring;
 * extracting it here removes ~30 lines of duplicated boilerplate per view.
 *
 * Note: SSE events that carry an `event:` field do NOT fire onmessage —
 * they fire addEventListener(<event>, ...). We subscribe to the named events
 * "agent-changed" and "agent-reaped" so callers actually see updates.
 *
 * The hook intentionally takes only the parsed payload to its handlers; any
 * view-specific logic (e.g. row removal via filename pattern parsing) lives
 * in the caller, not here.
 */
export function useAgentSseListener(handlers: AgentSseHandlers): void {
  // Stash handlers in a ref so changing identities between renders does not
  // tear down the SSE stream every render. The effect should only re-run if
  // the SSE wiring itself needs to change (which it doesn't — never).
  const handlersRef = useRef<AgentSseHandlers>(handlers);
  handlersRef.current = handlers;

  useEffect(() => {
    let alive = true;
    let stream: EventSource | null = null;

    void (async () => {
      try {
        const s = await sseEphemeral("/sse/agents");
        if (!alive) { s.close(); return; }
        stream = s;
        s.addEventListener("agent-changed", (ev: MessageEvent) => {
          try {
            const msg = JSON.parse(ev.data) as { status: AgentStatus | null; file?: string };
            handlersRef.current.onAgentChanged?.(msg.status, msg.file);
          } catch { /* parse error or heartbeat */ }
        });
        s.addEventListener("agent-reaped", (ev: MessageEvent) => {
          try {
            const { agentId, project } = JSON.parse(ev.data) as { agentId: string; project: string };
            handlersRef.current.onAgentReaped?.(agentId, project);
          } catch { /* */ }
        });
      } catch (e) {
        console.warn("SSE disabled:", e);
      }
    })();

    return () => { alive = false; stream?.close(); };
  }, []);
}
