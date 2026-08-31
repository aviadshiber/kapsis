#!/usr/bin/env bash
#===============================================================================
# Test: SSH Identities (scripts/lib/ssh-identities.sh)
#
# Host-tier tests (no container) for the declarative ssh.identities feature:
# materializing base64-transported deploy keys into SSH identity files, a
# generated ~/.ssh/config Include stanza, and best-effort known_hosts.
#
# Security note: never print decoded key material. The critical round-trip
# check uses `ssh-keygen -y -f <identity_file>`, which emits ONLY the
# derived public key.
#
# Category: security
# Container required: No (real throwaway ed25519 keypair generated locally).
# Hermetic: ssh-keyscan is stubbed on PATH (see setup_test_env) so the
# best-effort known_hosts pre-population never touches the network.
#===============================================================================

# Many per-test setup globals (AGENT_ID, PROJECT_PATH, ENV_*, SSH_IDENTITIES, ...)
# are consumed by the sourced generate_env_vars()/ssh-identities.sh functions, which
# ShellCheck can't follow — so it false-positives SC2034 (appears unused) on them.
# This directive must precede the first command to apply file-wide.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

SSH_IDENTITIES_LIB="$KAPSIS_ROOT/scripts/lib/ssh-identities.sh"
LAUNCH_AGENT_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

TEST_HOME=""
TEST_KEY_DIR=""
TEST_MOCK_BIN_DIR=""
ORIG_PATH="$PATH"

setup_test_env() {
    TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-ssh-identities-home.XXXXXX")
    TEST_KEY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-ssh-identities-keys.XXXXXX")
    export HOME="$TEST_HOME"

    # Stub ssh-keyscan on PATH exactly as tests/test-ssh-keychain.sh does, so
    # setup_ssh_identities' best-effort known_hosts pre-population
    # (_ssh_identities_keyscan) never makes a real network call for the
    # fake git.example.com host — keeps this suite hermetic and fast
    # instead of relying on a real DNS-resolution failure/timeout.
    TEST_MOCK_BIN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-ssh-identities-mockbin.XXXXXX")
    cat > "$TEST_MOCK_BIN_DIR/ssh-keyscan" <<'MOCKEOF'
#!/usr/bin/env bash
# No network: fail immediately, mirroring an unreachable host. Callers treat
# this as non-fatal (best-effort known_hosts pre-population).
exit 1
MOCKEOF
    chmod +x "$TEST_MOCK_BIN_DIR/ssh-keyscan"
    export PATH="$TEST_MOCK_BIN_DIR:$ORIG_PATH"
}

