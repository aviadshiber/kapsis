#!/usr/bin/env bash
#===============================================================================
# Test: Kapsis Infrastructure Artifact Filtering (Issue #391)
#
# Verifies that files written by Kapsis infrastructure during container setup
# are not committed to the user's feature branch:
#
#   1. CLAUDE.md/AGENTS.md — gist block bracketed by KAPSIS_GIST_BEGIN/END
#      sentinels is stripped before staging by strip_kapsis_injections()
#   2. .claude/settings.json — excluded by KAPSIS_DEFAULT_COMMIT_EXCLUDE even
#      when the file is already git-tracked
#   3. *.bak* files — filtered by KAPSIS_DEFAULT_EPHEMERAL_PATTERNS (Maven
#      plugin backups such as .mvn/extensions.xml.bak2 never reach a commit)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

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
    echo "$TEST_REPO"
}

cleanup_test_repo() {
    [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]] && rm -rf "$TEST_REPO"
    TEST_REPO=""
}

#===============================================================================
# strip_kapsis_injections() — CLAUDE.md / AGENTS.md gist block removal
#===============================================================================

test_strip_removes_gist_block_from_claude_md() {
    log_test "strip_kapsis_injections removes KAPSIS_GIST_BEGIN/END block from CLAUDE.md"

    setup_test_repo "strip-claude"
    cd "$TEST_REPO"

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

    if grep -qF "KAPSIS_GIST_BEGIN" CLAUDE.md 2>/dev/null; then
        log_fail "CLAUDE.md still contains KAPSIS_GIST_BEGIN after strip"
        cleanup_test_repo
        return 1
    fi

    if grep -qF "KAPSIS_GIST_END" CLAUDE.md 2>/dev/null; then
        log_fail "CLAUDE.md still contains KAPSIS_GIST_END after strip"
        cleanup_test_repo
        return 1
    fi

    if ! grep -q "Legitimate content here" CLAUDE.md; then
        log_fail "Legitimate CLAUDE.md content was destroyed by strip"
        cleanup_test_repo
        return 1
    fi

    if grep -q "Kapsis Activity Gist" CLAUDE.md; then
        log_fail "Gist instructions are still present in CLAUDE.md after strip"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_strip_removes_gist_block_from_agents_md() {
    log_test "strip_kapsis_injections removes KAPSIS_GIST_BEGIN/END block from AGENTS.md"

    setup_test_repo "strip-agents"
    cd "$TEST_REPO"

    cat > AGENTS.md << 'EOF'
# Agent instructions

Project specifics.

<!-- KAPSIS_GIST_BEGIN -->

# Kapsis Activity Gist
Keep gist.txt updated.

<!-- KAPSIS_GIST_END -->
EOF

    strip_kapsis_injections "$TEST_REPO"

    if grep -qF "KAPSIS_GIST_BEGIN" AGENTS.md 2>/dev/null; then
        log_fail "AGENTS.md still contains KAPSIS_GIST_BEGIN after strip"
        cleanup_test_repo
        return 1
    fi

    if ! grep -q "Project specifics" AGENTS.md; then
        log_fail "Legitimate AGENTS.md content was destroyed by strip"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_strip_is_noop_when_no_markers() {
    log_test "strip_kapsis_injections is a no-op when CLAUDE.md has no markers"

    setup_test_repo "strip-noop"
    cd "$TEST_REPO"

    local original_content="# Project instructions
Legitimate content only — no Kapsis markers."
    echo "$original_content" > CLAUDE.md

    strip_kapsis_injections "$TEST_REPO"

    local after_content
    after_content=$(cat CLAUDE.md)
    if [[ "$after_content" != "$original_content" ]]; then
        log_fail "CLAUDE.md was modified even though it had no Kapsis markers"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_strip_skips_absent_files() {
    log_test "strip_kapsis_injections succeeds when CLAUDE.md and AGENTS.md do not exist"

    setup_test_repo "strip-absent"
    cd "$TEST_REPO"

    # Neither file exists — should return 0 without error
    local rc=0
    strip_kapsis_injections "$TEST_REPO" || rc=$?

    if [[ $rc -ne 0 ]]; then
        log_fail "strip_kapsis_injections returned $rc when no MD files existed"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_strip_preserves_agent_edits_outside_block() {
    log_test "strip_kapsis_injections preserves agent edits made outside the gist block"

    setup_test_repo "strip-preserve"
    cd "$TEST_REPO"

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

    if ! grep -q "Agent-added section" CLAUDE.md; then
        log_fail "Agent edits after the gist block were lost"
        cleanup_test_repo
        return 1
    fi

    if ! grep -q "Original section" CLAUDE.md; then
        log_fail "Content before the gist block was lost"
        cleanup_test_repo
        return 1
    fi

    if grep -qF "KAPSIS_GIST_BEGIN" CLAUDE.md; then
        log_fail "Gist block sentinel still present after strip"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

#===============================================================================
# .claude/settings.json — excluded even when git-tracked
#===============================================================================

test_settings_json_excluded_from_commit_exclude() {
    log_test ".claude/settings.json is in KAPSIS_DEFAULT_COMMIT_EXCLUDE"

    if ! echo "$KAPSIS_DEFAULT_COMMIT_EXCLUDE" | grep -qF "settings.json"; then
        log_fail "KAPSIS_DEFAULT_COMMIT_EXCLUDE does not contain settings.json"
        return 1
    fi
}

test_tracked_settings_json_unstaged_by_validate() {
    log_test "validate_staged_files unstages .claude/settings.json even when git-tracked"

    setup_test_repo "settings-tracked"
    cd "$TEST_REPO"

    # Track .claude/settings.json so it survives KAPSIS_GIT_EXCLUDE_PATTERNS
    mkdir -p .claude
    echo '{"allowedTools":[]}' > .claude/settings.json
    git add .claude/settings.json
    git commit --quiet -m "Track settings.json"

    # Simulate agent session mutation
    echo '{"allowedTools":[],"enabledLspTools":["lsp"]}' > .claude/settings.json
    git add .claude/settings.json

    local staged_before
    staged_before=$(git diff --cached --name-only | grep "settings.json" || true)
    if [[ -z "$staged_before" ]]; then
        log_fail ".claude/settings.json was not staged — test setup error"
        cleanup_test_repo
        return 1
    fi

    validate_staged_files "$TEST_REPO"

    local staged_after
    staged_after=$(git diff --cached --name-only | grep "settings.json" || true)
    if [[ -n "$staged_after" ]]; then
        log_fail ".claude/settings.json is still staged after validate_staged_files"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

#===============================================================================
# *.bak* — ephemeral artifact pattern covers Maven plugin backups
#===============================================================================

test_bak_pattern_in_ephemeral_patterns() {
    log_test "KAPSIS_DEFAULT_EPHEMERAL_PATTERNS contains a *.bak* glob"

    if ! echo "$KAPSIS_DEFAULT_EPHEMERAL_PATTERNS" | grep -qF ".bak"; then
        log_fail "KAPSIS_DEFAULT_EPHEMERAL_PATTERNS does not contain a .bak pattern"
        return 1
    fi
}

test_bak_pattern_to_regex_matches_extensions_xml_bak2() {
    log_test "_pattern_to_regex for **/*.bak* matches .mvn/extensions.xml.bak2"

    local regex
    regex=$(_pattern_to_regex "**/*.bak*")
    local test_path=".mvn/extensions.xml.bak2"

    if ! echo "$test_path" | grep -qE "$regex"; then
        log_fail "Pattern regex '$regex' did not match '$test_path'"
        return 1
    fi
}

test_bak_pattern_to_regex_matches_simple_bak() {
    log_test "_pattern_to_regex for **/*.bak* matches simple foo.bak"

    local regex
    regex=$(_pattern_to_regex "**/*.bak*")

    if ! echo "foo.bak" | grep -qE "$regex"; then
        log_fail "Pattern regex '$regex' did not match 'foo.bak'"
        return 1
    fi
}

test_bak_files_unstaged_by_validate() {
    log_test "validate_staged_files unstages .mvn/extensions.xml.bak2 (Maven backup)"

    setup_test_repo "bak-unstage"
    cd "$TEST_REPO"

    mkdir -p .mvn
    echo "<extensions/>" > .mvn/extensions.xml
    echo "<extensions/>backup" > .mvn/extensions.xml.bak2
    echo "real work" > src.java

    git add .mvn/extensions.xml.bak2 src.java

    validate_staged_files "$TEST_REPO"

    local staged
    staged=$(git diff --cached --name-only)

    if echo "$staged" | grep -q "\.bak"; then
        log_fail ".mvn/extensions.xml.bak2 is still staged after validate_staged_files"
        cleanup_test_repo
        return 1
    fi

    if ! echo "$staged" | grep -q "src.java"; then
        log_fail "src.java (legitimate file) was incorrectly unstaged"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

test_bak_pattern_does_not_match_normal_files() {
    log_test "_pattern_to_regex for **/*.bak* does not match normal source files"

    local regex
    regex=$(_pattern_to_regex "**/*.bak*")
    local non_matches=("src/Main.java" "Makefile" "README.md" "src/backup_manager.go")

    for f in "${non_matches[@]}"; do
        if echo "$f" | grep -qE "$regex"; then
            log_fail "Pattern regex '$regex' incorrectly matched '$f'"
            return 1
        fi
    done
}

#===============================================================================
# Integration: full artifact scenario
#===============================================================================

test_full_artifact_scenario() {
    log_test "Integration: CLAUDE.md, settings.json, and .bak files all filtered"

    setup_test_repo "integration"
    cd "$TEST_REPO"

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

    # Artifacts must be absent
    if echo "$staged" | grep -q "settings.json"; then
        log_fail "settings.json must not be staged"
        cleanup_test_repo
        return 1
    fi
    if echo "$staged" | grep -q "\.bak"; then
        log_fail ".bak2 file must not be staged"
        cleanup_test_repo
        return 1
    fi

    # Gist block stripped from CLAUDE.md before even being staged
    if grep -qF "KAPSIS_GIST_BEGIN" CLAUDE.md 2>/dev/null; then
        log_fail "CLAUDE.md gist block must be stripped before commit"
        cleanup_test_repo
        return 1
    fi

    # Real work preserved
    if ! echo "$staged" | grep -q "bugfix.java"; then
        log_fail "bugfix.java (legitimate change) was incorrectly excluded"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Kapsis Infrastructure Artifact Filtering (Issue #391)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    run_test test_strip_removes_gist_block_from_claude_md
    run_test test_strip_removes_gist_block_from_agents_md
    run_test test_strip_is_noop_when_no_markers
    run_test test_strip_skips_absent_files
    run_test test_strip_preserves_agent_edits_outside_block

    run_test test_settings_json_excluded_from_commit_exclude
    run_test test_tracked_settings_json_unstaged_by_validate

    run_test test_bak_pattern_in_ephemeral_patterns
    run_test test_bak_pattern_to_regex_matches_extensions_xml_bak2
    run_test test_bak_pattern_to_regex_matches_simple_bak
    run_test test_bak_files_unstaged_by_validate
    run_test test_bak_pattern_does_not_match_normal_files

    run_test test_full_artifact_scenario

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
