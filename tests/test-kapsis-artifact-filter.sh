#!/usr/bin/env bash
#===============================================================================
# Test: Kapsis Infrastructure Artifact Filtering (Issue #391)
#
# Verifies that files written by Kapsis infrastructure during container setup
# are not committed to the user's feature branch:
#
#   1. CLAUDE.md/AGENTS.md — gist block bracketed by KAPSIS_GIST_BEGIN/END
#      sentinels is stripped before staging by strip_kapsis_injections().
#      Includes robustness cases from PR #394 review: multiple blocks,
#      unbalanced markers, CRLF line endings, trailing whitespace, files that
#      are 100% injection, and the legacy (pre-sentinel) "---" format.
#   2. .claude/settings.json — excluded by KAPSIS_DEFAULT_COMMIT_EXCLUDE even
#      when the file is already git-tracked; KAPSIS_EXTRA_COMMIT_EXCLUDE
#      appends user patterns without redeclaring defaults
#   3. *.bak / .mvn/*.bak* — filtered by KAPSIS_DEFAULT_EPHEMERAL_PATTERNS
#      (Maven plugin backups such as .mvn/extensions.xml.bak2 never reach a
#      commit) without over-matching names like README.bakery.md
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests
# shellcheck disable=SC2034  # Variables used by sourced scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Keep test logging out of ~/.kapsis/logs and disable status writes
# (post-container-git.sh runs log_init at source time — PR #394 review).
export KAPSIS_LOG_TO_FILE=false
export KAPSIS_LOG_CONSOLE=false
export KAPSIS_STATUS_ENABLED=false

source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-kapsis-artifact-filter"
source "$KAPSIS_ROOT/scripts/lib/status.sh"
source "$KAPSIS_ROOT/scripts/lib/constants.sh"

source "$KAPSIS_ROOT/scripts/post-container-git.sh"

TEST_REPO=""

setup_test_repo() {
    local test_name="$1"
    TEST_REPO=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-test-artifact-${test_name}-XXXXXX")
    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false
    echo "# Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"
}

cleanup_test_repo() {
    cd "${TMPDIR:-/tmp}"
    [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]] && rm -rf "$TEST_REPO"
    TEST_REPO=""
}

#===============================================================================
# strip_kapsis_injections() — CLAUDE.md / AGENTS.md gist block removal
#===============================================================================

test_strip_removes_gist_block_from_claude_md() {
    setup_test_repo "strip-claude"

    cat > CLAUDE.md << 'EOF'
# Project instructions

Legitimate content here.

<!-- KAPSIS_GIST_BEGIN -->

---

# Kapsis Activity Gist
Update /workspace/.kapsis/gist.txt with your progress.

<!-- KAPSIS_GIST_END -->
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "BEGIN sentinel should be stripped"
    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_END" "END sentinel should be stripped"
    assert_file_not_contains CLAUDE.md "Kapsis Activity Gist" "Gist instructions should be stripped"
    assert_file_contains CLAUDE.md "Legitimate content here" "Legitimate content should be preserved"

    cleanup_test_repo
}

test_strip_removes_gist_block_from_agents_md() {
    setup_test_repo "strip-agents"

    cat > AGENTS.md << 'EOF'
# Agent instructions

Project specifics.

<!-- KAPSIS_GIST_BEGIN -->

# Kapsis Activity Gist
Keep gist.txt updated.

<!-- KAPSIS_GIST_END -->
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains AGENTS.md "KAPSIS_GIST_BEGIN" "BEGIN sentinel should be stripped from AGENTS.md"
    assert_file_contains AGENTS.md "Project specifics" "Legitimate AGENTS.md content should be preserved"

    cleanup_test_repo
}

test_strip_is_noop_when_no_markers() {
    setup_test_repo "strip-noop"

    local original_content="# Project instructions
Legitimate content only — no Kapsis markers."
    echo "$original_content" > CLAUDE.md

    strip_kapsis_injections "$TEST_REPO"

    assert_equals "$original_content" "$(cat CLAUDE.md)" \
        "CLAUDE.md without markers should not be modified"

    cleanup_test_repo
}

