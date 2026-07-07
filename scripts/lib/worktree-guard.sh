#!/usr/bin/env bash
#===============================================================================
# worktree-guard.sh - Proportional-certainty in-use guard for worktree reaping
#                     (Issue #428)
#
# Sourced-only library. Do not execute directly.
#
# Problem: kapsis-cleanup.sh's clean_worktrees() removed every directory
# under the worktree root unconditionally -- including worktrees belonging
# to agents that are still actively running. This library adds a guard that
# callers invoke before deleting a worktree.
#
# Design (see design brief for Issue #428 for full rationale):
#   - status.json phase == "complete" is the sole zero-Podman-dependency,
#     unambiguous "safe to reap" signal -- reaped unconditionally.
#   - phase in error/failed/killed, or a missing status file, fall back to
#     the same age heuristic already used by worktree-manager.sh's
#     gc_stale_worktrees() (KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS, default
#     168h), optionally corroborated by a best-effort Podman label check
#     that can force a "skip" verdict if a live container is found.
#   - Any other phase (running/initializing/preparing/starting/committing/
#     pushing/post_processing/...) is treated as ambiguous: freshness of
#     status.json's updated_at against the liveness timeout+grace decides
#     "in use" (skip) vs. "stale" (fall through to the Podman check, then
#     the age heuristic).
#
# Fail-open guarantee: a Podman query failure/timeout/absence NEVER causes
# a skip-by-itself and NEVER blocks reaping of unrelated complete-phase
# worktrees in the same run -- it only removes the corroboration signal for
# the one ambiguous entry being evaluated, which then falls back to the age
# heuristic (matches the existing 168h caution baked into
# gc_stale_worktrees()'s error/failed/killed branch).
#
# Public API:
#   worktree_is_safe_to_reap <status_file> <worktree_path>
#     Returns 0 = safe to reap, 1 = skip (in use / ambiguous / retain).
#     On return 1, sets WORKTREE_GUARD_SKIP_REASON to a short human-readable
#     explanation suitable for print_item_skipped()'s "reason" argument.
#===============================================================================

[[ -n "${_KAPSIS_WORKTREE_GUARD_LOADED:-}" ]] && return 0
_KAPSIS_WORKTREE_GUARD_LOADED=1

WORKTREE_GUARD_SKIP_REASON=""

