#!/usr/bin/env bash
#===============================================================================
# Kapsis - Shared Constants
#
# Central location for constants used across Kapsis scripts.
# Source this file from any script that needs these values.
#===============================================================================

# shellcheck disable=SC2034
# SC2034: Variables defined here are used by scripts that source this file

# Guard against multiple sourcing
if [[ -n "${_KAPSIS_CONSTANTS_LOADED:-}" ]]; then
    return 0
fi
readonly _KAPSIS_CONSTANTS_LOADED=1

#===============================================================================
# CONTAINER MOUNT PATHS
#
# These paths define where files are mounted inside the container.
# Must be consistent between launch-agent.sh, entrypoint.sh, worktree-manager.sh,
# and test-framework.sh.
#===============================================================================

# Git directory mount point inside container
# In worktree mode, the sanitized .git directory is mounted here.
# We use .git-safe (not .git) because worktrees have a .git FILE that
# can't be mounted over with a directory in crun OCI runtime.
# Scripts must set GIT_DIR=$CONTAINER_GIT_PATH for git to work.
readonly CONTAINER_GIT_PATH="/workspace/.git-safe"

# Git objects mount point inside container (read-only)
readonly CONTAINER_OBJECTS_PATH="/workspace/.git-objects"

# Workspace path inside container
readonly CONTAINER_WORKSPACE_PATH="/workspace"

# Status directory mount point inside container
readonly CONTAINER_STATUS_PATH="/kapsis-status"

#===============================================================================
# COMMIT EXCLUDE PATTERNS (Issue #89)
#
# Files matching these patterns are automatically unstaged before commit.
# This provides a safety net for files that should never be committed,
# even if they somehow bypass info/exclude.
#
# Users can override with KAPSIS_COMMIT_EXCLUDE environment variable.
# Format: newline-separated list of gitignore-style patterns.
#===============================================================================

# Default patterns for files that should never be committed by Kapsis
# These are typically config files that the sandbox may modify but shouldn't commit
readonly KAPSIS_DEFAULT_COMMIT_EXCLUDE=".gitignore
**/.gitignore
.gitattributes
**/.gitattributes"

#===============================================================================
# PUSH TIMEOUT (Issue #227)
#
# Maximum seconds to wait for git push/fetch before aborting.
# Prevents indefinite hangs when credential helpers block on non-TTY contexts.
# Override with KAPSIS_PUSH_TIMEOUT environment variable.
#===============================================================================

readonly KAPSIS_DEFAULT_PUSH_TIMEOUT=60

#===============================================================================
# EPHEMERAL ARTIFACT PATTERNS (Issue #227)
#
# Patterns for test/build artifacts that are NEVER legitimate to commit from
# a sandbox run. These are filtered unconditionally (not user-overridable).
# Applies to files detected inside common tool cache directories.
#
# Pattern semantics (same as KAPSIS_DEFAULT_COMMIT_EXCLUDE):
#   **/<dir>/  — matches any file anywhere inside <dir>/ at any depth
#   **/<file>  — matches <file> at any depth
#===============================================================================

readonly KAPSIS_DEFAULT_EPHEMERAL_PATTERNS="**/__pycache__/
**/.pytest_cache/
.coverage
**/.coverage"

#===============================================================================
# NETWORK ISOLATION
#
# Default network mode for containers. Options: none, filtered, open
# - none:     Complete network isolation (--network=none)
# - filtered: DNS-based allowlist filtering (default, recommended)
# - open:     Unrestricted network access (not recommended)
#===============================================================================

readonly KAPSIS_DEFAULT_NETWORK_MODE="filtered"

#===============================================================================
# CONTAINER REGISTRY
#
# Default registry for pre-built Kapsis images.
# Used by build-image.sh --pull and build-agent-image.sh --pull.
#===============================================================================

readonly KAPSIS_REGISTRY="ghcr.io/aviadshiber"

#===============================================================================
# BACKEND CONFIGURATION
#
# Controls which container backend is used.
# - podman: Local Podman containers (default, existing behavior)
# - k8s:    Kubernetes Pods via AgentRequest CRD
#===============================================================================

