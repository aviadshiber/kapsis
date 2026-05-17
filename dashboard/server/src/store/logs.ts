import { stat, open } from "node:fs/promises";
import { join } from "node:path";

export interface LogChunk {
  agentId: string;
  bytesRead: number;
  nextOffset: number;
  size: number;
  lines: string[];
  truncated: boolean;
}

const MAX_CHUNK = 1024 * 1024; // 1 MiB per request

export class LogStore {
  constructor(private logDir: string) {}

  filePath(agentId: string): string {
    return join(this.logDir, `kapsis-${agentId}.log`);
  }

  async read(agentId: string, sinceOffset: number, maxBytes = MAX_CHUNK): Promise<LogChunk> {
    const path = this.filePath(agentId);
    let st: Awaited<ReturnType<typeof stat>>;
    try {
      st = await stat(path);
    } catch {
      return { agentId, bytesRead: 0, nextOffset: 0, size: 0, lines: [], truncated: false };
    }
    let offset = sinceOffset;
    if (offset > st.size) offset = 0; // log was rotated
    const want = Math.min(maxBytes, st.size - offset);
    if (want <= 0) {
      return { agentId, bytesRead: 0, nextOffset: offset, size: st.size, lines: [], truncated: false };
    }
    const fd = await open(path, "r");
    try {
      const buf = Buffer.alloc(want);
      const { bytesRead } = await fd.read(buf, 0, want, offset);
      const text = buf.subarray(0, bytesRead).toString("utf8");
      const splitAt = text.lastIndexOf("\n");
      const useable = splitAt >= 0 ? text.slice(0, splitAt) : "";
      const remainder = splitAt >= 0 ? text.length - splitAt - 1 : text.length;
      const consumed = bytesRead - Buffer.byteLength(remainder ? text.slice(text.length - remainder) : "", "utf8");
      const lines = useable ? useable.split("\n") : [];
      return {
        agentId,
        bytesRead: consumed,
        nextOffset: offset + consumed,
        size: st.size,
        lines,
        truncated: want < st.size - offset,
      };
    } finally {
      await fd.close();
    }
  }

  async size(agentId: string): Promise<number> {
    try { return (await stat(this.filePath(agentId))).size; } catch { return 0; }
  }
}
