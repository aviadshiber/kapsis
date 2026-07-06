#!/usr/bin/env bash
#===============================================================================
# transcript.sh — Conversation transcript persistence (Issue #390)
#
# Writes captured container output to ~/.kapsis/conversations/<agent-id>/
# transcript.txt so the post-mortem debugging workflow ("read the transcript
# when an agent hangs") has something to read.
#
# Used by launch-agent.sh:
#   - transcript_save          Normal path in main(), after backend_run and
#                              before the output buffer is deleted.
#   - transcript_save_partial  _cleanup_with_completion trap, for SIGTERM /
#                              early-error exits where the normal path never
#                              ran. Never overwrites an existing transcript.
#
# All functions no-op safely (returning 0) when the conversations directory
# is absent or the output buffer is missing/empty — transcript persistence
# must never fail or abort a run.
#===============================================================================

# Source guard
[[ -n "${_KAPSIS_TRANSCRIPT_LOADED:-}" ]] && return 0
_KAPSIS_TRANSCRIPT_LOADED=1

# Logging fallbacks for standalone sourcing (tests); launch-agent.sh sources
# logging.sh first, so the real implementations win there.
declare -f log_warn  &>/dev/null || log_warn()  { echo "[WARN] $*" >&2; }
declare -f log_debug &>/dev/null || log_debug() { [[ "${KAPSIS_DEBUG:-}" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }

# status.sh fallback for standalone sourcing (tests); launch-agent.sh sources
# status.sh first, so the real implementation (scripts/lib/status.sh) wins there.
declare -f status_set_transcript_content_missing &>/dev/null || status_set_transcript_content_missing() { :; }

# Default transcript cap: 50 MB. The tail is kept on truncation because the
# agent's own output is always at the end — the head is container bootstrap
# noise. Override per-run with KAPSIS_TRANSCRIPT_MAX_BYTES.
readonly KAPSIS_TRANSCRIPT_DEFAULT_MAX_BYTES=$((50 * 1024 * 1024))

#-------------------------------------------------------------------------------
# transcript_strip_ansi
#
# Filter (stdin → stdout): strips terminal escape sequences so transcripts
# are readable in plain-text viewers.
#
# Portability: the patterns embed the literal ESC/BEL/CR bytes via ANSI-C
# quoting ($'\x1b') — bash expands them before sed runs. BSD sed (macOS) has
# no \xHH regex escapes, so a single-quoted '\x1b' pattern would match the
# literal text "x1b" and silently strip nothing. Same technique as
# _sanitize_strip_ansi in sanitize-files.sh (which is file-in-place and
# count-returning, hence not reusable for this stream pipeline).
#
# Robustness: LC_ALL=C keeps sed and tr byte-oriented so invalid multi-byte
# sequences in agent output cannot abort the pipeline ("illegal byte
# sequence") and silently drop the transcript.
#
# Coverage:
#   expr 1: CSI sequences incl. private modes — ESC [ params final-byte
#           (SGR colors, cursor movement H/J/K, bracketed paste ?2004h/l)
#   expr 2: OSC sequences terminated by BEL — ESC ] payload BEL
#           (window titles, iTerm2 marks, OSC-8 hyperlinks)
#   expr 3: any residual ESC byte (bare escapes, ST-terminated remnants)
#   expr 4: trailing CR dropped (CRLF → LF) …
#   tr:     … and remaining mid-line CRs become newlines, so progress-bar
#           redraws appear as successive lines instead of overwriting.
#-------------------------------------------------------------------------------
transcript_strip_ansi() {
    LC_ALL=C sed \
        -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
        -e $'s/\x1b][^\x07\x1b]*\x07\\{0,1\\}//g' \
        -e $'s/\x1b//g' \
        -e $'s/\x0d$//' \
        | LC_ALL=C tr '\r' '\n'
}

#-------------------------------------------------------------------------------
# _transcript_write <transcript_path> <output_file> <header> <max_bytes>
#
# Shared writer: header + (possibly tail-truncated) output, ANSI-stripped.
# Returns 0 on success, 1 on write failure (already logged via log_warn).
#-------------------------------------------------------------------------------
_transcript_write() {
    local transcript_path="$1"
    local output_file="$2"
    local header="$3"
    local max_bytes="$4"

    local actual_bytes
    actual_bytes=$(wc -c < "$output_file" 2>/dev/null || echo 0)

    if {
        printf '%s\n' "$header"
        if (( actual_bytes > max_bytes )); then
            printf '# TRUNCATED: %d bytes total; showing last %d bytes\n' \
                "$actual_bytes" "$max_bytes"
            tail -c "$max_bytes" "$output_file"
        else
            cat "$output_file"
        fi
    } 2>/dev/null | transcript_strip_ansi 2>/dev/null > "$transcript_path"; then
        log_debug "Conversation transcript saved: $transcript_path (${actual_bytes} bytes captured)"
        return 0
    else
        log_warn "Failed to write conversation transcript: $transcript_path"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# _transcript_is_boilerplate_only <transcript_path>
#
# Detects the transcript-capture gap (Issue #430, defect 2): the captured
# transcript sometimes contains only container bootstrap chatter — entrypoint
# logging.sh-formatted lines, entrypoint's own pre-logging [KAPSIS]/[DEBUG]
# fallback prefix, liveness-monitor heartbeat lines, and dnsmasq's own stdout
# — with none of the actual agent dialogue. Validated against the
# investigation's sampled transcripts (102/102 boilerplate-only cases matched
# this pattern).
#
# Positive-match only: a line must match a KNOWN boilerplate shape to be
# excluded. Anything unfamiliar is treated as real content, so a verbose or
# differently-formatted agent is never false-flagged.
#
# Returns 0 (true) if every non-blank, non-header line matches known
# boilerplate; 1 otherwise (including on read failure — never claim missing
# content we couldn't actually inspect).
#-------------------------------------------------------------------------------
_transcript_is_boilerplate_only() {
    local transcript_path="$1"
    [[ -r "$transcript_path" ]] || return 1

    # shellcheck disable=SC2016 # intentionally literal in the regex, not expanded
    local boilerplate_re='(^# kapsis-transcript)|(\[entrypoint\])|(\[liveness-monitor\])|(^\[KAPSIS\])|(^\[DEBUG\])|(dnsmasq)'

    local leftover
    leftover=$(grep -Ev "$boilerplate_re" "$transcript_path" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
    [[ -z "$leftover" ]]
}

#-------------------------------------------------------------------------------
# transcript_save <conv_dir> <output_file> <agent_id> <exit_code> [<max_bytes>]
#
# Persists the full container output buffer as <conv_dir>/transcript.txt.
# No-op (exit 0) when conv_dir is absent or output_file is missing/empty.
# Never returns non-zero — a transcript failure must not fail the run.
#-------------------------------------------------------------------------------
transcript_save() {
    local conv_dir="$1"
    local output_file="$2"
    local agent_id="${3:-unknown}"
    local exit_code="${4:-unknown}"
    local max_bytes="${5:-${KAPSIS_TRANSCRIPT_MAX_BYTES:-$KAPSIS_TRANSCRIPT_DEFAULT_MAX_BYTES}}"

    [[ -n "$conv_dir" && -d "$conv_dir" ]] || return 0
    [[ -n "$output_file" && -f "$output_file" && -s "$output_file" ]] || return 0

    local header
    printf -v header '# kapsis-transcript agent=%s exit=%s at=%s' \
        "$agent_id" "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
    local transcript_path="${conv_dir}/transcript.txt"
    _transcript_write "$transcript_path" "$output_file" "$header" "$max_bytes" || true

    # Issue #430 defect 2 instrumentation: flag (don't fix) the transcript
    # capture gap so it's a visible, testable signal instead of a silent one.
    if [[ -f "$transcript_path" ]] && _transcript_is_boilerplate_only "$transcript_path"; then
        log_warn "Captured transcript for agent=$agent_id is boilerplate-only (entrypoint/liveness-monitor/dnsmasq lines) — agent dialogue may not have been captured; see transcript_content_missing in status.json"
        status_set_transcript_content_missing "true"
    else
        status_set_transcript_content_missing "false"
    fi
    return 0
}

#-------------------------------------------------------------------------------
# transcript_save_partial <conv_dir> <output_file> <agent_id> [<max_bytes>]
#
# Trap-path variant: persists a partial transcript on abnormal exit. Skips
# silently when the normal path already wrote transcript.txt. Same safety
# contract as transcript_save (never fails, never overwrites).
#-------------------------------------------------------------------------------
transcript_save_partial() {
    local conv_dir="$1"
    local output_file="$2"
    local agent_id="${3:-unknown}"
    local max_bytes="${4:-${KAPSIS_TRANSCRIPT_MAX_BYTES:-$KAPSIS_TRANSCRIPT_DEFAULT_MAX_BYTES}}"

    [[ -n "$conv_dir" && -d "$conv_dir" ]] || return 0
    [[ -n "$output_file" && -f "$output_file" && -s "$output_file" ]] || return 0

    local transcript_path="${conv_dir}/transcript.txt"
    # The normal path already wrote the full transcript — never overwrite it.
    [[ -f "$transcript_path" ]] && return 0

    local header
    printf -v header '# kapsis-transcript (interrupted) agent=%s at=%s' \
        "$agent_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
    _transcript_write "$transcript_path" "$output_file" "$header" "$max_bytes" || true
    return 0
}
