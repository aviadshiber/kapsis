import { describe, it, expect } from "bun:test";
import { computeHealth } from "../src/store/health";
import { LogStore } from "../src/store/logs";
import type { AgentStatus } from "../src/types";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const base = (overrides: Partial<AgentStatus> = {}): AgentStatus => ({
  version: "1.0",
  agent_id: "test",
  project: "demo",
  branch: null,
  sandbox_mode: "overlay",
  phase: "complete",
  progress: 100,
  message: "ok",
  gist: null,
  gist_updated_at: null,
  started_at: "2026-05-17T10:00:00Z",
  updated_at: new Date().toISOString(),
  exit_code: 0,
  error: null,
  worktree_path: null,
  pr_url: null,
  push_status: null,
  local_commit: null,
  remote_commit: null,
  push_fallback_command: null,
  commit_status: null,
  commit_sha: null,
  uncommitted_files: 0,
  heartbeat_at: null,
  error_type: null,
  machine_provider: null,
  ...overrides,
});

describe("computeHealth (terminal-only paths)", () => {
  let logs: LogStore;
  let dir: string;

  it("reports healthy on exit 0", async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-h-"));
    logs = new LogStore(dir);
    const h = await computeHealth(base(), logs);
    expect(h.state).toBe("healthy");
  });

  it("reports failed on mount_failure", async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-h-"));
    logs = new LogStore(dir);
    const h = await computeHealth(base({ exit_code: 4, error_type: "mount_failure", error: "virtio-fs" }), logs);
    expect(h.state).toBe("failed");
  });

  it("reports degraded on agent_partial", async () => {
    dir = await mkdtemp(join(tmpdir(), "kd-h-"));
    logs = new LogStore(dir);
    const h = await computeHealth(base({ exit_code: 1, error_type: "agent_partial" }), logs);
    expect(h.state).toBe("degraded");
  });
});
