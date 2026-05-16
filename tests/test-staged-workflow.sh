#!/usr/bin/env bash
#===============================================================================
# Tests for staged workflow support (Issue #85)
#
# Covers:
#   - stage-handoff.sh security validation
#   - handoff file extension allowlist
#   - handoff directory sanitization
#   - approval gate sentinel mechanics
#   - stage manifest write
#   - staged-launch.sh argument parsing (dry-run, --from-stage)
#   - per-stage config YAML parsing
#
# All tests are quick (no containers, no Podman).
# Run: ./tests/test-staged-workflow.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"
SCRIPTS_DIR="$KAPSIS_ROOT/scripts"

# Source the library under test directly — avoids bash -c quoting pitfalls.
# stage-handoff.sh defines log_* stubs when they are not already declared.
source "$LIB_DIR/stage-handoff.sh"

#-------------------------------------------------------------------------------
# Helper: create a minimal workflow YAML
#-------------------------------------------------------------------------------
_write_minimal_workflow() {
    local target="$1"
    cat > "$target" <<'YAML'
agent:
  command: "bash"
workflow:
  stages:
    - name: research
      task: "Research the topic"
      network: filtered
      no_credentials: true
      handoff:
        include:
          - "RESEARCH.md"
      approval:
        type: none
    - name: implementation
      task: "Implement using ${KAPSIS_HANDOFF_PATH}/RESEARCH.md"
      network: none
      security_profile: standard
      approval:
        type: none
YAML
}

#-------------------------------------------------------------------------------
# Helper: create a minimal per-stage config (no keychain, empty passthrough)
#-------------------------------------------------------------------------------
_write_no_cred_config() {
    local target="$1"
    printf 'environment:\n  keychain: {}\n  passthrough: []\n' > "$target"
}

#===============================================================================
# validate_stage_security
#===============================================================================

test_no_credentials_blocks_open_network() {
    log_test "validate_stage_security: no_credentials=true + network=open is rejected"
    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/cfg.yaml"
    _write_no_cred_config "$cfg"

    local rc=0
    validate_stage_security 'research' 'true' 'open' "$cfg" 2>/dev/null || rc=$?

    rm -rf "$tmpdir"
    assert_not_equals "0" "$rc" "Should fail when no_credentials=true + network=open"
}

test_no_credentials_allows_filtered_network() {
    log_test "validate_stage_security: no_credentials=true + network=filtered is accepted"
    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/cfg.yaml"
    _write_no_cred_config "$cfg"

    local rc=0
    validate_stage_security 'research' 'true' 'filtered' "$cfg" 2>/dev/null || rc=$?

    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "filtered network with no_credentials should succeed"
}

test_no_credentials_allows_none_network() {
    log_test "validate_stage_security: no_credentials=true + network=none is accepted"
    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/cfg.yaml"
    _write_no_cred_config "$cfg"

    local rc=0
    validate_stage_security 'research' 'true' 'none' "$cfg" 2>/dev/null || rc=$?

    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "none network with no_credentials should succeed"
}

test_with_credentials_skips_validation() {
    log_test "validate_stage_security: no_credentials=false skips all checks"
    local rc=0
    validate_stage_security 'impl' 'false' 'open' '/dev/null' 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "Credential-bearing stage ignores network/keychain checks"
}

test_no_credentials_blocks_keychain_entries() {
    log_test "validate_stage_security: no_credentials=true with keychain entries is rejected"
    if ! command -v yq &>/dev/null; then
        log_info "SKIP: yq not installed — keychain check requires yq"
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/cfg.yaml"
    # Write a config with a real keychain entry
    printf 'environment:\n  keychain:\n    MY_TOKEN:\n      service: "foo"\n  passthrough: []\n' > "$cfg"

    local rc=0
    validate_stage_security 'research' 'true' 'filtered' "$cfg" 2>/dev/null || rc=$?

    rm -rf "$tmpdir"
    assert_not_equals "0" "$rc" "Should fail when no_credentials=true but keychain entries exist"
}

#===============================================================================
# is_allowed_handoff_extension
#===============================================================================