cleanup_test_env() {
    [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
    [[ -n "$TEST_KEY_DIR" && -d "$TEST_KEY_DIR" ]] && rm -rf "$TEST_KEY_DIR"
    [[ -n "$TEST_MOCK_BIN_DIR" && -d "$TEST_MOCK_BIN_DIR" ]] && rm -rf "$TEST_MOCK_BIN_DIR"
    TEST_HOME=""
    TEST_KEY_DIR=""
    TEST_MOCK_BIN_DIR=""
    export PATH="$ORIG_PATH"
    # Clear any identity env vars leaked from a failed test
    local var
    for var in "${!KAPSIS_SSH_IDKEY_@}"; do
        unset "$var"
    done
    unset KAPSIS_SSH_IDENTITIES 2>/dev/null || true
}

# Generate a real throwaway ed25519 keypair and print its base64 form.
# Never echoes the private key material. Optional $1 names the key file
# (under TEST_KEY_DIR) so callers can generate multiple DISTINCT keys
# (e.g. for a multi-identity test — reusing one key across identities
# would mask an index-swap bug).
generate_throwaway_key_b64() {
    local name="${1:-throwaway_key}"
    local key_path="$TEST_KEY_DIR/$name"
    ssh-keygen -t ed25519 -N '' -f "$key_path" -C "kapsis-test-throwaway" >/dev/null 2>&1
    # Same idiom launch-agent.sh uses: base64 | tr -d '\n' — unconditionally
    # single-line on both GNU and BSD base64 (no reliance on `-w0`, GNU-only).
    base64 < "$key_path" | tr -d '\n'
}

#===============================================================================
# TEST CASES
#===============================================================================

test_script_exists() {
    log_test "ssh-identities.sh exists"
    assert_file_exists "$SSH_IDENTITIES_LIB" "ssh-identities.sh should exist"
}

test_script_passes_shellcheck() {
    log_test "Script passes shellcheck"
    if ! command -v shellcheck &>/dev/null; then
        log_skip "shellcheck not available"
        return 0
    fi
    local exit_code=0
    shellcheck "$SSH_IDENTITIES_LIB" || exit_code=$?
    assert_equals 0 "$exit_code" "Script should pass shellcheck"
}

test_no_identities_is_a_noop() {
    log_test "setup_ssh_identities: no-op when KAPSIS_SSH_IDENTITIES is unset"
    setup_test_env

    (
        source "$SSH_IDENTITIES_LIB"
        unset KAPSIS_SSH_IDENTITIES 2>/dev/null || true
        setup_ssh_identities
    )

    assert_file_not_exists "$TEST_HOME/.ssh/config" "Should not create .ssh/config when no identities configured"

    cleanup_test_env
}

test_materializes_identity_file_with_correct_permissions() {
    log_test "setup_ssh_identities: materializes identity file, mode 600"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    )

    local identity_file="$TEST_HOME/.ssh/kapsis_id_git_example_com"
    assert_file_exists "$identity_file" "Identity file should be created"

    local perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        perms=$(stat -f "%Lp" "$identity_file")
    else
        perms=$(stat -c "%a" "$identity_file")
    fi
    assert_equals "600" "$perms" "Identity file should have 600 permissions"

    cleanup_test_env
}

test_identity_file_round_trips_via_ssh_keygen() {
    log_test "setup_ssh_identities: identity file parses intact (newline-fidelity check)"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    )

    local identity_file="$TEST_HOME/.ssh/kapsis_id_git_example_com"

    # THE critical check: ssh-keygen -y only emits the derived public key,
    # never private key material — safe to use in test output/assertions.
    local exit_code=0
    ssh-keygen -y -f "$identity_file" >/dev/null 2>&1 || exit_code=$?
    assert_equals 0 "$exit_code" "ssh-keygen -y must succeed — proves the key round-tripped through base64 intact"

    cleanup_test_env
}

test_container_tier_decode_is_encoding_agnostic_round_trips_via_ssh_keygen() {
    # NOTE (LOW doc fix): originally named
    # test_encoding_base64_passthrough_round_trips_via_ssh_keygen, which
    # oversold what this exercises. `encoding` is a host-only field (see the
    # comment below) — setup_ssh_identities() (container tier) receives the
    # exact same shape of KAPSIS_SSH_IDKEY_0_B64 regardless of encoding=raw
    # vs encoding=base64, so this test is identical in shape to
    # test_identity_file_round_trips_via_ssh_keygen above. The real
    # raw-vs-base64 behavioral split (double-encode vs pass-through) is
    # covered host-side by the ssh_identity_key_transport_value() unit tests
    # below (test_transport_encoding_raw_base64_encodes /
    # test_transport_encoding_base64_passes_through_unchanged /
    # test_transport_encoding_base64_strips_trailing_newline). Kept as a
    # named regression anchor for the container-tier decode contract, not as
    # evidence of container-tier encoding-specific behavior (there isn't any).
    log_test "setup_ssh_identities: container-tier base64 -d decode is encoding-agnostic (same shape as encoding=raw; real split is host-side)"
    setup_test_env

    # `key.encoding` only changes HOST-side pre-processing (scripts/launch-agent.sh
    # generate_env_vars): for encoding=base64 the secret fetched from the store is
    # ALREADY base64(rawkey) (single line — this is the documented workaround for
    # secret stores, e.g. macOS `security -w`, that corrupt multi-line values on
    # retrieval), so the host passes it through UNCHANGED instead of re-encoding it.
    # `encoding` is never part of the container-visible KAPSIS_SSH_IDENTITIES
    # metadata (host-only field) and the container ALWAYS does exactly one
    # `base64 -d` regardless of encoding — so from setup_ssh_identities' point of
    # view this test receives the exact same shape of KAPSIS_SSH_IDKEY_0_B64 value
    # as the encoding=raw (default) path. This test proves that contract: a value
    # that was base64-encoded ONCE (whether by the host, for encoding=raw, or
    # pre-encoded by the operator and passed through untouched, for
    # encoding=base64) always decodes back to an intact key.
    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    )

    local identity_file="$TEST_HOME/.ssh/kapsis_id_git_example_com"

    local exit_code=0
    ssh-keygen -y -f "$identity_file" >/dev/null 2>&1 || exit_code=$?
    assert_equals 0 "$exit_code" \
        "ssh-keygen -y must succeed — proves an already-base64 (encoding=base64) value round-trips intact"

    cleanup_test_env
}

