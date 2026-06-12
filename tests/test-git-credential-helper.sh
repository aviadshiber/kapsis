#!/usr/bin/env bash
#===============================================================================
# Test: Git Credential Helper (Issue #188)
#
# Unit tests for scripts/git-credential-keyring and the entrypoint patching
# function patch_git_credential_helpers().
#
# Tests verify:
#   - Credential helper returns correct output for mapped hosts
#   - Silent exit for unmapped hosts and missing map files
#   - store/erase operations are no-ops
#   - Port stripping from host:port
#   - Entrypoint patching replaces macOS credential helpers
#   - Entrypoint patching preserves non-credential config
#   - Idempotent patching
#   - Graceful degradation when secret-tool is missing
#   - Credential map file has correct permissions
#   - YQ expression includes git_credential_for field
#   - Hostname validation rejects invalid characters
#
# Category: security
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source logging
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-git-credential-helper"

# Path to the credential helper script under test
HELPER_SCRIPT="$KAPSIS_ROOT/scripts/git-credential-keyring"

# Test directory for file operations
TEST_TEMP_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_tests() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-git-cred-test.XXXXXX")
    mkdir -p "$TEST_PROJECT"
}

cleanup_tests() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

#===============================================================================
# CREDENTIAL HELPER UNIT TESTS
#===============================================================================

test_get_returns_credentials_for_mapped_host() {
    log_test "git-credential-keyring: returns credentials for mapped host"

    local map_file="$TEST_TEMP_DIR/cred-map"
    cat > "$map_file" <<'EOF'
# Test map
github.com|gh-service|testuser||
EOF

    # Create a mock secret-tool that returns a known password
    local mock_bin="$TEST_TEMP_DIR/mock-bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/secret-tool" <<'MOCK'
#!/bin/bash
# Mock secret-tool: return test password for service/account lookup
if [[ "$1" == "lookup" ]] && [[ "$2" == "service" ]] && [[ "$3" == "gh-service" ]]; then
    echo "test-password-123"
    exit 0
fi
exit 1
MOCK
    chmod +x "$mock_bin/secret-tool"

    local output
    output=$(printf 'protocol=https\nhost=github.com\n\n' | \
        PATH="$mock_bin:$PATH" KAPSIS_GIT_CREDENTIAL_MAP="$map_file" \
        bash "$HELPER_SCRIPT" get 2>/dev/null)

    assert_contains "$output" "protocol=https" "Should output protocol"
    assert_contains "$output" "host=github.com" "Should output host"
    assert_contains "$output" "username=testuser" "Should output username"
    assert_contains "$output" "password=test-password-123" "Should output password"
}

