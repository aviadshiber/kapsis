#!/usr/bin/env bash
#===============================================================================
# Kapsis Security Library
#
# Provides security hardening functions for container launch.
# This library is sourced by launch-agent.sh.
#
# Features:
#   - Seccomp profile management
#   - Capability dropping
#   - Filesystem hardening
#   - Process isolation
#   - LSM (AppArmor/SELinux) detection
#
# Configuration:
#   Security options can be set via:
#   1. Config file (security: section)
#   2. Environment variables (KAPSIS_SECURITY_*)
#   3. Command line (--security-profile)
#
# Security Profiles:
#   - minimal: Basic userns isolation only
#   - standard: Capabilities + no-new-privileges (default)
#   - strict: Standard + seccomp + noexec mounts
#   - paranoid: Strict + readonly root + LSM
#===============================================================================

# Ensure we have the KAPSIS_ROOT set
KAPSIS_ROOT="${KAPSIS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

#===============================================================================
# SECURITY PROFILE DEFINITIONS
#===============================================================================

# Default security profile
KAPSIS_SECURITY_PROFILE="${KAPSIS_SECURITY_PROFILE:-standard}"

# Profile settings (overridable by config)
declare -A SECURITY_DEFAULTS
SECURITY_DEFAULTS=(
    [minimal_caps_drop_all]=false
    [minimal_no_new_privs]=false
    [minimal_seccomp]=false
    [minimal_pids_limit]=0
    [minimal_noexec_tmp]=false

    [standard_caps_drop_all]=true
    [standard_no_new_privs]=true
    [standard_seccomp]=false
    [standard_pids_limit]=1000
    [standard_noexec_tmp]=false

    [strict_caps_drop_all]=true
    [strict_no_new_privs]=true
    [strict_seccomp]=true
    [strict_pids_limit]=500
    [strict_noexec_tmp]=true
    [strict_readonly_root]=true

    [paranoid_caps_drop_all]=true
    [paranoid_no_new_privs]=true
    [paranoid_seccomp]=true
    [paranoid_pids_limit]=300
    [paranoid_noexec_tmp]=true
    [paranoid_readonly_root]=true
    [paranoid_require_lsm]=true
)

#===============================================================================
# CAPABILITY MANAGEMENT
#===============================================================================

# Minimal set of capabilities required for AI agents
# These are added back after --cap-drop=ALL
KAPSIS_CAPS_MINIMAL=(
    "CHOWN"          # File ownership for build artifacts
    "FOWNER"         # File owner operations
    "FSETID"         # Set-ID bits on files
    "KILL"           # Signal handling
    "SETGID"         # Group ID changes
    "SETUID"         # User ID changes
    "SYS_NICE"       # Process priority (Maven/Gradle)
    "NET_BIND_SERVICE"  # Bind to privileged ports (dnsmasq for DNS filtering)
)

# Generate capability arguments for podman
# Usage: caps=($(generate_capability_args))
generate_capability_args() {
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"
    local drop_all="${SECURITY_DEFAULTS[${profile}_caps_drop_all]:-true}"

    # Override from environment
    drop_all="${KAPSIS_CAPS_DROP_ALL:-$drop_all}"

    if [[ "$drop_all" != "true" ]]; then
        return
    fi

    echo "--cap-drop=ALL"

    # Add minimal capabilities
    local cap
    for cap in "${KAPSIS_CAPS_MINIMAL[@]}"; do
        echo "--cap-add=${cap}"
    done

    # Add any additional from config
    if [[ -n "${KAPSIS_CAPS_ADD:-}" ]]; then
        IFS=',' read -ra extra_caps <<< "$KAPSIS_CAPS_ADD"
        for cap in "${extra_caps[@]}"; do
            echo "--cap-add=${cap}"
        done
    fi
}

#===============================================================================
# SECCOMP PROFILE MANAGEMENT
#===============================================================================

