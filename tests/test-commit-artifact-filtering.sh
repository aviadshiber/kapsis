#!/usr/bin/env bash
#===============================================================================
# Unit tests for commit artifact filtering (Issue #391)
#
# Tests:
#   - strip_kapsis_injections() strips sentinel-bracketed gist blocks
#   - Agent edits outside the block are preserved
#   - Unbalanced BEGIN marker leaves the file unchanged (safety)
#   - Legacy (pre-#391) "---\n# Kapsis Activity Gist" blocks are stripped
#   - .claude/settings.json is in KAPSIS_DEFAULT_COMMIT_EXCLUDE
#   - **/*.bak and **/.mvn/*.bak* patterns in KAPSIS_DEFAULT_EPHEMERAL_PATTERNS
#   - _pattern_to_regex handles single * correctly (no cross-separator matching)
#   - KAPSIS_EXTRA_COMMIT_EXCLUDE appends to defaults without replacing them
#
# Run: ./tests/test-commit-artifact-filtering.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"
POST_GIT="$KAPSIS_ROOT/scripts/post-container-git.sh"

# Minimal status stub so strip_kapsis_injections can call status_set_stripped_injections
# without requiring the full status library.
_KAPSIS_STRIPPED_INJECTIONS=0
status_set_stripped_injections() { _KAPSIS_STRIPPED_INJECTIONS="${1:-0}"; }

# Source constants and logging, then the post-container-git helpers.
source "$LIB_DIR/constants.sh"
source "$LIB_DIR/logging.sh"
log_init "test-commit-artifact-filtering"
# Source the post-container-git.sh functions. The file's `if BASH_SOURCE == $0`
# guard prevents main() from running, so only the function definitions are loaded.
# shellcheck source=../scripts/post-container-git.sh
source "$POST_GIT"

#===============================================================================
# TEST: strip_kapsis_injections — sentinel format, happy path
#===============================================================================

test_strip_sentinel_block() {
    local wt
    wt=$(mktemp -d)

    cat > "${wt}/CLAUDE.md" << 'EOF'
# My Project

This is real content that the agent wrote.

<!-- KAPSIS_GIST_BEGIN -->

# Kapsis Activity Gist
Some injected instructions here.

<!-- KAPSIS_GIST_END -->
EOF

    _KAPSIS_STRIPPED_INJECTIONS=0
    strip_kapsis_injections "$wt"

    local result
    result=$(cat "${wt}/CLAUDE.md")

    assert_not_contains "$result" "KAPSIS_GIST_BEGIN" "sentinel BEGIN removed"
    assert_not_contains "$result" "KAPSIS_GIST_END" "sentinel END removed"
    assert_not_contains "$result" "Kapsis Activity Gist" "injected content removed"
    assert_contains "$result" "This is real content" "real content preserved"
    assert_equals "$_KAPSIS_STRIPPED_INJECTIONS" "1" "stripped_injections counter incremented"

    rm -rf "$wt"
}

#===============================================================================
# TEST: strip_kapsis_injections — agent edits outside block preserved
#===============================================================================

test_strip_preserves_agent_edits() {
    local wt
    wt=$(mktemp -d)

    cat > "${wt}/CLAUDE.md" << 'EOF'
# Original content

<!-- KAPSIS_GIST_BEGIN -->
injected block
<!-- KAPSIS_GIST_END -->

## New section added by agent

This was written by the AI agent during the session.
EOF

    strip_kapsis_injections "$wt"
    local result
    result=$(cat "${wt}/CLAUDE.md")

    assert_contains "$result" "Original content" "original header preserved"
    assert_contains "$result" "New section added by agent" "agent section preserved"
    assert_contains "$result" "This was written by the AI agent" "agent prose preserved"
    assert_not_contains "$result" "KAPSIS_GIST" "sentinel markers removed"

    rm -rf "$wt"
}

#===============================================================================
# TEST: strip_kapsis_injections — unbalanced BEGIN leaves file unchanged
#===============================================================================

test_strip_unbalanced_begin_leaves_file() {
    local wt
    wt=$(mktemp -d)

    cat > "${wt}/CLAUDE.md" << 'EOF'
# Content

<!-- KAPSIS_GIST_BEGIN -->
This block was never closed.
EOF

    local before
    before=$(cat "${wt}/CLAUDE.md")
    strip_kapsis_injections "$wt"
    local after
    after=$(cat "${wt}/CLAUDE.md")

    assert_equals "$before" "$after" "file unchanged on unbalanced BEGIN marker"

    rm -rf "$wt"
}

#===============================================================================
# TEST: strip_kapsis_injections — no injection is a no-op
#===============================================================================

test_strip_noop_when_no_injection() {
    local wt
    wt=$(mktemp -d)

    printf '# Clean project\n\nNo gist content here.\n' > "${wt}/CLAUDE.md"
    local before
    before=$(cat "${wt}/CLAUDE.md")

    _KAPSIS_STRIPPED_INJECTIONS=0
    strip_kapsis_injections "$wt"
    local after
    after=$(cat "${wt}/CLAUDE.md")

    assert_equals "$before" "$after" "file unchanged when no injection found"
    assert_equals "$_KAPSIS_STRIPPED_INJECTIONS" "0" "counter stays at zero"

    rm -rf "$wt"
}

#===============================================================================
# TEST: strip_kapsis_injections — legacy format stripped
#===============================================================================

