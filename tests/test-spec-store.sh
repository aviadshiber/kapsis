#!/usr/bin/env bash
#===============================================================================
# Test: Launch-spec persistence (scripts/lib/spec-store.sh)
#
# Verifies that spec_store_write produces the canonical
# ${KAPSIS_SPECS_DIR}/<agent_id>.md file for both --spec and --task modes,
# applies the size cap, refuses invalid agent_ids, and silently skips when
# no spec is provided (interactive mode).
#
# Quick test — no containers, no podman, no Kapsis launch required.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

SPEC_STORE_LIB="$KAPSIS_ROOT/scripts/lib/spec-store.sh"

# Per-test isolated temp dir to keep KAPSIS_SPECS_DIR scoped.
_setup_temp_specs_dir() {
    TMP_SPECS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-spec-store-test.XXXXXX")
    export KAPSIS_SPECS_DIR="$TMP_SPECS_DIR"
    # Re-source the library — guard variable means a second `source` won't
    # re-execute, but we explicitly clear it for tests so each call gets a
    # fresh KAPSIS_SPECS_DIR baked into the default.
    unset _KAPSIS_SPEC_STORE_LOADED
    # shellcheck source=/dev/null
    source "$SPEC_STORE_LIB"
}

_teardown_temp_specs_dir() {
    if [[ -n "${TMP_SPECS_DIR:-}" && -d "$TMP_SPECS_DIR" ]]; then
        rm -rf "$TMP_SPECS_DIR"
    fi
    unset TMP_SPECS_DIR
    unset KAPSIS_SPECS_DIR
}

#===============================================================================
# TEST CASES
#===============================================================================

test_writes_inline_task() {
    log_test "Testing spec_store_write --task writes inline task"
    _setup_temp_specs_dir

    spec_store_write "abc123" --task "fix the foo bar"
    local dest="$KAPSIS_SPECS_DIR/abc123.md"
    assert_true "[[ -f '$dest' ]]" "Spec file should exist"
    local content
    content="$(cat "$dest")"
    assert_equals "fix the foo bar" "$content" "File content matches inline task"

    _teardown_temp_specs_dir
}

test_writes_spec_file() {
    log_test "Testing spec_store_write --spec copies file content"
    _setup_temp_specs_dir

    local src
    src=$(mktemp "${TMPDIR:-/tmp}/spec-src.XXXXXX.md")
    printf '# DEV-42\n\nFix the bug.\n' > "$src"

    spec_store_write "agent42" --spec "$src"
    local dest="$KAPSIS_SPECS_DIR/agent42.md"
    assert_true "[[ -f '$dest' ]]" "Spec file should exist"
    local content
    content="$(cat "$dest")"
    assert_contains "$content" "DEV-42" "Persisted spec contains source header"
    assert_contains "$content" "Fix the bug" "Persisted spec contains source body"

    rm -f "$src"
    _teardown_temp_specs_dir
}

test_truncates_oversized_spec_file() {
    log_test "Testing 256 KB cap on --spec source files"
    _setup_temp_specs_dir

    local src
    src=$(mktemp "${TMPDIR:-/tmp}/big-spec.XXXXXX.md")
    # 300 KB of 'a' — over the 256 KB default cap.
    head -c 307200 /dev/zero | tr '\0' 'a' > "$src"

    spec_store_write "bigone" --spec "$src"
    local dest="$KAPSIS_SPECS_DIR/bigone.md"
    assert_true "[[ -f '$dest' ]]" "Spec file should exist"
    local size
    size=$(wc -c < "$dest" | tr -d ' ')
    # Should be exactly 256 KiB (262144 bytes).
    assert_equals "262144" "$size" "Persisted spec is truncated to 256 KB"

    rm -f "$src"
    _teardown_temp_specs_dir
}

test_silently_skips_when_no_spec_or_task() {
    log_test "Testing interactive mode (no --spec / --task) is a no-op"
    _setup_temp_specs_dir

    spec_store_write "interactive99"
    # No file should exist.
    local dest="$KAPSIS_SPECS_DIR/interactive99.md"
    assert_true "[[ ! -e '$dest' ]]" "No file written when neither --spec nor --task provided"

    _teardown_temp_specs_dir
}

test_rejects_missing_agent_id() {
    log_test "Testing missing agent_id returns error (exit 2)"
    _setup_temp_specs_dir

    local exit_code=0
    spec_store_write "" --task "anything" 2>/dev/null || exit_code=$?
    assert_equals "2" "$exit_code" "Missing agent_id returns exit 2"

    _teardown_temp_specs_dir
}

test_rejects_invalid_agent_id() {
    log_test "Testing invalid agent_id (path traversal) returns error"
    _setup_temp_specs_dir

    local exit_code=0
    spec_store_write "../etc/passwd" --task "evil" 2>/dev/null || exit_code=$?
    assert_equals "2" "$exit_code" "Path-traversal agent_id rejected"
    # Defense in depth: nothing should have been written outside KAPSIS_SPECS_DIR.
    assert_true "[[ ! -e '/etc/passwd.md' ]]" "No file leaked outside specs dir"

    _teardown_temp_specs_dir
}

test_overwrites_existing_spec() {
    log_test "Testing repeated writes overwrite the previous spec atomically"
    _setup_temp_specs_dir

    spec_store_write "rewrite" --task "first version"
    spec_store_write "rewrite" --task "second version"
    local dest="$KAPSIS_SPECS_DIR/rewrite.md"
    local content
    content="$(cat "$dest")"
    assert_equals "second version" "$content" "Second write overwrote first"

    _teardown_temp_specs_dir
}

test_spec_store_path_helper() {
    log_test "Testing spec_store_path computes canonical path"
    _setup_temp_specs_dir

    local path
    path="$(spec_store_path "abc123")"
    assert_equals "$KAPSIS_SPECS_DIR/abc123.md" "$path" "Path matches <specsDir>/<id>.md"

    _teardown_temp_specs_dir
}

test_file_permissions_restrictive() {
    log_test "Testing persisted spec is 0600 (no leak to other users)"
    _setup_temp_specs_dir

    spec_store_write "perm123" --task "private task"
    local dest="$KAPSIS_SPECS_DIR/perm123.md"
    local mode
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mode=$(stat -f "%Lp" "$dest")
    else
        mode=$(stat -c "%a" "$dest")
    fi
    assert_equals "600" "$mode" "Persisted spec has 0600 permissions"

    _teardown_temp_specs_dir
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo "Testing scripts/lib/spec-store.sh"

    run_test test_writes_inline_task
    run_test test_writes_spec_file
    run_test test_truncates_oversized_spec_file
    run_test test_silently_skips_when_no_spec_or_task
    run_test test_rejects_missing_agent_id
    run_test test_rejects_invalid_agent_id
    run_test test_overwrites_existing_spec
    run_test test_spec_store_path_helper
    run_test test_file_permissions_restrictive

    print_summary
}

main "$@"
