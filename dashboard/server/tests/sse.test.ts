import { describe, it, expect, afterEach } from "bun:test";
import { SseBroker } from "../src/sse";

async function collect(stream: ReadableStream<Uint8Array>, ms = 50): Promise<string> {
  const reader = stream.getReader();
  const dec = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const { value, done } = await Promise.race([
      reader.read(),
      new Promise<{ value: undefined; done: true }>((r) => setTimeout(() => r({ value: undefined, done: true }), Math.max(0, deadline - Date.now()))),
    ]);
    if (done) break;
    if (value) buf += dec.decode(value, { stream: true });
  }
  try { reader.releaseLock(); } catch { /* */ }
  return buf;
}

let brokers: SseBroker[] = [];

afterEach(() => { for (const b of brokers) b.close(); brokers = []; });

describe("SseBroker", () => {
  it("fans out events to subscribers of the topic only", async () => {
    const b = new SseBroker(60_000);
    brokers.push(b);
    const r1 = b.subscribe(["agents"]);
    const r2 = b.subscribe(["disk"]);

    b.publish("agents", { event: "agent-changed", data: { id: "abc" } });
    b.publish("disk", { event: "disk-changed", data: { reason: "cleanup" } });

    const got1 = await collect(r1.body!, 80);
    const got2 = await collect(r2.body!, 80);
    expect(got1).toContain("event: agent-changed");
    expect(got1).toContain('"id":"abc"');
    expect(got1).not.toContain("disk-changed");
    expect(got2).toContain("event: disk-changed");
    expect(got2).not.toContain("agent-changed");
  });

  it("removes a client when its stream is cancelled", async () => {
    const b = new SseBroker(60_000);
    brokers.push(b);
    const res = b.subscribe(["agents"]);
    expect(b.clientCount).toBe(1);
    await res.body!.cancel();
    // give the cancel callback a tick
    await Bun.sleep(20);
    expect(b.clientCount).toBe(0);
  });

  it("returns valid SSE headers", () => {
    const b = new SseBroker(60_000);
    brokers.push(b);
    const res = b.subscribe(["x"]);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    expect(res.headers.get("cache-control")).toContain("no-cache");
  });
});
