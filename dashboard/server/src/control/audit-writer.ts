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
  private initPromise: Promise<void> | null = null;
  private writeQueue = Promise.resolve();
  private writeFailures = 0;
  private chainBroken = false;
  private chainBrokenAt: number | null = null;

  constructor(private file: string) {}

  /** Idempotent + concurrency-safe. Caches the in-flight promise. */
  async init(): Promise<void> {
    if (this.initialized) return;
    if (this.initPromise) return this.initPromise;
    this.initPromise = this.doInit().finally(() => { this.initPromise = null; });
    return this.initPromise;
  }

  private async doInit(): Promise<void> {
    try {
      await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
    } catch (e) {
      log.warn("dashboard audit mkdir failed", { dir: dirname(this.file), err: String(e) });
    }
    try {
      await stat(this.file);
      // File exists — replay chain in order to recover both (a) next seq and
      // (b) the integrity status. If the chain is broken we refuse to extend
      // it and write a "chain-break" sentinel as our first event so a viewer
      // can see exactly where the audit gap began.
      const text = await Bun.file(this.file).text();
      let prevHash = GENESIS;
      let expectSeq = 0;
      let broken = false;
      let brokenAt: number | null = null;
      for (const line of text.split("\n")) {
        if (!line) continue;
        let ev: DashboardAuditEvent;
        try { ev = JSON.parse(line) as DashboardAuditEvent; } catch { broken = true; brokenAt = expectSeq; break; }
        if (ev.seq !== expectSeq || ev.prev_hash !== prevHash) {
          broken = true;
          brokenAt = ev.seq;
          break;
        }
        const input = `${ev.prev_hash}${ev.seq}${ev.timestamp}${ev.actor}${ev.action}${ev.target}${JSON.stringify(ev.detail)}`;
        const computed = createHash("sha256").update(input).digest("hex");
        if (computed !== ev.hash) {
          broken = true;
          brokenAt = ev.seq;
          break;
        }
        prevHash = ev.hash;
        expectSeq = ev.seq + 1;
      }
      if (broken) {
        this.chainBroken = true;
        this.chainBrokenAt = brokenAt;
        log.error("dashboard audit chain broken", { file: this.file, brokenAt });
        // Resume from beyond the last valid hash so the new "chain-break"
        // event is itself chained to the last good record.
        this.prevHash = prevHash;
        this.seq = expectSeq;
        this.initialized = true;
        // Record the break as an event (using appendOne directly to avoid
        // recursing through init). Best-effort: if this write also fails the
        // counter increments and future records will surface the issue.
        await this.appendOne("dashboard", "chain-break-detected", `at:${brokenAt ?? "unknown"}`, {
          note: "audit chain validation failed during init; subsequent entries continue from last verified hash",
        }).catch((e) => log.error("failed to record chain-break event", { err: String(e) }));
      } else {
        this.prevHash = prevHash;
        this.seq = expectSeq;
        this.initialized = true;
      }
    } catch {
      // File missing — start fresh.
      this.seq = 0;
      this.prevHash = GENESIS;
      this.initialized = true;
    }
  }

  async record(actor: string, action: string, target: string, detail: Record<string, unknown> = {}): Promise<DashboardAuditEvent> {
    if (!this.initialized) await this.init();
    // Serialize writes to keep the chain consistent under concurrency.
    const result = this.writeQueue.then(() => this.appendOne(actor, action, target, detail));
    this.writeQueue = result.then(() => undefined, () => undefined);
    return result;
  }

  /** Operational stats for /healthz-style introspection. */
  stats(): { seq: number; chainBroken: boolean; chainBrokenAt: number | null; writeFailures: number } {
    return {
      seq: this.seq,
      chainBroken: this.chainBroken,
      chainBrokenAt: this.chainBrokenAt,
      writeFailures: this.writeFailures,
    };
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
    try {
      const fd = await open(this.file, "a", 0o600);
      try {
        await fd.appendFile(line);
      } finally {
        await fd.close();
      }
    } catch (e) {
      // Surface ENOSPC / EACCES / EIO rather than swallowing — the dashboard
      // is the *only* consumer that records its own destructive actions, so
      // a silent write loss is a real auditability gap.
      this.writeFailures++;
      log.error("dashboard audit write failed", { file: this.file, err: String(e), writeFailures: this.writeFailures });
      throw e;
    }
    this.prevHash = hash;
    this.seq++;
    return ev;
  }
}
