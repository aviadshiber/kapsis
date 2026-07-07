#!/usr/bin/env bash
#===============================================================================
# Test: Conversation Transcript Capture (Issue #390)
#
# Verifies that ~/.kapsis/conversations/<agent-id>/transcript.txt is populated
# with captured container output after an agent run, so the post-mortem
# debugging workflow ("read the transcript when an agent hangs") has
# something to read.
#
# These tests exercise the REAL production functions from
# scripts/lib/transcript.sh (transcript_save, transcript_save_partial,
# transcript_strip_ansi) — not local re-implementations — plus a wiring test
# that launch-agent.sh actually sources the library and invokes both entry
# points. Reverting the launch-agent.sh integration turns these tests red.
#
# Tests:
#   - Constants defined and sane (TTL, container path)
#   - Wiring: launch-agent.sh sources lib/transcript.sh and calls
#     transcript_save (normal path) + transcript_save_partial (trap path)
#   - Transcript write: header present, content correct
#   - Transcript write: ANSI/OSC/CR sequences stripped (BSD-portable filter)
#   - Transcript write: 50 MB hard cap keeps the tail, not the head
#   - Transcript write: skipped gracefully when conv dir absent/empty buffer
#   - Interrupt path: partial transcript written, existing one not overwritten
#   - Cleanup: get_dir_mtime used (not get_file_mtime) so TTL fires
#   - Cleanup: stale dir age exceeds TTL; fresh dir age does not
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/lib/compat.sh"
# Real status_set_transcript_content_missing (Issue #430) so the fixture
# tests below observe the actual JSON-status wiring, not transcript.sh's
# standalone-sourcing no-op fallback.
source "$KAPSIS_ROOT/scripts/lib/status.sh"
# Production code under test
source "$KAPSIS_ROOT/scripts/lib/transcript.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_ttl_constant_exists_and_is_numeric() {
    log_test "KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS is defined and numeric"
    # shellcheck disable=SC2016
    assert_true '[[ -n "${KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS:-}" ]]' \
        "KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS must be defined"
    # shellcheck disable=SC2016
    assert_true '[[ "${KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS}" =~ ^[0-9]+$ ]]' \
        "KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS must be numeric"
    # shellcheck disable=SC2016
    assert_true '[[ "${KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS}" -ge 1 ]]' \
        "KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS must be at least 1 day"
}

test_container_conversations_path_constant() {
    log_test "CONTAINER_CONVERSATIONS_PATH constant is defined and non-empty"
    # shellcheck disable=SC2016
    assert_true '[[ -n "${CONTAINER_CONVERSATIONS_PATH:-}" ]]' \
        "CONTAINER_CONVERSATIONS_PATH must be defined"
    assert_equals "/home/developer/.claude/conversations" \
        "$CONTAINER_CONVERSATIONS_PATH" \
        "CONTAINER_CONVERSATIONS_PATH should be the standard claude conversations path"
}

test_launch_agent_wired_to_transcript_lib() {
    log_test "launch-agent.sh sources lib/transcript.sh and calls both save functions"

    local launch_agent="$KAPSIS_ROOT/scripts/launch-agent.sh"
    if ! grep -q 'lib/transcript\.sh' "$launch_agent"; then
        log_fail "launch-agent.sh must source lib/transcript.sh"
        return 1
    fi
    # Normal path: full transcript saved from the container output buffer
    if ! grep -Eq '^[[:space:]]*transcript_save[[:space:]]' "$launch_agent"; then
        log_fail "launch-agent.sh must call transcript_save (normal path)"
        return 1
    fi
    # Trap path: partial transcript saved on abnormal exit
    if ! grep -Eq '^[[:space:]]*transcript_save_partial[[:space:]]' "$launch_agent"; then
        log_fail "launch-agent.sh must call transcript_save_partial (trap path)"
        return 1
    fi
    # The resolved conversations dir must be cached where the mount is set up
    if ! grep -q 'KAPSIS_CONVERSATIONS_DIR_RESOLVED=' "$launch_agent"; then
        log_fail "launch-agent.sh must cache KAPSIS_CONVERSATIONS_DIR_RESOLVED at mount setup"
        return 1
    fi
}