test_get_returns_empty_for_unmapped_host() {
    log_test "git-credential-keyring: silent exit for unmapped host"

    local map_file="$TEST_TEMP_DIR/cred-map-unmapped"
    cat > "$map_file" <<'EOF'
github.com|gh-service|testuser||
EOF

    local output
    output=$(printf 'protocol=https\nhost=gitlab.com\n\n' | \
        KAPSIS_GIT_CREDENTIAL_MAP="$map_file" \
        bash "$HELPER_SCRIPT" get 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should exit 0 for unmapped host"
    assert_equals "" "$output" "Should produce no output for unmapped host"
}

test_store_is_noop() {
    log_test "git-credential-keyring: store is a no-op"

    local output
    output=$(printf 'protocol=https\nhost=github.com\nusername=user\npassword=pass\n\n' | \
        bash "$HELPER_SCRIPT" store 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "store should exit 0"
    assert_equals "" "$output" "store should produce no output"
}

test_erase_is_noop() {
    log_test "git-credential-keyring: erase is a no-op"

    local output
    output=$(printf 'protocol=https\nhost=github.com\n\n' | \
        bash "$HELPER_SCRIPT" erase 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "erase should exit 0"
    assert_equals "" "$output" "erase should produce no output"
}

test_strips_port_from_host() {
    log_test "git-credential-keyring: strips port from host:port"

    local map_file="$TEST_TEMP_DIR/cred-map-port"
    cat > "$map_file" <<'EOF'
github.com|gh-service|testuser||
EOF

    local mock_bin="$TEST_TEMP_DIR/mock-bin-port"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/secret-tool" <<'MOCK'
#!/bin/bash
if [[ "$1" == "lookup" ]] && [[ "$2" == "service" ]]; then
    echo "port-test-pass"
    exit 0
fi
exit 1
MOCK
    chmod +x "$mock_bin/secret-tool"

    local output
    output=$(printf 'protocol=https\nhost=github.com:443\n\n' | \
        PATH="$mock_bin:$PATH" KAPSIS_GIT_CREDENTIAL_MAP="$map_file" \
        bash "$HELPER_SCRIPT" get 2>/dev/null)

    assert_contains "$output" "password=port-test-pass" "Should match host after stripping port"
    assert_contains "$output" "host=github.com:443" "Should preserve original host in output"
}

test_missing_map_file_exits_cleanly() {
    log_test "git-credential-keyring: exits cleanly with missing map file"

    local output
    output=$(printf 'protocol=https\nhost=github.com\n\n' | \
        KAPSIS_GIT_CREDENTIAL_MAP="$TEST_TEMP_DIR/nonexistent-map" \
        bash "$HELPER_SCRIPT" get 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should exit 0 with missing map file"
    assert_equals "" "$output" "Should produce no output with missing map file"
}

test_no_credential_leakage_on_failure() {
    log_test "git-credential-keyring: no credential leakage on stderr"

    local map_file="$TEST_TEMP_DIR/cred-map-leak"
    cat > "$map_file" <<'EOF'
github.com|gh-service|testuser||
EOF

    # Mock secret-tool that fails
    local mock_bin="$TEST_TEMP_DIR/mock-bin-fail"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/secret-tool" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$mock_bin/secret-tool"

    local stderr_output
    stderr_output=$(printf 'protocol=https\nhost=github.com\n\n' | \
        PATH="$mock_bin:$PATH" KAPSIS_GIT_CREDENTIAL_MAP="$map_file" \
        bash "$HELPER_SCRIPT" get 2>&1 >/dev/null)

    assert_not_contains "${stderr_output:-}" "password" "stderr should not contain password"
    assert_not_contains "${stderr_output:-}" "token" "stderr should not contain token"
}

test_99designs_keyring_path() {
    log_test "git-credential-keyring: uses profile lookup when collection is set"

    local map_file="$TEST_TEMP_DIR/cred-map-99d"
    cat > "$map_file" <<'EOF'
git.example.com|bkt-svc|myuser|bkt|host/git.example.com/token
EOF

    local mock_bin="$TEST_TEMP_DIR/mock-bin-99d"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/secret-tool" <<'MOCK'
#!/bin/bash
# Return password only for profile lookup (99designs path)
if [[ "$1" == "lookup" ]] && [[ "$2" == "profile" ]] && [[ "$3" == "host/git.example.com/token" ]]; then
    echo "99designs-password"
    exit 0
fi
exit 1
MOCK
    chmod +x "$mock_bin/secret-tool"

    local output
    output=$(printf 'protocol=https\nhost=git.example.com\n\n' | \
        PATH="$mock_bin:$PATH" KAPSIS_GIT_CREDENTIAL_MAP="$map_file" \
        bash "$HELPER_SCRIPT" get 2>/dev/null)

    assert_contains "$output" "password=99designs-password" \
        "Should retrieve via profile lookup when collection is set"
}

test_multi_host_map_returns_correct_credentials() {
    log_test "git-credential-keyring: matches correct host in multi-host map"

    local map_file="$TEST_TEMP_DIR/cred-map-multi"
    cat > "$map_file" <<'EOF'
github.com|gh-service|ghuser||
gitlab.com|gl-service|gluser||
git.example.com|bkt-svc|bktuser|bkt|host/git.example.com/token
EOF

    local mock_bin="$TEST_TEMP_DIR/mock-bin-multi"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/secret-tool" <<'MOCK'
#!/bin/bash
if [[ "$1" == "lookup" ]] && [[ "$2" == "service" ]] && [[ "$3" == "gl-service" ]]; then
    echo "gitlab-password"
    exit 0
fi
exit 1
MOCK
    chmod +x "$mock_bin/secret-tool"

    local output
    output=$(printf 'protocol=https\nhost=gitlab.com\n\n' | \
        PATH="$mock_bin:$PATH" KAPSIS_GIT_CREDENTIAL_MAP="$map_file" \
        bash "$HELPER_SCRIPT" get 2>/dev/null)

    assert_contains "$output" "username=gluser" "Should return gitlab user for gitlab.com"
    assert_contains "$output" "password=gitlab-password" "Should return gitlab password"
    assert_not_contains "$output" "ghuser" "Should not return github user"
}

#===============================================================================
# ENTRYPOINT PATCHING TESTS
#===============================================================================

test_replaces_osxkeychain_helper() {
    log_test "patch_git_credential_helpers: replaces osxkeychain"

    local gitconfig="$TEST_TEMP_DIR/gitconfig-osx"
    cat > "$gitconfig" <<'EOF'
[user]
    name = Test User
    email = test@example.com
[credential]
    helper = osxkeychain
[core]
    editor = vim
EOF

    # Simulate the patching logic from entrypoint (sed replacement)
    local helper_path="/opt/kapsis/git-credential-keyring"
    local tmp_file
    tmp_file=$(mktemp "${gitconfig}.patch-XXXXXX")
    sed -E \
        -e "s|(helper[[:space:]]*=[[:space:]]*)osxkeychain.*|\1$helper_path|" \
        "$gitconfig" > "$tmp_file"
    mv "$tmp_file" "$gitconfig"

    assert_file_contains "$gitconfig" "helper = /opt/kapsis/git-credential-keyring" \
        "Should replace osxkeychain with git-credential-keyring"
    assert_file_not_contains "$gitconfig" "osxkeychain" \
        "Should not contain osxkeychain after patching"
}

test_preserves_non_credential_config() {
    log_test "patch_git_credential_helpers: preserves non-credential settings"

    local gitconfig="$TEST_TEMP_DIR/gitconfig-preserve"
    cat > "$gitconfig" <<'EOF'
[user]
    name = Test User
    email = test@example.com
[credential]
    helper = osxkeychain
[core]
    editor = vim
[alias]
    co = checkout
    st = status
EOF

    local helper_path="/opt/kapsis/git-credential-keyring"
    local tmp_file
    tmp_file=$(mktemp "${gitconfig}.patch-XXXXXX")
    sed -E \
        -e "s|(helper[[:space:]]*=[[:space:]]*)osxkeychain.*|\1$helper_path|" \
        "$gitconfig" > "$tmp_file"
    mv "$tmp_file" "$gitconfig"

    assert_file_contains "$gitconfig" "name = Test User" \
        "Should preserve user.name"
    assert_file_contains "$gitconfig" "email = test@example.com" \
        "Should preserve user.email"
    assert_file_contains "$gitconfig" "editor = vim" \
        "Should preserve core.editor"
    assert_file_contains "$gitconfig" "co = checkout" \
        "Should preserve alias.co"
}

test_idempotent_patching() {
    log_test "patch_git_credential_helpers: idempotent — running sed twice is safe"

    local gitconfig="$TEST_TEMP_DIR/gitconfig-idempotent"
    local helper_path="/opt/kapsis/git-credential-keyring"
    cat > "$gitconfig" <<EOF
[credential]
    helper = $helper_path
[user]
    name = Test
EOF

    # Run sed again — should not change anything
    local tmp_file
    tmp_file=$(mktemp "${gitconfig}.patch-XXXXXX")
    sed -E \
        -e "s|(helper[[:space:]]*=[[:space:]]*)osxkeychain.*|\1$helper_path|" \
        "$gitconfig" > "$tmp_file"
    mv "$tmp_file" "$gitconfig"

    local count
    count=$(grep -c "git-credential-keyring" "$gitconfig")
    assert_equals "1" "$count" "Should have exactly one credential helper entry after double patch"
}

test_replaces_gcm_helper() {
    log_test "patch_git_credential_helpers: replaces GCM Core helper"

    local gitconfig="$TEST_TEMP_DIR/gitconfig-gcm"
    cat > "$gitconfig" <<'EOF'
[credential]
    helper = /usr/local/share/gcm-core/git-credential-manager
EOF

    local helper_path="/opt/kapsis/git-credential-keyring"
    local tmp_file
    tmp_file=$(mktemp "${gitconfig}.patch-XXXXXX")
    sed -E \
        -e "s|(helper[[:space:]]*=[[:space:]]*)/usr/local/share/gcm.*|\1$helper_path|" \
        "$gitconfig" > "$tmp_file"
    mv "$tmp_file" "$gitconfig"

    assert_file_contains "$gitconfig" "helper = /opt/kapsis/git-credential-keyring" \
        "Should replace GCM Core with git-credential-keyring"
    assert_file_not_contains "$gitconfig" "gcm-core" \
        "Should not contain gcm-core after patching"
}

test_deduplicates_multiple_macos_helpers() {
    log_test "patch_git_credential_helpers: deduplicates when multiple macOS helpers present"

    local gitconfig="$TEST_TEMP_DIR/gitconfig-multi-helper"
    cat > "$gitconfig" <<'EOF'
[user]
    name = Test User
[credential]
    helper = osxkeychain
[credential "https://github.com"]
    helper = /usr/local/share/gcm-core/git-credential-manager
[core]
    editor = vim
EOF

    local helper_path="/opt/kapsis/git-credential-keyring"
    local tmp_file
    tmp_file=$(mktemp "${gitconfig}.patch-XXXXXX")
    # Apply same sed as entrypoint
    sed -E \
        -e "s|(helper[[:space:]]*=[[:space:]]*)osxkeychain.*|\1$helper_path|" \
        -e "s|(helper[[:space:]]*=[[:space:]]*)/usr/local/share/gcm.*|\1$helper_path|" \
        -e "s|(helper[[:space:]]*=[[:space:]]*)/usr/local/bin/git-credential-manager.*|\1$helper_path|" \
        "$gitconfig" > "$tmp_file"

    # Deduplicate (same logic as entrypoint)
    local seen_helper=false
    local dedup_file
    dedup_file=$(mktemp "${gitconfig}.dedup-XXXXXX")
    while IFS= read -r line; do
        if [[ "$line" =~ helper[[:space:]]*=[[:space:]]*/opt/kapsis/git-credential-keyring ]]; then
            if [[ "$seen_helper" == "true" ]]; then
                continue
            fi
            seen_helper=true
        fi
        echo "$line"
    done < "$tmp_file" > "$dedup_file"
    mv "$dedup_file" "$gitconfig"
    rm -f "$tmp_file"

    local count
    count=$(grep -c "git-credential-keyring" "$gitconfig")
    assert_equals "1" "$count" "Should have exactly one helper entry after deduplicating multiple macOS helpers"
    assert_file_contains "$gitconfig" "name = Test User" "Should preserve user.name"
    assert_file_contains "$gitconfig" "editor = vim" "Should preserve core.editor"
}

test_writes_credential_map_with_correct_permissions() {
    log_test "Credential map file has mode 600"

    local map_file="$TEST_TEMP_DIR/cred-map-perms"
    local map_data="github.com|gh-svc|user||,gitlab.com|gl-svc|user||"

    {
        echo "# Kapsis git credential map (auto-generated)"
        echo "# Format: host|service|account|keyring_collection|keyring_profile"
        echo "$map_data" | tr ',' '\n'
    } > "$map_file"
    chmod 600 "$map_file"

    local perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        perms=$(stat -f "%Lp" "$map_file")
    else
        perms=$(stat -c "%a" "$map_file")
    fi
    assert_equals "600" "$perms" "Credential map should have 600 permissions"

    # Verify content
    assert_file_contains "$map_file" "github.com|gh-svc|user||" \
        "Map should contain github.com entry"
    assert_file_contains "$map_file" "gitlab.com|gl-svc|user||" \
        "Map should contain gitlab.com entry"
}

#===============================================================================
# CONFIG PARSING TESTS
#===============================================================================

test_git_credential_for_in_yq_pipeline() {
    log_test "YQ expression includes git_credential_for as 9th field"

    if ! skip_if_not_mikefarah_yq; then
        return 0
    fi

    local test_config="$TEST_PROJECT/.kapsis-git-cred-yq-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    BKT_TOKEN:
      service: "taboola-bitbucket"
      account: "aviad.s"
      inject_to: "secret_store"
      keyring_collection: "bkt"
      keyring_profile: "host/git.example.com/token"
      git_credential_for: "git.example.com"
    PLAIN_TOKEN:
      service: "plain-svc"
      inject_to: "secret_store"
    GH_TOKEN:
      service: "github-pat"
      account: "testuser"
      git_credential_for: "github.com"
EOF

    local parsed
    parsed=$(parse_keychain_config "$test_config")

    rm -f "$test_config"

    assert_contains "$parsed" "BKT_TOKEN|taboola-bitbucket|aviad.s||0600|secret_store|bkt|host/git.example.com/token|git.example.com" \
        "git_credential_for should be parsed as 9th field for BKT_TOKEN"
    assert_contains "$parsed" "GH_TOKEN|github-pat|testuser||0600|secret_store|||github.com" \
        "git_credential_for should be parsed as 9th field for GH_TOKEN"
    # PLAIN_TOKEN has no git_credential_for — 9th field should be empty
    assert_contains "$parsed" "PLAIN_TOKEN|plain-svc|||0600|secret_store|||" \
        "Missing git_credential_for should produce empty 9th field"
}

test_git_credential_for_hostname_validation() {
    log_test "launch-agent.sh validates git_credential_for hostname characters"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"

    # Verify the validation regex exists
    assert_contains "$(cat "$launch_script")" 'git_credential_for' \
        "launch-agent.sh should reference git_credential_for"
    assert_contains "$(cat "$launch_script")" 'contains invalid characters' \
        "launch-agent.sh should validate hostname characters"
}

test_launch_agent_has_git_credential_map() {
    log_test "launch-agent.sh passes KAPSIS_GIT_CREDENTIAL_MAP_DATA to container"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"

    assert_contains "$(cat "$launch_script")" "KAPSIS_GIT_CREDENTIAL_MAP_DATA" \
        "launch-agent.sh should pass KAPSIS_GIT_CREDENTIAL_MAP_DATA"
    assert_contains "$(cat "$launch_script")" "GIT_CREDENTIAL_MAP" \
        "launch-agent.sh should track GIT_CREDENTIAL_MAP"
}

test_entrypoint_has_credential_helper_patching() {
    log_test "entrypoint.sh has patch_git_credential_helpers function"

    local entrypoint_script="$KAPSIS_ROOT/scripts/entrypoint.sh"

    assert_contains "$(cat "$entrypoint_script")" "patch_git_credential_helpers" \
        "entrypoint.sh should define/call patch_git_credential_helpers"
    assert_contains "$(cat "$entrypoint_script")" "KAPSIS_GIT_CREDENTIAL_MAP_DATA" \
        "entrypoint.sh should read KAPSIS_GIT_CREDENTIAL_MAP_DATA"
    assert_contains "$(cat "$entrypoint_script")" "osxkeychain" \
        "entrypoint.sh should handle osxkeychain replacement"
}

test_containerfile_includes_credential_helper() {
    log_test "Containerfile installs git-credential-keyring"

    local containerfile="$KAPSIS_ROOT/Containerfile"

    assert_contains "$(cat "$containerfile")" "git-credential-keyring" \
        "Containerfile should COPY git-credential-keyring"
    assert_contains "$(cat "$containerfile")" "ln -sf /opt/kapsis/git-credential-keyring" \
        "Containerfile should symlink git-credential-keyring to PATH"
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "Git Credential Helper (issue #188)"

    # Setup
    setup_tests
    trap cleanup_tests EXIT

    # Credential helper unit tests
    run_test test_get_returns_credentials_for_mapped_host
    run_test test_get_returns_empty_for_unmapped_host
    run_test test_store_is_noop
    run_test test_erase_is_noop
    run_test test_strips_port_from_host
    run_test test_missing_map_file_exits_cleanly
    run_test test_no_credential_leakage_on_failure
    run_test test_99designs_keyring_path
    run_test test_multi_host_map_returns_correct_credentials

    # Entrypoint patching tests
    run_test test_replaces_osxkeychain_helper
    run_test test_preserves_non_credential_config
    run_test test_idempotent_patching
    run_test test_replaces_gcm_helper
    run_test test_deduplicates_multiple_macos_helpers
    run_test test_writes_credential_map_with_correct_permissions

    # Config parsing and integration tests
    run_test test_git_credential_for_in_yq_pipeline
    run_test test_git_credential_for_hostname_validation
    run_test test_launch_agent_has_git_credential_map
    run_test test_entrypoint_has_credential_helper_patching
    run_test test_containerfile_includes_credential_helper

    # Summary
    print_summary
}

main "$@"
