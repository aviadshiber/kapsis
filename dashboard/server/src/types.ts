// Re-export the single source of truth in @kapsis/dashboard-shared. Server
// code keeps importing from "./types" for backward compatibility; new code
// should import directly from "@kapsis/dashboard-shared".
//
// AgentStatus.error_type union mirrors the set documented in
// scripts/lib/status.sh::status_set_error_type. "exec_channel_hang" (added
// for Issue #382) is legacy since Issue #414: no longer emitted — the
// exec-channel watchdog was demoted to a non-terminal degraded-state
// reporter. The value stays in the union so historical status files still
// render as failed. Live exec-channel degradation is surfaced via
// KAPSIS_EXEC_CHANNEL_DEGRADED / KAPSIS_EXEC_CHANNEL_RECOVERED log lines,
// consumed by tailRules in store/health.ts.
//
// Last sync added HostEvent for Issue #407 (host-side commit-strip audit
// sidecar <agent-id>-host-events.jsonl; non-chained, not matched by
// AUDIT_FILE_RE).
export * from "@kapsis/dashboard-shared";
