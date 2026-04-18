#!/usr/bin/env bash
#===============================================================================
# Test: Credential File Template Injection (Issue #241)
#
# Verifies that inject_file_template correctly substitutes {{VALUE}} placeholders
# and writes formatted credential files with proper permissions.
#
# Category: security
# Container required: No (sourced-function tests only)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

ENTRYPOINT_SCRIPT="$KAPSIS_ROOT/scripts/entrypoint.sh"

#===============================================================================
# HELPER: Source inject_credential_files() from entrypoint.sh
#
# The entrypoint sources logging.sh and defines inject_credential_files().
# We source the function in isolation by extracting it.
#===============================================================================

# Create a minimal environment to source entrypoint functions
_setup_entrypoint_env() {
    # Source logging (required by inject_credential_files)
    source "$KAPSIS_ROOT/scripts/lib/logging.sh"
    init_logging "test-credential-template" 2>/dev/null || true

    # Source only the inject_credential_files function from entrypoint
    eval "$(sed -n '/^inject_credential_files()/,/^}/p' "$ENTRYPOINT_SCRIPT")"
}

#===============================================================================
# TEMPLATE SUBSTITUTION TESTS
#===============================================================================

test_template_basic_substitution() {
    log_test "Testing basic {{VALUE}} substitution in template"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-test-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/hosts.yml"

    # Create template: gh CLI hosts.yml format
    local template
    template=$(printf 'github.com:\n  oauth_token: {{VALUE}}\n  user: testuser\n  git_protocol: https\n')
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    # Set up env vars as entrypoint would see them
    export TEST_GH_TOKEN="ghp_abc123secrettoken"
    export KAPSIS_TMPL_TEST_GH_TOKEN="$template_b64"
    export KAPSIS_CREDENTIAL_FILES="TEST_GH_TOKEN|${output_file}|0600"

    # Run injection
    inject_credential_files

    # Verify file content
    local content
    content=$(cat "$output_file")
    assert_contains "$content" "oauth_token: ghp_abc123secrettoken" \
        "Template should substitute {{VALUE}} with secret"
    assert_contains "$content" "git_protocol: https" \
        "Template should preserve non-placeholder content"
    assert_not_contains "$content" "{{VALUE}}" \
        "No {{VALUE}} placeholder should remain"

    # Verify permissions
    local perms
    perms=$(stat -f '%Lp' "$output_file" 2>/dev/null || stat -c '%a' "$output_file" 2>/dev/null)
    assert_equals "600" "$perms" "File permissions should be 0600"

    # Cleanup
    rm -rf "$output_dir"
    unset TEST_GH_TOKEN KAPSIS_TMPL_TEST_GH_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

test_template_shell_metacharacters_in_secret() {
    log_test "Testing secret with shell metacharacters is written literally"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-meta-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/config.yml"

    local template
    template=$(printf 'token: {{VALUE}}\n')
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    # Secret contains shell metacharacters that must NOT be interpreted
    export META_TOKEN='$() `rm -rf /` ; echo pwned & | > /dev/null'
    export KAPSIS_TMPL_META_TOKEN="$template_b64"
    export KAPSIS_CREDENTIAL_FILES="META_TOKEN|${output_file}|0600"

    inject_credential_files

    local content
    content=$(cat "$output_file")
    # The shell metacharacters must appear literally in the file
    assert_contains "$content" '$() `rm -rf /`' \
        "Shell metacharacters should be written literally"
    assert_contains "$content" "; echo pwned" \
        "Semicolons should be written literally"

    rm -rf "$output_dir"
    unset META_TOKEN KAPSIS_TMPL_META_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

test_template_sed_metacharacters_in_secret() {
    log_test "Testing secret with sed metacharacters (& and \\1) is written literally"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-sed-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/config.yml"

    local template
    template=$(printf 'token: {{VALUE}}\n')
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    # Secret contains sed replacement metacharacters
    export SED_TOKEN='value&with\1backref'
    export KAPSIS_TMPL_SED_TOKEN="$template_b64"
    export KAPSIS_CREDENTIAL_FILES="SED_TOKEN|${output_file}|0600"

    inject_credential_files

    local content
    content=$(cat "$output_file")
    assert_contains "$content" 'value&with\1backref' \
        "Sed metacharacters should be written literally (bash parameter expansion, not sed)"

    rm -rf "$output_dir"
    unset SED_TOKEN KAPSIS_TMPL_SED_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

test_template_multiline() {
    log_test "Testing multi-line template preserves structure"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-multiline-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/kubeconfig.yml"

    local template
    template=$(cat <<'TMPL'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://k8s.example.com
  name: prod
users:
- name: deploy
  user:
    token: {{VALUE}}
TMPL
)
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    export K8S_TOKEN="eyJhbGciOiJSUzI1NiJ9.fake-jwt-token"
    export KAPSIS_TMPL_K8S_TOKEN="$template_b64"
    export KAPSIS_CREDENTIAL_FILES="K8S_TOKEN|${output_file}|0600"

    inject_credential_files

    local content
    content=$(cat "$output_file")
    assert_contains "$content" "apiVersion: v1" "Multi-line template should preserve first line"
    assert_contains "$content" "token: eyJhbGciOiJSUzI1NiJ9.fake-jwt-token" \
        "Multi-line template should substitute {{VALUE}}"
    assert_contains "$content" "server: https://k8s.example.com" \
        "Multi-line template should preserve non-placeholder lines"

    rm -rf "$output_dir"
    unset K8S_TOKEN KAPSIS_TMPL_K8S_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

test_raw_value_without_template() {
    log_test "Testing raw value write when no template is specified"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-raw-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/raw-token"

    export RAW_TOKEN="plain-secret-value"
    export KAPSIS_CREDENTIAL_FILES="RAW_TOKEN|${output_file}|0600"
    # No KAPSIS_TMPL_RAW_TOKEN set — should fall through to raw write

    inject_credential_files

    local content
    content=$(cat "$output_file")
    # Raw write uses printf '%s\n' so there should be a trailing newline
    assert_equals "plain-secret-value" "$content" \
        "Raw value should be written as-is when no template"

    rm -rf "$output_dir"
    unset RAW_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

test_template_env_vars_unset_after_injection() {
    log_test "Testing KAPSIS_CREDENTIAL_FILES and KAPSIS_TMPL_* are unset after injection"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-unset-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/token"

    local template
    template=$(printf 'token: {{VALUE}}\n')
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    export UNSET_TOKEN="secret123"
    export KAPSIS_TMPL_UNSET_TOKEN="$template_b64"
    export KAPSIS_CREDENTIAL_FILES="UNSET_TOKEN|${output_file}|0600"

    inject_credential_files

    # KAPSIS_CREDENTIAL_FILES should be unset
    assert_equals "" "${KAPSIS_CREDENTIAL_FILES:-}" \
        "KAPSIS_CREDENTIAL_FILES should be unset after injection"
    # KAPSIS_TMPL_* should be unset
    assert_equals "" "${KAPSIS_TMPL_UNSET_TOKEN:-}" \
        "KAPSIS_TMPL_UNSET_TOKEN should be unset after injection"
    # Secret env var itself should be unset (prevents leak to agent process)
    assert_equals "" "${UNSET_TOKEN:-}" \
        "Secret env var UNSET_TOKEN should be unset after injection"

    rm -rf "$output_dir"
}

test_template_multiple_value_markers() {
    log_test "Testing template with multiple {{VALUE}} markers substitutes all"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-multi-marker-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/config.json"

    local template
    template=$(printf '{"primary": "{{VALUE}}", "backup": "{{VALUE}}"}\n')
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    export MULTI_TOKEN="tok_abc"
    export KAPSIS_TMPL_MULTI_TOKEN="$template_b64"
    export KAPSIS_CREDENTIAL_FILES="MULTI_TOKEN|${output_file}|0600"

    inject_credential_files

    local content
    content=$(cat "$output_file")
    # Both occurrences should be replaced
    local count
    count=$(grep -o 'tok_abc' <<< "$content" | wc -l)
    assert_equals "2" "$(echo "$count" | tr -d ' ')" \
        "Both {{VALUE}} markers should be substituted"

    rm -rf "$output_dir"
    unset MULTI_TOKEN KAPSIS_TMPL_MULTI_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

test_template_bad_base64_skipped() {
    log_test "Testing invalid base64 template is skipped with error"

    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-badb64-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/token"

    export BAD_TOKEN="secret"
    export KAPSIS_TMPL_BAD_TOKEN="not-valid-base64!!!"
    export KAPSIS_CREDENTIAL_FILES="BAD_TOKEN|${output_file}|0600"

    # Should not crash — bad decode is skipped
    inject_credential_files 2>/dev/null || true

    # File should NOT be created (decode failed → skipped)
    assert_file_not_exists "$output_file" "Bad base64 should not produce a file"

    rm -rf "$output_dir"
    unset BAD_TOKEN KAPSIS_TMPL_BAD_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

test_template_without_value_marker_writes_verbatim() {
    log_test "Testing template without {{VALUE}} writes template verbatim (entrypoint bypass)"

    # When launch-agent.sh is bypassed (e.g., direct container invocation),
    # a template without {{VALUE}} should write the template content as-is.
    # The split-and-rejoin loop never iterates, so content = remaining = template.
    _setup_entrypoint_env

    local output_dir="$TEST_PROJECT/.kapsis-tmpl-nomarker-$$"
    mkdir -p "$output_dir"
    local output_file="$output_dir/config.yml"

    local template
    template=$(printf 'static_key: some-fixed-value\n')
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    export NOMARKER_TOKEN="secret-unused"
    export KAPSIS_TMPL_NOMARKER_TOKEN="$template_b64"
    export KAPSIS_CREDENTIAL_FILES="NOMARKER_TOKEN|${output_file}|0600"

    inject_credential_files

    local content
    content=$(cat "$output_file")
    assert_contains "$content" "static_key: some-fixed-value" \
        "Template without {{VALUE}} should write template content verbatim"
    assert_not_contains "$content" "secret-unused" \
        "Secret should not appear when template has no {{VALUE}} marker"

    rm -rf "$output_dir"
    unset NOMARKER_TOKEN KAPSIS_TMPL_NOMARKER_TOKEN KAPSIS_CREDENTIAL_FILES 2>/dev/null || true
}

#===============================================================================
# LAUNCH-AGENT VALIDATION TESTS (config parsing, no container)
#===============================================================================

test_template_validation_in_launch_script() {
    log_test "Testing inject_file_template validation logic exists in launch-agent.sh"

    # Structural guards — ensures the code paths are not accidentally deleted.
    # Uses grep -q directly on file to avoid loading entire script into shell arg.
    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"

    assert_true "grep -q 'KAPSIS_TMPL_' '$launch_script'" \
        "launch-agent.sh should reference KAPSIS_TMPL_ env vars"
    assert_true "grep -q 'inject_file_template' '$launch_script'" \
        "launch-agent.sh should reference inject_file_template"
    assert_true "grep -q 'missing required {{VALUE}}' '$launch_script'" \
        "launch-agent.sh should validate {{VALUE}} marker"
    assert_true "grep -q 'exceeds 64 KB limit' '$launch_script'" \
        "launch-agent.sh should enforce size limit"
    assert_true "grep -q 'contains NUL bytes' '$launch_script'" \
        "launch-agent.sh should reject NUL bytes"
    assert_true "grep -q 'markers (max 5)' '$launch_script'" \
        "launch-agent.sh should cap marker count"
}

test_nul_check_no_false_positive() {
    log_test "Testing NUL byte check does not false-positive on valid template (Bug #251)"

    # The old check [[ "$var" == *$'\0'* ]] always matches because bash
    # variables cannot hold NUL bytes — $'\0' in a pattern is empty string,
    # making *$'\0'* equivalent to * (matches everything).
    # The new check compares raw byte counts via pipe.

    # Valid template — should pass NUL check
    local template='{"token": "{{VALUE}}"}'
    local template_b64
    template_b64=$(printf '%s' "$template" | base64)

    local raw_byte_count clean_byte_count
    raw_byte_count=$(printf '%s' "$template_b64" | base64 -d 2>/dev/null | wc -c)
    clean_byte_count=$(printf '%s' "$template_b64" | base64 -d 2>/dev/null | tr -d '\0' | wc -c)

    assert_equals "$raw_byte_count" "$clean_byte_count" \
        "Valid template should have equal raw and clean byte counts"
}

test_nul_check_detects_actual_nul() {
    log_test "Testing NUL byte check detects actual NUL bytes in template"

    # Create a template WITH an embedded NUL byte, base64-encode it
    local template_b64
    template_b64=$(printf 'hello\0world' | base64)

    local raw_byte_count clean_byte_count
    raw_byte_count=$(printf '%s' "$template_b64" | base64 -d 2>/dev/null | wc -c)
    clean_byte_count=$(printf '%s' "$template_b64" | base64 -d 2>/dev/null | tr -d '\0' | wc -c)

    assert_true "(( raw_byte_count != clean_byte_count ))" \
        "Template with NUL should have different raw vs clean byte counts"
}

test_entrypoint_has_security_invariant() {
    log_test "Testing entrypoint.sh has SECURITY INVARIANT comment"

    local entrypoint="$KAPSIS_ROOT/scripts/entrypoint.sh"

    assert_true "grep -q 'SECURITY INVARIANT' '$entrypoint'" \
        "entrypoint.sh should have SECURITY INVARIANT comment"
    assert_true "grep -q 'NEVER use sed, envsubst, eval' '$entrypoint'" \
        "SECURITY INVARIANT should prohibit sed/envsubst/eval"
}

test_entrypoint_unsets_credential_files() {
    log_test "Testing entrypoint.sh unsets KAPSIS_CREDENTIAL_FILES after injection"

    local entrypoint="$KAPSIS_ROOT/scripts/entrypoint.sh"

    assert_true "grep -q 'unset KAPSIS_CREDENTIAL_FILES' '$entrypoint'" \
        "entrypoint.sh should unset KAPSIS_CREDENTIAL_FILES"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Credential File Template Injection"
    setup_test_project

    # Template substitution tests (sourced function, no container)
    run_test test_template_basic_substitution
    run_test test_template_shell_metacharacters_in_secret
    run_test test_template_sed_metacharacters_in_secret
    run_test test_template_multiline
    run_test test_raw_value_without_template
    run_test test_template_env_vars_unset_after_injection
    run_test test_template_multiple_value_markers
    run_test test_template_bad_base64_skipped
    run_test test_template_without_value_marker_writes_verbatim

    # Launch-agent validation tests (file content checks)
    run_test test_template_validation_in_launch_script
    run_test test_nul_check_no_false_positive
    run_test test_nul_check_detects_actual_nul
    run_test test_entrypoint_has_security_invariant
    run_test test_entrypoint_unsets_credential_files

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
