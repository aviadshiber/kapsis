#!/usr/bin/env bash
#===============================================================================
# Test: Config Verifier (config-verifier.sh)
#
# Covers the 8 public functions of scripts/lib/config-verifier.sh at the
# subprocess level (the script re-defines log_info/log_pass/log_error/log_warn
# and uses a module-global ERRORS counter, so we invoke it as `bash -c` rather
# than sourcing it).
#
# Functions exercised:
#   - validate_tool_phase_mapping (valid + each invalid-field case)
#   - validate_agent_profile
#   - validate_launch_config     (including nested lsp_servers + liveness)
#   - validate_network_config
#   - detect_config_type         (network / launch / agent / unknown)
#   - test_pattern_matching      (--test flag)
#   - check_dependencies         (missing yq → exit 2)
#   - print_summary              (via end-to-end exit code + summary text)
#
# Category: validation
# Container required: No (pure YAML fixtures + yq in PATH)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

VERIFIER="$KAPSIS_ROOT/scripts/lib/config-verifier.sh"

# Temp workspace for fixtures
FIXTURE_DIR=""

setup_fixture_dir() {
    FIXTURE_DIR=$(mktemp -d -t kapsis-config-verifier-XXXXXX)
}

teardown_fixture_dir() {
    [[ -n "$FIXTURE_DIR" && -d "$FIXTURE_DIR" ]] && rm -rf "$FIXTURE_DIR"
    FIXTURE_DIR=""
}

# run_verifier <args...>
# Runs the verifier as a subprocess; sets CAPTURED_STDOUT/STDERR/EXIT_CODE.
run_verifier() {
    capture_output "bash $VERIFIER $*"
}

# run_network_validator <fixture>
# The verifier's CLI has no direct route for network configs; main() routes
# them via detect_config_type() only in --all mode. For targeted tests we
# source the script and call validate_network_config() + print_summary()
# directly, then exit with ERRORS > 0 ? 1 : 0 to mirror main()'s exit code.
run_network_validator() {
    local fixture="$1"
    capture_output "bash -c 'source \"$VERIFIER\" 2>/dev/null; validate_network_config \"$fixture\"; print_summary; [[ \$ERRORS -eq 0 ]] && exit 0 || exit 1'"
}

#===============================================================================
# detect_config_type TESTS
#
# detect_config_type() doesn't have a CLI flag, so we source the verifier in
# a subshell where its module-level `set -euo pipefail` can't kill the test
# harness.
#===============================================================================

invoke_detect_type() {
    local fixture="$1"
    bash -c "source '$VERIFIER' 2>/dev/null; detect_config_type '$fixture'"
}

test_detect_type_network() {
    log_test "detect_config_type: classifies network allowlist YAML"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    cat > "$FIXTURE_DIR/net.yaml" <<EOF
network:
  mode: filtered
  allowlist:
    hosts: []
EOF

    local kind
    kind=$(invoke_detect_type "$FIXTURE_DIR/net.yaml")
    assert_equals "network" "$kind" "YAML with network.mode must classify as 'network'"
}

test_detect_type_launch() {
    log_test "detect_config_type: classifies launch config YAML"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    cat > "$FIXTURE_DIR/launch.yaml" <<EOF
agent:
  command: claude
EOF

    local kind
    kind=$(invoke_detect_type "$FIXTURE_DIR/launch.yaml")
    assert_equals "launch" "$kind" "YAML with agent.command must classify as 'launch'"
}

test_detect_type_agent_profile() {
    log_test "detect_config_type: classifies agent profile YAML"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    cat > "$FIXTURE_DIR/agent.yaml" <<EOF
name: claude-cli
version: "1.0"
EOF

    local kind
    kind=$(invoke_detect_type "$FIXTURE_DIR/agent.yaml")
    assert_equals "agent" "$kind" "YAML with top-level name+version must classify as 'agent'"
}

test_detect_type_unknown() {
    log_test "detect_config_type: returns 'unknown' for unclassifiable YAML"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    cat > "$FIXTURE_DIR/other.yaml" <<EOF
key: value
description: random
EOF

    local kind
    kind=$(invoke_detect_type "$FIXTURE_DIR/other.yaml")
    assert_equals "unknown" "$kind" "YAML without recognized markers must be 'unknown'"
}

