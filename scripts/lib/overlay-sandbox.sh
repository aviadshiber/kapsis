#!/usr/bin/env bash
#===============================================================================
# overlay-sandbox.sh — Overlay sandbox setup & named-volume export (Issue #376)
#
# On macOS the AVF virtio-fs cache-coherency bug (Apple FB16008360,
# podman#23061) corrupts kernel-OverlayFS metadata when upper/work live on the
# virtio-fs share. This library moves them into a per-agent Podman named
# volume (VM-native ext4) mounted at /overlay, merged with the read-only
# project mount at /lower by entrypoint.sh's setup_fuse_overlay().
#
# Sourced by launch-agent.sh (production) and by
# tests/test-overlay-volume-sandbox.sh (unit tests, with logging/is_macos/
# podman stubbed) — single source of truth, no body duplication.
#
# Public API (operates on launch-agent.sh globals):
#   overlay_volume_mode_enabled     — predicate: named-volume overlay active?
#   resolve_overlay_volume_mode     — downgrade to kernel OverlayFS when the
#                                     security profile forbids SYS_ADMIN
#   setup_overlay_sandbox           — compute paths, reset stale volume,
#                                     create host dirs
#   generate_overlay_project_mounts — append project/overlay mounts to
#                                     VOLUME_MOUNTS
#   export_overlay_volume_to_host   — hardened post-container volume → host
#                                     extraction
#
# Globals read:    PROJECT_PATH, AGENT_ID, SANDBOX_UPPER_BASE, DRY_RUN,
#                  KAPSIS_OVERLAY_USE_VOLUME, KAPSIS_SECURITY_PROFILE,
#                  KAPSIS_OVERLAY_VOLUME_SUFFIX
# Globals written: SANDBOX_ID, SANDBOX_DIR, UPPER_DIR, WORK_DIR,
#                  OVERLAY_VOLUME, VOLUME_MOUNTS, KAPSIS_OVERLAY_USE_VOLUME
#===============================================================================

[[ -n "${_KAPSIS_OVERLAY_SANDBOX_LOADED:-}" ]] && return 0
_KAPSIS_OVERLAY_SANDBOX_LOADED=1

# Stubs for isolated test contexts (production has logging.sh + compat.sh +
# launch-agent.sh's ensure_dir sourced/defined first).
declare -f log_info    &>/dev/null || log_info()    { echo "[INFO] $*"; }
declare -f log_warn    &>/dev/null || log_warn()    { echo "[WARN] $*" >&2; }
declare -f log_debug   &>/dev/null || log_debug()   { :; }
declare -f log_success &>/dev/null || log_success() { echo "[OK] $*"; }
declare -f is_macos    &>/dev/null || is_macos()    { [[ "$(uname -s)" == "Darwin" ]]; }
declare -f ensure_dir  &>/dev/null || ensure_dir()  { mkdir -p "$1"; }

#-------------------------------------------------------------------------------
# overlay_volume_mode_enabled
#
# True when the macOS named-volume fuse-overlayfs path is active. Callers must
# run resolve_overlay_volume_mode (via setup_overlay_sandbox) first so the
# security-profile downgrade is reflected.
#-------------------------------------------------------------------------------
overlay_volume_mode_enabled() {
    is_macos && [[ "${KAPSIS_OVERLAY_USE_VOLUME:-true}" == "true" ]]
}

#-------------------------------------------------------------------------------
# resolve_overlay_volume_mode
#
# fuse-overlayfs inside the rootless container requires `--cap-add SYS_ADMIN`,
# which contradicts the strict/paranoid security profile contract (PR #397
# review finding 5). When such a profile is active, downgrade to the kernel
# OverlayFS path (upper/work on virtio-fs) instead of silently re-adding the
# broadest Linux capability. The launch-lock serialization from PR #375 still
# mitigates the AVF race on that path.
#
# Mutates KAPSIS_OVERLAY_USE_VOLUME so every later check in the same process
# (mount generation, env vars, container command) stays consistent.
#-------------------------------------------------------------------------------
resolve_overlay_volume_mode() {
    if ! is_macos || [[ "${KAPSIS_OVERLAY_USE_VOLUME:-true}" != "true" ]]; then
        return 0
    fi

    case "${KAPSIS_SECURITY_PROFILE:-standard}" in
        strict|paranoid)
            log_warn "Security profile '${KAPSIS_SECURITY_PROFILE}' forbids the SYS_ADMIN capability required by the named-volume overlay (fuse-overlayfs)"
            log_warn "Falling back to kernel OverlayFS on virtio-fs — use KAPSIS_SECURITY_PROFILE=standard to re-enable the named-volume overlay (Issue #376)"
            KAPSIS_OVERLAY_USE_VOLUME="false"
            ;;
    esac
    return 0
}