test_strip_legacy_format() {
    local wt
    wt=$(mktemp -d)

    cat > "${wt}/CLAUDE.md" << 'EOF'
# My Project

Real content written by the project team.

---

# Kapsis Activity Gist
Some legacy gist instructions.
More instructions here.
EOF

    _KAPSIS_STRIPPED_INJECTIONS=0
    strip_kapsis_injections "$wt"
    local result
    result=$(cat "${wt}/CLAUDE.md")

    assert_contains "$result" "Real content written by the project team" "real content preserved"
    assert_not_contains "$result" "Kapsis Activity Gist" "legacy heading removed"
    assert_not_contains "$result" "legacy gist instructions" "legacy body removed"
    assert_equals "$_KAPSIS_STRIPPED_INJECTIONS" "1" "stripped_injections counter incremented"

    rm -rf "$wt"
}

#===============================================================================
# TEST: _pattern_to_regex — single * does not cross path separator
#===============================================================================

test_pattern_to_regex_single_star() {
    local regex

    regex=$(_pattern_to_regex "**/*.bak")
    echo "foo/bar.bak" | grep -qE "$regex"
    assert_equals "$?" "0" "**/*.bak matches foo/bar.bak"

    local matched=0
    echo "README.bakery.md" | grep -qE "$regex" && matched=1 || matched=0
    assert_equals "$matched" "0" "**/*.bak does NOT match README.bakery.md"

    regex=$(_pattern_to_regex "**/.mvn/*.bak*")
    echo ".mvn/extensions.xml.bak2" | grep -qE "$regex"
    assert_equals "$?" "0" "**/.mvn/*.bak* matches .mvn/extensions.xml.bak2"

    echo "src/.mvn/extensions.xml.bak10" | grep -qE "$regex"
    assert_equals "$?" "0" "**/.mvn/*.bak* matches nested .mvn path"

    # Single * must not cross the directory separator
    local cross_match=0
    echo ".mvn/subdir/file.bak2" | grep -qE "$regex" && cross_match=1 || cross_match=0
    assert_equals "$cross_match" "0" "**/.mvn/*.bak* does NOT cross directory separator"
}

#===============================================================================
# TEST: KAPSIS_DEFAULT_COMMIT_EXCLUDE contains .claude/settings.json
#===============================================================================

test_settings_json_in_default_excludes() {
    assert_contains "$KAPSIS_DEFAULT_COMMIT_EXCLUDE" ".claude/settings.json" \
        ".claude/settings.json in KAPSIS_DEFAULT_COMMIT_EXCLUDE"
    assert_contains "$KAPSIS_DEFAULT_COMMIT_EXCLUDE" "**/.claude/settings.json" \
        "**/.claude/settings.json in KAPSIS_DEFAULT_COMMIT_EXCLUDE"
}

#===============================================================================
# TEST: KAPSIS_DEFAULT_EPHEMERAL_PATTERNS contains bak patterns
#===============================================================================

test_bak_patterns_in_ephemeral() {
    assert_contains "$KAPSIS_DEFAULT_EPHEMERAL_PATTERNS" "**/*.bak" \
        "**/*.bak in KAPSIS_DEFAULT_EPHEMERAL_PATTERNS"
    assert_contains "$KAPSIS_DEFAULT_EPHEMERAL_PATTERNS" "**/.mvn/*.bak*" \
        "**/.mvn/*.bak* in KAPSIS_DEFAULT_EPHEMERAL_PATTERNS"
}

#===============================================================================
# TEST: KAPSIS_GIST_MARKER_BEGIN/END constants exist
#===============================================================================

test_gist_marker_constants_exist() {
    assert_not_equals "" "${KAPSIS_GIST_MARKER_BEGIN:-}" "KAPSIS_GIST_MARKER_BEGIN is set"
    assert_not_equals "" "${KAPSIS_GIST_MARKER_END:-}" "KAPSIS_GIST_MARKER_END is set"
    assert_contains "$KAPSIS_GIST_MARKER_BEGIN" "KAPSIS_GIST_BEGIN" "BEGIN marker contains sentinel text"
    assert_contains "$KAPSIS_GIST_MARKER_END" "KAPSIS_GIST_END" "END marker contains sentinel text"
}

#===============================================================================
# TEST: KAPSIS_EXTRA_COMMIT_EXCLUDE appends without replacing defaults
#===============================================================================

test_extra_commit_exclude_appends() {
    local wt
    wt=$(mktemp -d)
    git -C "$wt" init -q
    git -C "$wt" config user.email "test@test.com"
    git -C "$wt" config user.name "Test"

    # Stage a file matching the default excludes and one matching EXTRA
    echo "node_modules/" > "${wt}/.gitignore"
    echo "secret" > "${wt}/deploy.key"
    git -C "$wt" add .gitignore deploy.key

    KAPSIS_EXTRA_COMMIT_EXCLUDE="deploy.key" validate_staged_files "$wt" || true

    local staged
    staged=$(git -C "$wt" diff --cached --name-only 2>/dev/null || true)
    assert_not_contains "$staged" ".gitignore" ".gitignore excluded (default pattern)"
    assert_not_contains "$staged" "deploy.key" "deploy.key excluded (EXTRA pattern)"

    rm -rf "$wt"
}

#===============================================================================
# Run all tests
#===============================================================================

run_test test_strip_sentinel_block
run_test test_strip_preserves_agent_edits
run_test test_strip_unbalanced_begin_leaves_file
run_test test_strip_noop_when_no_injection
run_test test_strip_legacy_format
run_test test_pattern_to_regex_single_star
run_test test_settings_json_in_default_excludes
run_test test_bak_patterns_in_ephemeral
run_test test_gist_marker_constants_exist
run_test test_extra_commit_exclude_appends

print_summary
