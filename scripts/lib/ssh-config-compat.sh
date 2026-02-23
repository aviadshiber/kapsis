#!/usr/bin/env bash
#===============================================================================
# ssh-config-compat.sh - Cross-platform SSH config compatibility
#
# Patches SSH config files for macOS-to-Linux portability when mounting
# host ~/.ssh into containers. macOS-only directives like 'UseKeychain yes'
# cause SSH to fail on Linux with "Bad configuration option: usekeychain".
#
# Usage:
#   source ssh-config-compat.sh
#   patch_ssh_config_portability "/path/to/.ssh/config"
#
# See also: GitHub issue #172
#===============================================================================

[[ -n "${_KAPSIS_SSH_CONFIG_COMPAT_LOADED:-}" ]] && return 0
_KAPSIS_SSH_CONFIG_COMPAT_LOADED=1

#-------------------------------------------------------------------------------
# patch_ssh_config_portability <ssh_config_path>
#
# Prepends 'IgnoreUnknown UseKeychain,AddKeysToAgent' to the SSH config file
# so that Linux OpenSSH silently skips macOS-only directives instead of failing.
#
# Guards:
#   - Only runs on Linux (defensive; containers are always Linux)
#   - Only if the config file exists
#   - Idempotent: skips if IgnoreUnknown for these directives is already present
#
# Returns 0 on success or skip, 1 on error.
#-------------------------------------------------------------------------------
patch_ssh_config_portability() {
    local ssh_config="$1"

    # Only patch on Linux (container environment)
    if ! is_linux; then
        log_debug "SSH config portability: skipping (not Linux)"
        return 0
    fi

    # File must exist
    if [[ ! -f "$ssh_config" ]]; then
        log_debug "SSH config portability: no config file at $ssh_config"
        return 0
    fi

    # Idempotency: skip if already patched
    if grep -q "^IgnoreUnknown.*UseKeychain" "$ssh_config" 2>/dev/null; then
        log_debug "SSH config already patched for portability"
        return 0
    fi

    log_info "Patching SSH config for macOS-to-Linux portability..."

    # Prepend IgnoreUnknown directive using temp file + atomic mv
    local tmp_file
    tmp_file=$(mktemp "${ssh_config}.patch-XXXXXX") || {
        log_warn "SSH config portability: could not create temp file"
        return 1
    }

    {
        echo "# Added by Kapsis for macOS-to-Linux SSH config portability (issue #172)"
        echo "IgnoreUnknown UseKeychain,AddKeysToAgent"
        echo ""
        cat "$ssh_config"
    } > "$tmp_file"

    mv "$tmp_file" "$ssh_config"
    chmod 600 "$ssh_config"

    log_info "SSH config patched: added IgnoreUnknown for UseKeychain,AddKeysToAgent"
    return 0
}
