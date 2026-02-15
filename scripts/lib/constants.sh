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
#===============================================================================

# Valid inject_to values for keychain entries
readonly KAPSIS_SECRET_STORE_INJECT_TO_VALUES=("secret_store" "env")

# Default injection target (secret_store preferred for security)
readonly KAPSIS_SECRET_STORE_DEFAULT_INJECT_TO="secret_store"

#===============================================================================
# FILE SANITIZATION CONSTANTS
#===============================================================================

# Default enabled state for file sanitization
readonly KAPSIS_DEFAULT_SANITIZE_ENABLED="true"

# File extensions considered "code files" for homoglyph detection
# Homoglyph warnings only apply to code files where mixed scripts are suspicious
readonly KAPSIS_CODE_FILE_EXTENSIONS='\.(jsx?|tsx?|py|java|go|rb|rs|[ch](pp)?|cs|sh|bash|zsh|pl|php|swift|kt|scala|lua|r|sql|proto|thrift|avdl)$'
