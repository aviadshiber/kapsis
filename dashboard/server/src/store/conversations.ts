import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import type { ArtifactEntry } from "@kapsis/dashboard-shared";

export interface ConversationEntry {
  agentId: string;
  files: Array<{ name: string; size: number; mtime: string }>;
  totalBytes: number;
  empty: boolean;
}

// Path-traversal guard shared by every filename accepted from a caller.
// Rejects '/', '..', and a leading '.' — reused verbatim by both
// readFile() (conversations/<agentId>/<name>) and readArtifact()
// (statusDir/<name>) so there is exactly one guard to review, per the
// design brief's guardrail for Issue #430.
function isUnsafeName(name: string): boolean {
  return name.includes("/") || name.includes("..") || name.startsWith(".");
}

// Side-channel artifact whitelist (Issue #430, defect 3). MUST match,
// filename-for-filename, the basenames scripts/lib/status-sync.sh:92
// documents as the legitimate side-channel artifacts it mirrors:
// response-<id>.md, decisions-<id>.json, debug-<id>.log — written by
// scripts/hooks/kapsis-status-hook.sh with <id> equal to the exact agent id
// (KAPSIS_STATUS_AGENT_ID). No additions, no loosening (e.g. no wildcard
// extensions).
const ARTIFACT_KINDS: Array<{ kind: ArtifactEntry["kind"]; prefix: string; suffix: string }> = [
  { kind: "response", prefix: "response-", suffix: ".md" },
  { kind: "decisions", prefix: "decisions-", suffix: ".json" },
  { kind: "debug", prefix: "debug-", suffix: ".log" },
];

export class ConversationStore {
  constructor(private convDir: string, private statusDir?: string) {}

  async describe(agentId: string): Promise<ConversationEntry> {
    const dir = join(this.convDir, agentId);
    let entries: string[];
    try {
      entries = await readdir(dir);
    } catch {
      return { agentId, files: [], totalBytes: 0, empty: true };
    }
    const out: ConversationEntry["files"] = [];
    let total = 0;
    for (const name of entries) {
      try {
        const st = await stat(join(dir, name));
        if (!st.isFile()) continue;
        out.push({ name, size: st.size, mtime: st.mtime.toISOString() });
        total += st.size;
      } catch { /* skip */ }
    }
    return { agentId, files: out, totalBytes: total, empty: out.length === 0 };
  }

  async readFile(agentId: string, name: string, maxBytes = 5 * 1024 * 1024): Promise<string | null> {
    if (isUnsafeName(name)) return null;
    const path = join(this.convDir, agentId, name);
    try {
      const st = await stat(path);
      if (st.size > maxBytes) return null;
      return await readFile(path, "utf8");
    } catch {
      return null;
    }
  }

  // Lists the whitelisted side-channel artifacts (response/decisions/debug)
  // for a given agent id that exist directly under statusDir. Returns []
  // when statusDir wasn't provided (e.g. older test wiring) or none exist.
  async listArtifacts(agentId: string): Promise<ArtifactEntry[]> {
    if (!this.statusDir || isUnsafeName(agentId)) return [];
    const out: ArtifactEntry[] = [];
    for (const { kind, prefix, suffix } of ARTIFACT_KINDS) {
      const name = `${prefix}${agentId}${suffix}`;
      try {
        const st = await stat(join(this.statusDir, name));
        if (!st.isFile()) continue;
        out.push({ name, kind, size: st.size, mtime: st.mtime.toISOString() });
      } catch { /* artifact absent for this agent */ }
    }
    return out;
  }

  // Reads one whitelisted artifact's content by exact filename. Rejects
  // anything that isn't exactly one of the three whitelisted basenames for
  // this agent id, using the same traversal guard as readFile().
  async readArtifact(agentId: string, name: string, maxBytes = 5 * 1024 * 1024): Promise<string | null> {
    if (!this.statusDir || isUnsafeName(name) || isUnsafeName(agentId)) return null;
    const allowed = ARTIFACT_KINDS.some(({ prefix, suffix }) => name === `${prefix}${agentId}${suffix}`);
    if (!allowed) return null;
    const path = join(this.statusDir, name);
    try {
      const st = await stat(path);
      if (!st.isFile() || st.size > maxBytes) return null;
      return await readFile(path, "utf8");
    } catch {
      return null;
    }
  }
}