test_allowed_handoff_extensions() {
    log_test "is_allowed_handoff_extension: approved file types return 0"
    local rc=0
    is_allowed_handoff_extension 'RESEARCH.md'  || { rc=1; log_error "RESEARCH.md should be allowed"; }
    is_allowed_handoff_extension 'data.json'    || { rc=1; log_error "data.json should be allowed"; }
    is_allowed_handoff_extension 'config.yaml'  || { rc=1; log_error "config.yaml should be allowed"; }
    is_allowed_handoff_extension 'notes.txt'    || { rc=1; log_error "notes.txt should be allowed"; }
    is_allowed_handoff_extension 'output.csv'   || { rc=1; log_error "output.csv should be allowed"; }
    is_allowed_handoff_extension 'changes.diff' || { rc=1; log_error "changes.diff should be allowed"; }
    is_allowed_handoff_extension 'patch.patch'  || { rc=1; log_error "patch.patch should be allowed"; }
    assert_equals "0" "$rc" "All approved extensions should return 0"
}

test_blocked_handoff_extensions() {
    log_test "is_allowed_handoff_extension: executable/script types return non-zero"
    local rc=0
    is_allowed_handoff_extension 'exploit.sh'  && { rc=1; log_error "exploit.sh should be blocked"; }
    is_allowed_handoff_extension 'run.py'      && { rc=1; log_error "run.py should be blocked"; }
    is_allowed_handoff_extension 'hack.rb'     && { rc=1; log_error "hack.rb should be blocked"; }
    is_allowed_handoff_extension 'binary.bin'  && { rc=1; log_error "binary.bin should be blocked"; }
    is_allowed_handoff_extension 'code.js'     && { rc=1; log_error "code.js should be blocked"; }
    is_allowed_handoff_extension 'prog.go'     && { rc=1; log_error "prog.go should be blocked"; }
    assert_equals "0" "$rc" "All disallowed extensions should return non-zero"
}

#===============================================================================
# sanitize_handoff_dir
#===============================================================================

test_sanitize_removes_disallowed_files() {
    log_test "sanitize_handoff_dir: disallowed file types are removed"
    local tmpdir
    tmpdir=$(mktemp -d)

    touch "$tmpdir/RESEARCH.md"
    touch "$tmpdir/summary.json"
    touch "$tmpdir/exploit.sh"
    touch "$tmpdir/payload.py"

    sanitize_handoff_dir "$tmpdir" 2>/dev/null

    local rc=0
    [[ -f "$tmpdir/RESEARCH.md" ]]  || { rc=1; log_error "RESEARCH.md should remain"; }
    [[ -f "$tmpdir/summary.json" ]] || { rc=1; log_error "summary.json should remain"; }
    [[ ! -f "$tmpdir/exploit.sh" ]] || { rc=1; log_error "exploit.sh should be removed"; }
    [[ ! -f "$tmpdir/payload.py" ]] || { rc=1; log_error "payload.py should be removed"; }

    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "sanitize_handoff_dir should remove disallowed file types"
}

test_sanitize_noop_on_empty_dir() {
    log_test "sanitize_handoff_dir: succeeds on empty directory"
    local tmpdir
    tmpdir=$(mktemp -d)

    local rc=0
    sanitize_handoff_dir "$tmpdir" 2>/dev/null || rc=$?

    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "sanitize_handoff_dir should succeed on empty directory"
}

test_sanitize_noop_on_nonexistent_dir() {
    log_test "sanitize_handoff_dir: returns 0 when directory does not exist"
    local rc=0
    sanitize_handoff_dir "/tmp/does-not-exist-kapsis-$$" 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "sanitize_handoff_dir should return 0 for nonexistent directory"
}

#===============================================================================
# write_stage_manifest
#===============================================================================

test_stage_manifest_written() {
    log_test "write_stage_manifest: creates JSON manifest file with expected fields"
    local tmpdir
    tmpdir=$(mktemp -d)

    write_stage_manifest "$tmpdir" 'wf-test-001' 'research' \
        'workflow-wf-test-001-research' '0' "$tmpdir/research-handoff" 2>/dev/null

    local manifest_file="$tmpdir/wf-test-001/research.manifest.json"
    local rc=0
    [[ -f "$manifest_file" ]] || { rc=1; log_error "Manifest file not found at $manifest_file"; }

    if [[ -f "$manifest_file" ]]; then
        grep -q '"workflow_id"'  "$manifest_file" || { rc=1; log_error "Missing workflow_id field"; }
        grep -q '"stage_name"'   "$manifest_file" || { rc=1; log_error "Missing stage_name field"; }
        grep -q '"exit_code"'    "$manifest_file" || { rc=1; log_error "Missing exit_code field"; }
        grep -q '"research"'     "$manifest_file" || { rc=1; log_error "Missing research value"; }
        grep -q '"wf-test-001"'  "$manifest_file" || { rc=1; log_error "Missing workflow_id value"; }
        grep -q '"completed_at"' "$manifest_file" || { rc=1; log_error "Missing completed_at field"; }
    fi

    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Stage manifest should contain all expected fields"
}