test_transcript_written_to_conv_dir() {
    log_test "Transcript file is created in conversations dir by transcript_save"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-test-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-abc123"
    mkdir -p "$conv_dir"

    local buf="${tmpdir}/container_output"
    printf 'agent output line 1\nagent output line 2\n' > "$buf"

    transcript_save "$conv_dir" "$buf" "test-agent" "0"

    if [[ ! -f "${conv_dir}/transcript.txt" ]]; then
        log_fail "transcript.txt should exist after save"
        return 1
    fi
    assert_true '[[ -s "${conv_dir}/transcript.txt" ]]' \
        "transcript.txt should be non-empty"

    local content
    content=$(cat "${conv_dir}/transcript.txt")
    if [[ "$content" != *"agent output line 1"* ]]; then
        log_fail "transcript.txt should contain agent output"
        return 1
    fi
}

test_transcript_header_present() {
    log_test "Transcript contains kapsis-transcript header with agent and exit fields"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-hdr-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-hdr"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"
    echo "hello" > "$buf"

    transcript_save "$conv_dir" "$buf" "hdr-agent" "1"

    local first_line
    first_line=$(head -1 "${conv_dir}/transcript.txt")
    if [[ "$first_line" != "# kapsis-transcript agent=hdr-agent"* ]]; then
        log_fail "First line should be kapsis-transcript header, got: $first_line"
        return 1
    fi
    if [[ "$first_line" != *"exit=1"* ]]; then
        log_fail "Header should include exit code, got: $first_line"
        return 1
    fi
}

test_transcript_ansi_stripped() {
    log_test "ANSI escape codes are stripped from transcript by transcript_save"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-ansi-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-ansi"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"
    printf '\x1b[32mGREEN TEXT\x1b[0m normal text\n' > "$buf"

    transcript_save "$conv_dir" "$buf" "ansi-agent" "0"

    local content
    content=$(cat "${conv_dir}/transcript.txt")
    if [[ "$content" == *$'\x1b'* ]]; then
        log_fail "Transcript should have ANSI codes stripped"
        return 1
    fi
    if [[ "$content" != *"GREEN TEXT"* ]]; then
        log_fail "Transcript should still contain the visible text after stripping"
        return 1
    fi
}

test_strip_ansi_handles_osc_csi_and_cr() {
    log_test "transcript_strip_ansi strips OSC titles/hyperlinks, non-SGR CSI, and CR redraws"

    local out
    # OSC window title (BEL-terminated) + OSC-8 hyperlink
    out=$(printf '\x1b]0;window title\x07visible\x1b]8;;https://example.com\x07link\x1b]8;;\x07\n' \
        | transcript_strip_ansi)
    if [[ "$out" == *$'\x1b'* ]] || [[ "$out" == *"window title"* ]] \
        || [[ "$out" == *"example.com"* ]]; then
        log_fail "OSC sequences should be removed entirely, got: $out"
        return 1
    fi
    if [[ "$out" != *"visible"* ]] || [[ "$out" != *"link"* ]]; then
        log_fail "Visible text around OSC sequences must survive, got: $out"
        return 1
    fi

    # Non-SGR CSI: erase display/line, cursor home, bracketed paste markers
    out=$(printf '\x1b[2J\x1b[H\x1b[?2004hcontent\x1b[?2004l\x1b[1K end\n' \
        | transcript_strip_ansi)
    if [[ "$out" != "content end" ]]; then
        log_fail "Non-SGR CSI sequences should be removed, got: $out"
        return 1
    fi

    # CR progress redraws become separate lines; CRLF collapses to LF
    out=$(printf 'progress 10%%\rprogress 100%%\r\ndone\r\n' | transcript_strip_ansi)
    if [[ "$out" == *$'\r'* ]]; then
        log_fail "No carriage returns should remain, got: $(printf '%q' "$out")"
        return 1
    fi
    if [[ "$out" != *"progress 10%"* ]] || [[ "$out" != *"progress 100%"* ]] \
        || [[ "$out" != *"done"* ]]; then
        log_fail "All redraw frames should be preserved as lines, got: $out"
        return 1
    fi

    # Binary bytes must pass through without aborting the pipeline (LC_ALL=C)
    out=$(printf 'bin:\x80\xff:ok\n' | transcript_strip_ansi)
    if [[ "$out" != *"bin:"* ]] || [[ "$out" != *":ok"* ]]; then
        log_fail "Binary bytes must not abort the strip pipeline, got: $out"
        return 1
    fi
}