test_transport_encoding_raw_base64_encodes() {
    log_test "ssh_identity_key_transport_value: encoding=raw base64-encodes the fetched secret"

    # Host-side helper (scripts/launch-agent.sh), extracted from
    # generate_env_vars() for direct unit testing. Never logs/prints the
    # "secret" here — it's a synthetic non-secret test string, not real key
    # material, but treated the same way regardless.
    local result
    result=$(
        source "$LAUNCH_AGENT_SCRIPT"
        ssh_identity_key_transport_value "not-a-real-secret" "raw"
    )
    local expected
    expected=$(printf '%s' "not-a-real-secret" | base64 | tr -d '\n')
    assert_equals "$expected" "$result" \
        "encoding=raw must base64-encode the input exactly once"
}

test_transport_encoding_base64_passes_through_unchanged() {
    log_test "ssh_identity_key_transport_value: encoding=base64 passes an already-base64 value through unchanged"

    local already_b64
    already_b64=$(printf '%s' "not-a-real-secret" | base64 | tr -d '\n')

    local result
    result=$(
        source "$LAUNCH_AGENT_SCRIPT"
        ssh_identity_key_transport_value "$already_b64" "base64"
    )
    assert_equals "$already_b64" "$result" \
        "encoding=base64 must pass the already-base64 value through unchanged (no double-encoding)"

    # And it must NOT equal what encoding=raw would have produced from the
    # same input (which would indicate an accidental double base64-encode).
    local double_encoded
    double_encoded=$(printf '%s' "$already_b64" | base64 | tr -d '\n')
    assert_not_equals "$double_encoded" "$result" \
        "encoding=base64 result must not match a double-encoded value (regression: value was re-encoded)"
}

test_transport_encoding_base64_strips_trailing_newline() {
    log_test "ssh_identity_key_transport_value: encoding=base64 strips a trailing newline without re-encoding"

    local already_b64
    already_b64=$(printf '%s' "not-a-real-secret" | base64 | tr -d '\n')
    local already_b64_with_newline="${already_b64}"$'\n'

    local result
    result=$(
        source "$LAUNCH_AGENT_SCRIPT"
        ssh_identity_key_transport_value "$already_b64_with_newline" "base64"
    )
    assert_equals "$already_b64" "$result" \
        "encoding=base64 must strip a trailing newline the secret store retrieval may add"
}

#===============================================================================
# FIX-9: host-side generate_env_vars() coverage for ssh.identities
#
# The ~110-line loop in generate_env_vars() (scripts/launch-agent.sh) that
# resolves ssh.identities secrets host-side was previously untested beyond
# the extracted ssh_identity_key_transport_value() helper above. These tests
# source launch-agent.sh (safe: main() only runs when executed directly —
# see the BASH_SOURCE guard at the bottom of the script), mock
# query_secret_store_with_fallbacks(), and drive generate_env_vars()
# directly with the minimal set of globals it reads. All "secret" values
# below are synthetic test strings, never real key material.
#===============================================================================

