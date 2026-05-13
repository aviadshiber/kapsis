#!/usr/bin/env bash
#===============================================================================
# atomic-copy.sh - Race-condition-safe file and directory copying
#
# Provides atomic copy operations with validation for use in container
# staging, where host files mounted via bind mount may be written to
# concurrently. Prevents truncated copies that cause application crashes.
#
# Key properties:
#   - Atomic write via temp file + mv (no partial-read window)
#   - Size validation against source (catches truncation)
#   - JSON validation for .json files (when jq available)
#   - Cross-platform (macOS + Linux) via compat.sh
#
# Usage:
#   source atomic-copy.sh
#   atomic_copy_file "/src/file" "/dst/file"
#   atomic_copy_dir "/src/dir" "/dst/dir"
#
# See also: GitHub issue #151
#===============================================================================

# Source guard
[[ -n "${_KAPSIS_ATOMIC_COPY_LOADED:-}" ]] && return 0
_KAPSIS_ATOMIC_COPY_LOADED=1

_ATOMIC_COPY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source compat.sh for cross-platform get_file_size()
if [[ -z "${_KAPSIS_COMPAT_LOADED:-}" ]]; then
    if [[ -f "$_ATOMIC_COPY_LIB_DIR/compat.sh" ]]; then
        source "$_ATOMIC_COPY_LIB_DIR/compat.sh"
    fi
fi

# Source logging if available
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    if [[ -f "$_ATOMIC_COPY_LIB_DIR/logging.sh" ]]; then
        source "$_ATOMIC_COPY_LIB_DIR/logging.sh"
    else
        # Minimal fallback
        log_info() { echo "[INFO] $*"; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_debug() { :; }
    fi
fi

#-------------------------------------------------------------------------------
# _atomic_validate_file <src> <dst>
#
# Validates that dst matches src in size, and for .json files, is valid JSON.
# Returns: 0 = valid, 1 = invalid
#-------------------------------------------------------------------------------
_atomic_validate_file() {
    local src="$1"
    local dst="$2"

    # Size comparison via cross-platform get_file_size()
    local src_size dst_size
    if command -v get_file_size &>/dev/null; then
        src_size=$(get_file_size "$src")
        dst_size=$(get_file_size "$dst")
    else
        # Portable fallback: wc -c works everywhere
        src_size=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
        dst_size=$(wc -c < "$dst" 2>/dev/null | tr -d ' ')
    fi

    if [[ "${src_size:-0}" -ne "${dst_size:-0}" ]]; then
        log_debug "atomic-copy: size mismatch: src=${src_size} dst=${dst_size} for $(basename "$dst")"
        return 1
    fi

    # JSON validation for .json files
    if [[ "$dst" == *.json ]] && command -v jq &>/dev/null; then
        if ! jq empty "$dst" 2>/dev/null; then
            log_debug "atomic-copy: JSON validation failed for $(basename "$dst")"
            return 1
        fi
    fi

    return 0
}

#-------------------------------------------------------------------------------
# _atomic_count_files <dir>
#
# Counts regular files (recursively) in a directory. Portable across platforms.
# Returns: file count as integer
#-------------------------------------------------------------------------------
_atomic_count_files() {
    local dir="$1"
    find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

#-------------------------------------------------------------------------------
# _atomic_scratch_base
#
# Returns a writable scratch base directory for cross-filesystem fallback,
# preferring the per-user XDG runtime tmpfs (0700 by default on Linux) over
# the world-readable /tmp. Honours KAPSIS_SCRATCH_DIR override.
#
# Issue #328: defaulting to /tmp leaked credential filenames/sizes in the
# directory listing on multi-user hosts. Per-user runtime dir keeps both
# names and contents private.
#-------------------------------------------------------------------------------
_atomic_scratch_base() {
    if [[ -n "${KAPSIS_SCRATCH_DIR:-}" ]]; then
        echo "$KAPSIS_SCRATCH_DIR"
        return 0
    fi
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -d "$XDG_RUNTIME_DIR" ]] && [[ -w "$XDG_RUNTIME_DIR" ]]; then
        echo "$XDG_RUNTIME_DIR"
        return 0
    fi
    echo "${TMPDIR:-/tmp}"
}

