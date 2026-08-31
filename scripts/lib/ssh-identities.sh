#!/usr/bin/env bash
#===============================================================================
# ssh-identities.sh - Materialize declarative SSH identities (deploy keys)
#
# Reads KAPSIS_SSH_IDENTITIES (metadata) + KAPSIS_SSH_IDKEY_<n>_B64 (base64
# key material, one per identity, env-file only — NEVER a `-e` flag) set by
# scripts/launch-agent.sh's generate_env_vars(), and materializes each key as
# a proper SSH identity file plus a generated, non-destructive ~/.ssh/config
# Include stanza and port-aware known_hosts entry.
#
# Provider-agnostic: no hostnames/providers are hardcoded here. Config declares
# hosts via the generic `ssh.identities` block (see docs/CONFIG-REFERENCE.md).
#
# Security invariants:
#   - Key material NEVER passed as a raw `-e VAR=value`; only base64, only via
#     the env-file (mirrors inject_credential_files' template transport).
#   - umask 0077 during all writes; ~/.ssh 0700; identity files 0600.
#   - Base64 decode failure is fail-loud (log_error) and skips that identity —
#     never writes a partial/garbage key file.
#   - ALL KAPSIS_SSH_IDKEY_*_B64 and KAPSIS_SSH_IDENTITIES env vars are unset
#     at the end, including on early-return paths where they were read.
#   - Inputs are re-validated in-container (defense in depth; launch-agent.sh
#     already validated host-side).
#
# Environment:
#   KAPSIS_SSH_IDENTITIES     - comma-separated "host|port|user|identity_file|strict"
#   KAPSIS_SSH_IDKEY_<n>_B64  - base64-encoded private key for identity <n> (0-based,
#                               matching KAPSIS_SSH_IDENTITIES list order)
#
# Usage: Called automatically by entrypoint.sh, independent of git.transport_policy
#        source ssh-identities.sh && setup_ssh_identities
#===============================================================================

# Source guard
[[ -n "${_KAPSIS_SSH_IDENTITIES_LOADED:-}" ]] && return 0
_KAPSIS_SSH_IDENTITIES_LOADED=1

# Source logging if available
if [[ -f "${KAPSIS_LIB:-/opt/kapsis/lib}/logging.sh" ]]; then
    # shellcheck source=logging.sh
    source "${KAPSIS_LIB:-/opt/kapsis/lib}/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_debug() { :; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*"; }
fi

# Unset every SSH identity transport env var. Called unconditionally at the
# end of setup_ssh_identities(), including on early-return paths, so raw key
# material (base64 form) never survives into the agent process environment.
_ssh_identities_cleanup_env() {
    local var
    for var in "${!KAPSIS_SSH_IDKEY_@}"; do
        unset "$var"
    done
    unset KAPSIS_SSH_IDENTITIES
}

# Ensure `Include ~/.ssh/kapsis_identities` is the first line of ~/.ssh/config.
# No-clobber: never overwrites the (possibly staged/personal) config — only
# prepends the Include if missing. Idempotent: running twice does not
# duplicate the line. Creates the config (0600) if absent.
_ssh_identities_ensure_include() {
    local ssh_config="$HOME/.ssh/config"
    local include_line="Include ~/.ssh/kapsis_identities"

    if [[ ! -f "$ssh_config" ]]; then
        local old_umask
        old_umask=$(umask)
        umask 0077
        printf '%s\n' "$include_line" > "$ssh_config"
        umask "$old_umask"
        chmod 0600 "$ssh_config"
        log_debug "Created $ssh_config with kapsis identities Include"
        return 0
    fi

    if grep -qxF "$include_line" "$ssh_config" 2>/dev/null; then
        log_debug "$ssh_config already includes kapsis identities"
        return 0
    fi

    # Prepend (first-match precedence in ssh_config means our stanzas win).
    local tmp_config
    tmp_config=$(mktemp "${ssh_config}.kapsis-XXXXXX")
    {
        printf '%s\n' "$include_line"
        cat "$ssh_config"
    } > "$tmp_config"
    chmod 0600 "$tmp_config"
    mv "$tmp_config" "$ssh_config"
    log_debug "Prepended kapsis identities Include to $ssh_config"
}

# Best-effort port-aware known_hosts pre-population. Non-fatal on failure
# (StrictHostKeyChecking accept-new covers first-use). Dedups by the
# `[host]:port` (or bare `host` for port 22) known_hosts key form.
_ssh_identities_keyscan() {
    local host="$1"
    local port="$2"
    local known_hosts="$HOME/.ssh/known_hosts"

    if ! command -v ssh-keyscan &>/dev/null; then
        log_debug "ssh-keyscan not available — skipping known_hosts pre-population for $host"
        return 0
    fi

    local dedup_key="$host"
    if [[ "$port" != "22" ]]; then
        dedup_key="[${host}]:${port}"
    fi

    mkdir -p "$(dirname "$known_hosts")"
    touch "$known_hosts"
    # Use `ssh-keygen -F` (not an unanchored grep substring match) so this
    # correctly handles BOTH plain known_hosts entries and OpenSSH's hashed
    # format (HashKnownHosts yes), and doesn't false-positive on e.g.
    # "git.example.com " matching inside "sub.git.example.com ...".
    if command -v ssh-keygen &>/dev/null && ssh-keygen -q -F "$dedup_key" -f "$known_hosts" >/dev/null 2>&1; then
        log_debug "known_hosts already has an entry for $dedup_key"
        return 0
    fi

    local scanned
    if ! scanned=$(ssh-keyscan -t ed25519,rsa,ecdsa -p "$port" "$host" 2>/dev/null) || [[ -z "$scanned" ]]; then
        log_warn "ssh-keyscan failed for $host:$port — relying on strict_host_key_checking mode for first use"
        return 0
    fi

    local old_umask
    old_umask=$(umask)
    umask 0077
    printf '%s\n' "$scanned" >> "$known_hosts"
    umask "$old_umask"
    chmod 0600 "$known_hosts"
    log_debug "Pre-populated known_hosts for $dedup_key"
}