test_strip_skips_absent_files() {
    setup_test_repo "strip-absent"

    # Neither CLAUDE.md nor AGENTS.md exists — should return 0 without error
    local rc=0
    strip_kapsis_injections "$TEST_REPO" || rc=$?

    assert_equals "0" "$rc" "strip_kapsis_injections should succeed when no MD files exist"

    cleanup_test_repo
}

test_strip_fails_on_missing_worktree() {
    # Guarded cd (PR #394 review): a bad path must return 1, not silently run
    # in the caller's CWD (where it could edit an unrelated CLAUDE.md).
    setup_test_repo "strip-badpath"

    local rc=0
    strip_kapsis_injections "$TEST_REPO/does-not-exist" || rc=$?

    assert_equals "1" "$rc" "strip_kapsis_injections should fail for a missing worktree path"

    cleanup_test_repo
}

test_strip_preserves_agent_edits_outside_block() {
    setup_test_repo "strip-preserve"

    cat > CLAUDE.md << 'EOF'
# Project instructions

Original section.

<!-- KAPSIS_GIST_BEGIN -->

# Kapsis Activity Gist
Update gist.txt.

<!-- KAPSIS_GIST_END -->

## Agent-added section

The agent wrote this paragraph during the session.
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_contains CLAUDE.md "Agent-added section" "Agent edits after the gist block should survive"
    assert_file_contains CLAUDE.md "Original section" "Content before the gist block should survive"
    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "Sentinel should be stripped"

    cleanup_test_repo
}

test_strip_removes_multiple_blocks() {
    setup_test_repo "strip-multi"

    cat > CLAUDE.md << 'EOF'
# Project

Before first block.

<!-- KAPSIS_GIST_BEGIN -->
first injected block
<!-- KAPSIS_GIST_END -->

Between blocks.

<!-- KAPSIS_GIST_BEGIN -->
second injected block
<!-- KAPSIS_GIST_END -->

After second block.
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "All BEGIN sentinels should be stripped"
    assert_file_not_contains CLAUDE.md "first injected block" "First block content should be stripped"
    assert_file_not_contains CLAUDE.md "second injected block" "Second block content should be stripped"
    assert_file_contains CLAUDE.md "Between blocks." "Content between blocks should survive"
    assert_file_contains CLAUDE.md "After second block." "Content after the last block should survive"

    cleanup_test_repo
}

test_strip_unbalanced_begin_leaves_file_unchanged() {
    # BEGIN without END must NOT truncate the tail (PR #394 review): the
    # rewrite is discarded and the file left byte-identical.
    setup_test_repo "strip-unbalanced"

    cat > CLAUDE.md << 'EOF'
# Project

Content before.

<!-- KAPSIS_GIST_BEGIN -->
injected content with no END marker

Tail content that must not be truncated.
EOF

    local before after before_bytes after_bytes
    before=$(cat CLAUDE.md)
    before_bytes=$(wc -c < CLAUDE.md)

    strip_kapsis_injections "$TEST_REPO"

    after=$(cat CLAUDE.md)
    after_bytes=$(wc -c < CLAUDE.md)

    assert_equals "$before" "$after" "File with unbalanced BEGIN should be left unchanged"
    assert_equals "$before_bytes" "$after_bytes" "File size should be unchanged for unbalanced markers"

    cleanup_test_repo
}

test_strip_handles_crlf_line_endings() {
    # CRLF marker lines must still match — [[:space:]] covers \r (PR #394 review)
    setup_test_repo "strip-crlf"

    printf '# Project\r\nKeep me.\r\n<!-- KAPSIS_GIST_BEGIN -->\r\ninjected gist content\r\n<!-- KAPSIS_GIST_END -->\r\nTail line.\r\n' > CLAUDE.md

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "CRLF BEGIN sentinel should be stripped"
    assert_file_not_contains CLAUDE.md "injected gist content" "CRLF block content should be stripped"
    assert_file_contains CLAUDE.md "Keep me." "CRLF content before the block should survive"
    assert_file_contains CLAUDE.md "Tail line." "CRLF content after the block should survive"

    cleanup_test_repo
}

