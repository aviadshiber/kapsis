#!/usr/bin/env bash
#===============================================================================
# Test: SSH Config Cross-Platform Portability (Issue #172)
#
# Unit tests for scripts/lib/ssh-config-compat.sh
#
# Tests verify:
#   - Prepends IgnoreUnknown when UseKeychain is present
#   - Prepends IgnoreUnknown when AddKeysToAgent is present
#   - Idempotent: running twice doesn't duplicate the line
#   - Skips config that already has IgnoreUnknown for these directives
#   - Returns 0 when config file doesn't exist
#   - Preserves all original config content
#   - Maintains correct file permissions (600)
#
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source logging (provides log_info, log_debug, etc. + sources compat.sh)
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-ssh-config-portability"

# Override is_linux for testing — tests run on macOS host but the function
# targets Linux containers, so we simulate Linux for testability.
is_linux() { return 0; }

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/ssh-config-compat.sh"

# Test directory for file operations
TEST_TEMP_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_tests() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-ssh-compat-test.XXXXXX")
    log_info "Test temp directory: $TEST_TEMP_DIR"
}

cleanup_tests() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

#===============================================================================
# TEST CASES
#===============================================================================

test_patches_config_with_usekeychain() {
    log_test "patch_ssh_config_portability: prepends IgnoreUnknown when UseKeychain present"

    local ssh_config="$TEST_TEMP_DIR/config_usekeychain"
    cat > "$ssh_config" <<'EOF'
Host *
    UseKeychain yes
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519
EOF
    chmod 600 "$ssh_config"

    patch_ssh_config_portability "$ssh_config"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 on success"
    assert_file_contains "$ssh_config" "IgnoreUnknown UseKeychain,AddKeysToAgent" \
        "Should contain IgnoreUnknown directive"

    # Verify IgnoreUnknown is at the top (first non-comment line)
    local first_directive
    first_directive=$(grep -v '^#' "$ssh_config" | grep -v '^$' | head -1)
    assert_equals "IgnoreUnknown UseKeychain,AddKeysToAgent" "$first_directive" \
        "IgnoreUnknown should be the first directive"
}

test_patches_config_with_addkeystoagent() {
    log_test "patch_ssh_config_portability: prepends IgnoreUnknown when AddKeysToAgent present"

    local ssh_config="$TEST_TEMP_DIR/config_addkeys"
    cat > "$ssh_config" <<'EOF'
Host *
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_rsa
EOF
    chmod 600 "$ssh_config"

    patch_ssh_config_portability "$ssh_config"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 on success"
    assert_file_contains "$ssh_config" "IgnoreUnknown UseKeychain,AddKeysToAgent" \
        "Should contain IgnoreUnknown directive"
}

test_idempotent_no_duplicate() {
    log_test "patch_ssh_config_portability: idempotent — running twice doesn't duplicate"

    local ssh_config="$TEST_TEMP_DIR/config_idempotent"
    cat > "$ssh_config" <<'EOF'
Host *
    UseKeychain yes
    IdentityFile ~/.ssh/id_ed25519
EOF
    chmod 600 "$ssh_config"

    # Run twice
    patch_ssh_config_portability "$ssh_config"
    patch_ssh_config_portability "$ssh_config"

    # Count occurrences of IgnoreUnknown
    local count
    count=$(grep -c "^IgnoreUnknown" "$ssh_config")
    assert_equals "1" "$count" "Should have exactly one IgnoreUnknown line after two runs"
}

test_skips_already_patched() {
    log_test "patch_ssh_config_portability: skips config that already has IgnoreUnknown"

    local ssh_config="$TEST_TEMP_DIR/config_already_patched"
    cat > "$ssh_config" <<'EOF'
IgnoreUnknown UseKeychain,AddKeysToAgent
Host *
    UseKeychain yes
    IdentityFile ~/.ssh/id_ed25519
EOF
    chmod 600 "$ssh_config"

    # Get file content before
    local before
    before=$(cat "$ssh_config")

    patch_ssh_config_portability "$ssh_config"

    # Content should be unchanged
    local after
    after=$(cat "$ssh_config")
    assert_equals "$before" "$after" "File should be unchanged when already patched"
}

test_skips_missing_config() {
    log_test "patch_ssh_config_portability: returns 0 when config doesn't exist"

    local ssh_config="$TEST_TEMP_DIR/nonexistent_config"

    patch_ssh_config_portability "$ssh_config"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 for missing config"
    assert_file_not_exists "$ssh_config" "Should not create a file"
}

test_preserves_original_content() {
    log_test "patch_ssh_config_portability: preserves all original config content"

    local ssh_config="$TEST_TEMP_DIR/config_preserve"
    cat > "$ssh_config" <<'EOF'
Host *
    UseKeychain yes
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_key
EOF
    chmod 600 "$ssh_config"

    patch_ssh_config_portability "$ssh_config"

    # All original lines should still be present
    assert_file_contains "$ssh_config" "UseKeychain yes" "Should preserve UseKeychain line"
    assert_file_contains "$ssh_config" "AddKeysToAgent yes" "Should preserve AddKeysToAgent line"
    assert_file_contains "$ssh_config" "Host github.com" "Should preserve Host block"
    assert_file_contains "$ssh_config" "IdentityFile ~/.ssh/github_key" "Should preserve IdentityFile"
}

test_maintains_permissions() {
    log_test "patch_ssh_config_portability: maintains 600 permissions"

    local ssh_config="$TEST_TEMP_DIR/config_perms"
    cat > "$ssh_config" <<'EOF'
Host *
    UseKeychain yes
EOF
    chmod 600 "$ssh_config"

    patch_ssh_config_portability "$ssh_config"

    # Check permissions (cross-platform stat format)
    local perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        perms=$(stat -f "%Lp" "$ssh_config")
    else
        perms=$(stat -c "%a" "$ssh_config")
    fi
    assert_equals "600" "$perms" "File should have 600 permissions"
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "SSH Config Cross-Platform Portability (issue #172)"

    # Setup
    setup_tests

    # Ensure cleanup on exit
    trap cleanup_tests EXIT

    # Run tests
    run_test test_patches_config_with_usekeychain
    run_test test_patches_config_with_addkeystoagent
    run_test test_idempotent_no_duplicate
    run_test test_skips_already_patched
    run_test test_skips_missing_config
    run_test test_preserves_original_content
    run_test test_maintains_permissions

    # Summary
    print_summary
}

main "$@"
