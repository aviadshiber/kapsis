import { describe, it, expect } from "bun:test";
import { heartbeatRule, updatedAtRule, terminalRule, containerRule, tailRules } from "../src/store/health";
import type { AgentStatus } from "../src/types";

const baseStatus = (over: Partial<AgentStatus> = {}): AgentStatus => ({
  version: "1.0", agent_id: "abc", project: "demo",
  branch: null, sandbox_mode: "overlay", phase: "running", progress: 50,
  message: "ok", gist: null, gist_updated_at: null,
  started_at: new Date(Date.now() - 60_000).toISOString(),
  updated_at: new Date().toISOString(),
  exit_code: null, error: null, worktree_path: null, pr_url: null,
  push_status: null, local_commit: null, remote_commit: null,
  push_fallback_command: null, commit_status: null, commit_sha: null,
  uncommitted_files: 0, heartbeat_at: null, error_type: null,
  ...over,
});

describe("heartbeatRule", () => {
  it("unknown when heartbeat_at is null", () => {
    const r = heartbeatRule(baseStatus());
    expect(r.state).toBe("unknown");
  });
  it("healthy when fresh", () => {
    const r = heartbeatRule(baseStatus({ heartbeat_at: new Date().toISOString() }));
    expect(r.state).toBe("healthy");
  });
  it("degraded between 60-300s", () => {
    const r = heartbeatRule(baseStatus({ heartbeat_at: new Date(Date.now() - 120_000).toISOString() }));
    expect(r.state).toBe("degraded");
  });
  it("stalled past 300s", () => {
    const r = heartbeatRule(baseStatus({ heartbeat_at: new Date(Date.now() - 600_000).toISOString() }));
    expect(r.state).toBe("stalled");
  });
});

describe("updatedAtRule", () => {
  it("healthy in last 2 min", () => {
    expect(updatedAtRule(baseStatus()).state).toBe("healthy");
  });
  it("degraded 2-10 min", () => {
    expect(updatedAtRule(baseStatus({ updated_at: new Date(Date.now() - 5 * 60_000).toISOString() })).state).toBe("degraded");
  });
  it("stalled past 10 min", () => {
    expect(updatedAtRule(baseStatus({ updated_at: new Date(Date.now() - 30 * 60_000).toISOString() })).state).toBe("stalled");
  });
});

describe("terminalRule", () => {
  it("null for non-complete agents", () => {
    expect(terminalRule(baseStatus({ phase: "running" }))).toBeNull();
  });
  it("healthy on exit 0", () => {
    expect(terminalRule(baseStatus({ phase: "complete", exit_code: 0 }))!.state).toBe("healthy");
  });
  it("degraded on agent_partial", () => {
    expect(terminalRule(baseStatus({ phase: "complete", exit_code: 1, error_type: "agent_partial" }))!.state).toBe("degraded");
  });
  it("failed on mount_failure", () => {
    expect(terminalRule(baseStatus({ phase: "complete", exit_code: 4, error_type: "mount_failure", error: "vfs" }))!.state).toBe("failed");
  });
  it("failed on generic non-zero", () => {
    expect(terminalRule(baseStatus({ phase: "complete", exit_code: 5 }))!.state).toBe("failed");
  });
});

describe("containerRule", () => {
  const s = baseStatus({ phase: "running" });
  it("stalled when info is null", () => {
    expect(containerRule(s, null).state).toBe("stalled");
  });
  it("stalled when container missing", () => {
    expect(containerRule(s, { name: "kapsis-abc", exists: false, state: null, startedAt: null, image: null, pid: null, exitCode: null }).state).toBe("stalled");
  });
  it("healthy when running", () => {
    expect(containerRule(s, { name: "kapsis-abc", exists: true, state: "running", startedAt: null, image: null, pid: 1, exitCode: null }).state).toBe("healthy");
  });
  it("degraded when paused", () => {
    expect(containerRule(s, { name: "kapsis-abc", exists: true, state: "paused", startedAt: null, image: null, pid: 1, exitCode: null }).state).toBe("degraded");
  });
  it("stalled when exited / dead / stopped", () => {
    for (const state of ["exited", "dead", "stopped"]) {
      expect(containerRule(s, { name: "kapsis-abc", exists: true, state, startedAt: null, image: null, pid: 1, exitCode: 1 }).state).toBe("stalled");
    }
  });
});

describe("tailRules", () => {
  it("healthy on clean logs", () => {
    const { mount, liveness } = tailRules(["just a normal log line", "running"]);
    expect(mount.state).toBe("healthy");
    expect(liveness.state).toBe("healthy");
  });
  it("failed mount-probe when sentinel is present", () => {
    const { mount } = tailRules(["something", "KAPSIS_MOUNT_FAILURE: vfs drop"]);
    expect(mount.state).toBe("failed");
  });
  it("degraded liveness on soft skip; stalled on hard skip", () => {
    const soft = tailRules(["api_soft_skip x", "api_soft_skip y"]).liveness;
    expect(soft.state).toBe("degraded");
    const hard = tailRules(["api_hard_skip z"]).liveness;
    expect(hard.state).toBe("stalled");
  });
});