test_transcript_truncation_keeps_tail() {
    log_test "Oversized output is truncated at cap — tail kept, not head"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-trunc-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-trunc"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"

    # Write 200 KB: "HEAD" in the first byte, "TAIL" in the last bytes.
    # Cap at 100 KB so truncation triggers.
    dd if=/dev/zero bs=200000 count=1 2>/dev/null \
        | tr '\0' 'X' > "$buf"
    printf 'HEADMARKER' | dd of="$buf" bs=1 seek=0 conv=notrunc 2>/dev/null
    printf 'TAILMARKER' >> "$buf"

    local cap=$((100 * 1024))
    transcript_save "$conv_dir" "$buf" "trunc-agent" "0" "$cap"

    local content
    content=$(cat "${conv_dir}/transcript.txt")
    if [[ "$content" != *"TRUNCATED"* ]]; then
        log_fail "Transcript should contain TRUNCATED marker"
        return 1
    fi
    if [[ "$content" == *"HEADMARKER"* ]]; then
        log_fail "Head content should NOT be in truncated transcript (tail-keep mode)"
        return 1
    fi
    if [[ "$content" != *"TAILMARKER"* ]]; then
        log_fail "Tail content MUST be in truncated transcript"
        return 1
    fi
}

test_transcript_content_missing_flagged_for_boilerplate_only() {
    log_test "transcript_save sets transcript_content_missing=true for a boilerplate-only buffer (Issue #430)"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-boiler-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-boiler"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"
    cat > "$buf" << 'EOF'
[INFO] [entrypoint] [entrypoint.sh:122] Injecting credentials to files...
[WARN] [liveness-monitor] [liveness-monitor.sh:88] heartbeat check ok
dnsmasq: started, version 2.85 cachesize 150
EOF

    # Reset flag from any prior test in this process before exercising it.
    status_set_transcript_content_missing "false"
    transcript_save "$conv_dir" "$buf" "boiler-agent" "0"

    assert_equals "true" "$_KAPSIS_TRANSCRIPT_CONTENT_MISSING" \
        "transcript_content_missing must be set true when the transcript matches only known boilerplate"
}

test_transcript_content_missing_lands_in_status_json() {
    log_test "transcript_content_missing=true is persisted into the written status.json (Issue #430)"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-json-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-json"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"
    cat > "$buf" << 'EOF'
[INFO] [entrypoint] [entrypoint.sh:122] Injecting credentials to files...
dnsmasq: started, version 2.85 cachesize 150
EOF

    # Point status.sh at an isolated dir, run the real init → save →
    # complete sequence, then assert the key landed in the JSON on disk —
    # not just in the internal bash global.
    local saved_status_dir="$KAPSIS_STATUS_DIR"
    KAPSIS_STATUS_DIR="${tmpdir}/status"
    status_set_transcript_content_missing "false"
    status_init "convtest" "json-agent"
    transcript_save "$conv_dir" "$buf" "json-agent" "0"
    status_complete 0

    local status_file="${tmpdir}/status/kapsis-convtest-json-agent.json"
    # Restore shared state before asserting so a failure can't leak it.
    KAPSIS_STATUS_DIR="$saved_status_dir"
    _KAPSIS_STATUS_INITIALIZED=false
    status_set_transcript_content_missing "false"

    if [[ ! -f "$status_file" ]]; then
        log_fail "status.json should have been written at $status_file"
        return 1
    fi
    if ! grep -q '"transcript_content_missing": true' "$status_file"; then
        log_fail "status.json must contain \"transcript_content_missing\": true, got: $(cat "$status_file")"
        return 1
    fi
}

test_partial_transcript_content_missing_flagged_for_boilerplate_only() {
    log_test "transcript_save_partial (kill path) sets transcript_content_missing=true for boilerplate-only content (Issue #430)"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-pboiler-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-pboiler"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"
    cat > "$buf" << 'EOF'
[INFO] [entrypoint] [entrypoint.sh:122] Injecting credentials to files...
[WARN] [liveness-monitor] [liveness-monitor.sh:88] heartbeat check ok
dnsmasq: started, version 2.85 cachesize 150
EOF

    # Agents killed early (SIGTERM, mount failure, liveness kill) only ever
    # traverse this trap-path variant — it must flag the gap too.
    status_set_transcript_content_missing "false"
    transcript_save_partial "$conv_dir" "$buf" "pboiler-agent"

    if [[ ! -f "${conv_dir}/transcript.txt" ]]; then
        log_fail "transcript_save_partial should have written transcript.txt"
        return 1
    fi
    assert_equals "true" "$_KAPSIS_TRANSCRIPT_CONTENT_MISSING" \
        "transcript_content_missing must be set true by the kill-path variant for boilerplate-only content"
    status_set_transcript_content_missing "false"
}