test_stage_manifest_exit_code_preserved() {
    log_test "write_stage_manifest: non-zero exit code is written correctly"
    local tmpdir
    tmpdir=$(mktemp -d)

    write_stage_manifest "$tmpdir" 'wf-ec-test' 'research' \
        'workflow-wf-ec-test-research' '1' "$tmpdir/research-handoff" 2>/dev/null

    local manifest_file="$tmpdir/wf-ec-test/research.manifest.json"
    local rc=0
    [[ -f "$manifest_file" ]] || { rc=1; log_error "Manifest file not found"; }
    if [[ -f "$manifest_file" ]]; then
        grep -q '"exit_code": 1' "$manifest_file" || { rc=1; log_error "Exit code 1 not in manifest"; }
    fi

    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Non-zero exit code should be recorded in manifest"
}

#===============================================================================
# wait_for_stage_approval (sentinel mechanics)
#===============================================================================

test_approval_gate_creates_sentinel() {
    log_test "wait_for_stage_approval: sentinel file is created while pending"
    local tmpdir
    tmpdir=$(mktemp -d)
    local sentinel="${tmpdir}/wf-sentinel-test/research${KAPSIS_STAGE_APPROVAL_SENTINEL_EXT}"

    # Run approval gate in background; it will block until sentinel is removed
    wait_for_stage_approval "$tmpdir" 'wf-sentinel-test' 'research' 30 2>/dev/null &
    local gate_pid=$!

    # Give it a moment to create the sentinel
    local waited=0
    while [[ ! -f "$sentinel" && "$waited" -lt 20 ]]; do
        sleep 0.5
        ((waited++)) || true
    done

    local rc=0
    [[ -f "$sentinel" ]] || rc=1

    # Unblock by removing sentinel, then wait for background process
    rm -f "$sentinel"
    wait "$gate_pid" 2>/dev/null || true
    rm -rf "$tmpdir"

    assert_equals "0" "$rc" "Sentinel file should exist while approval is pending"
}

test_approval_gate_returns_zero_on_approval() {
    log_test "wait_for_stage_approval: returns 0 when sentinel is removed"
    local tmpdir
    tmpdir=$(mktemp -d)
    local sentinel="${tmpdir}/wf-ap-test/research${KAPSIS_STAGE_APPROVAL_SENTINEL_EXT}"

    # Concurrently remove the sentinel after a short delay
    ( sleep 1 && rm -f "$sentinel" ) &
    local remover_pid=$!

    local rc=0
    wait_for_stage_approval "$tmpdir" 'wf-ap-test' 'research' 30 2>/dev/null || rc=$?

    wait "$remover_pid" 2>/dev/null || true
    rm -rf "$tmpdir"

    assert_equals "0" "$rc" "Approval gate should return 0 when sentinel is removed"
}

#===============================================================================
# staged-launch.sh argument parsing
#===============================================================================

test_staged_launch_requires_config() {
    log_test "staged-launch.sh: exits non-zero when --config is omitted"
    local rc=0
    bash "$SCRIPTS_DIR/staged-launch.sh" /tmp 2>/dev/null || rc=$?
    assert_not_equals "0" "$rc" "Should exit non-zero without --config"
}

test_staged_launch_rejects_missing_config_file() {
    log_test "staged-launch.sh: exits non-zero when --config file does not exist"
    local rc=0
    bash "$SCRIPTS_DIR/staged-launch.sh" /tmp \
        --config /nonexistent/config.yaml 2>/dev/null || rc=$?
    assert_not_equals "0" "$rc" "Should exit non-zero for missing config file"
}

