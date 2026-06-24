#!/usr/bin/env bash
#===============================================================================
# Test: Gist Injection Provenance (Issue #408)
#
# Verifies that strip_kapsis_injections() in post-container-git.sh:
# 1. Strips sentinel blocks whose SHA-256 matches the host-side proof file
# 2. Preserves (and warns about) blocks that do NOT match — rogue injections
# 3. Is a no-op when no sentinels are present
# 4. Is a no-op when no proof file exists (degrades gracefully)
# 5. Removes the proof file after first use (one-time token)
#
# Also verifies inject_gist_instructions() wraps content in sentinels.
#===============================================================================
# shellcheck disable=SC1090

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/lib/compat.sh"
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-gist-provenance"
source "$KAPSIS_ROOT/scripts/post-container-git.sh"

AGENT_ID="test-provenance-agent"
TEST_TMPDIR=""
TEST_WORKTREE=""
_ORIG_TMPDIR="${TMPDIR:-/tmp}"

setup_test_env() {
    TEST_TMPDIR=$(mktemp -d "${_ORIG_TMPDIR}/kapsis-test-gist-prov-XXXXXX")
    TEST_WORKTREE=$(mktemp -d "${_ORIG_TMPDIR}/kapsis-test-gist-wt-XXXXXX")
    # Override TMPDIR so strip_kapsis_injections writes the proof file here
    export TMPDIR="$TEST_TMPDIR"
}

cleanup_test_env() {
    export TMPDIR="$_ORIG_TMPDIR"
    [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
    [[ -n "$TEST_WORKTREE" && -d "$TEST_WORKTREE" ]] && rm -rf "$TEST_WORKTREE"
    TEST_TMPDIR=""
    TEST_WORKTREE=""
}

make_proof_file() {
    local block="$1"
    local proof_file="${TEST_TMPDIR}/kapsis-${AGENT_ID}-gist-proof"
    printf '%s' "$block" | sha256_hash > "$proof_file"
    echo "$proof_file"
}

make_sentinel_block() {
    printf '%s\n%s\n%s' \
        "<!-- KAPSIS_GIST_BEGIN -->" \
        "# Kapsis Activity Gist" \
        "<!-- KAPSIS_GIST_END -->"
}

#-------------------------------------------------------------------------------
test_strip_removes_verified_block() {
    log_test "Verified sentinel block is stripped and content preserved"
    setup_test_env
    local block
    block=$(make_sentinel_block)

    make_proof_file "$block" > /dev/null

    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
# My Project

Some existing content.

---

${block}
EOF

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_false "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Sentinel block should be removed after strip"
    assert_true "grep -q 'existing content' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Non-injected content should be preserved"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_strip_preserves_rogue_block() {
    log_test "Rogue block (SHA mismatch) is preserved and flagged, not stripped"
    setup_test_env
    local legit_block
    legit_block=$(make_sentinel_block)
    make_proof_file "$legit_block" > /dev/null

    # Agent replaces legit block with rogue content using same markers
    cat > "${TEST_WORKTREE}/CLAUDE.md" <<'EOF'
# My Project

<!-- KAPSIS_GIST_BEGIN -->
rogue content the agent wants to hide
<!-- KAPSIS_GIST_END -->
EOF

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_true "grep -q 'rogue content' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Rogue block must NOT be stripped — SHA mismatch"
    assert_true "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Sentinel markers must survive when block is rogue"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_strip_noop_without_sentinels() {
    log_test "strip_kapsis_injections is a no-op when no sentinels are present"
    setup_test_env
    make_proof_file "$(make_sentinel_block)" > /dev/null

    printf '# Clean project\n\nNo injections here.\n' > "${TEST_WORKTREE}/CLAUDE.md"
    local before
    before=$(cat "${TEST_WORKTREE}/CLAUDE.md")

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    local after
    after=$(cat "${TEST_WORKTREE}/CLAUDE.md")
    assert_equals "$before" "$after" "File must be unchanged when no sentinels present"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_strip_noop_without_proof_file() {
    log_test "strip_kapsis_injections degrades gracefully when proof file is missing"
    setup_test_env
    # No proof file written — simulates KAPSIS_INJECT_GIST=false or missing host injection

    local block
    block=$(make_sentinel_block)
    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
# Project

${block}
EOF

    # Should not strip anything without proof (expected_sha256 is empty)
    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_true "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Block must be preserved when no proof file exists"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_proof_file_one_time_use() {
    log_test "Proof file is deleted after first strip (prevents session replay)"
    setup_test_env
    local block
    block=$(make_sentinel_block)
    local proof_file
    proof_file=$(make_proof_file "$block")

    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
${block}
EOF

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_false "[[ -f '$proof_file' ]]" \
        "Proof file must be deleted after first use"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_inject_gist_instructions_uses_sentinels() {
    log_test "inject_gist_instructions wraps appended content in KAPSIS_GIST_BEGIN/END sentinels"
    local gist_instructions="$KAPSIS_ROOT/scripts/lib/gist-instructions.md"
    [[ -f "$gist_instructions" ]] || {
        skip_test "test_inject_gist_instructions_uses_sentinels" "gist-instructions.md not found"
        return 0
    }

    setup_test_env
    local ws="${TEST_WORKTREE}"
    printf '# Project\n' > "${ws}/CLAUDE.md"

    # Source inject-status-hooks.sh in a subshell to avoid polluting test globals,
    # exporting the workspace variables before sourcing.
    (
        export KAPSIS_INJECT_GIST=true
        export KAPSIS_SANDBOX_MODE=worktree
        export KAPSIS_WORKSPACE="$ws"
        export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"
        export KAPSIS_STATUS_AGENT_ID="$AGENT_ID"
        source "$KAPSIS_ROOT/scripts/lib/inject-status-hooks.sh"
        inject_gist_instructions
    )

    assert_true "grep -q 'KAPSIS_GIST_BEGIN' '${ws}/CLAUDE.md'" \
        "inject_gist_instructions must add KAPSIS_GIST_BEGIN sentinel"
    assert_true "grep -q 'KAPSIS_GIST_END' '${ws}/CLAUDE.md'" \
        "inject_gist_instructions must add KAPSIS_GIST_END sentinel"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
print_test_header "Gist Injection Provenance (Issue #408)"

run_test test_strip_removes_verified_block    "Verified sentinel block is stripped"
run_test test_strip_preserves_rogue_block     "Rogue block (SHA mismatch) is preserved and flagged"
run_test test_strip_noop_without_sentinels    "No-op when file contains no sentinels"
run_test test_strip_noop_without_proof_file   "No-op (graceful degrade) when proof file missing"
run_test test_proof_file_one_time_use         "Proof file is deleted after first use"
run_test test_inject_gist_instructions_uses_sentinels "inject_gist_instructions wraps in sentinels"

print_summary
