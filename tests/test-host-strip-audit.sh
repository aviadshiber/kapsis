#!/usr/bin/env bash
#===============================================================================
# Test: Host-Side Commit-Strip Audit Sidecar (Issue #407)
#
# Verifies that strip_kapsis_injections() in post-container-git.sh records
# verified gist strips to the non-chained host-event sidecar written by
# audit_log_host_event() in scripts/lib/audit.sh:
#
#   1. A verified strip (audit enabled) appends one host_commit_mutation line
#      per mutated file with the expected detail fields.
#   2. A strip across both CLAUDE.md and AGENTS.md emits one line per file, and
#      the per-file rewrite guard leaves an unmutated file byte-identical
#      (regression test for #413's global-vs-per-file rewrite condition).
#   3. Audit disabled is a true no-op — no sidecar file is created.
#   4. A suspicious-only run (SHA mismatch) emits nothing.
#   5. No sentinels / no proof file emits nothing.
#   6. A verified strip does not disturb the container session's hash chain.
#   7. audit_log_host_event() unit behavior (perms, unknown fallback, secret
#      sanitization, append-not-truncate).
#   8. audit-report.sh renders the sidecar in text and JSON, with a clean
#      fallback when no sidecar exists.
#===============================================================================
# shellcheck disable=SC1090,SC1091

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/lib/compat.sh"
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
source "$KAPSIS_ROOT/scripts/lib/json-utils.sh"
log_init "test-host-strip-audit"
source "$KAPSIS_ROOT/scripts/post-container-git.sh"
source "$KAPSIS_ROOT/scripts/lib/audit.sh"

AGENT_ID="test-host-strip-agent"
TEST_TMPDIR=""
TEST_WORKTREE=""
TEST_AUDIT_DIR=""
_ORIG_TMPDIR="${TMPDIR:-/tmp}"
_ORIG_AUDIT_DIR="${KAPSIS_AUDIT_DIR:-}"
_ORIG_AUDIT_ENABLED="${KAPSIS_AUDIT_ENABLED:-}"

setup_test_env() {
    TEST_TMPDIR=$(mktemp -d "${_ORIG_TMPDIR}/kapsis-test-host-tmp-XXXXXX")
    TEST_WORKTREE=$(mktemp -d "${_ORIG_TMPDIR}/kapsis-test-host-wt-XXXXXX")
    TEST_AUDIT_DIR=$(mktemp -d "${_ORIG_TMPDIR}/kapsis-test-host-audit-XXXXXX")
    # strip_kapsis_injections reads the proof file from $TMPDIR.
    export TMPDIR="$TEST_TMPDIR"
    export KAPSIS_AUDIT_DIR="$TEST_AUDIT_DIR"
}