# Default backend when --backend is not specified
readonly KAPSIS_DEFAULT_BACKEND="podman"

# Supported backend values (space-separated for validation)
readonly KAPSIS_SUPPORTED_BACKENDS="podman k8s"

# K8s polling interval in seconds (how often to check CR status)
readonly KAPSIS_K8S_DEFAULT_POLL_INTERVAL=10

# K8s default namespace for AgentRequest CRs
readonly KAPSIS_K8S_DEFAULT_NAMESPACE="default"

# K8s maximum timeout in seconds (safety net for stuck CRs)
readonly KAPSIS_K8S_DEFAULT_TIMEOUT=7200

#===============================================================================
# GIT EXCLUDE PATTERNS (Issue #89)
#
# These patterns are written to $GIT_DIR/info/exclude to prevent accidental
# commits of internal files. The info/exclude file is local-only and never
# committed, making Kapsis's protection invisible to the repository.
#
# These are used by:
# - ensure_git_excludes() in worktree-manager.sh
# - create_sanitized_git() in worktree-manager.sh
#===============================================================================

# Header comment for info/exclude file
readonly KAPSIS_GIT_EXCLUDE_HEADER="# Kapsis protective patterns
# These patterns prevent accidental commits of internal files
# This file is local-only and never committed (transparent to user)"

# Patterns that should be excluded from git operations
# Each pattern on its own line, formatted for gitignore syntax
readonly KAPSIS_GIT_EXCLUDE_PATTERNS="# Kapsis internal files
.kapsis/

# Literal tilde paths (failed tilde expansion creates directory named \"~\")
# This is NOT the same as *~ which matches backup files ending in ~
~
~/

# AI tool configuration directories (should stay local)
.claude/
.codex/
.aider/"

#===============================================================================
# SECRET STORE INJECTION
#
# Controls how keychain secrets are injected into containers.
# "secret_store" = Linux Secret Service (gnome-keyring) — preferred, default
# "env" = environment variable (legacy, less secure)
#
# keyring_collection: (optional) D-Bus collection label for 99designs/keyring
# compat (Issue #170). When set, secrets are stored with the 'profile' attribute
# in a named collection, making them discoverable by Go CLI tools (bkt, gh).
# keyring_profile: (optional) Override the D-Bus item key / profile attribute.
# When omitted, the 'account' field is used as the profile key (Issue #176).
#===============================================================================

# Valid inject_to values for keychain entries
readonly KAPSIS_SECRET_STORE_INJECT_TO_VALUES=("secret_store" "env")

# Default injection target (secret_store preferred for security)
readonly KAPSIS_SECRET_STORE_DEFAULT_INJECT_TO="secret_store"

# YQ expression for parsing keychain config with inject_to support.
# Used by scripts/launch-agent.sh and tests/lib/test-framework.sh.
# Output format: VAR_NAME|service|account|inject_to_file|mode|inject_to|keyring_collection|keyring_profile|git_credential_for|inject_file_template_b64
# Field 10 (inject_file_template_b64) is the inject_file_template value base64-encoded via @base64.
# Empty string when not specified. Used by launch-agent.sh to populate KAPSIS_TMPL_* env vars.
# Requires KAPSIS_INJECT_DEFAULT env var to be set before calling yq.
# shellcheck disable=SC2016
readonly KAPSIS_YQ_KEYCHAIN_EXPR='.environment.keychain // {} | to_entries | .[] | .value.account |= (select(kind == "seq") | join(",")) // .value.account | .key + "|" + .value.service + "|" + (.value.account // "") + "|" + (.value.inject_to_file // "") + "|" + (.value.mode // "0600") + "|" + (.value.inject_to // strenv(KAPSIS_INJECT_DEFAULT)) + "|" + (.value.keyring_collection // "") + "|" + (.value.keyring_profile // "") + "|" + (.value.git_credential_for // "") + "|" + ((.value.inject_file_template // "") | @base64)'

#===============================================================================
# FILE SANITIZATION CONSTANTS
#===============================================================================