#-------------------------------------------------------------------------------
# _reset_stale_overlay_volume <volume_name>
#
# Named volumes survive `podman run --rm` — they are only removed by
# cleanup_agent_volumes at session end. A previous run that crashed before
# cleanup, or one launched with --keep-volumes, leaves upper/work content
# that would pollute this run's fuse-overlayfs upper layer and surface as
# phantom changes in the post-container diff (PR #397 review finding 1).
# Always start from a clean volume.
#-------------------------------------------------------------------------------
_reset_stale_overlay_volume() {
    local volume_name="$1"

    if podman volume exists "$volume_name" 2>/dev/null; then
        log_warn "Stale overlay volume from a previous run — removing: $volume_name"
        if ! podman volume rm --force "$volume_name" >/dev/null 2>&1; then
            log_warn "Could not remove stale overlay volume $volume_name — a previous run's changes may leak into this session"
        fi
    fi
}

#-------------------------------------------------------------------------------
# setup_overlay_sandbox
#
# Computes SANDBOX_ID/SANDBOX_DIR/UPPER_DIR/WORK_DIR and prepares either the
# named-volume path (macOS) or the host upper/work dirs (Linux, or macOS with
# KAPSIS_OVERLAY_USE_VOLUME=false).
#-------------------------------------------------------------------------------
setup_overlay_sandbox() {
    local project_name
    project_name=$(basename "$PROJECT_PATH")
    SANDBOX_ID="${project_name}-${AGENT_ID}"
    SANDBOX_DIR="${SANDBOX_UPPER_BASE}/${SANDBOX_ID}"
    UPPER_DIR="${SANDBOX_DIR}/upper"
    WORK_DIR="${SANDBOX_DIR}/work"

    log_info "Setting up overlay sandbox: $SANDBOX_ID"

    # Security-profile gate must run before the mode is first consulted.
    resolve_overlay_volume_mode

    if overlay_volume_mode_enabled; then
        # Issue #376: on macOS move overlay upper/work off the virtio-fs share onto
        # VM-native ext4 via a Podman named volume.  SANDBOX_DIR is still created on
        # the host so export_overlay_volume_to_host() has a target to extract into.
        OVERLAY_VOLUME="kapsis-${AGENT_ID}${KAPSIS_OVERLAY_VOLUME_SUFFIX:--overlay}"
        ensure_dir "$SANDBOX_DIR"
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_info "  [DRY-RUN] Would create overlay volume: $OVERLAY_VOLUME"
        else
            _reset_stale_overlay_volume "$OVERLAY_VOLUME"
            log_info "  Overlay volume (VM-native ext4): $OVERLAY_VOLUME"
            log_info "  Export target: $SANDBOX_DIR"
        fi
    else
        ensure_dir "$UPPER_DIR"
        ensure_dir "$WORK_DIR"
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_info "  [DRY-RUN] Would create upper directory: $UPPER_DIR"
            log_info "  [DRY-RUN] Would create work directory: $WORK_DIR"
        else
            log_info "  Upper directory: $UPPER_DIR"
            log_info "  Work directory: $WORK_DIR"
        fi
    fi
}

#-------------------------------------------------------------------------------
# generate_overlay_project_mounts
#
# Appends the project mount(s) for overlay mode to VOLUME_MOUNTS. Common
# mounts (status, caches, spec, SSH) are appended separately by the caller.
#-------------------------------------------------------------------------------
generate_overlay_project_mounts() {
    if overlay_volume_mode_enabled; then
        # Issue #376: fuse-overlayfs mode — upper/work in VM-native named volume.
        # Project is mounted read-only as /lower; entrypoint.sh's setup_fuse_overlay()
        # merges it with the named volume's /overlay/upper into /workspace via
        # fuse-overlayfs (userspace, no virtio-fs round-trips on metadata).
        VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/lower:ro")
        VOLUME_MOUNTS+=("-v" "${OVERLAY_VOLUME}:/overlay")
    else
        # Linux / macOS with KAPSIS_OVERLAY_USE_VOLUME=false: kernel OverlayFS.
        # upper/work live on the host filesystem (ext4 on Linux, virtio-fs on macOS).
        VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/workspace:O,upperdir=${UPPER_DIR},workdir=${WORK_DIR}")
    fi
}

