#!/usr/bin/env bash
#===============================================================================
# YAML Configuration Verifier for Kapsis
#
# Validates tool-phase-mapping.yaml and other configuration files.
# Used in CI and during development to catch config errors early.
#
# Usage:
#   ./scripts/lib/config-verifier.sh [config-file]
#   ./scripts/lib/config-verifier.sh --all
#
# Exit codes:
#   0 - All validations passed
#   1 - Validation error found
#   2 - Missing dependencies
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="${KAPSIS_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0

#===============================================================================
# Logging
#===============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    ((WARNINGS++)) || true
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((ERRORS++)) || true
}

#===============================================================================
# Dependency Checks
#===============================================================================

check_dependencies() {
    local missing=()

    if ! command -v yq &>/dev/null; then
        missing+=("yq")
    fi

    if ! command -v yamllint &>/dev/null; then
        log_warn "yamllint not installed - YAML linting will be skipped"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}"
        return 2
    fi

    return 0
}

#===============================================================================
# Schema Validators
#===============================================================================

# Validate tool-phase-mapping.yaml
validate_tool_phase_mapping() {
    local config_file="$1"
    local section_name="tool-phase-mapping"

    log_info "Validating $section_name: $config_file"

    # Check file exists
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    # YAML syntax check with yamllint (if available)
    if command -v yamllint &>/dev/null; then
        if ! yamllint -d "{extends: relaxed, rules: {line-length: disable}}" "$config_file" 2>/dev/null; then
            log_error "YAML syntax error in $config_file"
            return 1
        fi
        log_pass "YAML syntax valid"
    fi

    # Required top-level fields
    local required_fields=("version" "phase_ranges" "default_category" "patterns")
    for field in "${required_fields[@]}"; do
        if ! yq -r ".$field // \"null\"" "$config_file" 2>/dev/null | grep -qv '^null$'; then
            log_error "Missing required field: $field"
        else
            log_pass "Has required field: $field"
        fi
    done

    # Validate version format
    local version
    version=$(yq -r '.version // ""' "$config_file" 2>/dev/null)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_pass "Version format valid: $version"
    else
        log_error "Invalid version format: $version (expected: X.Y)"
    fi

    # Validate phase_ranges structure
    local phases=("exploring" "implementing" "building" "testing" "committing" "other")
    for phase in "${phases[@]}"; do
        local range
        range=$(yq -r ".phase_ranges.$phase // \"null\"" "$config_file" 2>/dev/null)
        if [[ "$range" == "null" ]]; then
            log_warn "Missing phase_range for: $phase"
        else
            # Validate [min, max] format
            local min max
            # shellcheck disable=SC1087 # Not a bash array, yq syntax
            min=$(yq -r ".phase_ranges.${phase}[0]" "$config_file" 2>/dev/null)
            # shellcheck disable=SC1087 # Not a bash array, yq syntax
            max=$(yq -r ".phase_ranges.${phase}[1]" "$config_file" 2>/dev/null)

            if [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
                if ((min >= 0 && min <= 100 && max >= 0 && max <= 100 && min <= max)); then
                    log_pass "Phase range $phase: [$min, $max]"
                else
                    log_error "Invalid range values for $phase: [$min, $max] (must be 0-100, min <= max)"
                fi
            else
                log_error "Invalid range format for $phase: $range"
            fi
        fi
    done

    # Validate patterns structure
    log_info "Validating patterns..."
    local total_patterns=0
    local pattern_categories=("testing" "committing" "exploring" "implementing" "building" "other")

    for category in "${pattern_categories[@]}"; do
        local count
        count=$(yq -r ".patterns.$category | length" "$config_file" 2>/dev/null || echo 0)
        if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
            log_pass "Category '$category' has $count patterns"
            ((total_patterns += count)) || true

            # Validate each pattern format
            # shellcheck disable=SC1087 # Not a bash array, yq syntax for array access
            while IFS= read -r pattern; do
                if [[ -z "$pattern" || "$pattern" == "null" ]]; then
                    continue
                fi

                # Check pattern format: "Tool" or "Tool(glob)"
                if [[ "$pattern" =~ ^[a-zA-Z_][a-zA-Z0-9_]*(\(.*\))?$ ]] || \
                   [[ "$pattern" =~ ^mcp__\* ]] || \
                   [[ "$pattern" =~ ^\./[a-zA-Z]+.*$ ]]; then
                    : # Pattern is valid
                else
                    log_warn "Unusual pattern format: $pattern"
                fi
            done < <(yq -r ".patterns.${category}[]" "$config_file" 2>/dev/null)
        else
            log_warn "No patterns defined for category: $category"
        fi
    done

    log_pass "Total patterns: $total_patterns"

    # Validate default_category
    local default_cat
    default_cat=$(yq -r '.default_category // "other"' "$config_file" 2>/dev/null)
    case "$default_cat" in
        exploring|implementing|building|testing|committing|other)
            log_pass "Valid default_category: $default_cat"
            ;;
        *)
            log_error "Invalid default_category: $default_cat"
            ;;
    esac

    return 0
}

