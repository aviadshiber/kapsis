import { homedir } from "node:os";
import { join } from "node:path";

export interface DashboardConfig {
  host: string;
  port: number;
  kapsisHome: string;
  readOnly: boolean;
  open: boolean;
  token: string | null;
  uiDistDir: string | null;
}

export const DEFAULT_PORT = 7777;
export const DEFAULT_HOST = "127.0.0.1";

export function defaultKapsisHome(): string {
  return process.env.KAPSIS_HOME ?? join(homedir(), ".kapsis");
}

export function paths(kapsisHome: string) {
  return {
    status: join(kapsisHome, "status"),
    audit: join(kapsisHome, "audit"),
    logs: join(kapsisHome, "logs"),
    conversations: join(kapsisHome, "conversations"),
    worktrees: join(kapsisHome, "worktrees"),
    sandboxes: join(kapsisHome, "sandboxes"),
    sanitizedGit: join(kapsisHome, "sanitized-git"),
    snapshots: join(kapsisHome, "snapshots"),
    // Where scripts/lib/spec-store.sh writes the per-agent launch spec.
    // Read-only from the dashboard's perspective — the dashboard never
    // writes here.
    specs: join(kapsisHome, "specs"),
    dashboardAudit: join(kapsisHome, "audit", "dashboard.jsonl"),
  } as const;
}

export type KapsisPaths = ReturnType<typeof paths>;