#===============================================================================
# validate_tool_phase_mapping TESTS
#===============================================================================

# Minimal well-formed tool-phase-mapping.yaml fixture
_write_valid_tpm() {
    local path="$1"
    cat > "$path" <<'EOF'
version: "1.0"
default_category: other
phase_ranges:
  exploring: [0, 30]
  implementing: [30, 60]
  building: [60, 70]
  testing: [70, 85]
  committing: [85, 100]
  other: [0, 100]
patterns:
  testing:
    - Bash(npm test)
    - Bash(mvn test)
  committing:
    - Bash(git commit*)
  exploring:
    - Read
    - Grep
  implementing:
    - Write
    - Edit
  building:
    - Bash(mvn clean install)
  other:
    - TodoWrite
EOF
}

test_tpm_valid_passes() {
    log_test "validate_tool_phase_mapping: well-formed YAML exits 0"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/tool-phase-mapping.yaml"
    _write_valid_tpm "$fixture"

    run_verifier "$fixture"
    assert_equals 0 "$CAPTURED_EXIT_CODE" "Valid TPM must exit 0"
    assert_contains "$CAPTURED_STDOUT" "Has required field: version" \
        "Must report required fields present"
    # Exit 0 means no errors; the wording of the success line differs when
    # yamllint is absent ("Passed with N warning(s)") vs present
    # ("All validations passed") — both are accepted.
    assert_not_contains "$CAPTURED_STDOUT" "[FAIL]" \
        "Valid TPM must not contain any FAIL lines"
}

test_tpm_missing_required_fails() {
    log_test "validate_tool_phase_mapping: missing required field exits 1"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/tool-phase-mapping.yaml"
    # Drop the 'patterns' block — a required top-level field
    cat > "$fixture" <<'EOF'
version: "1.0"
default_category: other
phase_ranges:
  exploring: [0, 30]
EOF

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Missing required field must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Missing required field: patterns" \
        "Must name the missing field explicitly"
}

test_tpm_bad_version_format_fails() {
    log_test "validate_tool_phase_mapping: malformed version exits 1"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/tool-phase-mapping.yaml"
    _write_valid_tpm "$fixture"
    # Break just the version
    sed -i 's/version: "1.0"/version: "v1"/' "$fixture"

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Invalid version format must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Invalid version format" \
        "Must explain version format failure"
}

test_tpm_bad_phase_range_fails() {
    log_test "validate_tool_phase_mapping: min > max in a phase range exits 1"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/tool-phase-mapping.yaml"
    _write_valid_tpm "$fixture"
    # min > max
    sed -i 's/exploring: \[0, 30\]/exploring: [50, 10]/' "$fixture"

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Invalid phase range must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Invalid range values for exploring" \
        "Must pinpoint the broken phase range"
}

test_tpm_bad_default_category_fails() {
    log_test "validate_tool_phase_mapping: invalid default_category exits 1"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/tool-phase-mapping.yaml"
    _write_valid_tpm "$fixture"
    sed -i 's/default_category: other/default_category: nonsense/' "$fixture"

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Unknown default_category must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Invalid default_category: nonsense" \
        "Must name the invalid category"
}

#===============================================================================
# validate_launch_config TESTS
#===============================================================================

test_launch_valid_passes() {
    log_test "validate_launch_config: minimal valid launch config exits 0"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/launch.yaml"
    cat > "$fixture" <<'EOF'
agent:
  command: claude
resources:
  memory: 4g
  cpus: 2
EOF

    run_verifier "$fixture"
    assert_equals 0 "$CAPTURED_EXIT_CODE" "Minimal launch config must exit 0"
    assert_contains "$CAPTURED_STDOUT" "Has agent.command" \
        "Must confirm required agent.command present"
    assert_contains "$CAPTURED_STDOUT" "Valid memory format: 4g" \
        "Must confirm memory format parsed"
}

test_launch_missing_agent_command_fails() {
    log_test "validate_launch_config: missing agent.command exits 1"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/launch.yaml"
    cat > "$fixture" <<'EOF'
resources:
  memory: 2g
EOF

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Missing agent.command must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Missing required field: agent.command" \
        "Must explicitly name agent.command as missing"
}