test_generate_env_vars_ssh_identities_index_alignment() {
    log_test "generate_env_vars: KAPSIS_SSH_IDKEY_<n>_B64 index aligns with the identity at metadata position n"

    local output
    output=$(
        source "$LAUNCH_AGENT_SCRIPT"

        # Mock: distinguishable fake secret per (service, account) pair.
        query_secret_store_with_fallbacks() {
            local service="$1" account="$2"
            if [[ "$service" == "service-a" && "$account" == "account-a" ]]; then
                printf '%s' "fake-secret-identity-0"
                return 0
            elif [[ "$service" == "service-b" && "$account" == "account-b" ]]; then
                printf '%s' "fake-secret-identity-1"
                return 0
            fi
            return 1
        }

        # Minimal globals generate_env_vars() reads (see scripts/launch-agent.sh
        # top-level DEFAULT VALUES section for the rest, already set by sourcing).
        AGENT_ID="test-agent"
        PROJECT_PATH="/tmp/kapsis-fix9-test"
        ENV_PASSTHROUGH=""
        ENV_KEYCHAIN=""
        ENV_SET="{}"
        GIT_ATTRIBUTION_COMMIT=""
        GIT_ATTRIBUTION_PR=""
        SANDBOX_MODE="worktree"
        SSH_IDENTITIES=$'git.example.com|2222|git||accept-new|service-a|account-a|raw\ngit2.example.com|2223|deploy||accept-new|service-b|account-b|raw'

        generate_env_vars

        for e in "${SECRET_ENV_VARS[@]}"; do printf 'SECRET:%s\n' "$e"; done
        for e in "${ENV_VARS[@]}"; do printf 'ENVVAR:%s\n' "$e"; done
    )

    local expected_b64_0 expected_b64_1
    expected_b64_0=$(printf '%s' "fake-secret-identity-0" | base64 | tr -d '\n')
    expected_b64_1=$(printf '%s' "fake-secret-identity-1" | base64 | tr -d '\n')

    assert_contains "$output" "SECRET:KAPSIS_SSH_IDKEY_0_B64=${expected_b64_0}" \
        "Index 0's key material must come from identity 0's mocked secret-store call"
    assert_contains "$output" "SECRET:KAPSIS_SSH_IDKEY_1_B64=${expected_b64_1}" \
        "Index 1's key material must come from identity 1's mocked secret-store call, not identity 0's"
    assert_contains "$output" "ENVVAR:KAPSIS_SSH_IDENTITIES=git.example.com|2222|git|" \
        "Metadata must list identity 0 (git.example.com) first"
    assert_contains "$output" "git2.example.com|2223|deploy|" \
        "Metadata must list identity 1 (git2.example.com) second, matching KAPSIS_SSH_IDKEY_1_B64's index"
}

test_generate_env_vars_ssh_identities_missing_secret_aborts() {
    log_test "generate_env_vars: a secret-store miss for any identity aborts (exit 1) to avoid index desync"

    local exit_code=0
    (
        source "$LAUNCH_AGENT_SCRIPT"

        # Only identity 0's secret resolves; identity 1's service/account never matches.
        query_secret_store_with_fallbacks() {
            local service="$1" account="$2"
            if [[ "$service" == "service-a" && "$account" == "account-a" ]]; then
                printf '%s' "fake-secret-identity-0"
                return 0
            fi
            return 1
        }

        AGENT_ID="test-agent"
        PROJECT_PATH="/tmp/kapsis-fix9-test"
        ENV_PASSTHROUGH=""
        ENV_KEYCHAIN=""
        ENV_SET="{}"
        GIT_ATTRIBUTION_COMMIT=""
        GIT_ATTRIBUTION_PR=""
        SANDBOX_MODE="worktree"
        SSH_IDENTITIES=$'git.example.com|2222|git||accept-new|service-a|account-a|raw\ngit2.example.com|2223|deploy||accept-new|service-b|account-b|raw'

        generate_env_vars
    ) >/dev/null 2>&1 || exit_code=$?

    assert_equals 1 "$exit_code" \
        "generate_env_vars must abort (exit 1) rather than silently skip a missing identity secret (would desync the index<->key pairing)"
}