#-------------------------------------------------------------------------------
# _overlay_symlink_escapes <root> <link>
#
# Returns 0 (true) when the symlink's target resolves outside <root>:
# absolute targets, unreadable links, or relative targets whose `..`
# components climb above the export root. Returns 1 for safe intra-tree
# relative links (e.g. node_modules/.bin entries), which are legitimate
# agent output and must be preserved.
#-------------------------------------------------------------------------------
_overlay_symlink_escapes() {
    local root="$1"
    local link="$2"
    local target
    target=$(readlink "$link" 2>/dev/null) || return 0
    [[ "$target" == /* ]] && return 0

    # Depth of the link's parent directory below the export root.
    local rel="${link#"$root"/}"
    local parent_rel
    parent_rel=$(dirname "$rel")
    local depth=0
    local -a parts=()
    if [[ "$parent_rel" != "." ]]; then
        IFS='/' read -r -a parts <<< "$parent_rel"
        depth=${#parts[@]}
    fi

    # Walk the target components; if depth ever goes negative, the link
    # escapes the export root.
    local -a tparts=()
    IFS='/' read -r -a tparts <<< "$target"
    local comp
    for comp in "${tparts[@]}"; do
        case "$comp" in
            ""|".") continue ;;
            "..")
                ((depth--)) || true
                if (( depth < 0 )); then
                    return 0
                fi
                ;;
            *) ((depth++)) || true ;;
        esac
    done
    return 1
}

#-------------------------------------------------------------------------------
# _sanitize_overlay_export <root>
#
# Symlink/special-file hardening for untrusted volume content (PR #397 review
# finding 4; same attack class as scripts/lib/status-sync.sh).  A buggy or
# compromised agent can plant a symlink like `upper/x -> /Users/me/.ssh` in
# the volume; anything later writing through the extracted link would escape
# SANDBOX_DIR. Device/fifo/socket nodes are never legitimate workspace
# content (fuse-overlayfs whiteouts cannot be re-created by unprivileged tar
# anyway) and are dropped outright.
#-------------------------------------------------------------------------------
_sanitize_overlay_export() {
    local root="$1"

    # Drop special files: block/char devices, fifos, sockets.
    find "$root" \( -type b -o -type c -o -type p -o -type s \) -delete 2>/dev/null || true

    # Drop symlinks that point outside the export root; keep safe intra-tree
    # relative links (legitimate agent output, e.g. node_modules/.bin).
    local link
    while IFS= read -r -d '' link; do
        if _overlay_symlink_escapes "$root" "$link"; then
            log_warn "Stripping unsafe symlink from overlay export: ${link#"$root"/} -> $(readlink "$link" 2>/dev/null || echo '?')"
            rm -f "$link"
        fi
    done < <(find "$root" -type l -print0 2>/dev/null)
}

#-------------------------------------------------------------------------------
# export_overlay_volume_to_host
#
# After the container exits, extract the overlay named volume's upper/ and
# work/ subtrees (they sit at the volume root, so tar entries are already
# relative — no path stripping involved) into SANDBOX_DIR so the rest of
# post_container_overlay() can inspect, scope-validate, and present changes
# without knowing about named volumes.
#
# Hardening (PR #397 review findings 2 + 4):
#   - extraction lands in a fresh staging dir under SANDBOX_DIR, with
#     --no-same-owner --no-same-permissions, then is sanitized
#     (_sanitize_overlay_export) before being moved into place
#   - pipeline stderr is captured and surfaced via log_warn instead of
#     being discarded
#
# Always returns 0 — export failure must not mask the agent's exit code.
#-------------------------------------------------------------------------------
export_overlay_volume_to_host() {
    if ! overlay_volume_mode_enabled; then
        return 0
    fi
    [[ -z "${OVERLAY_VOLUME:-}" ]] && return 0

    log_info "Exporting overlay volume to host for post-container analysis..."
    ensure_dir "$SANDBOX_DIR"

    # Staging dir on the same filesystem as SANDBOX_DIR so the final move is
    # cheap and the extraction never writes through pre-existing paths.
    local staging
    if ! staging=$(mktemp -d "${SANDBOX_DIR}/.export-staging-XXXXXX" 2>/dev/null); then
        log_warn "Overlay volume export failed — cannot create staging dir under $SANDBOX_DIR"
        return 0
    fi

    local err_file
    if ! err_file=$(mktemp 2>/dev/null); then
        err_file="/dev/null"
    fi

    # --no-same-owner / --no-same-permissions: strip tar-member ownership and
    # umask overrides (we run unprivileged; modes come from the local umask).
    local export_rc=0
    podman volume export "$OVERLAY_VOLUME" 2>"$err_file" \
        | tar -C "$staging" --no-same-owner --no-same-permissions -xf - 2>>"$err_file" \
        || export_rc=$?

    if [[ "$export_rc" -ne 0 ]]; then
        log_warn "Overlay volume export pipeline reported rc=$export_rc — extracted content may be incomplete"
        if [[ "$err_file" != "/dev/null" && -s "$err_file" ]]; then
            log_warn "Export stderr: $(head -c 2000 "$err_file")"
        fi
    fi
    [[ "$err_file" != "/dev/null" ]] && rm -f "$err_file"

    _sanitize_overlay_export "$staging"

    # Move upper/ and work/ into place, replacing any leftovers from a prior
    # export attempt for this same session.
    local moved=0
    local sub
    for sub in upper work; do
        if [[ -d "$staging/$sub" ]]; then
            rm -rf "${SANDBOX_DIR:?}/${sub}"
            if mv "$staging/$sub" "$SANDBOX_DIR/$sub" 2>/dev/null; then
                ((moved++)) || true
            else
                log_warn "Failed to move exported '$sub' into $SANDBOX_DIR"
            fi
        fi
    done
    rm -rf "$staging"

    if (( moved > 0 )); then
        log_success "Overlay volume exported to $SANDBOX_DIR"
    else
        log_warn "Overlay volume export produced no content (rc=$export_rc) — UPPER_DIR may be empty"
    fi
    return 0
}