# Validate agent profile YAML (configs/agents/*.yaml)
validate_agent_profile() {
    local config_file="$1"

    log_info "Validating agent profile: $config_file"

    if [[ ! -f "$config_file" ]]; then
        log_error "Agent profile not found: $config_file"
        return 1
    fi

    # YAML syntax
    if command -v yamllint &>/dev/null; then
        if ! yamllint -d "{extends: relaxed, rules: {line-length: disable}}" "$config_file" 2>/dev/null; then
            log_error "YAML syntax error in $config_file"
            return 1
        fi
        log_pass "YAML syntax valid"
    fi

    # Required fields for agent profiles
    local required=("name" "version")
    for field in "${required[@]}"; do
        if yq -r ".$field // \"null\"" "$config_file" 2>/dev/null | grep -qv '^null$'; then
            log_pass "Has required field: $field"
        else
            log_error "Missing required field: $field"
        fi
    done

    # Optional but recommended fields
    local optional=("description" "install" "dependencies" "auth")
    for field in "${optional[@]}"; do
        if yq -r ".$field // \"null\"" "$config_file" 2>/dev/null | grep -qv '^null$'; then
            log_pass "Has optional field: $field"
        fi
    done

    return 0
}

# Validate Kapsis launch config YAML (configs/*.yaml - top-level)
validate_launch_config() {
    local config_file="$1"

    log_info "Validating launch config: $config_file"

    if [[ ! -f "$config_file" ]]; then
        log_error "Launch config not found: $config_file"
        return 1
    fi

    # YAML syntax
    if command -v yamllint &>/dev/null; then
        if ! yamllint -d "{extends: relaxed, rules: {line-length: disable}}" "$config_file" 2>/dev/null; then
            log_error "YAML syntax error in $config_file"
            return 1
        fi
        log_pass "YAML syntax valid"
    fi

    # Required: agent section with command
    if yq -r ".agent.command // \"null\"" "$config_file" 2>/dev/null | grep -qv '^null$'; then
        log_pass "Has agent.command"
    else
        log_error "Missing required field: agent.command"
    fi

    # Optional sections
    local sections=("filesystem" "environment" "resources" "maven" "git")
    for section in "${sections[@]}"; do
        if yq -r ".$section // \"null\"" "$config_file" 2>/dev/null | grep -qv '^null$'; then
            log_pass "Has section: $section"
        fi
    done

    # Validate resources if present
    local memory cpus
    memory=$(yq -r '.resources.memory // ""' "$config_file" 2>/dev/null)
    cpus=$(yq -r '.resources.cpus // ""' "$config_file" 2>/dev/null)

    if [[ -n "$memory" && "$memory" != "null" ]]; then
        if [[ "$memory" =~ ^[0-9]+[gGmM]$ ]]; then
            log_pass "Valid memory format: $memory"
        else
            log_warn "Unusual memory format: $memory (expected: Xg or Xm)"
        fi
    fi

    if [[ -n "$cpus" && "$cpus" != "null" ]]; then
        if [[ "$cpus" =~ ^[0-9]+$ ]]; then
            log_pass "Valid cpus format: $cpus"
        else
            log_warn "Unusual cpus format: $cpus (expected: integer)"
        fi
    fi

    # Validate git.auto_push if present
    local auto_push_enabled
    auto_push_enabled=$(yq -r '.git.auto_push.enabled // ""' "$config_file" 2>/dev/null)
    if [[ -n "$auto_push_enabled" && "$auto_push_enabled" != "null" ]]; then
        if [[ "$auto_push_enabled" == "true" || "$auto_push_enabled" == "false" ]]; then
            log_pass "Valid git.auto_push.enabled: $auto_push_enabled"
        else
            log_error "Invalid git.auto_push.enabled: $auto_push_enabled (must be true/false)"
        fi
    fi

    # Validate agent.inject_gist if present
    local inject_gist
    inject_gist=$(yq -r '.agent.inject_gist // ""' "$config_file" 2>/dev/null)
    if [[ -n "$inject_gist" && "$inject_gist" != "null" ]]; then
        if [[ "$inject_gist" == "true" || "$inject_gist" == "false" ]]; then
            log_pass "Valid agent.inject_gist: $inject_gist"
        else
            log_error "Invalid agent.inject_gist: $inject_gist (must be true/false)"
        fi
    fi

    return 0
}

