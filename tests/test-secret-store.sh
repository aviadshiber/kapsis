#!/usr/bin/env bash
#===============================================================================
# Test: Secret Store Library (secret-store.sh)
#
# Unit tests for scripts/lib/secret-store.sh — the cross-platform credential
# retrieval layer (macOS Keychain / Linux secret-tool).
#
# The sibling test-secret-store-injection.sh covers the injection feature;
# this file covers the library API:
#   - detect_os()
#   - query_secret_store(service, account)
#   - query_secret_store_with_fallbacks(service, accounts, var_name)
#   - account masking in debug logs
#   - graceful behavior when the backend binary is absent
#
# Category: security
# Container required: No (uses PATH shims to mock `security` / `secret-tool`)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

SECRET_STORE_LIB="$KAPSIS_ROOT/scripts/lib/secret-store.sh"

# Working dir for per-test PATH shims
SHIM_DIR=""

#===============================================================================
# HELPERS
#===============================================================================

# Set up a shim directory that we prepend to PATH so we can fake `security` or
# `secret-tool`. Each shim's behavior is controlled by a sibling file
# <name>.out / <name>.rc, so tests don't have to regenerate the script body.
setup_shims() {
    SHIM_DIR=$(mktemp -d -t kapsis-secret-store-XXXXXX)
    export ORIGINAL_PATH="$PATH"
    export PATH="$SHIM_DIR:$PATH"
}

teardown_shims() {
    if [[ -n "${ORIGINAL_PATH:-}" ]]; then
        export PATH="$ORIGINAL_PATH"
    fi
    if [[ -n "$SHIM_DIR" && -d "$SHIM_DIR" ]]; then
        rm -rf "$SHIM_DIR"
    fi
    SHIM_DIR=""
}

# make_shim <name> <rc> <stdout>
# Writes a small shim script that records its argv to <name>.calls, prints
# <stdout>, and exits <rc>.
make_shim() {
    local name="$1"
    local rc="$2"
    local out="${3:-}"

    local shim="$SHIM_DIR/$name"
    cat > "$shim" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_DIR/${name}.calls"
printf '%s' "$out"
exit $rc
EOF
    chmod +x "$shim"
    : > "$SHIM_DIR/${name}.calls"
}

remove_shim() {
    local name="$1"
    rm -f "$SHIM_DIR/$name" "$SHIM_DIR/${name}.calls"
}

# Source the library fresh. The guard `_KAPSIS_SECRET_STORE_LOADED` means
# re-sourcing is a no-op inside the same shell, so to re-source we unset it.
source_lib() {
    unset _KAPSIS_SECRET_STORE_LOADED 2>/dev/null || true
    # shellcheck source=../scripts/lib/secret-store.sh
    source "$SECRET_STORE_LIB"
}

#===============================================================================
# detect_os() TESTS
#===============================================================================

test_detect_os_returns_known_value() {
    log_test "detect_os: returns macos, linux, or unknown"

    source_lib
    local result
    result=$(detect_os)

    # Assert the value is one of the three documented outcomes
    case "$result" in
        macos|linux|unknown) : ;;
        *)
            _log_failure "detect_os returned unexpected value" "Got: $result"
            return 1
            ;;
    esac
}

test_detect_os_matches_uname() {
    log_test "detect_os: matches the running platform"

    source_lib
    local result
    result=$(detect_os)

    case "$(uname -s)" in
        Darwin*) assert_equals "macos" "$result" "Darwin must map to macos" ;;
        Linux*)  assert_equals "linux" "$result" "Linux must map to linux" ;;
        *)       assert_equals "unknown" "$result" "Other platforms must map to unknown" ;;
    esac
}

#===============================================================================
# query_secret_store() TESTS — Linux path
#===============================================================================

test_query_linux_success() {
    log_test "query_secret_store: returns value when secret-tool succeeds"

    # Only meaningful on Linux; skip on macOS (uses `security`, not `secret-tool`)
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    make_shim secret-tool 0 "hunter2"

    source_lib
    local value
    value=$(query_secret_store "gh-api" "alice")

    assert_equals "hunter2" "$value" "Should return the value produced by secret-tool"
    assert_file_contains "$SHIM_DIR/secret-tool.calls" "service gh-api account alice" \
        "secret-tool should be invoked with service + account arguments"
}