#-------------------------------------------------------------------------------
# _atomic_run_mktemp <flag-args...> -- <template>
#
# Runs mktemp with stdout and stderr captured to separate sinks (Issue #328:
# previous `2>&1`-into-a-single-var conflated stderr warnings with the path
# on success). Sets _ATOMIC_MKTEMP_PATH on success, _ATOMIC_MKTEMP_ERR on
# failure. Returns mktemp's exit code.
#
# Usage:
#   _atomic_run_mktemp -d "/parent/.atomic-copy-dir-XXXXXX"
#-------------------------------------------------------------------------------
_atomic_run_mktemp() {
    local err_file rc
    err_file="${TMPDIR:-/tmp}/.kapsis-mktemp-err.$$.${RANDOM}"
    _ATOMIC_MKTEMP_PATH=""
    _ATOMIC_MKTEMP_ERR=""
    _ATOMIC_MKTEMP_PATH=$(mktemp "$@" 2>"$err_file") && rc=0 || rc=$?
    if [[ -f "$err_file" ]]; then
        _ATOMIC_MKTEMP_ERR=$(cat "$err_file" 2>/dev/null || true)
        rm -f "$err_file" 2>/dev/null || true
    fi
    return "$rc"
}

# GNU coreutils cp emits these benign-but-non-zero patterns when staging
# host config dirs through virtio-fs on macOS. atomic_copy_dir always runs
# inside the Linux container (GNU cp), never against BSD cp on a macOS
# host — atomic_copy_dir is invoked only from scripts/entrypoint.sh inside
# the kapsis sandbox. BSD cp's different formats would fail these matches
# and be treated as real failures (fail-safe).
#
# Caller pins LC_ALL=C around the cp invocation so locale translations
# can't defeat the regexes on non-English container images.
# Guard against `readonly` failing on re-source (tests use _reset_atomic_copy_lib).
#
# (1) cp's "cannot stat" form. Two errno mappings observed in the wild:
#     - ENOENT  ("No such file or directory") — bind-mounted AF_UNIX sockets
#       on virtio-fs read paths (issue #328).
#     - ENOTSUPP ("Operation not supported") — same socket class on the
#       /kapsis-staging bind-mount; different kernel/cp combo (issue #335).
if [[ -z "${_ATOMIC_CP_STAT_FAIL_REGEX:-}" ]]; then
    readonly _ATOMIC_CP_STAT_FAIL_REGEX='^cp:[[:space:]]+cannot[[:space:]]+stat[[:space:]]+.+:[[:space:]]+(No[[:space:]]+such[[:space:]]+file[[:space:]]+or[[:space:]]+directory|Operation[[:space:]]+not[[:space:]]+supported)$'
fi

# (2) cp's post-copy fchmod warning. GNU cp tries to restore source mode
# bits on the destination AFTER the data copy; this fails (with non-zero
# exit) when src/dst differ in uid or when dst lives on a filesystem
# that rejects chmod. The data IS copied; the count check is the final
# guard.
if [[ -z "${_ATOMIC_CP_PRESERVE_PERMS_REGEX:-}" ]]; then
    readonly _ATOMIC_CP_PRESERVE_PERMS_REGEX='^cp:[[:space:]]+preserving[[:space:]]+permissions[[:space:]]+for[[:space:]]+.+:[[:space:]]+(Permission[[:space:]]+denied|Operation[[:space:]]+not[[:space:]]+permitted)$'
fi