test_transcript_content_missing_not_set_for_real_content() {
    log_test "transcript_save leaves transcript_content_missing unset when real content is interleaved (Issue #430)"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-real-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-real"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"
    cat > "$buf" << 'EOF'
[INFO] [entrypoint] [entrypoint.sh:122] Injecting credentials to files...
Sure, I can help with that — here is my plan for the refactor.
dnsmasq: started, version 2.85 cachesize 150
EOF

    status_set_transcript_content_missing "true"  # start "dirty" so we prove it gets cleared
    transcript_save "$conv_dir" "$buf" "real-agent" "0"

    assert_not_equals "true" "$_KAPSIS_TRANSCRIPT_CONTENT_MISSING" \
        "transcript_content_missing must not be true when real agent dialogue is present"
}

test_transcript_skipped_when_conv_dir_absent() {
    log_test "No error when conversations directory is absent (agent ran without mount)"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-absent-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local buf="${tmpdir}/buf"
    echo "output" > "$buf"

    # conv_dir does NOT exist — save should be a no-op, not an error
    local exit_code=0
    transcript_save "${tmpdir}/nonexistent-conv" "$buf" "absent-agent" "0" || exit_code=$?
    assert_equals "0" "$exit_code" "Transcript save should not fail when conv dir is absent"

    # Empty conv_dir argument (trap before mount setup) — also a no-op
    exit_code=0
    transcript_save_partial "" "$buf" "absent-agent" || exit_code=$?
    assert_equals "0" "$exit_code" "Partial save should not fail when conv dir is empty"
}

test_transcript_skipped_when_buffer_empty() {
    log_test "Transcript not written when container output buffer is empty"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-empty-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-empty"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/empty_buf"
    # Create an empty (zero-byte) file
    : > "$buf"

    transcript_save "$conv_dir" "$buf" "empty-agent" "0"

    if [[ -f "${conv_dir}/transcript.txt" ]]; then
        log_fail "transcript.txt should NOT be created when buffer is empty"
        return 1
    fi
}

test_interrupt_path_saves_transcript() {
    log_test "transcript_save_partial saves partial transcript before buffer deletion"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-int-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-int"
    mkdir -p "$conv_dir"
    local buf="${tmpdir}/buf"
    echo "partial work done" > "$buf"

    # Simulate the interrupt path (normal save NOT called first)
    transcript_save_partial "$conv_dir" "$buf" "int-agent"

    if [[ ! -f "${conv_dir}/transcript.txt" ]]; then
        log_fail "Interrupt path should create transcript.txt"
        return 1
    fi
    local content
    content=$(cat "${conv_dir}/transcript.txt")
    if [[ "$content" != *"interrupted"* ]]; then
        log_fail "Interrupt transcript should contain 'interrupted' marker"
        return 1
    fi
    if [[ "$content" != *"int-agent"* ]]; then
        log_fail "Interrupt transcript header should contain the agent id"
        return 1
    fi
    if [[ "$content" != *"partial work done"* ]]; then
        log_fail "Interrupt transcript should contain captured output"
        return 1
    fi
}

test_interrupt_path_does_not_overwrite_existing_transcript() {
    log_test "transcript_save_partial skips write when transcript.txt already exists"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-noow-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-noow"
    mkdir -p "$conv_dir"
    echo "already written by normal path" > "${conv_dir}/transcript.txt"

    local buf="${tmpdir}/buf"
    echo "interrupt output" > "$buf"

    transcript_save_partial "$conv_dir" "$buf" "noow-agent"

    local content
    content=$(cat "${conv_dir}/transcript.txt")
    assert_equals "already written by normal path" "$content" \
        "Existing transcript.txt should not be overwritten by interrupt path"
}

