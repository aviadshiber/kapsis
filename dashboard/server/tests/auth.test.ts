import { describe, it, expect } from "bun:test";
import { generateToken, verifyToken, extractBearer } from "../src/auth";

describe("auth", () => {
  it("generates a unique token", () => {
    const a = generateToken();
    const b = generateToken();
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThan(20);
  });

  it("accepts a correct token", () => {
    const t = generateToken();
    expect(verifyToken(t, t)).toBe(true);
  });

  it("rejects wrong / missing / different-length tokens", () => {
    const t = generateToken();
    expect(verifyToken(t, null)).toBe(false);
    expect(verifyToken(t, "")).toBe(false);
    expect(verifyToken(t, "x")).toBe(false);
    expect(verifyToken(t, t.slice(0, -1) + "X")).toBe(false);
  });

  it("extracts bearer from header", () => {
    const req = new Request("http://x/", { headers: { authorization: "Bearer abc123" } });
    expect(extractBearer(req)).toBe("abc123");
  });

  it("extracts token from query", () => {
    const req = new Request("http://x/?token=qq");
    expect(extractBearer(req)).toBe("qq");
  });

  it("returns null when neither is present", () => {
    expect(extractBearer(new Request("http://x/"))).toBeNull();
  });
});