# Materialize one identity's key file. Returns 1 on decode failure without
# writing a partial file.
# Args: $1=idx $2=identity_file(already ~-expanded)
_ssh_identities_write_key() {
    local idx="$1"
    local identity_file="$2"
    local b64_var="KAPSIS_SSH_IDKEY_${idx}_B64"
    local b64_value="${!b64_var:-}"

    if [[ -z "$b64_value" ]]; then
        log_error "Missing $b64_var for SSH identity #$idx — skipping"
        return 1
    fi

    local decoded
    if ! decoded=$(printf '%s' "$b64_value" | base64 -d 2>/dev/null); then
        log_error "Failed to base64-decode SSH identity #$idx — skipping (no partial file written)"
        return 1
    fi
    if [[ -z "$decoded" ]]; then
        log_error "Decoded SSH identity #$idx is empty — skipping"
        return 1
    fi

    mkdir -p "$(dirname "$identity_file")"
    chmod 0700 "$(dirname "$identity_file")" 2>/dev/null || true

    local old_umask
    old_umask=$(umask)
    umask 0077
    if ! printf '%s\n' "$decoded" > "$identity_file" 2>/dev/null; then
        umask "$old_umask"
        log_error "Failed to write SSH identity file $identity_file — skipping"
        return 1
    fi
    umask "$old_umask"
    chmod 0600 "$identity_file" 2>/dev/null || true
    return 0
}

# Main entry point. Called from entrypoint.sh's main(), independent of
# git.transport_policy (ssh.identities always applies, like ssh.verify_hosts).
setup_ssh_identities() {
    if [[ -z "${KAPSIS_SSH_IDENTITIES:-}" ]]; then
        log_debug "No SSH identities to set up (ssh.identities not configured)"
        # Defense-in-depth: always clean up, even on this early-return path
        # (harmless no-op if nothing was set) — see this function's/the
        # module header comment's "unconditionally" invariant.
        _ssh_identities_cleanup_env
        return 0
    fi

    log_info "Setting up declarative SSH identities..."

    mkdir -p "$HOME/.ssh"
    chmod 0700 "$HOME/.ssh"

    local stanzas_file="$HOME/.ssh/kapsis_identities"
    local old_umask
    old_umask=$(umask)
    umask 0077
    : > "$stanzas_file"
    umask "$old_umask"
    chmod 0600 "$stanzas_file"

    local idx entry host port user identity_file strict
    IFS=',' read -ra _kapsis_ssh_entries <<< "$KAPSIS_SSH_IDENTITIES"
    # FIX-6: iterate over array indices directly instead of a hand-maintained
    # counter — a forgotten `((idx++))` on any skip/success path used to risk
    # silently mis-pairing a key with the wrong host/metadata.
    for idx in "${!_kapsis_ssh_entries[@]}"; do
        entry="${_kapsis_ssh_entries[idx]}"
        IFS='|' read -r host port user identity_file strict <<< "$entry"

        if [[ -z "$host" ]]; then
            continue
        fi

        # --- Defense-in-depth re-validation (host-side already validated) ---
        if [[ ! "$host" =~ ^[A-Za-z0-9._-]+$ ]]; then
            log_error "ssh.identities[$idx]: invalid host '$host' — skipping"
            continue
        fi
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_error "ssh.identities[$idx]: invalid port '$port' for host '$host' — skipping"
            continue
        fi
        case "$strict" in
            accept-new|yes|no) : ;;
            *)
                log_error "ssh.identities[$idx]: invalid strict_host_key_checking '$strict' for host '$host' — skipping"
                continue
                ;;
        esac
        # user is optional — only validate when non-empty. Also reject the
        # metadata delimiters (',' field separator, '|' entry separator) and
        # newlines, which would otherwise desync the index<->key pairing.
        if [[ -n "$user" ]] && [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
            log_error "ssh.identities[$idx]: invalid user '$user' for host '$host' — skipping"
            continue
        fi
        # Allowlist path chars only (implicitly rejects ',' '|' newline that would
        # desync the delimited transport); separate '..' guard for traversal.
        if [[ ! "$identity_file" =~ ^[A-Za-z0-9._/~-]+$ ]] || [[ "$identity_file" == *".."* ]]; then
            log_error "ssh.identities[$idx]: invalid identity_file path for host '$host' — skipping"
            continue
        fi

        # Expand leading ~
        identity_file="${identity_file/#\~/$HOME}"

        if ! _ssh_identities_write_key "$idx" "$identity_file"; then
            continue
        fi

        {
            printf 'Host %s\n' "$host"
            printf '    HostName %s\n' "$host"
            printf '    Port %s\n' "$port"
            [[ -n "$user" ]] && printf '    User %s\n' "$user"
            printf '    IdentityFile %s\n' "$identity_file"
            printf '    IdentitiesOnly yes\n'
            printf '    StrictHostKeyChecking %s\n' "$strict"
            printf '    UserKnownHostsFile ~/.ssh/known_hosts\n'
            printf '\n'
        } >> "$stanzas_file"

        log_success "Materialized SSH identity for host '$host' (port $port)"

        # Best-effort port-aware known_hosts pre-population (non-fatal).
        _ssh_identities_keyscan "$host" "$port"
    done

    chmod 0600 "$stanzas_file"
    _ssh_identities_ensure_include

    _ssh_identities_cleanup_env
}
