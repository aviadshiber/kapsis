import { describe, it, expect } from "bun:test";
import { sanitizeDistPath } from "../src/server";

describe("sanitizeDistPath", () => {
  it.each([
    ["/index.html", "index.html"],
    ["/assets/index.js", "assets/index.js"],
    ["/a/b/c.png", "a/b/c.png"],
  ])("accepts %p → %p", (input, want) => {
    expect(sanitizeDistPath(input)).toBe(want);
  });

  it.each([
    "/../etc/passwd",
    "/assets/../../../etc/passwd",
    "/assets/%2e%2e/secret",   // URL-encoded ..
    "/foo/./bar",
    "/foo\\bar",
    "/foo\0bar",
  ])("rejects %p", (input) => {
    expect(sanitizeDistPath(input)).toBeNull();
  });

  it("allows dotfile-like names that aren't '.' or '..'", () => {
    // Vite emits assets like /assets/index-XXXX.js — we should NOT block
    // dotfile names in general (e.g. .well-known), just '.' and '..' segments.
    expect(sanitizeDistPath("/assets/.git/HEAD")).toBe("assets/.git/HEAD");
  });

  it("rejects malformed percent-encoding", () => {
    expect(sanitizeDistPath("/%FF%G0")).toBeNull();
  });
});