test_launch_bad_auto_push_fails() {
    log_test "validate_launch_config: git.auto_push.enabled must be true/false"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/launch.yaml"
    cat > "$fixture" <<'EOF'
agent:
  command: claude
git:
  auto_push:
    enabled: "yes"
EOF

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Non-bool auto_push must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Invalid git.auto_push.enabled" \
        "Must flag invalid boolean"
}

test_launch_lsp_missing_command_fails() {
    log_test "validate_launch_config: lsp_servers.<name>.command is required"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/launch.yaml"
    cat > "$fixture" <<'EOF'
agent:
  command: claude
lsp_servers:
  pyright:
    languages:
      python: [".py"]
EOF

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Missing lsp command must exit 1"
    assert_contains "$CAPTURED_STDOUT" "lsp_servers.pyright: missing required field 'command'" \
        "Must name the server whose command is missing"
}

test_launch_liveness_timeout_below_minimum_fails() {
    log_test "validate_launch_config: liveness.timeout < 60 is rejected"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/launch.yaml"
    cat > "$fixture" <<'EOF'
agent:
  command: claude
liveness:
  enabled: true
  timeout: 30
  check_interval: 10
EOF

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "timeout=30 must be rejected"
    assert_contains "$CAPTURED_STDOUT" "Invalid liveness.timeout: 30" \
        "Must flag the below-minimum timeout"
}

#===============================================================================
# validate_network_config TESTS
#===============================================================================

test_network_valid_filtered_passes() {
    log_test "validate_network_config: filtered mode with allowlist exits 0"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/net.yaml"
    cat > "$fixture" <<'EOF'
network:
  mode: filtered
  allowlist:
    hosts:
      - github.com
      - gitlab.com
    registries:
      - registry.npmjs.org
  dns_servers:
    - 1.1.1.1
  dns_pinning:
    enabled: true
    fallback: dynamic
    resolve_timeout: 10
EOF

    run_network_validator "$fixture"
    assert_equals 0 "$CAPTURED_EXIT_CODE" "Valid filtered net config must exit 0"
    assert_contains "$CAPTURED_STDOUT" "Valid network.mode: filtered" ""
    assert_contains "$CAPTURED_STDOUT" "Valid dns_pinning.enabled: true" ""
}

test_network_bad_mode_fails() {
    log_test "validate_network_config: unknown network.mode is rejected"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/net.yaml"
    cat > "$fixture" <<'EOF'
network:
  mode: partially-open
EOF

    run_network_validator "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Unknown mode must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Invalid network.mode: partially-open" \
        "Must name the invalid mode"
}

test_network_bad_dns_fallback_fails() {
    log_test "validate_network_config: dns_pinning.fallback must be dynamic/abort"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/net.yaml"
    cat > "$fixture" <<'EOF'
network:
  mode: filtered
  dns_pinning:
    enabled: true
    fallback: whatever
EOF

    run_network_validator "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Unknown dns_pinning.fallback must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Invalid dns_pinning.fallback: whatever" ""
}

test_network_bad_dns_timeout_fails() {
    log_test "validate_network_config: dns_pinning.resolve_timeout out of range"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/net.yaml"
    cat > "$fixture" <<'EOF'
network:
  mode: filtered
  dns_pinning:
    resolve_timeout: 9999
EOF

    run_network_validator "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Out-of-range timeout must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Invalid dns_pinning.resolve_timeout: 9999" \
        "Must name the invalid timeout value"
}

#===============================================================================
# validate_agent_profile TESTS
#===============================================================================

test_agent_profile_valid_passes() {
    log_test "validate_agent_profile: minimal valid profile exits 0"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local profile_dir="$FIXTURE_DIR/agents"
    mkdir -p "$profile_dir"
    local fixture="$profile_dir/claude-cli.yaml"
    cat > "$fixture" <<'EOF'
name: claude-cli
version: "1.0"
description: Test profile
EOF

    run_verifier "$fixture"
    assert_equals 0 "$CAPTURED_EXIT_CODE" "Valid agent profile must exit 0"
    assert_contains "$CAPTURED_STDOUT" "Has required field: name" \
        "Must confirm required fields"
    assert_contains "$CAPTURED_STDOUT" "Has required field: version" ""
}