test_query_linux_no_account() {
    log_test "query_secret_store: invokes secret-tool with service only when account is empty"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    make_shim secret-tool 0 "only-service"
    source_lib

    local value
    value=$(query_secret_store "gh-api")

    assert_equals "only-service" "$value" "Should return the service-only lookup value"
    # The service-only branch does NOT pass an 'account' argument
    assert_file_contains "$SHIM_DIR/secret-tool.calls" "service gh-api" \
        "secret-tool should be invoked with service"
    assert_file_not_contains "$SHIM_DIR/secret-tool.calls" "account" \
        "secret-tool should not receive 'account' when none was passed"
}

test_query_linux_missing_credential_nonzero_exit() {
    log_test "query_secret_store: returns non-zero and empty stdout when credential is missing"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    # secret-tool exits 1 when the credential is not found
    make_shim secret-tool 1 ""
    source_lib

    set +e
    local value
    value=$(query_secret_store "gh-api" "bob")
    local rc=$?
    set -e

    assert_equals "" "$value" "Should produce empty stdout when secret missing"
    # Non-zero propagation from secret-tool
    if [[ $rc -eq 0 ]]; then
        _log_failure "Expected non-zero exit when credential is missing" "Got: $rc"
        return 1
    fi
}

test_query_linux_missing_binary_warns_and_fails() {
    log_test "query_secret_store: warns and returns non-zero when secret-tool is absent"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    # Deliberately do NOT create a secret-tool shim. We must still allow the
    # standard binaries the lib relies on (uname, etc.) to resolve, so we
    # explicitly shadow just `secret-tool` with a missing shim: nothing to
    # create — but we must also guarantee no real `secret-tool` is earlier in
    # PATH. Achieve that by moving SHIM_DIR to the front (already done) AND
    # dropping any directories that could contain a real secret-tool. We keep
    # PATH pointing at common tool locations so `uname` / `command -v` work.
    # /usr/bin and /bin are present on every supported Linux target; macOS has
    # them too but this test only runs on Linux.
    export PATH="$SHIM_DIR:/usr/bin:/bin"

    source_lib

    set +e
    local stderr_capture
    stderr_capture=$(query_secret_store "gh-api" "alice" 2>&1 1>/dev/null)
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        _log_failure "Expected non-zero exit when secret-tool is absent" "Got: $rc"
        return 1
    fi
    assert_contains "$stderr_capture" "secret-tool not found" \
        "Should emit a WARN about missing secret-tool"
}

#===============================================================================
# query_secret_store_with_fallbacks() TESTS (Linux)
#===============================================================================

test_fallbacks_single_account_backward_compat() {
    log_test "query_secret_store_with_fallbacks: single account (no comma) delegates to query_secret_store"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    make_shim secret-tool 0 "single"
    source_lib

    local value
    value=$(query_secret_store_with_fallbacks "svc" "only-account" "TOKEN")
    assert_equals "single" "$value" "Single-account path should return the value"
}

test_fallbacks_tries_accounts_in_order() {
    log_test "query_secret_store_with_fallbacks: tries accounts left-to-right and stops on first hit"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    # Dynamic shim: succeeds only for account=third; fails for others.
    cat > "$SHIM_DIR/secret-tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$0.calls"
# Arguments are: lookup service <svc> account <acct>
account=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "account" ]]; then
        shift
        account="${1:-}"
    fi
    shift
done
case "$account" in
    third)  printf '%s' "found-on-third"; exit 0 ;;
    *)      exit 1 ;;
esac
EOF
    chmod +x "$SHIM_DIR/secret-tool"
    : > "$SHIM_DIR/secret-tool.calls"

    source_lib

    local value
    value=$(query_secret_store_with_fallbacks "svc" "first,second,third,fourth" "TOKEN")
    assert_equals "found-on-third" "$value" "Should return hit from 'third'"

    local calls_file="$SHIM_DIR/secret-tool.calls"
    # Expect exactly first, second, third calls — the 'fourth' attempt must not happen
    local line1 line2 line3 line4
    line1=$(sed -n '1p' "$calls_file")
    line2=$(sed -n '2p' "$calls_file")
    line3=$(sed -n '3p' "$calls_file")
    line4=$(sed -n '4p' "$calls_file" || true)

    assert_contains "$line1" "account first"  "1st call must use 'first'"
    assert_contains "$line2" "account second" "2nd call must use 'second'"
    assert_contains "$line3" "account third"  "3rd call must use 'third'"
    assert_equals  "" "$line4" "Must not try 'fourth' after hit on 'third'"
}