# Default enabled state for file sanitization
readonly KAPSIS_DEFAULT_SANITIZE_ENABLED="true"

# File extensions considered "code files" for homoglyph detection
# Homoglyph warnings only apply to code files where mixed scripts are suspicious
readonly KAPSIS_CODE_FILE_EXTENSIONS='\.(jsx?|tsx?|py|java|go|rb|rs|[ch](pp)?|cs|sh|bash|zsh|pl|php|swift|kt|scala|lua|r|sql|proto|thrift|avdl)$'

#===============================================================================
# AUDIT SYSTEM DEFAULTS
#===============================================================================

# Default enabled state for audit logging (opt-in for initial release)
readonly KAPSIS_DEFAULT_AUDIT_ENABLED="false"

# Per-session audit file size cap (MB) before rotation
readonly KAPSIS_AUDIT_MAX_FILE_SIZE_MB="${KAPSIS_AUDIT_MAX_FILE_SIZE_MB:-50}"

# Auto-delete audit files older than this (days)
readonly KAPSIS_AUDIT_TTL_DAYS="${KAPSIS_AUDIT_TTL_DAYS:-30}"

# Total audit directory size cap (MB), oldest files pruned first
readonly KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB="${KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB:-500}"

# Container mount point for audit directory
readonly CONTAINER_AUDIT_PATH="/kapsis-audit"

#===============================================================================
# CLEANUP DEFAULTS (Fix #183)
#
# Configurable via YAML (cleanup: section) or environment variables.
# Environment variables take precedence over YAML, which takes precedence
# over these defaults.
#===============================================================================

# Max age (hours) for stale worktrees. 0 = age-based cleanup disabled.
readonly KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS=168  # 7 days

# Whether to run opportunistic GC when launching a new agent
readonly KAPSIS_DEFAULT_CLEANUP_GC_ON_LAUNCH="true"

# Whether GC runs in background (non-blocking) during agent launch
readonly KAPSIS_DEFAULT_CLEANUP_GC_BACKGROUND="true"

# Whether branch cleanup is enabled (opt-in to prevent accidental branch loss)
readonly KAPSIS_DEFAULT_CLEANUP_BRANCH_ENABLED="false"

# Branch prefixes to consider for cleanup (pipe-separated for matching)
readonly KAPSIS_DEFAULT_CLEANUP_BRANCH_PREFIXES="ai-agent/|kapsis/"

# Protected branch patterns — never deleted (pipe-separated for matching)
readonly KAPSIS_DEFAULT_CLEANUP_BRANCH_PROTECTED="main|master|develop|release/.*|stable/.*"

# Only delete branches that are fully pushed to remote
readonly KAPSIS_DEFAULT_CLEANUP_BRANCH_REQUIRE_PUSHED="true"

# Lock directory for background GC (prevents concurrent runs)
readonly KAPSIS_GC_LOCK_DIR="${HOME}/.kapsis/locks"

#===============================================================================
# VM HEALTH DEFAULTS (Fix #238)
#
# Thresholds for Podman VM health monitoring.
# Override via environment variables (e.g., KAPSIS_CLEANUP_VM_INODE_WARN_PCT=60).
#===============================================================================

# Inode usage warning threshold (percentage)
readonly KAPSIS_DEFAULT_CLEANUP_VM_INODE_WARN_PCT=70

# Inode usage critical threshold — triggers auto image cleanup (percentage)
readonly KAPSIS_DEFAULT_CLEANUP_VM_INODE_CRITICAL_PCT=90

# Disk usage warning threshold (percentage)
readonly KAPSIS_DEFAULT_CLEANUP_VM_DISK_WARN_PCT=80

# Disk usage critical threshold (percentage)
readonly KAPSIS_DEFAULT_CLEANUP_VM_DISK_CRITICAL_PCT=95

# Journal vacuum target size
readonly KAPSIS_DEFAULT_CLEANUP_VM_JOURNAL_VACUUM_SIZE="100M"

# Timeout (seconds) for podman machine ssh commands
readonly KAPSIS_DEFAULT_CLEANUP_VM_SSH_TIMEOUT=15