# Validate network allowlist config YAML (configs/network-*.yaml or files with network.mode)
validate_network_config() {
    local config_file="$1"

    log_info "Validating network config: $config_file"

    if [[ ! -f "$config_file" ]]; then
        log_error "Network config not found: $config_file"
        return 1
    fi

    # YAML syntax
    if command -v yamllint &>/dev/null; then
        if ! yamllint -d "{extends: relaxed, rules: {line-length: disable}}" "$config_file" 2>/dev/null; then
            log_error "YAML syntax error in $config_file"
            return 1
        fi
        log_pass "YAML syntax valid"
    fi

    # Required: network.mode
    local network_mode
    network_mode=$(yq -r '.network.mode // "null"' "$config_file" 2>/dev/null)
    if [[ "$network_mode" != "null" && -n "$network_mode" ]]; then
        if [[ "$network_mode" =~ ^(none|filtered|open)$ ]]; then
            log_pass "Valid network.mode: $network_mode"
        else
            log_error "Invalid network.mode: $network_mode (must be: none, filtered, open)"
        fi
    else
        log_error "Missing required field: network.mode"
    fi

    # Validate allowlist if mode is filtered
    if [[ "$network_mode" == "filtered" ]]; then
        local has_allowlist
        has_allowlist=$(yq -r '.network.allowlist // "null"' "$config_file" 2>/dev/null)
        if [[ "$has_allowlist" != "null" ]]; then
            log_pass "Has network.allowlist section"

            # Count domains in each category
            local categories=("hosts" "registries" "containers" "ai" "custom")
            for category in "${categories[@]}"; do
                local count
                count=$(yq -r ".network.allowlist.$category | length // 0" "$config_file" 2>/dev/null)
                if [[ "$count" -gt 0 ]]; then
                    log_pass "Allowlist.$category: $count domains"
                fi
            done
        else
            log_warn "Mode is 'filtered' but no allowlist defined"
        fi
    fi

    # Validate DNS servers if present
    local dns_count
    dns_count=$(yq -r '.network.dns_servers | length // 0' "$config_file" 2>/dev/null)
    if [[ "$dns_count" -gt 0 ]]; then
        log_pass "Has $dns_count DNS server(s)"
    fi

    return 0
}

# Detect config type based on content
detect_config_type() {
    local config_file="$1"

    # Check for network.mode (network config)
    if yq -r '.network.mode // "null"' "$config_file" 2>/dev/null | grep -qv '^null$'; then
        echo "network"
        return
    fi

    # Check for agent.command (launch config)
    if yq -r '.agent.command // "null"' "$config_file" 2>/dev/null | grep -qv '^null$'; then
        echo "launch"
        return
    fi

    # Check for name + version (agent profile)
    if yq -r '.name // "null"' "$config_file" 2>/dev/null | grep -qv '^null$' && \
       yq -r '.version // "null"' "$config_file" 2>/dev/null | grep -qv '^null$'; then
        echo "agent"
        return
    fi

    echo "unknown"
}

#===============================================================================
# Test Pattern Matching
#===============================================================================

test_pattern_matching() {
    local config_file="$1"

    log_info "Testing pattern matching logic..."

    # Source the tool-phase-mapping script
    local mapping_script="$KAPSIS_ROOT/scripts/hooks/tool-phase-mapping.sh"
    if [[ ! -f "$mapping_script" ]]; then
        log_error "Tool mapping script not found: $mapping_script"
        return 1
    fi

    # Set config path and source
    export TOOL_MAPPING_CONFIG="$config_file"
    source "$mapping_script"

    # Test cases: tool_name, command, expected_category
    local test_cases=(
        "Read||exploring"
        "Write||implementing"
        "Edit||implementing"
        "Bash|git commit -m test|committing"
        "Bash|npm test|testing"
        "Bash|mvn clean install|building"
        "Bash|ls -la|exploring"
        "TodoWrite||other"
        "mcp__jira__create||other"
    )

    local passed=0
    local failed=0

    for test in "${test_cases[@]}"; do
        IFS='|' read -r tool cmd expected <<< "$test"
        local result
        result=$(map_tool_to_category "$tool" "$cmd")

        if [[ "$result" == "$expected" ]]; then
            log_pass "map_tool_to_category('$tool', '$cmd') = '$result'"
            ((passed++)) || true
        else
            log_error "map_tool_to_category('$tool', '$cmd') = '$result' (expected: '$expected')"
            ((failed++)) || true
        fi
    done

    log_info "Pattern matching tests: $passed passed, $failed failed"

    return 0
}

