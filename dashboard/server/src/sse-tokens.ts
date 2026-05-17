import { randomBytes, timingSafeEqual } from "node:crypto";

const DEFAULT_TTL_MS = 60_000;

interface Entry {
  token: string;
  expiresAt: number;
}

/**
 * EventSource cannot send custom Authorization headers, so SSE auth has to
 * travel in the URL. To avoid leaking the long-lived bearer in
 * URL/access-log/referer surfaces, the dashboard mints short-lived,
 * single-purpose tokens via a bearer-gated POST endpoint. Each ephemeral
 * token is valid for ~60s and consumed at SSE-connect time; the long-lived
 * bearer never appears in any URL on the wire.
 */
export class EphemeralTokenStore {
  private entries = new Map<string, Entry>();
  private sweeper: ReturnType<typeof setInterval> | null = null;

  constructor(private ttlMs = DEFAULT_TTL_MS) {
    this.sweeper = setInterval(() => this.sweep(), Math.max(5_000, ttlMs / 2));
  }

  close(): void {
    if (this.sweeper) clearInterval(this.sweeper);
    this.sweeper = null;
    this.entries.clear();
  }

  mint(): { token: string; ttlMs: number } {
    const token = randomBytes(24).toString("base64url");
    this.entries.set(token, { token, expiresAt: Date.now() + this.ttlMs });
    return { token, ttlMs: this.ttlMs };
  }

  consume(presented: string | null): boolean {
    if (!presented) return false;
    const now = Date.now();
    for (const [k, e] of this.entries) {
      if (e.expiresAt < now) {
        this.entries.delete(k);
        continue;
      }
      if (k.length !== presented.length) continue;
      if (timingSafeEqual(Buffer.from(k), Buffer.from(presented))) {
        // One-shot: invalidate after first use.
        this.entries.delete(k);
        return true;
      }
    }
    return false;
  }

  private sweep(): void {
    const now = Date.now();
    for (const [k, e] of this.entries) {
      if (e.expiresAt < now) this.entries.delete(k);
    }
  }

  get size(): number {
    return this.entries.size;
  }
}
