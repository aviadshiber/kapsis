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
const NEWLINE = 0x0a;

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
      // Find the last newline in the raw bytes — *not* in a decoded string.
      // Decoding first would replace any split multi-byte UTF-8 sequence at
      // the end with U+FFFD (3 bytes), which would make Buffer.byteLength of
      // the remainder report more bytes than were actually consumed and
      // permanently stall the offset on the truncated character. Working in
      // bytes avoids that whole class of bugs.
      const splitAtByte = buf.subarray(0, bytesRead).lastIndexOf(NEWLINE);
      if (splitAtByte < 0) {
        // No newline in this read window — wait for more input rather than
        // advance, so we don't mid-decode a partial line.
        return {
          agentId,
          bytesRead: 0,
          nextOffset: offset,
          size: st.size,
          lines: [],
          truncated: want < st.size - offset,
        };
      }
      const useable = buf.subarray(0, splitAtByte).toString("utf8");
      const consumed = splitAtByte + 1; // include the newline byte
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
