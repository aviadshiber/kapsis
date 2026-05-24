#!/usr/bin/env bash
# =============================================================================
# spec-store.sh — Canonical launch-spec persistence (write side)
# =============================================================================
#
# Kapsis-core capability: writes the launch spec (the resolved `--spec` file
# contents or the `--task` inline string) to a stable per-agent location:
#
#     ${KAPSIS_SPECS_DIR:-${HOME}/.kapsis/specs}/<agent_id>.md
#
# This file is the canonical answer to "what was this agent asked to do?"
# It is intentionally separate from the worktree's `.kapsis/task-spec-*`
# (which is written inside the container, after launch, and only when
# entrypoint reaches the inject step) and from caller-specific spec dirs
# (slack-bot's ~/.slack/specs, /dev's checkout-local copies, etc.).
#
# Read side is the consumer's concern — the dashboard SpecStore reads from
# the same canonical path, and any future tool that needs to recover the
# launch intent can do the same. This library does NOT define a read API:
# the file is plain UTF-8 and any consumer just opens it.
#
# Usage:
#   source "$SCRIPT_DIR/lib/spec-store.sh"
#   spec_store_write "<agent_id>" --spec /path/to/spec.md
#   spec_store_write "<agent_id>" --task "fix the foo bar"
#
# Failure mode: best-effort. Any error logs a warning and returns 0. The
# caller continues; consumers that find no file simply render an empty
# state.

[[ -n "${_KAPSIS_SPEC_STORE_LOADED:-}" ]] && return 0
_KAPSIS_SPEC_STORE_LOADED=1

# 256 KB cap — matches the dashboard reader's cap and the design doc. Files
# larger than this are truncated at write time so we don't waste disk on
# content downstream consumers would truncate anyway.
: "${KAPSIS_SPEC_MAX_BYTES:=$((256 * 1024))}"

# Default location; overridable for tests and unusual installs.
: "${KAPSIS_SPECS_DIR:=${HOME}/.kapsis/specs}"

# spec_store_dir — print the directory specs are written into.
spec_store_dir() {
    printf '%s\n' "$KAPSIS_SPECS_DIR"
}

# spec_store_path <agent_id> — print the canonical path for an agent's spec.
# Pure path computation, does not touch the filesystem.
spec_store_path() {
    local agent_id="$1"
    if [[ -z "$agent_id" ]]; then
        printf 'spec_store_path: agent_id required\n' >&2
        return 2
    fi
    printf '%s/%s.md\n' "$KAPSIS_SPECS_DIR" "$agent_id"
}

# spec_store_write <agent_id> --spec <file> | --task <string>
#
# Writes the spec to the canonical location atomically (temp-file + rename
# in the same directory). Permissions 0600 so a multi-user host doesn't
# leak the agent's task to other users.
#
# Returns 0 always (best-effort); logs at debug on success, warn on any
# recoverable failure. Returns 2 on invalid usage so the caller can fix
# its own code.
spec_store_write() {
    local agent_id="$1"; shift || true
    if [[ -z "$agent_id" ]]; then
        printf 'spec_store_write: agent_id required as first arg\n' >&2
        return 2
    fi
    if ! [[ "$agent_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
        printf 'spec_store_write: invalid agent_id %q (must match [A-Za-z0-9_-]+)\n' "$agent_id" >&2
        return 2
    fi

    local mode="" payload=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --spec) mode="file"; payload="${2:-}"; shift 2 ;;
            --task) mode="inline"; payload="${2:-}"; shift 2 ;;
            *) printf 'spec_store_write: unknown flag %q\n' "$1" >&2; return 2 ;;
        esac
    done
    if [[ -z "$mode" ]]; then
        # Nothing to persist — interactive mode is valid; not an error.
        _spec_log debug "spec_store_write: no --task/--spec, skipping"
        return 0
    fi

    local specs_dir="$KAPSIS_SPECS_DIR"
    if ! mkdir -p "$specs_dir" 2>/dev/null; then
        _spec_log warn "spec_store_write: could not create $specs_dir"
        return 0
    fi

    local dest="$specs_dir/${agent_id}.md"
    local tmp
    if ! tmp=$(mktemp "${specs_dir}/.${agent_id}.XXXXXX.md" 2>/dev/null); then
        _spec_log warn "spec_store_write: mktemp failed in $specs_dir"
        return 0
    fi

    if [[ "$mode" == "file" ]]; then
        if [[ ! -f "$payload" ]]; then
            _spec_log warn "spec_store_write: spec file not found: $payload"
            rm -f "$tmp"
            return 0
        fi
        # head -c is POSIX (works on macOS BSD + GNU). The cap is in bytes
        # so a multibyte char at the boundary may split — acceptable for a
        # preview file.
        if ! head -c "$KAPSIS_SPEC_MAX_BYTES" "$payload" >"$tmp" 2>/dev/null; then
            _spec_log warn "spec_store_write: failed reading $payload"
            rm -f "$tmp"
            return 0
        fi
    else
        # Inline task — write the string verbatim. printf is safer than echo
        # for strings starting with `-` or containing backslash escapes.
        if ! printf '%s\n' "$payload" | head -c "$KAPSIS_SPEC_MAX_BYTES" >"$tmp" 2>/dev/null; then
            _spec_log warn "spec_store_write: failed writing inline task"
            rm -f "$tmp"
            return 0
        fi
    fi

    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$dest" 2>/dev/null; then
        _spec_log warn "spec_store_write: rename $tmp -> $dest failed"
        rm -f "$tmp"
        return 0
    fi
    _spec_log debug "spec_store_write: wrote $dest"
    return 0
}

# Tiny logging shim: prefer the project's logging.sh helpers when available
# (sourcing them from launch-agent.sh), fall back to stderr otherwise so
# this library is usable from tests without dragging the full logger in.
_spec_log() {
    local level="$1"; shift
    case "$level" in
        debug) if declare -F log_debug >/dev/null 2>&1; then log_debug "$@"; fi ;;
        warn)  if declare -F log_warn  >/dev/null 2>&1; then log_warn  "$@"; else printf 'WARN: %s\n' "$*" >&2; fi ;;
        *)     printf '%s: %s\n' "$level" "$*" >&2 ;;
    esac
}