test_write_secrets_env_file_fail_closed_on_mktemp_failure() {
    log_test "write_secrets_env_file: mktemp failure with a pending KAPSIS_SSH_IDKEY_* aborts, never falls back to inline -e (regression, security invariant)"

    local mock_bin_dir
    mock_bin_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-mktemp-fail-mock.XXXXXX")
    cat > "$mock_bin_dir/mktemp" <<'MOCKEOF'
#!/usr/bin/env bash
# Simulate a restricted environment where temp-file creation fails.
exit 1
MOCKEOF
    chmod +x "$mock_bin_dir/mktemp"

    local exit_code=0
    local output
    output=$(
        source "$LAUNCH_AGENT_SCRIPT"
        SECRET_ENV_VARS=("KAPSIS_SSH_IDKEY_0_B64=ZmFrZS1zZWNyZXQtbWF0ZXJpYWw=")
        ENV_VARS=()
        export PATH="$mock_bin_dir:$PATH"
        write_secrets_env_file
        # Would-be podman command construction: confirm no inline -e ever
        # carries the key material, whether write_secrets_env_file returned
        # or aborted first.
        for e in "${ENV_VARS[@]}"; do printf 'ENVVAR:%s\n' "$e"; done
    ) 2>&1 || exit_code=$?

    rm -rf "$mock_bin_dir"

    assert_equals 1 "$exit_code" \
        "write_secrets_env_file must abort (exit 1) rather than fall back to inline -e when a KAPSIS_SSH_IDKEY_* secret is pending and mktemp fails"
    assert_not_contains "$output" "KAPSIS_SSH_IDKEY" \
        "Key material must never appear as an inline -e ENV_VARS entry — grepping the would-be podman command args"
}

test_yq_expr_handles_int_typed_field_without_dropping_identities() {
    log_test "KAPSIS_YQ_SSH_IDENTITIES_EXPR: an int-typed field (e.g. numeric key.account) still parses"

    if ! command -v yq &>/dev/null; then
        log_skip "yq not available"
        return 0
    fi

    # KAPSIS_YQ_SSH_IDENTITIES_EXPR is defined in scripts/lib/constants.sh
    # (sourced globally by the test framework). Regression test for: a field
    # that YAML-parses as a non-string scalar (int) made the whole "..."+<int>
    # concatenation error in yq, silently dropping ALL identities.
    local fixture
    fixture=$(mktemp "${TMPDIR:-/tmp}/kapsis-ssh-yq-fixture.XXXXXX.yaml")
    cat > "$fixture" <<'EOF'
ssh:
  identities:
    - host: git.example.com
      port: 2222
      user: git
      key:
        service: my-deploy-key
        account: 12345
EOF

    local result
    result=$(yq "$KAPSIS_YQ_SSH_IDENTITIES_EXPR" "$fixture" 2>/dev/null || true)
    rm -f "$fixture"

    assert_not_equals "" "$result" \
        "yq expression must not return empty when a field (key.account) is int-typed"
    assert_contains "$result" "git.example.com|2222|git||accept-new|my-deploy-key|12345|raw" \
        "int-typed key.account must be coerced to string and appear in the pipe-delimited output"
}

test_ssh_config_include_is_first_line() {
    log_test "setup_ssh_identities: ~/.ssh/config first line is the kapsis Include"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    )

    local ssh_config="$TEST_HOME/.ssh/config"
    assert_file_exists "$ssh_config" "$HOME/.ssh/config should be created"

    local first_line
    first_line=$(head -1 "$ssh_config")
    assert_equals "Include ~/.ssh/kapsis_identities" "$first_line" \
        "First line of ~/.ssh/config must be the kapsis Include"

    cleanup_test_env
}

