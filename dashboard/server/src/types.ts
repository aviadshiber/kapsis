// Re-export the single source of truth in @kapsis/dashboard-shared. Server
// code keeps importing from "./types" for backward compatibility; new code
// should import directly from "@kapsis/dashboard-shared".
//
// AgentStatus.error_type union mirrors the set documented in
// scripts/lib/status.sh::status_set_error_type. Last sync added
// "exec_channel_hang" for Issue #382 (host-side podman exec watchdog).
export * from "@kapsis/dashboard-shared";
