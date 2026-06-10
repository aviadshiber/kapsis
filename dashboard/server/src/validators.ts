import { errorResponse } from "./http";

// Matches the agent-id formats actually produced by scripts/launch-agent.sh:
//   - default: 6-char hex (e.g. ebedab)
//   - user-supplied via --agent-id: lowercase ASCII / digits / hyphen / underscore
// 3..64 chars. Underscore is intentionally included to match real-world ids
// used by integration tests and the slack-bot agent (e.g. slack-bot_t1).
const AGENT_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$/;

const RESERVED_ID = new Set(["", ".", "..", "-", "_"]);

export function isValidAgentId(id: string): boolean {
  if (RESERVED_ID.has(id)) return false;
  // Reject ids that start with `-` so shelling out (`podman kill <id>`) can't
  // confuse them with a flag, even though our argv invocations always pass
  // the literal `kapsis-` prefix. AGENT_ID_RE already enforces alphanumeric
  // first char, but keep the explicit guard for clarity.
  if (id.startsWith("-")) return false;
  return AGENT_ID_RE.test(id);
}

export function requireAgentId(id: string): Response | null {
  if (isValidAgentId(id)) return null;
  return errorResponse(400, "invalid agent id", { agentId: id });
}

/** Same shape used by control/kill.ts so the regex stays in one place. */
export const AGENT_ID_PATTERN = AGENT_ID_RE;
