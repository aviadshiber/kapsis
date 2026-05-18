import { randomBytes, timingSafeEqual } from "node:crypto";

const DEFAULT_TTL_MS = 10 * 60_000;

interface Entry {
  token: string;
  expiresAt: number;
}

/**
 * EventSource cannot send custom Authorization headers, so SSE auth has to
 * travel in the URL. To avoid leaking the long-lived bearer in
 * URL/access-log/referer surfaces, the dashboard mints short-lived
 * ephemeral tokens via a bearer-gated POST endpoint. Each token is valid
 * for ~10 minutes and can be re-consumed within that window (so
 * EventSource's automatic reconnect logic works after transient network
 * blips); the long-lived bearer never appears in any URL on the wire.
 *
 * Threat model: localhost-only dashboard, so URL-sniffing requires local
 * process access, which already implies the attacker can read the bearer
 * from the dashboard's process tree. Replay within the 10-min window is
 * acceptable in that model — making the token one-shot broke
 * EventSource auto-reconnect across long-running SSE streams (e.g. live
 * cleanup output).
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

  /**
   * Returns true when `presented` matches a non-expired token. Does NOT
   * delete the token on success — the same token can be re-presented
   * within the TTL window. Expired entries are evicted lazily.
   */
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
