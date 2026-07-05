#!/usr/bin/env bash
#===============================================================================
# Test: Kapsis Infrastructure Artifact Filtering (Issue #391)
#
# Verifies that files written by Kapsis infrastructure during container setup
# are not committed to the user's feature branch:
#
#   1. .claude/settings.json — excluded by KAPSIS_DEFAULT_COMMIT_EXCLUDE even
#      when the file is already git-tracked; KAPSIS_EXTRA_COMMIT_EXCLUDE
#      appends user patterns without redeclaring defaults
#   2. *.bak / .mvn/*.bak* — filtered by KAPSIS_DEFAULT_EPHEMERAL_PATTERNS
#      (Maven plugin backups such as .mvn/extensions.xml.bak2 never reach a
#      commit) without over-matching names like README.bakery.md
#
# Note: stripping of Kapsis-injected gist blocks from CLAUDE.md/AGENTS.md is
# covered separately (Issue #408, tests/test-gist-injection-provenance.sh).
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

    # Simulate agent session artifacts
    echo '{"allowedTools":[],"lsp":true}' > .claude/settings.json
    mkdir -p .mvn
    echo "<extensions/>backup" > .mvn/extensions.xml.bak2
    echo "real fix here" > bugfix.java

    git add .claude/settings.json .mvn/extensions.xml.bak2 bugfix.java

    # Validate (unstages excluded/ephemeral files) as commit_changes does
    validate_staged_files "$TEST_REPO"

    local staged
    staged=$(git diff --cached --name-only)

    assert_not_contains "$staged" "settings.json" "settings.json must not be staged"
    assert_not_contains "$staged" "extensions.xml.bak2" ".bak2 file must not be staged"
    assert_contains "$staged" "bugfix.java" "Legitimate change must stay staged"

    cleanup_test_repo
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "Kapsis Infrastructure Artifact Filtering (Issue #391)"

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
