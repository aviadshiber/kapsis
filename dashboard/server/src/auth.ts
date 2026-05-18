import { randomBytes, timingSafeEqual } from "node:crypto";

export function generateToken(): string {
  return randomBytes(32).toString("base64url");
}

export function verifyToken(expected: string, presented: string | null): boolean {
  if (!presented) return false;
  const a = Buffer.from(expected);
  const b = Buffer.from(presented);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * Extracts the long-lived bearer ONLY from the Authorization header. We
 * deliberately do NOT accept ?token=... here — that's exclusively for the
 * short-lived ephemeral SSE token (see sse-tokens.ts and the authorizeSse
 * path in server.ts). Putting the bearer in a URL would leak it via access
 * logs, browser history, and Referer headers — defeating the whole point
 * of the SSE-token split.
 */
export function extractBearer(req: Request): string | null {
  const auth = req.headers.get("authorization");
  if (auth?.startsWith("Bearer ")) return auth.slice(7);
  return null;
}