test_strip_handles_trailing_whitespace_on_markers() {
    setup_test_repo "strip-whitespace"

    printf '# Project\nKeep me.\n<!-- KAPSIS_GIST_BEGIN -->   \ninjected content\n<!-- KAPSIS_GIST_END -->\t\nTail line.\n' > CLAUDE.md

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "BEGIN sentinel with trailing spaces should be stripped"
    assert_file_not_contains CLAUDE.md "injected content" "Block content should be stripped"
    assert_file_contains CLAUDE.md "Tail line." "Content after the block should survive"

    cleanup_test_repo
}

test_strip_empties_file_that_is_all_injection() {
    # A file that is 100% injection strips to empty — the empty result is
    # written (injection only appends to existing files, so the pre-injection
    # state was an empty file). PR #394 review: the old -s guard left the
    # whole block in place here.
    setup_test_repo "strip-allinjection"

    cat > CLAUDE.md << 'EOF'
<!-- KAPSIS_GIST_BEGIN -->
# Kapsis Activity Gist
Update gist.txt.
<!-- KAPSIS_GIST_END -->
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "Sentinel should be stripped from 100%-injection file"
    assert_file_not_contains CLAUDE.md "Kapsis Activity Gist" "Block content should be stripped from 100%-injection file"
    assert_equals "" "$(cat CLAUDE.md)" "100%-injection file should be empty after strip"

    cleanup_test_repo
}

test_strip_leaves_stray_end_marker() {
    # A stray END with no matching BEGIN is ordinary content: it is printed
    # through (an HTML comment, invisible in rendered Markdown) and nothing
    # around it is removed.
    setup_test_repo "strip-strayend"

    cat > CLAUDE.md << 'EOF'
# Project

<!-- KAPSIS_GIST_BEGIN -->
real injected block
<!-- KAPSIS_GIST_END -->

Visible middle content.

<!-- KAPSIS_GIST_END -->

Visible tail content.
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "real injected block" "Balanced block should be stripped"
    assert_file_contains CLAUDE.md "Visible middle content." "Content before stray END should survive"
    assert_file_contains CLAUDE.md "Visible tail content." "Content after stray END should survive"
    assert_file_contains CLAUDE.md "KAPSIS_GIST_END" "Stray END marker is left in place (harmless HTML comment)"

    cleanup_test_repo
}

test_strip_is_not_markdown_aware() {
    # Documented limitation: marker lines inside a fenced code block (e.g. a
    # doc that documents this feature) are still treated as markers. A
    # balanced pair inside a fence is stripped like any block; content after
    # the fence is never truncated.
    setup_test_repo "strip-fenced"

    cat > CLAUDE.md << 'EOF'
# Doc

Example of the sentinel format:

```
<!-- KAPSIS_GIST_BEGIN -->
example block content
<!-- KAPSIS_GIST_END -->
```

Tail after fence.
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "Markers inside fences are stripped (not Markdown-aware)"
    assert_file_contains CLAUDE.md "Tail after fence." "Content after the fence must never be truncated"
    assert_file_contains CLAUDE.md "# Doc" "Content before the fence should survive"

    cleanup_test_repo
}

test_strip_round_trip_is_byte_exact() {
    # inject_gist_instructions → strip_kapsis_injections must restore the
    # file byte-for-byte: not even a whitespace-only diff may reach the
    # commit (the strip consumes the blank line the injector writes).
    setup_test_repo "round-trip"

    printf '# My project\n\nUser instructions.\n' > CLAUDE.md
    cp CLAUDE.md claude.orig

    # Run the real injector in a subshell (it sets set -e and its own logging)
    (
        export KAPSIS_WORKSPACE="$TEST_REPO"
        export KAPSIS_INJECT_GIST=true
        export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"
        source "$KAPSIS_ROOT/scripts/lib/inject-status-hooks.sh"
        inject_gist_instructions
    ) >/dev/null 2>&1

    assert_file_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "Injection should add the sentinel block"

    strip_kapsis_injections "$TEST_REPO"

    local rc=0
    cmp -s claude.orig CLAUDE.md || rc=$?
    assert_equals "0" "$rc" "inject -> strip must restore CLAUDE.md byte-for-byte"

    cleanup_test_repo
}

