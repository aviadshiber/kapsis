import { describe, it, expect } from "bun:test";
import { isValidAgentId, requireAgentId } from "../src/validators";

describe("isValidAgentId", () => {
  it.each([
    "abc",
    "abc-123",
    "ebedab",
    "slack-bot-42",
    "0123456789abcdef0123456789abcdef",
  ])("accepts %p", (id) => {
    expect(isValidAgentId(id)).toBe(true);
  });

  it.each([
    "",
    ".",
    "..",
    "ab",       // too short
    "-leading-dash",
    "has space",
    "has/slash",
    "has;semi",
    "has|pipe",
    "has`backtick",
    "x".repeat(33), // too long
    "with$dollar",
  ])("rejects %p", (id) => {
    expect(isValidAgentId(id)).toBe(false);
  });
});

describe("requireAgentId", () => {
  it("returns null for valid", () => {
    expect(requireAgentId("abc")).toBeNull();
  });
  it("returns a 400 Response for invalid", async () => {
    const res = requireAgentId("../bad");
    expect(res).not.toBeNull();
    expect(res!.status).toBe(400);
    const body = await res!.json() as { error?: string };
    expect(body.error).toContain("invalid agent id");
  });
});