#-------------------------------------------------------------------------------
# _worktree_guard_agent_id <worktree_dirname>
#
# Extracts the trailing agent-id from a worktree directory name using the
# verified naming convention <project>-<6-hex-agent-id> (matches
# worktree-manager.sh's create_worktree()/generate_agent_id()).
#
# Known limitation: launch-agent.sh also accepts a user-supplied --agent-id
# matching ^[a-zA-Z0-9_-]+$, which this parser deliberately does NOT try to
# handle -- project names may themselves contain hyphens, so splitting
# <project>-<arbitrary-agent-id> is ambiguous. Callers must treat a parse
# failure as "no Podman corroboration available" and fall back to the age
# heuristic, NOT as a reason to retain the worktree forever.
#
# Prints the agent-id and returns 0 on match; prints nothing and returns 1
# if the name doesn't match the convention.
#-------------------------------------------------------------------------------
_worktree_guard_agent_id() {
    local dirname="$1"
    if [[ "$dirname" =~ ^(.+)-([0-9a-f]{6})$ ]]; then
        echo "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

#-------------------------------------------------------------------------------
# _worktree_guard_ts_to_epoch <iso8601_timestamp>
#
# Converts a status.json ISO-8601 UTC timestamp (e.g. 2026-07-03T12:34:56Z,
# written by status.sh's _status_timestamp) to Unix epoch seconds.
# Cross-platform (GNU date -d / BSD date -j -f). Prints "0" on failure.
#-------------------------------------------------------------------------------
_worktree_guard_ts_to_epoch() {
    local ts="$1"
    ts="${ts%Z}"
    ts="${ts/T/ }"
    date -u -d "$ts" +%s 2>/dev/null || \
        date -u -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || \
        echo "0"
}

#-------------------------------------------------------------------------------
# _worktree_guard_age_verdict <worktree_path>
#
# Age-based fallback verdict shared by the missing-status-file and
# error/failed/killed branches. Mirrors gc_stale_worktrees()
# (worktree-manager.sh) exactly: directory mtime vs.
# KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS (default 168h).
#
# Returns 0 = reap (older than max age, or max age disabled via 0),
# 1 = skip (younger than max age, or mtime unavailable).
#-------------------------------------------------------------------------------
_worktree_guard_age_verdict() {
    local worktree_path="$1"
    local max_age_hours="${KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS:-${KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS:-168}}"

    if ! [[ "$max_age_hours" =~ ^[0-9]+$ ]] || (( max_age_hours <= 0 )); then
        # max_age_hours=0 (or invalid) disables age-based reaping entirely.
        WORKTREE_GUARD_SKIP_REASON="age-based cleanup disabled"
        return 1
    fi

    if ! declare -f get_dir_mtime &>/dev/null; then
        WORKTREE_GUARD_SKIP_REASON="mtime helper unavailable"
        return 1
    fi

    local mtime
    mtime=$(get_dir_mtime "$worktree_path") || {
        WORKTREE_GUARD_SKIP_REASON="mtime unavailable"
        return 1
    }
    [[ -z "$mtime" ]] && {
        WORKTREE_GUARD_SKIP_REASON="mtime unavailable"
        return 1
    }

    local age_secs max_age_secs
    age_secs=$(( $(date +%s) - mtime ))
    max_age_secs=$(( max_age_hours * 3600 ))

    if (( age_secs > max_age_secs )); then
        return 0
    fi

    WORKTREE_GUARD_SKIP_REASON="younger than ${max_age_hours}h max age"
    return 1
}

#-------------------------------------------------------------------------------
# _worktree_guard_podman_live <agent_id>
#
# Best-effort, fail-open Podman corroboration: is there a running container
# labeled kapsis.agent-id=<agent_id>? Uses the existing timeout helper
# (compat.sh's _KAPSIS_TIMEOUT_CMD) so a hung Podman VM cannot hang the
# housekeeper. Never used to force a "reap" verdict -- only ever to force
# or confirm a "skip" verdict when a live container is actually found.
#
# Returns 0 = live container found (skip), 1 = not found or check
# unavailable/failed (no signal either way -- caller falls back to the age
# heuristic; this is the fail-open path).
#-------------------------------------------------------------------------------
_worktree_guard_podman_live() {
    local agent_id="$1"

    command -v podman &>/dev/null || return 1

    # Guardrail: never issue an unwrapped Podman call. If no timeout binary
    # is available, skip the check entirely (fail open) rather than risk
    # hanging the housekeeper on a stuck VM.
    [[ -n "${_KAPSIS_TIMEOUT_CMD:-}" ]] || return 1

    local container_id
    container_id=$("$_KAPSIS_TIMEOUT_CMD" 5 podman ps \
        --filter "label=kapsis.agent-id=${agent_id}" \
        --format "{{.ID}}" 2>/dev/null | head -1) || return 1

    [[ -n "$container_id" ]]
}

#-------------------------------------------------------------------------------
# worktree_is_safe_to_reap <status_file> <worktree_path>
#
# Public entry point. See file header for full decision logic.
#-------------------------------------------------------------------------------
worktree_is_safe_to_reap() {
    local status_file="$1"
    local worktree_path="$2"
    local worktree_name
    worktree_name=$(basename "$worktree_path")

    WORKTREE_GUARD_SKIP_REASON=""

    # --- Missing status file: age-fallback, optionally corroborated ---
    if [[ ! -f "$status_file" ]]; then
        local agent_id
        if agent_id=$(_worktree_guard_agent_id "$worktree_name"); then
            if _worktree_guard_podman_live "$agent_id"; then
                WORKTREE_GUARD_SKIP_REASON="live container found (no status file)"
                return 1
            fi
        fi
        # An unparseable name (e.g. a user-supplied --agent-id that doesn't
        # match the <project>-<6-hex> convention -- see
        # _worktree_guard_agent_id) simply means Podman corroboration is
        # unavailable; the age heuristic below still decides the verdict.
        # Retaining unconditionally here would make such a worktree
        # permanently un-reapable.
        _worktree_guard_age_verdict "$worktree_path" && return 0
        [[ -z "$WORKTREE_GUARD_SKIP_REASON" ]] && WORKTREE_GUARD_SKIP_REASON="no status file, not yet aged out"
        return 1
    fi

    # Dependency-free phase extraction -- mirrors clean_status()'s existing
    # grep pattern (kapsis-cleanup.sh) rather than requiring jq.
    local phase
    phase=$(grep -o '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$status_file" 2>/dev/null | cut -d'"' -f4)

    local agent_id=""
    agent_id=$(_worktree_guard_agent_id "$worktree_name") || true

    # --- Terminal phase "complete": exit_code determines the verdict.
    # status_complete() writes phase="complete" for EVERY exit code,
    # including 3 (uncommitted changes remain) and 6 (commit failed) --
    # both of which are designed to preserve the worktree for manual
    # recovery. Only exit_code 0 is a true zero-Podman-dependency,
    # unambiguous "safe to reap" signal. Any other exit_code (or a
    # missing/unparseable one) must NOT be fast-reaped.
    if [[ "$phase" == "complete" ]]; then
        local exit_code
        exit_code=$(grep -o '"exit_code"[[:space:]]*:[[:space:]]*[0-9]*' "$status_file" 2>/dev/null | grep -o '[0-9]*$')

        if [[ "$exit_code" == "0" ]]; then
            return 0
        fi

        if [[ -z "$exit_code" ]]; then
            # Missing/unparseable exit_code -- fail-safe: skip rather than
            # risk deleting a worktree preserved for manual recovery.
            WORKTREE_GUARD_SKIP_REASON="phase: complete, exit_code unavailable"
            return 1
        fi

        # Non-zero exit_code (e.g. 3, 6): route through the same
        # age-fallback used for terminal failure phases below.
        if [[ -n "$agent_id" ]] && _worktree_guard_podman_live "$agent_id"; then
            WORKTREE_GUARD_SKIP_REASON="live container found (phase: complete, exit_code: ${exit_code})"
            return 1
        fi
        _worktree_guard_age_verdict "$worktree_path" && return 0
        [[ -z "$WORKTREE_GUARD_SKIP_REASON" ]] && WORKTREE_GUARD_SKIP_REASON="phase: complete, exit_code: ${exit_code}, not yet aged out"
        return 1
    fi

    # --- Terminal failure phases: same age-fallback as gc_stale_worktrees() ---
    if [[ "$phase" == "error" || "$phase" == "failed" || "$phase" == "killed" ]]; then
        if [[ -n "$agent_id" ]] && _worktree_guard_podman_live "$agent_id"; then
            WORKTREE_GUARD_SKIP_REASON="live container found (phase: ${phase})"
            return 1
        fi
        _worktree_guard_age_verdict "$worktree_path" && return 0
        [[ -z "$WORKTREE_GUARD_SKIP_REASON" ]] && WORKTREE_GUARD_SKIP_REASON="phase: ${phase}, not yet aged out"
        return 1
    fi

    # --- Ambiguous phase (running/initializing/... or unrecognized/empty) ---
    # Never use top-level directory mtime here -- get_dir_mtime only updates
    # on direct-child add/remove/rename, so a long agent run editing nested
    # files won't bump it (verified trap). Use status.json's updated_at
    # against the liveness timeout+grace instead.
    local updated_at
    updated_at=$(grep -o '"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$status_file" 2>/dev/null | cut -d'"' -f4)

    local heartbeat_fresh=false
    if [[ -n "$updated_at" ]]; then
        local updated_epoch now stale_secs threshold_secs
        updated_epoch=$(_worktree_guard_ts_to_epoch "$updated_at")
        if [[ "$updated_epoch" != "0" ]]; then
            now=$(date +%s)
            stale_secs=$(( now - updated_epoch ))
            local liveness_timeout="${KAPSIS_LIVENESS_TIMEOUT:-900}"
            local liveness_grace="${KAPSIS_LIVENESS_GRACE_PERIOD:-300}"
            threshold_secs=$(( liveness_timeout + liveness_grace ))
            if (( stale_secs < threshold_secs )); then
                heartbeat_fresh=true
            fi
        fi
    fi

    if [[ "$heartbeat_fresh" == "true" ]]; then
        WORKTREE_GUARD_SKIP_REASON="in use (phase: ${phase:-unknown}, fresh heartbeat)"
        return 1
    fi

    # Heartbeat is stale (or missing/unparseable) -- try the Podman
    # corroboration as a tiebreaker, then fall back to the age heuristic.
    # A Podman failure/timeout here degrades to the age verdict (fail-open),
    # it never forces a "reap".
    if [[ -n "$agent_id" ]] && _worktree_guard_podman_live "$agent_id"; then
        WORKTREE_GUARD_SKIP_REASON="live container found (phase: ${phase:-unknown}, stale heartbeat)"
        return 1
    fi

    _worktree_guard_age_verdict "$worktree_path" && return 0
    [[ -z "$WORKTREE_GUARD_SKIP_REASON" ]] && WORKTREE_GUARD_SKIP_REASON="phase: ${phase:-unknown}, stale heartbeat, not yet aged out"
    return 1
}