#===============================================================================
# strip_kapsis_injections() — legacy (pre-#391) "---" format
#===============================================================================

test_strip_removes_legacy_format_block() {
    # Files injected by Kapsis versions before #391 have no sentinels — the
    # block was appended as: "" / "---" / "" / <gist instructions> at EOF.
    setup_test_repo "strip-legacy"

    cat > CLAUDE.md << 'EOF'
# Project instructions

Legitimate content here.

---

# Kapsis Activity Gist

Update `/workspace/.kapsis/gist.txt` with your current activity.

## How to Update

```bash
echo "your current activity" > /workspace/.kapsis/gist.txt
```
EOF

    strip_kapsis_injections "$TEST_REPO"

    assert_file_not_contains CLAUDE.md "Kapsis Activity Gist" "Legacy gist block should be stripped"
    assert_file_not_contains CLAUDE.md "How to Update" "Legacy gist body should be stripped"

    # Exact result: separator and trailing blanks removed, user content intact
    local expected="# Project instructions

Legitimate content here."
    assert_equals "$expected" "$(cat CLAUDE.md)" \
        "Only the user content (without the --- separator) should remain"

    cleanup_test_repo
}

test_strip_legacy_refuses_when_user_h1_follows() {
    # Conservative guard: an H1 after the legacy heading means user content
    # may have been appended after the injection — refuse rather than delete.
    setup_test_repo "strip-legacy-h1"

    cat > CLAUDE.md << 'EOF'
# Project

User content.

---

# Kapsis Activity Gist

Update gist.txt.

# User Section Added Later

Important user notes that must not be deleted.
EOF

    local before
    before=$(cat CLAUDE.md)

    strip_kapsis_injections "$TEST_REPO"

    assert_equals "$before" "$(cat CLAUDE.md)" \
        "Legacy strip must refuse when another H1 follows the gist heading"

    cleanup_test_repo
}

test_strip_legacy_requires_separator() {
    # Without the "---" separator above the heading the legacy layout is not
    # recognizable — leave the file unchanged (manual cleanup documented).
    setup_test_repo "strip-legacy-nosep"

    cat > CLAUDE.md << 'EOF'
# Project

# Kapsis Activity Gist

Some user-authored section that merely reuses the phrase.
EOF

    local before
    before=$(cat CLAUDE.md)

    strip_kapsis_injections "$TEST_REPO"

    assert_equals "$before" "$(cat CLAUDE.md)" \
        "Legacy strip must not fire without a --- separator above the heading"

    cleanup_test_repo
}

#===============================================================================
# .claude/settings.json — excluded even when git-tracked
#===============================================================================

test_settings_json_in_commit_exclude() {
    assert_contains "$KAPSIS_DEFAULT_COMMIT_EXCLUDE" ".claude/settings.json" \
        "KAPSIS_DEFAULT_COMMIT_EXCLUDE should contain .claude/settings.json"
    assert_contains "$KAPSIS_DEFAULT_COMMIT_EXCLUDE" "**/.claude/settings.json" \
        "KAPSIS_DEFAULT_COMMIT_EXCLUDE should contain the any-depth settings.json pattern"
}

test_tracked_settings_json_unstaged_by_validate() {
    setup_test_repo "settings-tracked"

    # Track .claude/settings.json so it survives KAPSIS_GIT_EXCLUDE_PATTERNS
    mkdir -p .claude
    echo '{"allowedTools":[]}' > .claude/settings.json
    git add .claude/settings.json
    git commit --quiet -m "Track settings.json"

    # Simulate agent session mutation
    echo '{"allowedTools":[],"enabledLspTools":["lsp"]}' > .claude/settings.json
    git add .claude/settings.json

    assert_contains "$(git diff --cached --name-only)" "settings.json" \
        "Test setup: settings.json should be staged before validation"

    validate_staged_files "$TEST_REPO"

    assert_not_contains "$(git diff --cached --name-only)" "settings.json" \
        ".claude/settings.json should be unstaged by validate_staged_files"

    cleanup_test_repo
}

