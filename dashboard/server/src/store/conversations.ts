import { readdir, stat, lstat, open } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
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
    return readRegularFile(path, maxBytes);
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
        // lstat (not stat) so a symlink is rejected outright instead of
        // followed — statusDir is a read-write bind mount into the
        // container on Linux, so a hostile agent could otherwise plant
        // e.g. `ln -s /etc/passwd response-<id>.md` for exfiltration.
        // See readArtifact() below for the matching O_NOFOLLOW read guard.
        const st = await lstat(join(this.statusDir, name));
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
    return readRegularFile(path, maxBytes);
  }
}

// Shared hardened reader for caller-influenced paths (conversation files and
// side-channel artifacts — both live in directories an agent can write to).
//   - O_NOFOLLOW closes the stat->open TOCTOU: the open() call itself fails
//     if the final path component is a symlink, so a symlink swapped in
//     after a directory-listing lstat check (or targeting a path never
//     listed at all) still cannot be read through.
//   - O_NONBLOCK prevents a denial-of-service via a planted FIFO: a FIFO at
//     a whitelisted basename is not a symlink, and a plain O_RDONLY open()
//     on it would block until a writer appears. With O_NONBLOCK the open
//     returns immediately and the fstat below rejects it.
//   - fstat on the OPEN fd (not a pre-open stat) then rejects anything that
//     is not a regular file (FIFOs, devices, directories) and anything over
//     maxBytes.
async function readRegularFile(path: string, maxBytes: number): Promise<string | null> {
  let handle;
  try {
    handle = await open(
      path,
      fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | fsConstants.O_NONBLOCK,
    );
    const st = await handle.stat();
    if (!st.isFile() || st.size > maxBytes) return null;
    return await handle.readFile({ encoding: "utf8" });
  } catch {
    return null;
  } finally {
    await handle?.close().catch(() => { /* already closed/failed to open */ });
  }
}