# Get the seccomp profile path for an agent
# Usage: profile=$(get_seccomp_profile "claude")
get_seccomp_profile() {
    local agent_name="${1:-}"
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"
    local seccomp_enabled="${SECURITY_DEFAULTS[${profile}_seccomp]:-false}"

    # Override from environment
    seccomp_enabled="${KAPSIS_SECCOMP_ENABLED:-$seccomp_enabled}"

    if [[ "$seccomp_enabled" != "true" ]]; then
        return
    fi

    local seccomp_dir="${KAPSIS_ROOT}/security/seccomp"

    # Check for audit mode first
    if [[ "${KAPSIS_SECCOMP_AUDIT:-false}" == "true" ]]; then
        if [[ -f "${seccomp_dir}/kapsis-audit.json" ]]; then
            echo "${seccomp_dir}/kapsis-audit.json"
            return
        fi
    fi

    # Check for custom profile
    if [[ -n "${KAPSIS_SECCOMP_PROFILE:-}" ]] && [[ -f "${KAPSIS_SECCOMP_PROFILE}" ]]; then
        echo "${KAPSIS_SECCOMP_PROFILE}"
        return
    fi

    # Check for agent-specific profile
    if [[ -n "$agent_name" ]] && [[ -f "${seccomp_dir}/kapsis-${agent_name}.json" ]]; then
        echo "${seccomp_dir}/kapsis-${agent_name}.json"
        return
    fi

    # Fall back to base profile
    if [[ -f "${seccomp_dir}/kapsis-agent-base.json" ]]; then
        echo "${seccomp_dir}/kapsis-agent-base.json"
    fi
}

# Generate seccomp arguments for podman
# Usage: args=$(generate_seccomp_args "claude")
generate_seccomp_args() {
    local agent_name="${1:-}"
    local profile_path

    profile_path=$(get_seccomp_profile "$agent_name")

    if [[ -n "$profile_path" ]]; then
        echo "--security-opt"
        echo "seccomp=${profile_path}"
    fi
}

#===============================================================================
# PROCESS ISOLATION
#===============================================================================

# Generate process isolation arguments
# Usage: args=($(generate_process_isolation_args))
generate_process_isolation_args() {
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"

    # No new privileges
    local no_new_privs="${SECURITY_DEFAULTS[${profile}_no_new_privs]:-true}"
    no_new_privs="${KAPSIS_NO_NEW_PRIVILEGES:-$no_new_privs}"

    if [[ "$no_new_privs" == "true" ]]; then
        echo "--security-opt"
        echo "no-new-privileges:true"
    fi

    # PID limit
    local pids_limit="${SECURITY_DEFAULTS[${profile}_pids_limit]:-1000}"
    pids_limit="${KAPSIS_PIDS_LIMIT:-$pids_limit}"

    if [[ "$pids_limit" -gt 0 ]]; then
        echo "--pids-limit=${pids_limit}"
    fi

    # File descriptor limit
    local fd_limit="${KAPSIS_ULIMIT_NOFILE:-65536}"
    echo "--ulimit"
    echo "nofile=${fd_limit}:${fd_limit}"

    # User namespace (always enabled)
    echo "--userns=keep-id"

    # PID namespace isolation (default, but explicit)
    echo "--pid=private"
}

#===============================================================================
# FILESYSTEM HARDENING
#===============================================================================

# Generate tmpfs mount arguments
# Usage: args=($(generate_tmpfs_args))
generate_tmpfs_args() {
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"
    local noexec="${SECURITY_DEFAULTS[${profile}_noexec_tmp]:-false}"
    noexec="${KAPSIS_NOEXEC_TMP:-$noexec}"

    local tmp_size="${KAPSIS_TMP_SIZE:-1g}"
    local vartmp_size="${KAPSIS_VARTMP_SIZE:-500m}"

    local options="rw,nosuid,nodev,size="

    if [[ "$noexec" == "true" ]]; then
        options="rw,noexec,nosuid,nodev,size="
    fi

    echo "--tmpfs"
    echo "/tmp:${options}${tmp_size}"
    echo "--tmpfs"
    echo "/var/tmp:${options}${vartmp_size}"
}