test_no_clobber_preserves_existing_config() {
    log_test "setup_ssh_identities: no-clobber — preserves pre-existing ~/.ssh/config content"
    setup_test_env

    mkdir -p "$TEST_HOME/.ssh"
    chmod 700 "$TEST_HOME/.ssh"
    cat > "$TEST_HOME/.ssh/config" <<'EOF'
Host personal-host
    User someone
    IdentityFile ~/.ssh/personal_key
EOF
    chmod 600 "$TEST_HOME/.ssh/config"

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    )

    assert_file_contains "$TEST_HOME/.ssh/config" "Host personal-host" \
        "Pre-existing config content must be preserved"
    assert_file_contains "$TEST_HOME/.ssh/config" "IdentityFile ~/.ssh/personal_key" \
        "Pre-existing IdentityFile line must be preserved"

    local first_line
    first_line=$(head -1 "$TEST_HOME/.ssh/config")
    assert_equals "Include ~/.ssh/kapsis_identities" "$first_line" \
        "Include must be prepended as the first line"

    cleanup_test_env
}

test_stanza_contains_identities_only_and_port() {
    log_test "setup_ssh_identities: generated stanza has IdentitiesOnly yes and correct Port"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    )

    local stanzas_file="$TEST_HOME/.ssh/kapsis_identities"
    assert_file_exists "$stanzas_file" "Stanzas file should be created"
    assert_file_contains "$stanzas_file" "IdentitiesOnly yes" "Stanza must set IdentitiesOnly yes"
    assert_file_contains "$stanzas_file" "Port 2222" "Stanza must have the correct Port"
    assert_file_contains "$stanzas_file" "Host git.example.com" "Stanza must have the correct Host"

    cleanup_test_env
}

test_two_identities_do_not_cross_pair() {
    log_test "setup_ssh_identities: two identities each get their own key/host/port (FIX-8, guards FIX-6 index bug)"
    setup_test_env

    # Two DISTINCT throwaway keys — reusing one key for both identities would
    # mask an index<->host mis-pairing bug (the exact class FIX-6 removed the
    # fragile hand-maintained idx counter to prevent).
    local key0_b64 key1_b64
    key0_b64=$(generate_throwaway_key_b64 "throwaway_key_0")
    key1_b64=$(generate_throwaway_key_b64 "throwaway_key_1")

    local pub0 pub1
    pub0=$(ssh-keygen -y -f "$TEST_KEY_DIR/throwaway_key_0")
    pub1=$(ssh-keygen -y -f "$TEST_KEY_DIR/throwaway_key_1")
    assert_not_equals "$pub0" "$pub1" "Sanity: the two throwaway keys must actually be different"

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_0|accept-new,git2.example.com|2223|deploy|~/.ssh/kapsis_id_1|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key0_b64"
        export KAPSIS_SSH_IDKEY_1_B64="$key1_b64"
        setup_ssh_identities
    )

    local identity_file_0="$TEST_HOME/.ssh/kapsis_id_0"
    local identity_file_1="$TEST_HOME/.ssh/kapsis_id_1"
    assert_file_exists "$identity_file_0" "Identity #0 file should be created"
    assert_file_exists "$identity_file_1" "Identity #1 file should be created"

    # Round-trip integrity for each identity file, independently.
    local exit_code=0
    ssh-keygen -y -f "$identity_file_0" >/dev/null 2>&1 || exit_code=$?
    assert_equals 0 "$exit_code" "Identity #0 file must round-trip via ssh-keygen -y"
    exit_code=0
    ssh-keygen -y -f "$identity_file_1" >/dev/null 2>&1 || exit_code=$?
    assert_equals 0 "$exit_code" "Identity #1 file must round-trip via ssh-keygen -y"

    # The critical cross-pairing check: identity #0's file must derive the
    # SAME public key as throwaway_key_0 (not throwaway_key_1), and vice
    # versa. This is what would catch an index-swap bug that "two files
    # exist" alone cannot.
    local derived_pub0 derived_pub1
    derived_pub0=$(ssh-keygen -y -f "$identity_file_0")
    derived_pub1=$(ssh-keygen -y -f "$identity_file_1")
    assert_equals "$pub0" "$derived_pub0" "Identity #0's file must contain key #0's material, not key #1's"
    assert_equals "$pub1" "$derived_pub1" "Identity #1's file must contain key #1's material, not key #0's"

    # Stanza content must pair each host with its own port (not the other
    # identity's) — checked via the actual per-identity stanza text, not
    # just file existence.
    local stanzas_file="$TEST_HOME/.ssh/kapsis_identities"
    assert_file_exists "$stanzas_file" "Stanzas file should be created"

    local stanza_0 stanza_1
    stanza_0=$(awk '/^Host git\.example\.com$/{flag=1} flag{print} /^$/{if(flag)exit}' "$stanzas_file")
    stanza_1=$(awk '/^Host git2\.example\.com$/{flag=1} flag{print} /^$/{if(flag)exit}' "$stanzas_file")

    assert_contains "$stanza_0" "Port 2222" "Identity #0's stanza must have port 2222, not identity #1's port"
    assert_contains "$stanza_0" "User git" "Identity #0's stanza must have user 'git'"
    assert_contains "$stanza_0" "IdentityFile $identity_file_0" "Identity #0's stanza must reference its own identity file"

    assert_contains "$stanza_1" "Port 2223" "Identity #1's stanza must have port 2223, not identity #0's port"
    assert_contains "$stanza_1" "User deploy" "Identity #1's stanza must have user 'deploy'"
    assert_contains "$stanza_1" "IdentityFile $identity_file_1" "Identity #1's stanza must reference its own identity file"

    cleanup_test_env
}

