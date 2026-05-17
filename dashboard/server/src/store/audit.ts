import { readdir, readFile, stat } from "node:fs/promises";
import { join, basename } from "node:path";
import { createHash } from "node:crypto";
import { log } from "../logger";
import type { AuditEvent } from "../types";

const GENESIS = "0".repeat(64);
const AUDIT_FILE_RE = /^([^-]+)-(\d{8}-\d{6}-\d+)\.audit\.jsonl(\.[0-9]+)?$/;

export interface AuditChainStatus {
  valid: boolean;
  lastSeq: number;
  lastHash: string;
  brokenAt: number | null;
  reason: string | null;
}

export interface AuditQuery {
  agentId?: string;
  eventType?: string;
  sinceSeq?: number;
  limit?: number;
}

/**
 * Reads and parses Kapsis audit JSONL files. Mirrors the hash chain format
 * from scripts/lib/audit.sh: hash = sha256(prev_hash + seq + timestamp +
 * event_type + tool_name + detail_json_raw).
 */
export class AuditStore {
  constructor(private auditDir: string) {}

  async listFiles(agentId?: string): Promise<string[]> {
    let files: string[];
    try {
      files = await readdir(this.auditDir);
    } catch {
      return [];
    }
    return files
      .filter((f) => {
        const m = f.match(AUDIT_FILE_RE);
        if (!m) return false;
        return !agentId || m[1] === agentId;
      })
      .map((f) => join(this.auditDir, f));
  }

  /** Parse all events for a given agent across all session/rotated files. */
  async query(q: AuditQuery): Promise<AuditEvent[]> {
    const files = await this.listFiles(q.agentId);
    files.sort();
    const all: AuditEvent[] = [];
    const limit = q.limit ?? 5000;
    for (const f of files) {
      try {
        const text = await readFile(f, "utf8");
        for (const line of text.split("\n")) {
          if (!line) continue;
          let ev: AuditEvent;
          try { ev = JSON.parse(line) as AuditEvent; } catch { continue; }
          if (q.eventType && ev.event_type !== q.eventType) continue;
          if (q.sinceSeq !== undefined && ev.seq <= q.sinceSeq) continue;
          all.push(ev);
          if (all.length >= limit) break;
        }
      } catch (e) {
        log.warn("audit file read failed", { file: f, err: String(e) });
      }
      if (all.length >= limit) break;
    }
    return all;
  }

  /**
   * Verify the hash chain of a single audit file. Implements the same algorithm
   * as audit_verify_chain() in scripts/lib/audit.sh:
   *   hash_input = prev_hash + seq + timestamp + event_type + tool_name + detail_raw
   *
   * `detail_raw` is the raw JSON substring extracted between `"detail":` and
   * `,"prev_hash"` — matching the bash sed extraction.
   */
  async verifyFile(file: string): Promise<AuditChainStatus> {
    let text: string;
    try {
      text = await readFile(file, "utf8");
    } catch (e) {
      return { valid: false, lastSeq: -1, lastHash: GENESIS, brokenAt: null, reason: `cannot read: ${String(e)}` };
    }
    let prevHash = GENESIS;
    let lastSeq = -1;
    let lineNum = 0;
    for (const raw of text.split("\n")) {
      if (!raw) continue;
      lineNum++;
      const detailMatch = raw.match(/"detail":(.*),"prev_hash"/);
      if (!detailMatch) {
        return { valid: false, lastSeq, lastHash: prevHash, brokenAt: lastSeq + 1, reason: `line ${lineNum}: detail extraction failed` };
      }
      const detailRaw = detailMatch[1]!;
      let parsed: AuditEvent;
      try { parsed = JSON.parse(raw) as AuditEvent; } catch (e) {
        return { valid: false, lastSeq, lastHash: prevHash, brokenAt: lastSeq + 1, reason: `line ${lineNum}: JSON parse failed: ${String(e)}` };
      }
      if (parsed.prev_hash !== prevHash) {
        return { valid: false, lastSeq, lastHash: prevHash, brokenAt: parsed.seq, reason: `seq ${parsed.seq}: prev_hash mismatch (expected ${prevHash.slice(0, 8)}..., got ${parsed.prev_hash.slice(0, 8)}...)` };
      }
      const input = `${prevHash}${parsed.seq}${parsed.timestamp}${parsed.event_type}${parsed.tool_name}${detailRaw}`;
      const computed = createHash("sha256").update(input).digest("hex");
      if (computed !== parsed.hash) {
        return { valid: false, lastSeq, lastHash: prevHash, brokenAt: parsed.seq, reason: `seq ${parsed.seq}: hash mismatch (expected ${computed.slice(0, 8)}..., got ${parsed.hash.slice(0, 8)}...)` };
      }
      prevHash = parsed.hash;
      lastSeq = parsed.seq;
    }
    return { valid: true, lastSeq, lastHash: prevHash, brokenAt: null, reason: null };
  }

  async exists(): Promise<boolean> {
    try { await stat(this.auditDir); return true; } catch { return false; }
  }

  static auditFileMatches(name: string, agentId?: string): boolean {
    const m = basename(name).match(AUDIT_FILE_RE);
    if (!m) return false;
    return !agentId || m[1] === agentId;
  }
}