# Check if read-only root should be enabled
# Usage: if should_use_readonly_root; then ...
should_use_readonly_root() {
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"
    local readonly_root="${SECURITY_DEFAULTS[${profile}_readonly_root]:-false}"
    readonly_root="${KAPSIS_READONLY_ROOT:-$readonly_root}"

    [[ "$readonly_root" == "true" ]]
}

# Generate read-only root arguments
# Usage: args=($(generate_readonly_root_args))
generate_readonly_root_args() {
    if should_use_readonly_root; then
        echo "--read-only"
        echo "--tmpfs"
        echo "/run:rw,noexec,nosuid,nodev,size=100m"
        # /home/developer must be writable for tool caches, staged configs, credentials
        # Named volumes (m2, gradle, ge) mount on top so build caches survive
        echo "--tmpfs"
        echo "/home/developer:rw,nosuid,nodev,size=500m"
    fi
}

#===============================================================================
# LSM (AppArmor/SELinux) DETECTION
#===============================================================================

# Detect which LSM is active on the system
# Returns: apparmor, selinux, or none
detect_lsm() {
    # Check AppArmor
    if command -v aa-status &>/dev/null; then
        if aa-status --enabled 2>/dev/null; then
            echo "apparmor"
            return
        fi
    fi

    # Check SELinux
    if command -v getenforce &>/dev/null; then
        local mode
        mode=$(getenforce 2>/dev/null || echo "Disabled")
        if [[ "$mode" != "Disabled" ]]; then
            echo "selinux"
            return
        fi
    fi

    echo "none"
}

# Check if the Kapsis LSM profile is installed
# Usage: if is_lsm_profile_installed; then ...
is_lsm_profile_installed() {
    local lsm
    lsm=$(detect_lsm)

    case "$lsm" in
        apparmor)
            aa-status 2>/dev/null | grep -q "kapsis-agent"
            ;;
        selinux)
            semodule -l 2>/dev/null | grep -q "kapsis_agent"
            ;;
        *)
            return 1
            ;;
    esac
}

# Generate LSM arguments for podman
# Usage: args=($(generate_lsm_args))
generate_lsm_args() {
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"
    local require_lsm="${SECURITY_DEFAULTS[${profile}_require_lsm]:-false}"
    require_lsm="${KAPSIS_REQUIRE_LSM:-$require_lsm}"

    local lsm_mode="${KAPSIS_LSM_MODE:-auto}"
    local lsm

    case "$lsm_mode" in
        disabled)
            echo "--security-opt"
            echo "label=disable"
            return
            ;;
        auto)
            lsm=$(detect_lsm)
            ;;
        *)
            lsm="$lsm_mode"
            ;;
    esac

    case "$lsm" in
        apparmor)
            if is_lsm_profile_installed; then
                echo "--security-opt"
                echo "apparmor=kapsis-agent"
            else
                if [[ "$require_lsm" == "true" ]]; then
                    log_error "AppArmor profile 'kapsis-agent' not installed and require_lsm=true"
                    return 1
                fi
                log_warn "AppArmor active but kapsis-agent profile not installed, disabling labels"
                echo "--security-opt"
                echo "label=disable"
            fi
            ;;
        selinux)
            if is_lsm_profile_installed; then
                echo "--security-opt"
                echo "label=type:kapsis_agent_t"
            else
                if [[ "$require_lsm" == "true" ]]; then
                    log_error "SELinux policy 'kapsis_agent' not installed and require_lsm=true"
                    return 1
                fi
                log_warn "SELinux active but kapsis_agent policy not installed, disabling labels"
                echo "--security-opt"
                echo "label=disable"
            fi
            ;;
        none|*)
            # No LSM, disable labels for overlay compatibility
            echo "--security-opt"
            echo "label=disable"
            ;;
    esac
}