test_idempotent_rerun_no_duplicate_include() {
    log_test "setup_ssh_identities: idempotent — re-run doesn't duplicate the Include"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
        # Re-run — env vars were unset by the first call, so re-export.
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    )

    local ssh_config="$TEST_HOME/.ssh/config"
    local include_count
    include_count=$(grep -c "^Include ~/.ssh/kapsis_identities$" "$ssh_config")
    assert_equals "1" "$include_count" "Include line must appear exactly once after two runs"

    cleanup_test_env
}

test_env_vars_unset_after_use() {
    log_test "setup_ssh_identities: KAPSIS_SSH_IDKEY_*_B64 and KAPSIS_SSH_IDENTITIES unset after use"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    local leaked=0
    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
        [[ -n "${KAPSIS_SSH_IDENTITIES:-}" ]] && exit 1
        [[ -n "${KAPSIS_SSH_IDKEY_0_B64:-}" ]] && exit 1
        exit 0
    ) || leaked=1

    assert_equals 0 "$leaked" "Transport env vars must be unset after setup_ssh_identities runs"

    cleanup_test_env
}

test_no_key_material_in_output() {
    log_test "setup_ssh_identities: no decoded key material appears in stdout/stderr"
    setup_test_env

    local key_path="$TEST_KEY_DIR/throwaway_key"
    ssh-keygen -t ed25519 -N '' -f "$key_path" -C "kapsis-test-throwaway" >/dev/null 2>&1
    local key_b64
    key_b64=$(base64 < "$key_path" | tr -d '\n')

    # A distinctive substring from the middle of the actual decoded private
    # key body (never the base64 transport form, never the public key) —
    # this must NEVER appear in setup_ssh_identities' output.
    local key_body_line
    key_body_line=$(sed -n '2p' "$key_path")

    local combined_output
    combined_output=$(
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities
    ) 2>&1

    assert_not_contains "$combined_output" "$key_body_line" \
        "Decoded private key material must never appear in setup_ssh_identities output"
    # Marker split across two adjacent string literals so secret-scanners
    # (e.g. GitGuardian) don't false-positive on this guard string itself as a
    # committed private key — the two literals concatenate to the real header.
    local key_marker="BEGIN OPENSSH PRIVATE ""KEY"
    assert_not_contains "$combined_output" "$key_marker" \
        "Private key marker must never appear in setup_ssh_identities output"

    cleanup_test_env
}

