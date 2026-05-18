import { log } from "./logger";

export type SseEvent = { event?: string; data: unknown; id?: string };

type Client = {
  id: number;
  controller: ReadableStreamDefaultController<Uint8Array>;
  topics: Set<string>;
};

const encoder = new TextEncoder();

function format({ event, data, id }: SseEvent): string {
  const payload = typeof data === "string" ? data : JSON.stringify(data);
  let s = "";
  if (id) s += `id: ${id}\n`;
  if (event) s += `event: ${event}\n`;
  for (const line of payload.split("\n")) s += `data: ${line}\n`;
  s += "\n";
  return s;
}

export class SseBroker {
  private clients = new Map<number, Client>();
  private nextId = 1;
  private heartbeat: ReturnType<typeof setInterval> | null = null;

  constructor(private heartbeatMs = 15000) {
    this.heartbeat = setInterval(() => this.pingAll(), heartbeatMs);
  }

  close(): void {
    if (this.heartbeat) clearInterval(this.heartbeat);
    for (const c of this.clients.values()) {
      try { c.controller.close(); } catch { /* already closed */ }
    }
    this.clients.clear();
  }

  /** Build a streaming Response for the given topic set. */
  subscribe(topics: string[]): Response {
    const id = this.nextId++;
    let client: Client | null = null;
    const broker = this;

    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        client = { id, controller, topics: new Set(topics) };
        broker.clients.set(id, client);
        controller.enqueue(encoder.encode(`: connected\n\n`));
        log.debug("sse client connected", { id, topics });
      },
      cancel() {
        broker.clients.delete(id);
        log.debug("sse client disconnected", { id });
      },
    });

    return new Response(stream, {
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache, no-transform",
        connection: "keep-alive",
        "x-accel-buffering": "no",
      },
    });
  }

  /** Publish an event to all clients subscribed to `topic`. */
  publish(topic: string, ev: SseEvent): void {
    const payload = encoder.encode(format(ev));
    for (const c of this.clients.values()) {
      if (!c.topics.has(topic)) continue;
      try {
        c.controller.enqueue(payload);
      } catch {
        this.clients.delete(c.id);
      }
    }
  }

  private pingAll(): void {
    const payload = encoder.encode(`: ping ${Date.now()}\n\n`);
    for (const c of this.clients.values()) {
      try { c.controller.enqueue(payload); } catch { this.clients.delete(c.id); }
    }
  }

  get clientCount(): number {
    return this.clients.size;
  }
}