#===============================================================================
# Main
#===============================================================================

print_summary() {
    echo ""
    echo "========================================"
    echo "Validation Summary"
    echo "========================================"
    if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
        echo -e "${GREEN}All validations passed!${NC}"
    elif [[ $ERRORS -eq 0 ]]; then
        echo -e "${YELLOW}Passed with $WARNINGS warning(s)${NC}"
    else
        echo -e "${RED}Failed with $ERRORS error(s) and $WARNINGS warning(s)${NC}"
    fi
    echo "========================================"
}

usage() {
    echo "Usage: $0 [options] [config-file]"
    echo ""
    echo "Options:"
    echo "  --all           Validate all known config files"
    echo "  --test          Also run pattern matching tests"
    echo "  --help          Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 configs/tool-phase-mapping.yaml"
    echo "  $0 --all --test"
}

main() {
    local validate_all=false
    local run_tests=false
    local config_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                validate_all=true
                shift
                ;;
            --test)
                run_tests=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                config_file="$1"
                shift
                ;;
        esac
    done

    echo "========================================"
    echo "Kapsis Config Verifier"
    echo "========================================"
    echo ""

    # Check dependencies
    check_dependencies || exit 2

    if [[ "$validate_all" == true ]]; then
        # Validate tool-phase-mapping config
        validate_tool_phase_mapping "$KAPSIS_ROOT/configs/tool-phase-mapping.yaml"
        echo ""

        # Validate top-level configs (configs/*.yaml) - auto-detect type
        for config in "$KAPSIS_ROOT"/configs/*.yaml; do
            local basename
            basename=$(basename "$config")
            # Skip tool-phase-mapping (already validated above)
            if [[ "$basename" != "tool-phase-mapping.yaml" && -f "$config" ]]; then
                local config_type
                config_type=$(detect_config_type "$config")
                case "$config_type" in
                    network)
                        validate_network_config "$config"
                        ;;
                    launch)
                        validate_launch_config "$config"
                        ;;
                    *)
                        log_warn "Unknown config type for: $config"
                        ;;
                esac
                echo ""
            fi
        done

        # Validate agent profiles (configs/agents/*.yaml)
        for profile in "$KAPSIS_ROOT"/configs/agents/*.yaml; do
            if [[ -f "$profile" ]]; then
                validate_agent_profile "$profile"
                echo ""
            fi
        done

        if [[ "$run_tests" == true ]]; then
            test_pattern_matching "$KAPSIS_ROOT/configs/tool-phase-mapping.yaml"
        fi
    elif [[ -n "$config_file" ]]; then
        # Validate specific file
        local basename
        basename=$(basename "$config_file")
        local dirname
        dirname=$(dirname "$config_file")

        case "$basename" in
            tool-phase-mapping.yaml)
                validate_tool_phase_mapping "$config_file"
                if [[ "$run_tests" == true ]]; then
                    test_pattern_matching "$config_file"
                fi
                ;;
            *.yaml)
                # Check if it's an agent profile or launch config
                if [[ "$dirname" == *"/agents"* ]]; then
                    validate_agent_profile "$config_file"
                else
                    # Determine by content: launch configs have agent.command
                    if yq -r '.agent.command // "null"' "$config_file" 2>/dev/null | grep -qv '^null$'; then
                        validate_launch_config "$config_file"
                    elif yq -r '.name // "null"' "$config_file" 2>/dev/null | grep -qv '^null$'; then
                        validate_agent_profile "$config_file"
                    else
                        log_warn "Unknown config type, attempting launch config validation"
                        validate_launch_config "$config_file"
                    fi
                fi
                ;;
            *)
                log_error "Unknown config file type: $config_file"
                exit 1
                ;;
        esac
    else
        # Default: validate tool-phase-mapping
        validate_tool_phase_mapping "$KAPSIS_ROOT/configs/tool-phase-mapping.yaml"
        if [[ "$run_tests" == true ]]; then
            test_pattern_matching "$KAPSIS_ROOT/configs/tool-phase-mapping.yaml"
        fi
    fi

    print_summary

    if [[ $ERRORS -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