#===============================================================================
# RESOURCE LIMITS
#===============================================================================

# Generate enhanced resource limit arguments
# Usage: args=($(generate_resource_limit_args "$memory" "$cpus"))
generate_resource_limit_args() {
    local memory="${1:-8g}"
    local cpus="${2:-4}"

    # Memory (hard limit with no swap)
    echo "--memory=${memory}"
    echo "--memory-swap=${memory}"

    # Memory reservation (soft limit)
    local reservation="${KAPSIS_MEMORY_RESERVATION:-2g}"
    echo "--memory-reservation=${reservation}"

    # OOM score adjustment (prefer killing container)
    echo "--oom-score-adj=500"

    # CPU limit
    echo "--cpus=${cpus}"

    # CPU shares for scheduling priority
    local cpu_shares="${KAPSIS_CPU_SHARES:-1024}"
    echo "--cpu-shares=${cpu_shares}"
}

#===============================================================================
# MAIN: Generate All Security Arguments
#===============================================================================

# Generate all security-related arguments for podman run
# Usage: security_args=($(generate_security_args "$agent_name" "$memory" "$cpus"))
generate_security_args() {
    local agent_name="${1:-}"
    local memory="${2:-8g}"
    local cpus="${3:-4}"

    log_debug "Generating security args for profile: ${KAPSIS_SECURITY_PROFILE}"

    # Capability management
    generate_capability_args

    # Seccomp profile
    generate_seccomp_args "$agent_name"

    # Process isolation
    generate_process_isolation_args

    # Filesystem hardening (tmpfs)
    generate_tmpfs_args

    # Read-only root (if enabled)
    generate_readonly_root_args

    # LSM configuration
    generate_lsm_args

    # Resource limits
    generate_resource_limit_args "$memory" "$cpus"
}

# Print security configuration summary
# Usage: print_security_summary
print_security_summary() {
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"

    echo ""
    echo "Security Configuration:"
    echo "  Profile:          ${profile}"
    echo "  Capabilities:     ${SECURITY_DEFAULTS[${profile}_caps_drop_all]:-unknown}"
    echo "  No New Privs:     ${SECURITY_DEFAULTS[${profile}_no_new_privs]:-unknown}"
    echo "  Seccomp:          ${SECURITY_DEFAULTS[${profile}_seccomp]:-unknown}"
    echo "  PID Limit:        ${SECURITY_DEFAULTS[${profile}_pids_limit]:-unknown}"
    echo "  NoExec /tmp:      ${SECURITY_DEFAULTS[${profile}_noexec_tmp]:-unknown}"
    echo "  LSM:              $(detect_lsm)"
    echo ""
}

#===============================================================================
# VALIDATION
#===============================================================================

# Validate security configuration
# Usage: if validate_security_config; then ...
validate_security_config() {
    local profile="${KAPSIS_SECURITY_PROFILE:-standard}"

    # Check profile is valid
    case "$profile" in
        minimal|standard|strict|paranoid)
            ;;
        *)
            log_error "Invalid security profile: $profile"
            log_error "Valid profiles: minimal, standard, strict, paranoid"
            return 1
            ;;
    esac

    # Check seccomp profile exists if enabled
    local seccomp_enabled="${SECURITY_DEFAULTS[${profile}_seccomp]:-false}"
    seccomp_enabled="${KAPSIS_SECCOMP_ENABLED:-$seccomp_enabled}"

    if [[ "$seccomp_enabled" == "true" ]]; then
        local seccomp_path
        seccomp_path=$(get_seccomp_profile "")
        if [[ -z "$seccomp_path" ]] || [[ ! -f "$seccomp_path" ]]; then
            log_error "Seccomp enabled but profile not found"
            return 1
        fi
        log_debug "Seccomp profile: $seccomp_path"
    fi

    return 0
}