test_staged_launch_dry_run_lists_stages() {
    log_test "staged-launch.sh --dry-run: logs both stages without running launch-agent.sh"

    if ! command -v yq &>/dev/null; then
        log_info "SKIP: yq not installed"
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/workflow.yaml"
    _write_minimal_workflow "$cfg"

    local out rc=0
    out=$(bash "$SCRIPTS_DIR/staged-launch.sh" /tmp \
        --config "$cfg" \
        --no-approval \
        --dry-run 2>&1) || rc=$?

    rm -rf "$tmpdir"

    echo "$out" | grep -qi "research"        || { rc=1; log_error "Expected 'research' in dry-run output"; }
    echo "$out" | grep -qi "implementation"  || { rc=1; log_error "Expected 'implementation' in dry-run output"; }

    assert_equals "0" "$rc" "Dry-run should succeed and mention both stages"
}

test_staged_launch_from_stage_skips_earlier() {
    log_test "staged-launch.sh --from-stage: earlier stages are logged as skipped"

    if ! command -v yq &>/dev/null; then
        log_info "SKIP: yq not installed"
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/workflow.yaml"
    _write_minimal_workflow "$cfg"

    local out rc=0
    out=$(bash "$SCRIPTS_DIR/staged-launch.sh" /tmp \
        --config "$cfg" \
        --no-approval \
        --dry-run \
        --from-stage implementation 2>&1) || rc=$?

    rm -rf "$tmpdir"

    echo "$out" | grep -qi "skip.*research"  || { rc=1; log_error "Expected 'skip' for research stage"; }
    echo "$out" | grep -qi "implementation"  || { rc=1; log_error "Expected 'implementation' in output"; }

    assert_equals "0" "$rc" "--from-stage should skip earlier stages"
}

#===============================================================================
# YAML structure
#===============================================================================

test_stage_count_parsed_from_yaml() {
    log_test "workflow.stages | length: yq can count stages in minimal config"

    if ! command -v yq &>/dev/null; then
        log_info "SKIP: yq not installed"
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/wf.yaml"
    _write_minimal_workflow "$cfg"

    local count rc=0
    count=$(yq '.workflow.stages | length' "$cfg" 2>/dev/null) || rc=$?
    rm -rf "$tmpdir"

    assert_equals "0" "$rc"  "yq should succeed parsing workflow config"
    assert_equals "2" "$count" "Minimal workflow should have 2 stages"
}

test_stage_names_extracted_from_yaml() {
    log_test "workflow.stages[].name: yq extracts stage names correctly"

    if ! command -v yq &>/dev/null; then
        log_info "SKIP: yq not installed"
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local cfg="$tmpdir/wf.yaml"
    _write_minimal_workflow "$cfg"

    local names rc=0
    names=$(yq -r '.workflow.stages[].name' "$cfg" 2>/dev/null) || rc=$?
    rm -rf "$tmpdir"

    assert_equals "0" "$rc" "yq should succeed"
    echo "$names" | grep -q "^research$"        || { rc=1; log_error "research not in names"; }
    echo "$names" | grep -q "^implementation$"  || { rc=1; log_error "implementation not in names"; }
    assert_equals "0" "$rc" "Both stage names should be extractable from YAML"
}

#===============================================================================
# Run all tests
#===============================================================================

main() {
    log_info "=== validate_stage_security ==="
    run_test test_no_credentials_blocks_open_network
    run_test test_no_credentials_allows_filtered_network
    run_test test_no_credentials_allows_none_network
    run_test test_with_credentials_skips_validation
    run_test test_no_credentials_blocks_keychain_entries

    log_info "=== is_allowed_handoff_extension ==="
    run_test test_allowed_handoff_extensions
    run_test test_blocked_handoff_extensions

    log_info "=== sanitize_handoff_dir ==="
    run_test test_sanitize_removes_disallowed_files
    run_test test_sanitize_noop_on_empty_dir
    run_test test_sanitize_noop_on_nonexistent_dir

    log_info "=== write_stage_manifest ==="
    run_test test_stage_manifest_written
    run_test test_stage_manifest_exit_code_preserved

    log_info "=== wait_for_stage_approval ==="
    run_test test_approval_gate_creates_sentinel
    run_test test_approval_gate_returns_zero_on_approval

    log_info "=== staged-launch.sh CLI ==="
    run_test test_staged_launch_requires_config
    run_test test_staged_launch_rejects_missing_config_file
    run_test test_staged_launch_dry_run_lists_stages
    run_test test_staged_launch_from_stage_skips_earlier

    log_info "=== YAML structure ==="
    run_test test_stage_count_parsed_from_yaml
    run_test test_stage_names_extracted_from_yaml

    print_summary
}

main "$@"