cleanup_test_env() {
    export TMPDIR="$_ORIG_TMPDIR"
    if [[ -n "$_ORIG_AUDIT_DIR" ]]; then
        export KAPSIS_AUDIT_DIR="$_ORIG_AUDIT_DIR"
    else
        unset KAPSIS_AUDIT_DIR
    fi
    if [[ -n "$_ORIG_AUDIT_ENABLED" ]]; then
        export KAPSIS_AUDIT_ENABLED="$_ORIG_AUDIT_ENABLED"
    else
        unset KAPSIS_AUDIT_ENABLED
    fi
    [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
    [[ -n "$TEST_WORKTREE" && -d "$TEST_WORKTREE" ]] && rm -rf "$TEST_WORKTREE"
    [[ -n "$TEST_AUDIT_DIR" && -d "$TEST_AUDIT_DIR" ]] && rm -rf "$TEST_AUDIT_DIR"
    TEST_TMPDIR=""
    TEST_WORKTREE=""
    TEST_AUDIT_DIR=""
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

host_events_file() {
    echo "${TEST_AUDIT_DIR}/${AGENT_ID}-host-events.jsonl"
}

#-------------------------------------------------------------------------------
test_verified_strip_emits_one_event() {
    log_test "Verified strip (audit enabled) appends one host_commit_mutation line"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true

    local block
    block=$(make_sentinel_block)
    make_proof_file "$block" > /dev/null
    local expected_hash
    expected_hash=$(printf '%s' "$block" | sha256_hash)

    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
# My Project

Some existing content.

---

${block}
EOF

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    local hf
    hf=$(host_events_file)
    assert_file_exists "$hf" "Host-events sidecar must be created"

    # Guard against the file-nuking regression: surrounding content must survive.
    assert_true "grep -q 'existing content' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Non-injected content must be preserved after the strip"
    assert_false "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Sentinel block must be removed"

    local line_count
    line_count=$(wc -l < "$hf" | tr -d ' ')
    assert_equals "1" "$line_count" "Exactly one host event line expected"

    local line
    line=$(head -1 "$hf")
    assert_equals "host_commit_mutation" "$(json_get_string "$line" "event_type")" \
        "event_type must be host_commit_mutation"
    assert_equals "strip_kapsis_injections" "$(json_get_string "$line" "tool_name")" \
        "tool_name must be strip_kapsis_injections"
    assert_equals "CLAUDE.md" "$(json_get_string "$line" "file")" \
        "detail.file must be CLAUDE.md"
    assert_equals "1" "$(json_get_number "$line" "blocks_stripped")" \
        "detail.blocks_stripped must be 1"
    assert_equals "verified" "$(json_get_string "$line" "proof_outcome")" \
        "detail.proof_outcome must be verified"
    assert_equals "$expected_hash" "$(json_get_string "$line" "removed_sha256")" \
        "detail.removed_sha256 must equal the proof file hash"

    local bytes_removed
    bytes_removed=$(json_get_number "$line" "bytes_removed")
    assert_true "[[ '$bytes_removed' -gt 0 ]]" "detail.bytes_removed must be > 0"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_strip_both_files_emits_two_events() {
    log_test "Verified strip in both CLAUDE.md and AGENTS.md emits one event per file"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true

    local block
    block=$(make_sentinel_block)
    make_proof_file "$block" > /dev/null

    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
# Claude
${block}
EOF
    cat > "${TEST_WORKTREE}/AGENTS.md" <<EOF
# Agents
${block}
EOF

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_false "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/CLAUDE.md'" \
        "CLAUDE.md sentinel must be removed"
    assert_false "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/AGENTS.md'" \
        "AGENTS.md sentinel must be removed"

    local hf
    hf=$(host_events_file)
    local line_count
    line_count=$(wc -l < "$hf" | tr -d ' ')
    assert_equals "2" "$line_count" "Exactly two host event lines expected (one per file)"

    assert_true "grep -q '\"file\":\"CLAUDE.md\"' '$hf'" "Event for CLAUDE.md expected"
    assert_true "grep -q '\"file\":\"AGENTS.md\"' '$hf'" "Event for AGENTS.md expected"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_per_file_rewrite_guard_regression() {
    log_test "Per-file guard: an unmutated file stays byte-identical when another file strips (#413 regression)"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true

    # CLAUDE.md gets a VERIFIED block (matches proof → stripped).
    local verified_block
    verified_block=$(make_sentinel_block)
    make_proof_file "$verified_block" > /dev/null

    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
# Claude
${verified_block}
EOF

    # AGENTS.md gets a SUSPICIOUS block (SHA mismatch → preserved) followed by
    # trailing blank lines. The old code (gating on the GLOBAL stripped_count)
    # would rewrite AGENTS.md because CLAUDE.md stripped, and the trailing-blank
    # trim would change its bytes. The per-file guard must leave it untouched.
    printf '%s\n%s\n%s\n%s\n\n\n' \
        "# Agents" \
        "<!-- KAPSIS_GIST_BEGIN -->" \
        "rogue content not matching the proof" \
        "<!-- KAPSIS_GIST_END -->" \
        > "${TEST_WORKTREE}/AGENTS.md"

    local agents_before
    agents_before=$(mktemp "${TEST_TMPDIR}/agents-before-XXXXXX")
    cp "${TEST_WORKTREE}/AGENTS.md" "$agents_before"

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_false "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/CLAUDE.md'" \
        "CLAUDE.md verified block must be stripped"
    assert_true "cmp -s '$agents_before' '${TEST_WORKTREE}/AGENTS.md'" \
        "AGENTS.md must be byte-identical — no spurious rewrite from CLAUDE.md's strip"
    assert_true "grep -q 'rogue content' '${TEST_WORKTREE}/AGENTS.md'" \
        "AGENTS.md suspicious block must be preserved"

    # Only CLAUDE.md changed bytes → exactly one host event.
    local hf
    hf=$(host_events_file)
    local line_count
    line_count=$(wc -l < "$hf" | tr -d ' ')
    assert_equals "1" "$line_count" "Only the mutated file (CLAUDE.md) emits an event"
    assert_equals "CLAUDE.md" "$(json_get_string "$(head -1 "$hf")" "file")" \
        "The single event must be for CLAUDE.md"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_audit_disabled_is_noop() {
    log_test "Audit disabled: strip works and returns 0, no sidecar file created"
    setup_test_env
    # KAPSIS_AUDIT_ENABLED unset → falls back to KAPSIS_DEFAULT_AUDIT_ENABLED=false
    unset KAPSIS_AUDIT_ENABLED

    local block
    block=$(make_sentinel_block)
    make_proof_file "$block" > /dev/null

    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
# Project
${block}
EOF

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"
    local rc=$?
    assert_equals "0" "$rc" "strip_kapsis_injections must return 0"

    assert_false "grep -q 'KAPSIS_GIST_BEGIN' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Block must still be stripped even with audit disabled"
    assert_file_not_exists "$(host_events_file)" \
        "No sidecar file must be created when audit is disabled"

    # Explicitly-false variant.
    export KAPSIS_AUDIT_ENABLED=false
    cat > "${TEST_WORKTREE}/AGENTS.md" <<EOF
# Agents
${block}
EOF
    make_proof_file "$block" > /dev/null
    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"
    assert_file_not_exists "$(host_events_file)" \
        "No sidecar file with KAPSIS_AUDIT_ENABLED=false"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_suspicious_only_emits_nothing() {
    log_test "Suspicious-only run (SHA mismatch) emits no host event"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true

    local legit_block
    legit_block=$(make_sentinel_block)
    make_proof_file "$legit_block" > /dev/null

    cat > "${TEST_WORKTREE}/CLAUDE.md" <<'EOF'
# Project

<!-- KAPSIS_GIST_BEGIN -->
rogue content the agent wants to hide
<!-- KAPSIS_GIST_END -->
EOF

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_true "grep -q 'rogue content' '${TEST_WORKTREE}/CLAUDE.md'" \
        "Suspicious block must be preserved"
    assert_file_not_exists "$(host_events_file)" \
        "No host event when zero bytes changed"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_no_sentinels_emits_nothing() {
    log_test "No sentinels / no proof file: no-op, emits nothing"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true
    # No proof file written.

    printf '# Clean project\n\nNo injections here.\n' > "${TEST_WORKTREE}/CLAUDE.md"

    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_file_not_exists "$(host_events_file)" \
        "No host event when there are no sentinel blocks"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_chain_non_interference() {
    log_test "A verified strip does not disturb the container session hash chain"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true

    # Build a real 3-event session chain with the production hash formula.
    audit_init "$AGENT_ID" "test-project" "claude-cli"
    audit_log_event "shell_command" "Bash" '{"command":"ls"}'
    audit_log_event "session_end" "audit_finalize" '{"action":"session_end"}'
    local session_file="$_KAPSIS_AUDIT_FILE"

    assert_file_exists "$session_file" "Session audit file must exist"
    assert_true "audit_verify_chain '$session_file'" \
        "Freshly written chain must verify before the strip"

    local session_before
    session_before=$(mktemp "${TEST_TMPDIR}/session-before-XXXXXX")
    cp "$session_file" "$session_before"

    # Run a verified strip (writes to the sidecar, must not touch the chain).
    local block
    block=$(make_sentinel_block)
    make_proof_file "$block" > /dev/null
    cat > "${TEST_WORKTREE}/CLAUDE.md" <<EOF
# Project
${block}
EOF
    strip_kapsis_injections "$TEST_WORKTREE" "$AGENT_ID"

    assert_true "cmp -s '$session_before' '$session_file'" \
        "Session .audit.jsonl must be byte-identical after the strip"
    assert_true "audit_verify_chain '$session_file'" \
        "Chain must still verify after the strip"

    # And the sidecar exists but has a distinct, non-chained filename.
    assert_file_exists "$(host_events_file)" "Sidecar must be written"
    assert_false "[[ '$(host_events_file)' == *.audit.jsonl ]]" \
        "Sidecar filename must not match the chained *.audit.jsonl pattern"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_audit_log_host_event_unit() {
    log_test "audit_log_host_event: perms, unknown fallback, sanitization, append"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true

    # Empty agent_id argument falls back to the 'unknown'-keyed filename.
    audit_log_host_event "" "host_commit_mutation" "strip_kapsis_injections" '{"action":"noop"}'
    assert_file_exists "${TEST_AUDIT_DIR}/unknown-host-events.jsonl" \
        "Empty agent_id must key the file as 'unknown'"

    # Directory 700, file 600.
    local dir_perm
    dir_perm=$(get_file_mode "$TEST_AUDIT_DIR")
    assert_equals "700" "$dir_perm" "Audit dir must be mode 700"
    local file_perm
    file_perm=$(get_file_mode "${TEST_AUDIT_DIR}/unknown-host-events.jsonl")
    assert_equals "600" "$file_perm" "Sidecar file must be mode 600"

    # Secret sanitization: a Bearer token in detail must be masked.
    audit_log_host_event "$AGENT_ID" "host_commit_mutation" "strip_kapsis_injections" \
        '{"note":"Bearer sk-supersecret-value-123"}'
    local hf
    hf=$(host_events_file)
    assert_file_exists "$hf" "Sidecar for the real agent must exist"
    assert_true "grep -q 'MASKED' '$hf'" "Bearer token must be masked by sanitize_secrets"
    assert_false "grep -q 'sk-supersecret-value-123' '$hf'" \
        "Raw secret must not appear in the sidecar"

    # Two sequential calls append (no truncation).
    audit_log_host_event "$AGENT_ID" "host_commit_mutation" "strip_kapsis_injections" '{"action":"second"}'
    local line_count
    line_count=$(wc -l < "$hf" | tr -d ' ')
    assert_equals "2" "$line_count" "Two calls must append two lines"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
test_audit_report_rendering() {
    log_test "audit-report.sh renders the host-events sidecar in text and JSON"
    setup_test_env
    export KAPSIS_AUDIT_ENABLED=true

    # Build a session audit file for the same agent-id.
    audit_init "$AGENT_ID" "test-project" "claude-cli"
    audit_log_event "session_end" "audit_finalize" '{"action":"session_end"}'
    local session_file="$_KAPSIS_AUDIT_FILE"

    # Emit one host event for the same agent-id.
    audit_log_host_event "$AGENT_ID" "host_commit_mutation" "strip_kapsis_injections" \
        '{"action":"gist_injection_strip","file":"CLAUDE.md","blocks_stripped":1,"bytes_removed":57,"removed_sha256":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","proof_outcome":"verified","suspicious_blocks_preserved":0}'

    local report="$KAPSIS_ROOT/scripts/audit-report.sh"

    # Text output includes the section, file, and bytes.
    local text_out
    text_out=$(KAPSIS_AUDIT_DIR="$TEST_AUDIT_DIR" NO_COLOR=1 "$report" "$session_file" --format text)
    assert_contains "$text_out" "Host-Side Commit Mutations" "Text report must contain the host section header"
    assert_contains "$text_out" "CLAUDE.md" "Text report must name the mutated file"
    assert_contains "$text_out" "57" "Text report must show bytes_removed"

    # JSON output has a host_events array with one parseable element.
    local json_out
    json_out=$(KAPSIS_AUDIT_DIR="$TEST_AUDIT_DIR" NO_COLOR=1 "$report" "$session_file" --format json)
    assert_contains "$json_out" '"host_events"' "JSON report must contain a host_events key"
    local host_len
    host_len=$(printf '%s' "$json_out" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["host_events"]))')
    assert_equals "1" "$host_len" "host_events array must have exactly one element"

    # No sidecar → text fallback + json [].
    rm -f "$(host_events_file)"
    local text_empty
    text_empty=$(KAPSIS_AUDIT_DIR="$TEST_AUDIT_DIR" NO_COLOR=1 "$report" "$session_file" --format text)
    assert_contains "$text_empty" "No host events recorded." "Text fallback when no sidecar"
    local json_empty
    json_empty=$(KAPSIS_AUDIT_DIR="$TEST_AUDIT_DIR" NO_COLOR=1 "$report" "$session_file" --format json)
    local host_len_empty
    host_len_empty=$(printf '%s' "$json_empty" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["host_events"]))')
    assert_equals "0" "$host_len_empty" "host_events must be [] when no sidecar exists"

    cleanup_test_env
}

#-------------------------------------------------------------------------------
print_test_header "Host-Side Commit-Strip Audit Sidecar (Issue #407)"

run_test test_verified_strip_emits_one_event        "Verified strip emits one host event"
run_test test_strip_both_files_emits_two_events     "Both files stripped emit two events"
run_test test_per_file_rewrite_guard_regression     "Per-file rewrite guard (#413 regression)"
run_test test_audit_disabled_is_noop                "Audit disabled is a true no-op"
run_test test_suspicious_only_emits_nothing         "Suspicious-only emits nothing"
run_test test_no_sentinels_emits_nothing            "No sentinels emits nothing"
run_test test_chain_non_interference                "Chain non-interference"
run_test test_audit_log_host_event_unit             "audit_log_host_event unit behavior"
run_test test_audit_report_rendering                "audit-report.sh renders the sidecar"

print_summary