test_agent_profile_missing_name_fails() {
    log_test "validate_agent_profile: missing name exits 1"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local profile_dir="$FIXTURE_DIR/agents"
    mkdir -p "$profile_dir"
    local fixture="$profile_dir/bad.yaml"
    cat > "$fixture" <<'EOF'
version: "1.0"
EOF

    run_verifier "$fixture"
    assert_equals 1 "$CAPTURED_EXIT_CODE" "Missing name must exit 1"
    assert_contains "$CAPTURED_STDOUT" "Missing required field: name" \
        "Must explicitly name missing required field"
}

#===============================================================================
# check_dependencies TESTS
#===============================================================================

test_check_dependencies_missing_yq_exits_2() {
    log_test "check_dependencies: missing yq returns exit 2"

    # Build an isolated PATH that contains ONLY a fresh temp directory (no yq,
    # no yamllint). The verifier uses bash builtins (echo, printf, local, etc.)
    # which don't require PATH, but it also needs `uname` — we shim that in by
    # symlinking the host's uname into our isolated directory.
    local iso
    iso=$(mktemp -d -t kapsis-yq-missing-XXXXXX)
    trap "rm -rf '$iso'" RETURN

    # Symlink the bare-minimum external commands the verifier uses during its
    # bootstrap: dirname (for SCRIPT_DIR), bash (for re-exec), uname. We do NOT
    # link yq or yamllint — their absence is what we're testing.
    local helper
    for helper in dirname uname bash; do
        local src
        src=$(command -v "$helper") || continue
        [[ -x "$src" ]] && ln -s "$src" "$iso/$helper"
    done

    # Explicitly do NOT place yq (or yamllint) in $iso. With PATH set to just
    # $iso, `command -v yq` will fail → check_dependencies returns 2 → main
    # exits 2.
    capture_output "PATH='$iso' bash '$VERIFIER'"
    assert_equals 2 "$CAPTURED_EXIT_CODE" "Missing yq must exit with code 2"
    assert_contains "$CAPTURED_STDOUT" "Missing required dependencies" \
        "Must report missing deps"
}

#===============================================================================
# test_pattern_matching (--test flag)
#===============================================================================

test_pattern_matching_runs() {
    log_test "test_pattern_matching (--test): runs pattern assertions against tool-phase-mapping.yaml"
    setup_fixture_dir
    trap teardown_fixture_dir RETURN

    local fixture="$FIXTURE_DIR/tool-phase-mapping.yaml"
    _write_valid_tpm "$fixture"

    run_verifier "--test '$fixture'"
    # We don't enforce 0 exit — pattern tests can produce log_error if the
    # embedded test cases don't match the fixture exactly. We DO enforce that
    # the pattern-testing header is printed.
    assert_contains "$CAPTURED_STDOUT" "Testing pattern matching logic" \
        "--test flag must execute test_pattern_matching"
    assert_contains "$CAPTURED_STDOUT" "Pattern matching tests:" \
        "Must print the pattern matching summary line"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Config Verifier (scripts/lib/config-verifier.sh)"

    # detect_config_type
    run_test test_detect_type_network
    run_test test_detect_type_launch
    run_test test_detect_type_agent_profile
    run_test test_detect_type_unknown

    # validate_tool_phase_mapping
    run_test test_tpm_valid_passes
    run_test test_tpm_missing_required_fails
    run_test test_tpm_bad_version_format_fails
    run_test test_tpm_bad_phase_range_fails
    run_test test_tpm_bad_default_category_fails

    # validate_launch_config
    run_test test_launch_valid_passes
    run_test test_launch_missing_agent_command_fails
    run_test test_launch_bad_auto_push_fails
    run_test test_launch_lsp_missing_command_fails
    run_test test_launch_liveness_timeout_below_minimum_fails

    # validate_network_config
    run_test test_network_valid_filtered_passes
    run_test test_network_bad_mode_fails
    run_test test_network_bad_dns_fallback_fails
    run_test test_network_bad_dns_timeout_fails

    # validate_agent_profile
    run_test test_agent_profile_valid_passes
    run_test test_agent_profile_missing_name_fails

    # check_dependencies
    run_test test_check_dependencies_missing_yq_exits_2

    # test_pattern_matching
    run_test test_pattern_matching_runs

    print_summary
}

main "$@"
