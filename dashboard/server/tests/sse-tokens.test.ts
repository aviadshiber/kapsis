import { describe, it, expect, afterEach } from "bun:test";
import { EphemeralTokenStore } from "../src/sse-tokens";

let stores: EphemeralTokenStore[] = [];
afterEach(() => { for (const s of stores) s.close(); stores = []; });

describe("EphemeralTokenStore", () => {
  it("mints unique tokens with a ttl", () => {
    const s = new EphemeralTokenStore();
    stores.push(s);
    const a = s.mint();
    const b = s.mint();
    expect(a.token).not.toBe(b.token);
    expect(a.ttlMs).toBeGreaterThan(0);
  });

  it("accepts a valid token repeatedly within the ttl (so EventSource reconnect works)", () => {
    const s = new EphemeralTokenStore();
    stores.push(s);
    const { token } = s.mint();
    expect(s.consume(token)).toBe(true);
    expect(s.consume(token)).toBe(true);
    expect(s.consume(token)).toBe(true);
  });

  it("rejects unknown tokens", () => {
    const s = new EphemeralTokenStore();
    stores.push(s);
    expect(s.consume("not-a-real-token")).toBe(false);
    expect(s.consume("")).toBe(false);
    expect(s.consume(null)).toBe(false);
  });

  it("expires tokens past the ttl", async () => {
    const s = new EphemeralTokenStore(50);
    stores.push(s);
    const { token } = s.mint();
    await Bun.sleep(75);
    expect(s.consume(token)).toBe(false);
  });

  it("constant-time comparison: same-length wrong token is rejected", () => {
    const s = new EphemeralTokenStore();
    stores.push(s);
    const { token } = s.mint();
    const sameLenWrong = "x".repeat(token.length);
    expect(s.consume(sameLenWrong)).toBe(false);
  });
});
