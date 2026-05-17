import { errorResponse } from "./http";

// Matches the agent-id format produced by scripts/launch-agent.sh: 6-char hex
// by default, but operators sometimes give longer custom ids (slack-bot,
// integration-test names) so we accept hyphens and 3–32 chars total.
const AGENT_ID_RE = /^[a-zA-Z0-9-]{3,32}$/;

const RESERVED_ID = new Set(["", ".", "..", "-"]);

export function isValidAgentId(id: string): boolean {
  if (RESERVED_ID.has(id)) return false;
  // Reject ids that start with `-` so shelling out (`podman kill <id>`) can't
  // confuse them with a flag, even though our argv invocations always pass
  // the literal `kapsis-` prefix.
  if (id.startsWith("-")) return false;
  return AGENT_ID_RE.test(id);
}

export function requireAgentId(id: string): Response | null {
  if (isValidAgentId(id)) return null;
  return errorResponse(400, "invalid agent id", { agentId: id });
}

/** Same shape used by control/kill.ts so the regex stays in one place. */
export const AGENT_ID_PATTERN = AGENT_ID_RE;
