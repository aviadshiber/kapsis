import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

export interface ConversationEntry {
  agentId: string;
  files: Array<{ name: string; size: number; mtime: string }>;
  totalBytes: number;
  empty: boolean;
}

export class ConversationStore {
  constructor(private convDir: string) {}

  async describe(agentId: string): Promise<ConversationEntry> {
    const dir = join(this.convDir, agentId);
    let entries: string[];
    try {
      entries = await readdir(dir);
    } catch {
      return { agentId, files: [], totalBytes: 0, empty: true };
    }
    const out: ConversationEntry["files"] = [];
    let total = 0;
    for (const name of entries) {
      try {
        const st = await stat(join(dir, name));
        if (!st.isFile()) continue;
        out.push({ name, size: st.size, mtime: st.mtime.toISOString() });
        total += st.size;
      } catch { /* skip */ }
    }
    return { agentId, files: out, totalBytes: total, empty: out.length === 0 };
  }

  async readFile(agentId: string, name: string, maxBytes = 5 * 1024 * 1024): Promise<string | null> {
    if (name.includes("/") || name.includes("..") || name.startsWith(".")) return null;
    const path = join(this.convDir, agentId, name);
    try {
      const st = await stat(path);
      if (st.size > maxBytes) return null;
      return await readFile(path, "utf8");
    } catch {
      return null;
    }
  }
}