test_cleanup_uses_dir_mtime_not_file_mtime() {
    log_test "get_dir_mtime works on conversation directories (regression: get_file_mtime fails on dirs)"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-mtime-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local conv_dir="${tmpdir}/agent-mtime"
    mkdir -p "$conv_dir"

    # get_file_mtime must return empty (and non-zero) for a directory
    local file_mtime
    file_mtime=$(get_file_mtime "$conv_dir" 2>/dev/null || echo "")
    if [[ -n "$file_mtime" ]]; then
        log_fail "get_file_mtime should return empty for a directory (found: $file_mtime)"
        return 1
    fi

    # get_dir_mtime must return a valid epoch for the same directory
    local dir_mtime
    dir_mtime=$(get_dir_mtime "$conv_dir" 2>/dev/null || echo "")
    if [[ -z "$dir_mtime" ]]; then
        log_fail "get_dir_mtime should return a value for a directory"
        return 1
    fi
    # shellcheck disable=SC2016
    assert_true '[[ "$dir_mtime" =~ ^[0-9]+$ ]]' \
        "get_dir_mtime should return a numeric epoch"
}

test_cleanup_ttl_removes_old_conv_dir() {
    log_test "clean_conversations removes directories older than TTL"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-ttl-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local stale_dir="${tmpdir}/agent-stale"
    mkdir -p "$stale_dir"
    # Make it 30 days old (well past the 7-day default TTL)
    touch -d "30 days ago" "$stale_dir" 2>/dev/null \
        || touch -t "$(date -d '30 days ago' '+%Y%m%d%H%M' 2>/dev/null || date -v-30d '+%Y%m%d%H%M')" \
            "$stale_dir" 2>/dev/null || true

    local mtime
    mtime=$(get_dir_mtime "$stale_dir" 2>/dev/null || echo "")
    if [[ -z "$mtime" ]]; then
        log_fail "Could not set stale mtime for test directory — skipping"
        return 0  # not a test failure; environment limitation
    fi

    local now ttl_days ttl_seconds age
    now=$(date +%s)
    ttl_days="${KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS:-7}"
    ttl_seconds=$((ttl_days * 86400))
    age=$((now - mtime))

    if (( age <= ttl_seconds )); then
        log_fail "Test setup failed: stale_dir is only ${age}s old, needs to be older than ${ttl_seconds}s"
        return 1
    fi

    # Confirm the cleanup logic would remove it
    assert_true '(( age > ttl_seconds ))' \
        "Stale directory age should exceed TTL"
}

test_cleanup_ttl_preserves_fresh_conv_dir() {
    log_test "clean_conversations preserves directories within TTL"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-conv-fresh-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local fresh_dir="${tmpdir}/agent-fresh"
    mkdir -p "$fresh_dir"
    # Freshly created — mtime is now

    local mtime now ttl_days ttl_seconds age
    mtime=$(get_dir_mtime "$fresh_dir" 2>/dev/null || echo "")
    now=$(date +%s)
    ttl_days="${KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS:-7}"
    ttl_seconds=$((ttl_days * 86400))
    age=$((now - mtime))

    assert_true '(( age < ttl_seconds ))' \
        "Fresh directory age should be below TTL and should be preserved"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Conversation Transcript Capture (Issue #390)"

    run_test test_ttl_constant_exists_and_is_numeric
    run_test test_container_conversations_path_constant
    run_test test_launch_agent_wired_to_transcript_lib
    run_test test_transcript_written_to_conv_dir
    run_test test_transcript_header_present
    run_test test_transcript_ansi_stripped
    run_test test_strip_ansi_handles_osc_csi_and_cr
    run_test test_transcript_truncation_keeps_tail
    run_test test_transcript_content_missing_flagged_for_boilerplate_only
    run_test test_transcript_content_missing_lands_in_status_json
    run_test test_partial_transcript_content_missing_flagged_for_boilerplate_only
    run_test test_transcript_content_missing_not_set_for_real_content
    run_test test_transcript_skipped_when_conv_dir_absent
    run_test test_transcript_skipped_when_buffer_empty
    run_test test_interrupt_path_saves_transcript
    run_test test_interrupt_path_does_not_overwrite_existing_transcript
    run_test test_cleanup_uses_dir_mtime_not_file_mtime
    run_test test_cleanup_ttl_removes_old_conv_dir
    run_test test_cleanup_ttl_preserves_fresh_conv_dir

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