test_extra_commit_exclude_appends_to_defaults() {
    # KAPSIS_EXTRA_COMMIT_EXCLUDE (PR #394 review) adds user patterns without
    # redeclaring the defaults.
    setup_test_repo "extra-exclude"

    echo "secret data" > deploy.secret
    echo "modified ignore" > .gitignore
    echo "real work" > main.go
    git add deploy.secret .gitignore main.go

    export KAPSIS_EXTRA_COMMIT_EXCLUDE="**/*.secret"
    validate_staged_files "$TEST_REPO"
    unset KAPSIS_EXTRA_COMMIT_EXCLUDE

    local staged
    staged=$(git diff --cached --name-only)
    assert_not_contains "$staged" "deploy.secret" "Extra pattern should unstage *.secret files"
    assert_not_contains "$staged" ".gitignore" "Default patterns should still apply with EXTRA set"
    assert_contains "$staged" "main.go" "Legitimate files should stay staged"

    cleanup_test_repo
}

#===============================================================================
# *.bak — ephemeral artifact patterns cover Maven plugin backups
#===============================================================================

test_bak_patterns_in_ephemeral_patterns() {
    assert_contains "$KAPSIS_DEFAULT_EPHEMERAL_PATTERNS" "**/*.bak" \
        "Ephemeral patterns should contain the exact-suffix **/*.bak glob"
    assert_contains "$KAPSIS_DEFAULT_EPHEMERAL_PATTERNS" "**/.mvn/*.bak*" \
        "Ephemeral patterns should contain the .mvn-scoped *.bak* glob"
}

test_mvn_bak_pattern_matches_extensions_xml_bak2() {
    local regex
    regex=$(_pattern_to_regex "**/.mvn/*.bak*")

    assert_true "echo '.mvn/extensions.xml.bak2' | grep -qE '$regex'" \
        "**/.mvn/*.bak* should match .mvn/extensions.xml.bak2"
    assert_true "echo 'sub/module/.mvn/extensions.xml.bak10' | grep -qE '$regex'" \
        "**/.mvn/*.bak* should match nested .mvn backups"
}

test_bak_pattern_matches_simple_bak() {
    local regex
    regex=$(_pattern_to_regex "**/*.bak")

    assert_true "echo 'foo.bak' | grep -qE '$regex'" "**/*.bak should match foo.bak at root"
    assert_true "echo 'src/config.bak' | grep -qE '$regex'" "**/*.bak should match nested .bak files"
}

test_bak_patterns_do_not_over_match() {
    # Regression guard for PR #394 review: the old **/*.bak* glob matched
    # legitimate names like README.bakery.md and notes.bak.swp.
    local suffix_regex mvn_regex
    suffix_regex=$(_pattern_to_regex "**/*.bak")
    mvn_regex=$(_pattern_to_regex "**/.mvn/*.bak*")

    local f
    for f in "README.bakery.md" "notes.bak.swp" "src/Main.java" "Makefile" "src/backup_manager.go" "config.xml.bak2"; do
        assert_false "echo '$f' | grep -qE '$suffix_regex'" \
            "**/*.bak must not match '$f'"
    done
    for f in "README.bakery.md" "notes.bak.swp" "src/Main.java" "foo.bak"; do
        assert_false "echo '$f' | grep -qE '$mvn_regex'" \
            "**/.mvn/*.bak* must not match '$f' (outside .mvn/)"
    done
}