test_decode_failure_is_fail_loud_no_partial_file() {
    log_test "setup_ssh_identities: base64 decode failure skips identity, no partial key file"
    setup_test_env

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|2222|git|~/.ssh/kapsis_id_git_example_com|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="not-valid-base64!!!"
        setup_ssh_identities 2>/dev/null
    )

    assert_file_not_exists "$TEST_HOME/.ssh/kapsis_id_git_example_com" \
        "Must not write a partial/garbage key file on decode failure"

    cleanup_test_env
}

test_rejects_invalid_host_in_container() {
    log_test "setup_ssh_identities: defense-in-depth rejects invalid host"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git example.com/evil|22||~/.ssh/kapsis_id_bad|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities 2>/dev/null
    )

    assert_file_not_exists "$TEST_HOME/.ssh/kapsis_id_bad" "Must not materialize a key for an invalid host"

    cleanup_test_env
}

test_rejects_invalid_user_in_container() {
    log_test "setup_ssh_identities: defense-in-depth rejects invalid user (delimiter-desync guard)"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|22|bad user|~/.ssh/kapsis_id_bad_user|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities 2>/dev/null
    )

    assert_file_not_exists "$TEST_HOME/.ssh/kapsis_id_bad_user" "Must not materialize a key for an invalid user"

    cleanup_test_env
}

test_rejects_identity_file_with_comma_in_container() {
    log_test "setup_ssh_identities: defense-in-depth rejects identity_file containing ',' (delimiter-desync guard)"
    setup_test_env

    local key_b64
    key_b64=$(generate_throwaway_key_b64)

    (
        source "$SSH_IDENTITIES_LIB"
        export KAPSIS_SSH_IDENTITIES="git.example.com|22|git|~/.ssh/kapsis_id_bad,evil|accept-new"
        export KAPSIS_SSH_IDKEY_0_B64="$key_b64"
        setup_ssh_identities 2>/dev/null
    )

    assert_file_not_exists "$TEST_HOME/.ssh/kapsis_id_bad,evil" \
        "Must not materialize a key for an identity_file containing a ',' delimiter"

    cleanup_test_env
}

#===============================================================================
# RUN TESTS
#===============================================================================

print_test_header "SSH Identities (scripts/lib/ssh-identities.sh)"

run_test test_script_exists
run_test test_script_passes_shellcheck
run_test test_no_identities_is_a_noop
run_test test_materializes_identity_file_with_correct_permissions
run_test test_identity_file_round_trips_via_ssh_keygen
run_test test_container_tier_decode_is_encoding_agnostic_round_trips_via_ssh_keygen
run_test test_transport_encoding_raw_base64_encodes
run_test test_transport_encoding_base64_passes_through_unchanged
run_test test_transport_encoding_base64_strips_trailing_newline
run_test test_generate_env_vars_ssh_identities_index_alignment
run_test test_generate_env_vars_ssh_identities_missing_secret_aborts
run_test test_write_secrets_env_file_fail_closed_on_mktemp_failure
run_test test_yq_expr_handles_int_typed_field_without_dropping_identities
run_test test_ssh_config_include_is_first_line
run_test test_no_clobber_preserves_existing_config
run_test test_stanza_contains_identities_only_and_port
run_test test_two_identities_do_not_cross_pair
run_test test_idempotent_rerun_no_duplicate_include
run_test test_env_vars_unset_after_use
run_test test_no_key_material_in_output
run_test test_decode_failure_is_fail_loud_no_partial_file
run_test test_rejects_invalid_host_in_container
run_test test_rejects_invalid_user_in_container
run_test test_rejects_identity_file_with_comma_in_container

print_summary
