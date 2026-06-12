// Re-export the single source of truth in @kapsis/dashboard-shared. Server
// code keeps importing from "./types" for backward compatibility; new code
// should import directly from "@kapsis/dashboard-shared".
//
// AgentStatus.error_type union mirrors the set documented in
// scripts/lib/status.sh::status_set_error_type. Last sync added
// "exec_channel_hang" for Issue #382 (host-side podman exec watchdog).
// AgentStatus.stripped_injections added for Issue #391 (pre-commit strip
// of Kapsis-injected CLAUDE.md/AGENTS.md gist blocks).
export * from "@kapsis/dashboard-shared";