test_bak_files_unstaged_by_validate() {
    setup_test_repo "bak-unstage"

    mkdir -p .mvn
    echo "<extensions/>" > .mvn/extensions.xml
    echo "<extensions/>backup" > .mvn/extensions.xml.bak2
    echo "old copy" > rootfile.bak
    echo "real work" > src.java
    echo "bakery docs" > README.bakery.md

    git add .mvn/extensions.xml.bak2 rootfile.bak src.java README.bakery.md

    validate_staged_files "$TEST_REPO"

    local staged
    staged=$(git diff --cached --name-only)
    assert_not_contains "$staged" "extensions.xml.bak2" "Maven .bak2 backup should be unstaged"
    assert_not_contains "$staged" "rootfile.bak" "Plain .bak file should be unstaged"
    assert_contains "$staged" "src.java" "Legitimate source file should stay staged"
    assert_contains "$staged" "README.bakery.md" "README.bakery.md must NOT be filtered (over-match guard)"

    cleanup_test_repo
}

#===============================================================================
# Integration: full artifact scenario
#===============================================================================

test_full_artifact_scenario() {
    setup_test_repo "integration"

    # Tracked settings.json (pre-existing in project)
    mkdir -p .claude
    echo '{"allowedTools":[]}' > .claude/settings.json
    git add .claude/settings.json
    git commit --quiet -m "Track settings"

    # CLAUDE.md with gist block
    cat > CLAUDE.md << 'EOF'
# Project

Legitimate content.

<!-- KAPSIS_GIST_BEGIN -->

# Kapsis Activity Gist
Update gist.txt.

<!-- KAPSIS_GIST_END -->
EOF
    git add CLAUDE.md
    git commit --quiet -m "Add CLAUDE.md"

    # Simulate agent session artifacts
    echo '{"allowedTools":[],"lsp":true}' > .claude/settings.json
    mkdir -p .mvn
    echo "<extensions/>backup" > .mvn/extensions.xml.bak2
    echo "real fix here" > bugfix.java

    git add .claude/settings.json .mvn/extensions.xml.bak2 bugfix.java

    # Run the pre-commit strip first (as commit_changes does)
    strip_kapsis_injections "$TEST_REPO"

    # Then validate (unstages excluded/ephemeral files)
    validate_staged_files "$TEST_REPO"

    local staged
    staged=$(git diff --cached --name-only)

    assert_not_contains "$staged" "settings.json" "settings.json must not be staged"
    assert_not_contains "$staged" "extensions.xml.bak2" ".bak2 file must not be staged"
    assert_file_not_contains CLAUDE.md "KAPSIS_GIST_BEGIN" "Gist block must be stripped before commit"
    assert_contains "$staged" "bugfix.java" "Legitimate change must stay staged"

    cleanup_test_repo
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "Kapsis Infrastructure Artifact Filtering (Issue #391)"

    run_test test_strip_removes_gist_block_from_claude_md
    run_test test_strip_removes_gist_block_from_agents_md
    run_test test_strip_is_noop_when_no_markers
    run_test test_strip_skips_absent_files
    run_test test_strip_fails_on_missing_worktree
    run_test test_strip_preserves_agent_edits_outside_block
    run_test test_strip_removes_multiple_blocks
    run_test test_strip_unbalanced_begin_leaves_file_unchanged
    run_test test_strip_handles_crlf_line_endings
    run_test test_strip_handles_trailing_whitespace_on_markers
    run_test test_strip_empties_file_that_is_all_injection
    run_test test_strip_leaves_stray_end_marker
    run_test test_strip_is_not_markdown_aware
    run_test test_strip_round_trip_is_byte_exact

    run_test test_strip_removes_legacy_format_block
    run_test test_strip_legacy_refuses_when_user_h1_follows
    run_test test_strip_legacy_requires_separator

    run_test test_settings_json_in_commit_exclude
    run_test test_tracked_settings_json_unstaged_by_validate
    run_test test_extra_commit_exclude_appends_to_defaults

    run_test test_bak_patterns_in_ephemeral_patterns
    run_test test_mvn_bak_pattern_matches_extensions_xml_bak2
    run_test test_bak_pattern_matches_simple_bak
    run_test test_bak_patterns_do_not_over_match
    run_test test_bak_files_unstaged_by_validate

    run_test test_full_artifact_scenario

    print_summary
}

main "$@"