test_fallbacks_returns_nonzero_when_all_fail() {
    log_test "query_secret_store_with_fallbacks: returns non-zero when every account misses"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    make_shim secret-tool 1 ""
    source_lib

    set +e
    local value
    value=$(query_secret_store_with_fallbacks "svc" "a,b,c" "TOKEN")
    local rc=$?
    set -e

    assert_equals "" "$value" "Output must be empty when no account has the secret"
    if [[ $rc -eq 0 ]]; then
        _log_failure "Expected non-zero exit when all accounts miss" "Got: $rc"
        return 1
    fi
}

test_fallbacks_trims_whitespace_in_account_list() {
    log_test "query_secret_store_with_fallbacks: trims whitespace around account names"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    cat > "$SHIM_DIR/secret-tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$0.calls"
account=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "account" ]]; then
        shift
        account="${1:-}"
    fi
    shift
done
case "$account" in
    target) printf '%s' "trimmed-hit"; exit 0 ;;
    *)      exit 1 ;;
esac
EOF
    chmod +x "$SHIM_DIR/secret-tool"
    : > "$SHIM_DIR/secret-tool.calls"

    source_lib

    # Spaces surrounding the account names must still resolve.
    local value
    value=$(query_secret_store_with_fallbacks "svc" " other , target , extra " "TOKEN")
    assert_equals "trimmed-hit" "$value" "Must match 'target' despite whitespace padding"
}

test_fallbacks_masks_account_in_debug_log() {
    log_test "query_secret_store_with_fallbacks: masks account names in debug output"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "non-Linux platform"
        return 0
    fi

    setup_shims
    trap teardown_shims RETURN

    make_shim secret-tool 0 "value"
    source_lib

    # Enable debug logging; the lib's log_debug fallback only writes when
    # KAPSIS_DEBUG is set.
    local stderr_capture
    stderr_capture=$(KAPSIS_DEBUG=1 query_secret_store_with_fallbacks \
        "svc" "first,alice-admin" "GH_TOKEN" 2>&1 1>/dev/null)

    # Mask format is "<first-3-chars>***" — only the first 3 chars should ever
    # be emitted, and the rest of the account must NOT leak.
    assert_contains "$stderr_capture" "fir***" \
        "Debug log should emit masked form 'fir***' for 'first'"
    assert_not_contains "$stderr_capture" "first," \
        "Debug log must not contain the unmasked account name"
}

#===============================================================================
# GUARD / DOUBLE-SOURCE TESTS (platform-agnostic)
#===============================================================================

test_double_source_protection() {
    log_test "secret-store.sh: double-sourcing does not redefine state"

    source_lib
    local first_value
    first_value="${_KAPSIS_SECRET_STORE_LOADED:-}"

    # Re-source WITHOUT unsetting the guard; must return cleanly.
    # shellcheck source=../scripts/lib/secret-store.sh
    source "$SECRET_STORE_LIB"

    local second_value
    second_value="${_KAPSIS_SECRET_STORE_LOADED:-}"

    assert_equals "1" "$first_value"  "First source should set guard to 1"
    assert_equals "1" "$second_value" "Second source must not clear/alter guard"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Secret Store Library (scripts/lib/secret-store.sh)"

    # detect_os
    run_test test_detect_os_returns_known_value
    run_test test_detect_os_matches_uname

    # query_secret_store (Linux path; macOS skips)
    run_test test_query_linux_success
    run_test test_query_linux_no_account
    run_test test_query_linux_missing_credential_nonzero_exit
    run_test test_query_linux_missing_binary_warns_and_fails

    # query_secret_store_with_fallbacks
    run_test test_fallbacks_single_account_backward_compat
    run_test test_fallbacks_tries_accounts_in_order
    run_test test_fallbacks_returns_nonzero_when_all_fail
    run_test test_fallbacks_trims_whitespace_in_account_list
    run_test test_fallbacks_masks_account_in_debug_log

    # Guard
    run_test test_double_source_protection

    print_summary
}

main "$@"