#-------------------------------------------------------------------------------
# _atomic_cp_stderr_is_benign_only <cp_stderr>
#
# Returns 0 when the captured cp stderr contains at least one non-empty
# line AND every non-empty line matches one of the known-benign patterns:
#
#   (1) `cp: cannot stat 'X': (No such file or directory|Operation not
#       supported)` — readdir/stat mismatch on unstattable entries
#       (sockets, FIFOs, files deleted mid-copy). Issues #328 and #335.
#   (2) `cp: preserving permissions for 'X': (Permission denied|Operation
#       not permitted)` — cp's post-copy fchmod step; the data IS copied
#       but cp couldn't restore source mode bits. Issue #335.
#
# Returns 1 if stderr is empty, contains only whitespace, OR has any
# unrecognized line — caller must treat as a real failure.
#
# The caller MUST still validate the payload via the regular-file count
# comparison; this helper only certifies that the stderr signal alone
# is non-fatal.
#
# Limitation (issue #328 root-cause comment): _atomic_count_files uses
# `find -type f`, which itself calls stat(). If a REGULAR file in the
# source tree exhibits the same readdir-visible-but-stat-ENOENT/ENOTSUPP
# pathology (vs. just sockets), it would be excluded from BOTH source
# and destination counts — and slip through silently. In the motivating
# macOS+virtio-fs case the unstattable pattern is restricted to AF_UNIX
# socket inodes, so this is theoretical; documenting for future
# hardening.
#
# Motivating case (issues #328 + #335): on macOS hosts, virtio-fs
# returns AF_UNIX socket entries from readdir() but errors from stat().
# Different kernel/cp combos return different errnos for the same
# situation (ENOENT vs ENOTSUPP). cp also emits a benign "preserving
# permissions" warning when it can't restore source mode bits on the
# destination (different uid, or fs rejects chmod). Without tolerating
# these patterns, overlay-mode staged-config copy is unusable on every
# host that has git fsmonitor (`.claude`), an ssh-agent socket (`.ssh`),
# or any other live IPC in a staged dir.
#-------------------------------------------------------------------------------
_atomic_cp_stderr_is_benign_only() {
    local stderr="$1"
    [[ -z "$stderr" ]] && return 1
    local saw_line=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        saw_line=1
        if [[ "$line" =~ $_ATOMIC_CP_STAT_FAIL_REGEX ]]; then
            continue
        fi
        if [[ "$line" =~ $_ATOMIC_CP_PRESERVE_PERMS_REGEX ]]; then
            continue
        fi
        return 1
    done <<< "$stderr"
    # Reject whitespace-only / newline-only stderr (no signal to whitelist).
    [[ $saw_line -eq 1 ]] && return 0
    return 1
}

#-------------------------------------------------------------------------------
# _atomic_cp_with_enoent_tolerance <site_label> <cp_args...>
#
# Wraps `cp $cp_args` to centralize the issue #328 stat-ENOENT
# tolerance pattern across atomic_copy_dir's three cp call sites
# (main path, scratch-fallback, last-resort direct cp).
#
# Behavior:
#   1. Runs `LC_ALL=C cp "$@"` with stderr captured (LC_ALL=C pins the
#      diagnostic format so locale translations cannot defeat the
#      classifier).
#   2. If cp exits non-zero AND every stderr line matches the benign
#      stat-ENOENT signature, treat as success — caller's regular-file
#      count comparison is the final guard.
#   3. Sets _ATOMIC_CP_STDERR so the caller can include the raw stderr
#      in a log_warn message on real failures.
#
# Returns: cp's exit code, possibly rewritten 1→0 by the tolerance
# rule. <site_label> is included in the log_debug message so operators
# can identify which patched path activated tolerance.
#-------------------------------------------------------------------------------
_atomic_cp_with_enoent_tolerance() {
    local site="$1"; shift
    local cp_err cp_rc
    cp_err=$(LC_ALL=C cp "$@" 2>&1) && cp_rc=0 || cp_rc=$?
    if [[ $cp_rc -ne 0 ]] && _atomic_cp_stderr_is_benign_only "$cp_err"; then
        log_debug "atomic_copy_dir: cp non-zero in ${site} but stderr is stat-ENOENT only; deferring to count check"
        cp_rc=0
    fi
    _ATOMIC_CP_STDERR="$cp_err"
    return "$cp_rc"
}

