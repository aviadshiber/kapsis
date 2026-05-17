import { open, mkdir, stat } from "node:fs/promises";
import { dirname } from "node:path";
import { createHash } from "node:crypto";
import { log } from "../logger";
import type { DashboardAuditEvent } from "../types";

const GENESIS = "0".repeat(64);

/**
 * Always-on audit log for dashboard-initiated actions (kill, cleanup, settings).
 * Lives at ~/.kapsis/audit/dashboard.jsonl. Hash-chained, same algorithm as
 * scripts/lib/audit.sh but with a smaller schema (no session_id/agent_type).
 *
 * Hash input: prev_hash + seq + timestamp + actor + action + target + detail_json
 */
export class DashboardAuditWriter {
  private seq = 0;
  private prevHash = GENESIS;
  private initialized = false;
  private writeQueue = Promise.resolve();

  constructor(private file: string) {}

  async init(): Promise<void> {
    if (this.initialized) return;
    try {
      await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
    } catch (e) {
      log.warn("dashboard audit mkdir failed", { dir: dirname(this.file), err: String(e) });
    }
    try {
      await stat(this.file);
      // File exists — scan for the last seq + hash to continue the chain.
      const text = await Bun.file(this.file).text();
      let lastSeq = -1;
      let lastHash = GENESIS;
      for (const line of text.split("\n")) {
        if (!line) continue;
        try {
          const ev = JSON.parse(line) as DashboardAuditEvent;
          if (ev.seq > lastSeq) {
            lastSeq = ev.seq;
            lastHash = ev.hash;
          }
        } catch { /* ignore */ }
      }
      this.seq = lastSeq + 1;
      this.prevHash = lastHash;
    } catch {
      // File missing — start fresh.
      this.seq = 0;
      this.prevHash = GENESIS;
    }
    this.initialized = true;
  }

  async record(actor: string, action: string, target: string, detail: Record<string, unknown> = {}): Promise<DashboardAuditEvent> {
    if (!this.initialized) await this.init();
    // Serialize writes to keep the chain consistent under concurrency.
    const result = this.writeQueue.then(() => this.appendOne(actor, action, target, detail));
    this.writeQueue = result.then(() => undefined, () => undefined);
    return result;
  }

  private async appendOne(actor: string, action: string, target: string, detail: Record<string, unknown>): Promise<DashboardAuditEvent> {
    const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    const detailJson = JSON.stringify(detail);
    const input = `${this.prevHash}${this.seq}${timestamp}${actor}${action}${target}${detailJson}`;
    const hash = createHash("sha256").update(input).digest("hex");
    const ev: DashboardAuditEvent = {
      seq: this.seq,
      timestamp,
      actor,
      action,
      target,
      detail,
      prev_hash: this.prevHash,
      hash,
    };
    const line = JSON.stringify(ev) + "\n";
    const fd = await open(this.file, "a", 0o600);
    try {
      await fd.appendFile(line);
    } finally {
      await fd.close();
    }
    this.prevHash = hash;
    this.seq++;
    return ev;
  }
}