#-------------------------------------------------------------------------------
# atomic_copy_file <src> <dst>
#
# Atomically copies a single file with validation.
#
# Strategy:
#   1. Copy to temp file in same directory as destination
#   2. Atomic rename (mv) to final location
#   3. Validate size match and JSON integrity
#
# Returns: 0 = success, 1 = failed (corrupt destination removed on validation failure)
#-------------------------------------------------------------------------------
atomic_copy_file() {
    local src="$1"
    local dst="$2"

    if [[ ! -f "$src" ]]; then
        log_warn "atomic_copy_file: source not found: $src"
        return 1
    fi

    # Ensure destination directory exists
    mkdir -p "$(dirname "$dst")" 2>/dev/null || true

    # Create temp file in same directory as dst (required for atomic mv).
    # Issue #328: capture mktemp stderr without conflating it with stdout
    # (the path on success), so warnings emitted on success don't poison
    # the captured path.
    local tmp_file=""
    local mktemp_err=""
    if _atomic_run_mktemp "$(dirname "$dst")/.atomic-copy-XXXXXX"; then
        tmp_file="$_ATOMIC_MKTEMP_PATH"
    else
        mktemp_err="$_ATOMIC_MKTEMP_ERR"
    fi

    if [[ -z "$tmp_file" ]] || [[ ! -e "$tmp_file" ]]; then
        log_warn "atomic_copy_file: mktemp failed for $(basename "$dst"): ${mktemp_err:-no stderr}"

        # Issue #328: degraded path when dirname(dst) can't host a temp file.
        # We do a single direct cp into dst (atomicity is already lost when
        # the parent rejected mktemp; staging through scratch buys nothing
        # for single files and adds two file copies).
        local fallback_err
        fallback_err=$(cp -p "$src" "$dst" 2>&1) || {
            log_warn "atomic_copy_file: fallback cp failed for $(basename "$dst"): ${fallback_err:-no stderr}"
            return 1
        }
        chmod u+w "$dst" 2>/dev/null || true
        if _atomic_validate_file "$src" "$dst"; then
            return 0
        fi
        log_warn "atomic_copy_file: validation failed for $(basename "$dst") (fallback path) — removing corrupt copy"
        rm -f "$dst" 2>/dev/null || true
        return 1
    fi

    # Copy to temp file
    local cp_err
    if cp_err=$(cp -p "$src" "$tmp_file" 2>&1); then
        # Atomic rename to destination
        mv "$tmp_file" "$dst"
        chmod u+w "$dst" 2>/dev/null || true

        # Validate the copy
        if _atomic_validate_file "$src" "$dst"; then
            return 0
        fi

        # Rollback: remove corrupt destination to prevent use of bad data (issue #164)
        log_warn "atomic_copy_file: validation failed for $(basename "$dst") — removing corrupt copy"
        rm -f "$dst" 2>/dev/null || true
        return 1
    else
        rm -f "$tmp_file" 2>/dev/null || true
        log_warn "atomic_copy_file: cp failed for $(basename "$dst"): ${cp_err:-no stderr}"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# atomic_copy_dir <src_dir> <dst_dir>
#
# Atomically copies a directory's contents with validation.
#
# Strategy:
#   1. Copy to temp directory alongside destination
#   2. Validate file count matches
#   3. Atomic replace: rm old, mv temp to final
#
# Returns: 0 = success, 1 = failed (fallback copy used)
#-------------------------------------------------------------------------------
atomic_copy_dir() {
    local src="$1"
    local dst="$2"

    if [[ ! -d "$src" ]]; then
        log_warn "atomic_copy_dir: source not found: $src"
        return 1
    fi

    # Issue #335-C: dst may already exist with restrictive perms — either
    # because the caller pre-created it (e.g. entrypoint's
    # setup_staged_config_overlays does mkdir -p "$dst") under a
    # restrictive umask, or because the Containerfile's mkdir/COPY
    # commands ran as root while the runtime uid is different. The
    # subsequent rm-rf-then-mv replacement strategy needs to be able to
    # unlink dst's existing contents.
    #
    # Best-effort chmod tree to grant USER rwx so we can remove our
    # own files. Silently fails for entries we don't own (|| true), in
    # which case the subsequent rm-rf surfaces the real EACCES error
    # for the operator. Adds only u+rwx (not g, not o, not setuid
    # bits), so no security regression for dst trees under HOME.
    if [[ -d "$dst" ]]; then
        chmod -R u+rwx "$dst" 2>/dev/null || true
    fi

    # Create temp directory alongside destination (same filesystem for atomic mv).
    # Issue #328: capture mktemp stderr without conflating it with stdout
    # (the path on success) so warnings emitted on success don't poison
    # the captured path.
    local tmp_dir=""
    local mktemp_err=""
    if _atomic_run_mktemp -d "$(dirname "$dst")/.atomic-copy-dir-XXXXXX"; then
        tmp_dir="$_ATOMIC_MKTEMP_PATH"
    else
        mktemp_err="$_ATOMIC_MKTEMP_ERR"
    fi

    if [[ -z "$tmp_dir" ]] || [[ ! -d "$tmp_dir" ]]; then
        log_warn "atomic_copy_dir: mktemp failed for $(basename "$dst"): ${mktemp_err:-no stderr}"

        # Issue #328: cross-filesystem fallback. dirname(dst) may be RO; try
        # a writable scratch outside the destination tree and stage there
        # before a best-effort, non-atomic copy into dst. Atomicity is lost
        # but the alternative is a guaranteed failure.
        local scratch_base
        scratch_base=$(_atomic_scratch_base)
        mkdir -p "$scratch_base" 2>/dev/null || true
        chmod 0700 "$scratch_base" 2>/dev/null || true  # tighten if newly created
        local scratch_err=""
        if _atomic_run_mktemp -d "${scratch_base}/.kapsis-atomic-copy-XXXXXX"; then
            tmp_dir="$_ATOMIC_MKTEMP_PATH"
        else
            scratch_err="$_ATOMIC_MKTEMP_ERR"
            tmp_dir=""
        fi

        if [[ -z "$tmp_dir" ]] || [[ ! -d "$tmp_dir" ]]; then
            log_warn "atomic_copy_dir: scratch mktemp in ${scratch_base} also failed: ${scratch_err:-no stderr}"
            # Last resort: copy directly to dst with surfaced stderr.
            # Issue #328 (review finding #1): return reflects whether the
            # direct cp actually succeeded, so callers don't log a false
            # "validation failed" for data that's intact on disk.
            mkdir -p "$dst" 2>/dev/null || true
            _atomic_cp_with_enoent_tolerance "last-resort direct cp for $(basename "$dst")" \
                -rp "$src/." "$dst/"
            local direct_rc=$?
            find "$dst" -type d -exec chmod u+w {} + 2>/dev/null || true
            if [[ $direct_rc -ne 0 ]]; then
                log_warn "atomic_copy_dir: direct cp failed for $(basename "$dst"): ${_ATOMIC_CP_STDERR:-no stderr}"
                return 1
            fi
            # Validate file count matches; only then can we report success.
            local _src_n _dst_n
            _src_n=$(_atomic_count_files "$src")
            _dst_n=$(_atomic_count_files "$dst")
            if [[ "$_src_n" -eq "$_dst_n" ]]; then
                log_debug "atomic_copy_dir: last-resort direct cp succeeded for $(basename "$dst")"
                return 0
            fi
            log_warn "atomic_copy_dir: direct cp left mismatched file count for $(basename "$dst") (src=${_src_n} dst=${_dst_n})"
            return 1
        fi

        log_debug "atomic_copy_dir: using cross-fs scratch ${tmp_dir} for $(basename "$dst")"
        # Issue #328: tolerate benign cp stderr from virtio-fs (sockets/FIFOs
        # readdir-visible but stat-invisible). See _atomic_cp_with_enoent_tolerance.
        _atomic_cp_with_enoent_tolerance "scratch-stage cp src→tmp for $(basename "$dst")" \
            -rp "$src/." "$tmp_dir/"
        local scratch_cp_rc=$?
        if [[ $scratch_cp_rc -eq 0 ]]; then
            find "$tmp_dir" -type d -exec chmod u+w {} + 2>/dev/null || true

            # Issue #328 (review finding #2): the stage cp into dst must not
            # validate against a pre-populated dst — stale files would either
            # mask a real success (count mismatch → false failure) or hide
            # leftover state (matching count → false success). Clear dst
            # contents first; preserve dst's own permissions/ownership.
            if [[ -d "$dst" ]]; then
                find "$dst" -mindepth 1 -delete 2>/dev/null || true
            else
                mkdir -p "$dst" 2>/dev/null || true
                # Preserve source's dir mode for new dst (e.g. 0700 for .ssh)
                if command -v get_file_mode &>/dev/null; then
                    local _src_mode
                    _src_mode=$(get_file_mode "$src" 2>/dev/null || echo "")
                    if [[ -n "$_src_mode" ]]; then
                        chmod "$_src_mode" "$dst" 2>/dev/null || true
                    fi
                fi
            fi

            # tmp_dir → dst: scratch is local FS we just populated, no
            # virtio-fs socket pathology — keep plain cp rc semantics.
            local stage_err
            stage_err=$(cp -rp "$tmp_dir/." "$dst/" 2>&1) || {
                log_warn "atomic_copy_dir: stage cp into $dst failed: ${stage_err:-no stderr}"
                rm -rf "$tmp_dir" 2>/dev/null || true
                return 1
            }
            find "$dst" -type d -exec chmod u+w {} + 2>/dev/null || true
            rm -rf "$tmp_dir" 2>/dev/null || true

            # Compare src vs dst regular-file counts as the final guard.
            local src_count dst_count
            src_count=$(_atomic_count_files "$src")
            dst_count=$(_atomic_count_files "$dst")
            if [[ "$src_count" -eq "$dst_count" ]]; then
                return 0
            fi
            log_warn "atomic_copy_dir: scratch-path file count mismatch (src=${src_count} dst=${dst_count}) for $(basename "$dst")"
            return 1
        fi
        log_warn "atomic_copy_dir: scratch-stage cp failed for $(basename "$dst"): ${_ATOMIC_CP_STDERR:-no stderr}"
        rm -rf "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    # Copy contents to temp directory (preserve permissions).
    # Issue #328: tolerate benign cp stderr from virtio-fs (sockets/FIFOs
    # readdir-visible but stat-invisible). See _atomic_cp_with_enoent_tolerance.
    _atomic_cp_with_enoent_tolerance "main path cp src→tmp for $(basename "$dst")" \
        -rp "$src/." "$tmp_dir/"
    local cp_rc=$?

    if [[ $cp_rc -eq 0 ]]; then
        find "$tmp_dir" -type d -exec chmod u+w {} + 2>/dev/null || true

        # Validate: compare file counts
        local src_count tmp_count
        src_count=$(_atomic_count_files "$src")
        tmp_count=$(_atomic_count_files "$tmp_dir")

        if [[ "$src_count" -eq "$tmp_count" ]]; then
            # Replace destination atomically
            rm -rf "$dst"
            mv "$tmp_dir" "$dst"
            return 0
        fi

        log_warn "atomic_copy_dir: file count mismatch (src=${src_count} tmp=${tmp_count}) for $(basename "$dst")"
        rm -rf "$tmp_dir" 2>/dev/null || true
    else
        rm -rf "$tmp_dir" 2>/dev/null || true
        log_warn "atomic_copy_dir: cp failed for $(basename "$dst"): ${_ATOMIC_CP_STDERR:-no stderr}"
    fi

    # Fallback: copy directly (better to have potentially incomplete files than none)
    log_warn "atomic_copy_dir: using fallback copy for $(basename "$dst")"
    local fallback_err
    mkdir -p "$dst" 2>/dev/null || true
    fallback_err=$(cp -rp "$src/." "$dst/" 2>&1) || log_warn "atomic_copy_dir: fallback cp failed for $(basename "$dst"): ${fallback_err:-no stderr}"
    find "$dst" -type d -exec chmod u+w {} + 2>/dev/null || true
    return 1
}
