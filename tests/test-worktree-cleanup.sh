#!/usr/bin/env bash
#===============================================================================
# Test: Worktree Auto-Cleanup (Fix #169)
#
# Verifies automatic worktree cleanup behavior:
# - Worktrees are removed after agent completion (default)
# - --keep-worktree preserves worktrees
# - gc_stale_worktrees cleans completed agent worktrees
#
# These tests do NOT require containers — they test worktree-manager
# functions directly against a temporary git repository.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST HELPERS
#===============================================================================

# Create a minimal worktree for cleanup testing (no container needed)
setup_cleanup_test() {
    local agent_id="$1"

    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

    local project_name
    project_name=$(basename "$TEST_PROJECT")
    CLEANUP_WORKTREE_PATH="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

    # Create worktree
    create_worktree "$TEST_PROJECT" "$agent_id" "feature/cleanup-test-${agent_id}" >/dev/null
}

teardown_cleanup_test() {
    local agent_id="$1"

    # Force remove if still exists
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh" 2>/dev/null || true
    cleanup_worktree "$TEST_PROJECT" "$agent_id" 2>/dev/null || true
}

#===============================================================================
# TEST CASES
#===============================================================================

test_cleanup_worktree_removes_worktree() {
    log_test "Testing cleanup_worktree removes worktree directory"

    local agent_id="cleanup-rm-$$"
    setup_cleanup_test "$agent_id"

    # Worktree should exist
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "Worktree should exist before cleanup"

    # Run cleanup
    cleanup_worktree "$TEST_PROJECT" "$agent_id"

    # Worktree should be gone
    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "Worktree should be removed after cleanup"
        return 1
    fi

    return 0
}

test_gc_cleans_stale_completed_worktrees() {
    log_test "Testing gc_stale_worktrees cleans completed agent worktrees"

    local agent_id="gc-complete-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")

    # Create a status file marking this agent as complete
    local status_dir="${HOME}/.kapsis/status"
    mkdir -p "$status_dir"
    local status_file="${status_dir}/kapsis-${project_name}-${agent_id}.json"
    echo '{"phase": "complete", "agent_id": "'"$agent_id"'"}' > "$status_file"

    # Worktree should exist before GC
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "Worktree should exist before GC"

    # Run GC
    gc_stale_worktrees "$TEST_PROJECT"

    # Worktree should be gone
    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "GC should have removed completed agent's worktree"
        rm -f "$status_file"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    # Cleanup status file
    rm -f "$status_file"
    return 0
}

test_gc_preserves_running_worktrees() {
    log_test "Testing gc_stale_worktrees preserves running agent worktrees"

    local agent_id="gc-running-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")

    # Create a status file marking this agent as running (not complete)
    local status_dir="${HOME}/.kapsis/status"
    mkdir -p "$status_dir"
    local status_file="${status_dir}/kapsis-${project_name}-${agent_id}.json"
    echo '{"phase": "running", "agent_id": "'"$agent_id"'"}' > "$status_file"

    # Run GC
    gc_stale_worktrees "$TEST_PROJECT"

    # Worktree should still exist (agent is running)
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "GC should preserve running agent's worktree"

    # Cleanup
    rm -f "$status_file"
    teardown_cleanup_test "$agent_id"
}

test_keep_worktree_preserves_worktree() {
    log_test "Testing --keep-worktree preserves worktree (simulated post-container path)"

    local agent_id="keep-wt-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")
    local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

    # Simulate the post_container_worktree cleanup decision with KEEP_WORKTREE=true
    # This mirrors the actual if/else in launch-agent.sh post_container_worktree()
    local KEEP_WORKTREE=true
    local EXIT_CODE=0
    if [[ "$KEEP_WORKTREE" == "true" ]] || [[ "$EXIT_CODE" -ne 0 ]]; then
        : # Preserve — no cleanup (matches production code path)
    else
        cleanup_worktree "$TEST_PROJECT" "$agent_id"
        prune_worktrees "$TEST_PROJECT"
    fi

    assert_dir_exists "$worktree_path" "Worktree should exist when keep-worktree is true"

    # Cleanup for next test
    teardown_cleanup_test "$agent_id"
}

test_default_cleanup_removes_worktree() {
    log_test "Testing default behavior removes worktree (simulated post-container path)"

    local agent_id="default-rm-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")
    local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

    # Simulate the default KEEP_WORKTREE=false path
    cleanup_worktree "$TEST_PROJECT" "$agent_id"
    prune_worktrees "$TEST_PROJECT"

    if [[ -d "$worktree_path" ]]; then
        log_fail "Worktree should be removed when keep-worktree is false (default)"
        return 1
    fi

    return 0
}

test_gc_handles_no_status_dir() {
    log_test "Testing gc_stale_worktrees handles missing status directory"

    # Use a temporary project path whose status files won't exist
    # This avoids moving the real ~/.kapsis/status directory (which could
    # affect other running agents)
    local fake_project
    fake_project=$(mktemp -d)
    mkdir -p "$fake_project/.git"
    git -C "$fake_project" init --quiet

    # GC should return 0 without errors (no matching status files)
    local exit_code=0
    gc_stale_worktrees "$fake_project" 2>/dev/null || exit_code=$?

    rm -rf "$fake_project"

    assert_equals "0" "$exit_code" "GC should succeed with no matching status files"
}

#===============================================================================
# BRANCH CLEANUP TESTS (Fix #183)
#===============================================================================

test_cleanup_branch_deletes_agent_branch() {
    log_test "Testing cleanup_branch deletes a merged agent branch"

    local branch_name="ai-agent/test-delete-$$"

    cd "$TEST_PROJECT"
    git checkout -b "$branch_name" 2>/dev/null
    git checkout - 2>/dev/null

    # Verify branch exists
    if ! git rev-parse --verify "$branch_name" &>/dev/null; then
        log_fail "Branch should exist before cleanup"
        return 1
    fi

    # Disable require_pushed for this test (local-only branch)
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="false" \
        cleanup_branch "$TEST_PROJECT" "$branch_name"

    # Verify branch is gone
    if git rev-parse --verify "$branch_name" &>/dev/null 2>&1; then
        log_fail "Branch should be deleted after cleanup_branch"
        git branch -D "$branch_name" 2>/dev/null || true
        return 1
    fi

    return 0
}

test_cleanup_branch_preserves_protected() {
    log_test "Testing cleanup_branch preserves protected branches"

    cd "$TEST_PROJECT"
    local branch_name="main"

    # main is in the default protected list — cleanup_branch should skip it
    local exit_code=0
    cleanup_branch "$TEST_PROJECT" "$branch_name" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "cleanup_branch should return 1 (skipped) for protected branch"
}

test_cleanup_branch_preserves_checked_out() {
    log_test "Testing cleanup_branch preserves branch checked out in worktree"

    local agent_id="branch-checkout-$$"
    local branch_name="feature/checked-out-test-${agent_id}"

    # Create a worktree with this branch (making it checked out)
    setup_cleanup_test "$agent_id"

    cd "$TEST_PROJECT"

    # Try to delete the branch that's checked out in the worktree
    local exit_code=0
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="false" \
        cleanup_branch "$TEST_PROJECT" "feature/cleanup-test-${agent_id}" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "cleanup_branch should return 1 (skipped) for checked-out branch"

    teardown_cleanup_test "$agent_id"
}

test_cleanup_branch_preserves_unpushed() {
    log_test "Testing cleanup_branch preserves branches without remote (require_pushed=true)"

    local branch_name="ai-agent/unpushed-test-$$"

    cd "$TEST_PROJECT"
    git checkout -b "$branch_name" 2>/dev/null
    # Make a commit so the branch has content
    echo "test" > "test-unpushed-$$"
    git add "test-unpushed-$$"
    git commit -m "test commit" --quiet 2>/dev/null
    git checkout - 2>/dev/null

    # With require_pushed=true (default), should skip
    local exit_code=0
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="true" \
        cleanup_branch "$TEST_PROJECT" "$branch_name" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "cleanup_branch should return 1 (skipped) for unpushed branch"

    # Cleanup
    git branch -D "$branch_name" 2>/dev/null || true
}

test_gc_age_cleans_old_worktrees() {
    log_test "Testing gc_stale_worktrees_by_age cleans old worktrees"

    local agent_id="gc-age-old-$$"
    setup_cleanup_test "$agent_id"

    # Backdate the worktree directory to 8 days ago (older than default 7-day TTL)
    local old_time=$(($(date +%s) - 8 * 24 * 3600))
    touch -t "$(date -r "$old_time" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old_time" +%Y%m%d%H%M.%S 2>/dev/null)" "$CLEANUP_WORKTREE_PATH" 2>/dev/null || {
        # Fallback: try GNU touch
        touch -d "@$old_time" "$CLEANUP_WORKTREE_PATH" 2>/dev/null || true
    }

    # Run age-based GC with 168h (7 days) max age
    KAPSIS_CLEANUP_BRANCH_ENABLED="false" \
        gc_stale_worktrees_by_age "$TEST_PROJECT" 168 "false"

    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "GC-age should have removed worktree older than 7 days"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    return 0
}

test_gc_age_preserves_recent_worktrees() {
    log_test "Testing gc_stale_worktrees_by_age preserves recent worktrees"

    local agent_id="gc-age-new-$$"
    setup_cleanup_test "$agent_id"

    # Worktree was just created, should be preserved
    KAPSIS_CLEANUP_BRANCH_ENABLED="false" \
        gc_stale_worktrees_by_age "$TEST_PROJECT" 168 "false"

    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "GC-age should preserve recent worktree"

    teardown_cleanup_test "$agent_id"
}

test_gc_age_zero_disables() {
    log_test "Testing gc_stale_worktrees_by_age disabled when max_age_hours=0"

    local agent_id="gc-age-zero-$$"
    setup_cleanup_test "$agent_id"

    # Backdate the worktree
    local old_time=$(($(date +%s) - 30 * 24 * 3600))
    touch -t "$(date -r "$old_time" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old_time" +%Y%m%d%H%M.%S 2>/dev/null)" "$CLEANUP_WORKTREE_PATH" 2>/dev/null || true

    # With max_age_hours=0, cleanup should be disabled
    gc_stale_worktrees_by_age "$TEST_PROJECT" 0 "false"

    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "GC-age should be disabled when max_age_hours=0"

    teardown_cleanup_test "$agent_id"
}

test_cleanup_worktree_with_branch_deletion() {
    log_test "Testing cleanup_worktree with delete_branch=true"

    local agent_id="wt-branch-del-$$"
    local branch_name="feature/cleanup-test-${agent_id}"
    setup_cleanup_test "$agent_id"

    # Verify both worktree and branch exist
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "Worktree should exist before cleanup"

    cd "$TEST_PROJECT"
    if ! git rev-parse --verify "$branch_name" &>/dev/null; then
        log_fail "Branch should exist before cleanup"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    # Cleanup with branch deletion (require_pushed=false, add test prefix for local test)
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="false" \
    KAPSIS_CLEANUP_BRANCH_PREFIXES="ai-agent/|kapsis/|feature/cleanup-test" \
        cleanup_worktree "$TEST_PROJECT" "$agent_id" "true"

    # Worktree should be gone
    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "Worktree should be removed"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    # Branch should be gone
    cd "$TEST_PROJECT"
    if git rev-parse --verify "$branch_name" &>/dev/null 2>&1; then
        log_fail "Branch should be deleted when delete_branch=true"
        git branch -D "$branch_name" 2>/dev/null || true
        return 1
    fi

    return 0
}

test_cleanup_worktrees_flag_accepted() {
    log_test "Testing --worktrees flag is accepted by kapsis-cleanup.sh (Fix #220)"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    local output
    local exit_code=0
    output=$("$cleanup_script" --worktrees --dry-run 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "--worktrees should not cause exit 1"
    assert_not_contains "$output" "Unknown option" "--worktrees should not trigger 'Unknown option' error"
}

test_cleanup_volumes_and_worktrees_combined() {
    log_test "Testing --volumes --worktrees combined flags work (Fix #220)"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    local output
    local exit_code=0
    output=$("$cleanup_script" --volumes --worktrees --dry-run 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "--volumes --worktrees should not cause exit 1"
    assert_not_contains "$output" "Unknown option" "--volumes --worktrees should not trigger 'Unknown option' error"
}

test_cleanup_config_env_override() {
    log_test "Testing environment variables override default constants"

    # Source constants for defaults
    source "$KAPSIS_ROOT/scripts/lib/constants.sh" 2>/dev/null || true

    # Verify defaults exist
    assert_equals "168" "$KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS" \
        "Default worktree max age should be 168"
    assert_equals "false" "$KAPSIS_DEFAULT_CLEANUP_BRANCH_ENABLED" \
        "Default branch cleanup should be disabled"

    # Verify env var takes precedence
    local result
    KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS=24
    result="${KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS:-$KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS}"
    assert_equals "24" "$result" "Env var should override default"
    unset KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS

    # Without env var, default should be used
    result="${KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS:-$KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS}"
    assert_equals "168" "$result" "Default should be used when env var is unset"

    return 0
}

#===============================================================================
# IN-USE GUARD TESTS (Issue #428)
#
# clean_worktrees() in kapsis-cleanup.sh previously removed every worktree
# unconditionally -- these tests exercise that function directly (via
# `kapsis-cleanup.sh --force`), fully isolated from the real ~/.kapsis tree
# via a per-test KAPSIS_DIR override, so they never touch a developer's
# live agents or unrelated projects.
#===============================================================================

# Create a worktree + status file pair, isolated under a temp KAPSIS_DIR.
# Sets GUARD_TMP_DIR, GUARD_PROJECT, GUARD_WORKTREE_PATH, GUARD_STATUS_FILE
# for the caller.
#
# Uses a dedicated project dir (NOT $TEST_PROJECT) because $TEST_PROJECT is
# named "$HOME/.kapsis-test-project-$$" (leading dot) -- clean_worktrees()'s
# `"$WORKTREE_DIR"/*` glob does not match dotfiles, which would make these
# guard tests spuriously fail regardless of the guard's own correctness.
setup_guard_test() {
    local agent_id="$1"
    local phase="$2"
    local updated_at="${3:-}"
    # Real status_complete() always writes a concrete exit_code (default 0)
    # once phase=complete -- default to "0" here so complete-phase fixtures
    # match production JSON shape and exercise the fast-reap path rather
    # than the guard's fail-safe (missing exit_code) branch.
    local exit_code="${4:-0}"

    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

    GUARD_TMP_DIR=$(mktemp -d)
    KAPSIS_WORKTREE_BASE="${GUARD_TMP_DIR}/worktrees"
    mkdir -p "${GUARD_TMP_DIR}/status"

    GUARD_PROJECT="${GUARD_TMP_DIR}/project"
    mkdir -p "$GUARD_PROJECT"
    git init -q "$GUARD_PROJECT"
    git -C "$GUARD_PROJECT" config user.email "test@kapsis.local"
    git -C "$GUARD_PROJECT" config user.name "Kapsis Test"
    git -C "$GUARD_PROJECT" config commit.gpgsign false
    git -C "$GUARD_PROJECT" config tag.gpgsign false
    echo "guard test" > "$GUARD_PROJECT/README.md"
    git -C "$GUARD_PROJECT" add -A
    git -C "$GUARD_PROJECT" commit -q -m "Initial guard test project"

    local project_name
    project_name=$(basename "$GUARD_PROJECT")
    GUARD_WORKTREE_PATH="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"
    GUARD_STATUS_FILE="${GUARD_TMP_DIR}/status/kapsis-${project_name}-${agent_id}.json"

    create_worktree "$GUARD_PROJECT" "$agent_id" "feature/guard-test-${agent_id}" >/dev/null

    if [[ -n "$updated_at" ]]; then
        echo '{"phase": "'"$phase"'", "agent_id": "'"$agent_id"'", "updated_at": "'"$updated_at"'", "exit_code": '"$exit_code"'}' \
            > "$GUARD_STATUS_FILE"
    else
        echo '{"phase": "'"$phase"'", "agent_id": "'"$agent_id"'", "exit_code": '"$exit_code"'}' > "$GUARD_STATUS_FILE"
    fi
}

teardown_guard_test() {
    local agent_id="$1"

    source "$KAPSIS_ROOT/scripts/worktree-manager.sh" 2>/dev/null || true
    cleanup_worktree "$GUARD_PROJECT" "$agent_id" 2>/dev/null || true
    rm -rf "$GUARD_TMP_DIR" 2>/dev/null || true
}

test_clean_worktrees_preserves_running_fresh_heartbeat() {
    log_test "Testing clean_worktrees preserves phase=running with fresh heartbeat"

    local agent_id
    agent_id=$(printf '%06x' "$$")
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    setup_guard_test "$agent_id" "running" "$now"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force >/dev/null 2>&1 || true

    assert_dir_exists "$GUARD_WORKTREE_PATH" \
        "Worktree with fresh heartbeat should survive kapsis-cleanup --force"
    assert_file_exists "$GUARD_WORKTREE_PATH/.git" \
        "Worktree .git metadata should survive kapsis-cleanup --force"

    teardown_guard_test "$agent_id"
}

test_clean_worktrees_reaps_complete_without_podman() {
    log_test "Testing clean_worktrees reaps phase=complete with podman absent from PATH"

    local agent_id
    agent_id=$(printf '%06x' "$(( $$ + 1 ))")
    setup_guard_test "$agent_id" "complete" "" 0

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    # Minimal system PATH with no podman -- proves the complete-phase fast
    # path has zero podman dependency (Issue #428 acceptance criterion 2).
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force >/dev/null 2>&1 || true

    if [[ -d "$GUARD_WORKTREE_PATH" ]]; then
        log_fail "Complete-phase worktree should be reaped even without podman in PATH"
        teardown_guard_test "$agent_id"
        return 1
    fi

    rm -rf "$GUARD_TMP_DIR" 2>/dev/null || true
    return 0
}

test_clean_worktrees_skips_running_stale_heartbeat_no_podman_hit() {
    log_test "Testing clean_worktrees skips phase=running with stale heartbeat and no podman hit"

    local agent_id
    agent_id=$(printf '%06x' "$(( $$ + 2 ))")
    # Stale: older than liveness timeout(900s) + grace(300s) = 1200s default
    local stale
    stale=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    setup_guard_test "$agent_id" "running" "$stale"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    # Minimal PATH with no podman -- guarantees no podman label hit is
    # possible, isolating the "stale heartbeat, no corroboration" branch.
    local output
    output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force 2>&1) || true

    assert_dir_exists "$GUARD_WORKTREE_PATH" \
        "Worktree with stale heartbeat and no podman hit should be skipped, not deleted"
    assert_contains "$output" "SKIPPED" \
        "Skipped worktree should be reported via print_item_skipped"
    assert_not_contains "$output" "Total: 1 worktrees" \
        "Skipped worktree must not be counted in ITEMS_CLEANED"

    teardown_guard_test "$agent_id"
}

test_clean_worktrees_podman_failure_does_not_block_other_removals() {
    log_test "Testing a podman failure on one ambiguous entry doesn't block other reaps"

    local complete_agent_id
    complete_agent_id=$(printf '%06x' "$(( $$ + 3 ))")
    setup_guard_test "$complete_agent_id" "complete" "" 0
    local complete_worktree_path="$GUARD_WORKTREE_PATH"
    local shared_tmp="$GUARD_TMP_DIR"
    local shared_project="$GUARD_PROJECT"

    # Second, ambiguous (stale-heartbeat, no status "complete") worktree in
    # the SAME run, sharing the same isolated KAPSIS_DIR/project.
    local stale_agent_id
    stale_agent_id=$(printf '%06x' "$(( $$ + 4 ))")
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"
    KAPSIS_WORKTREE_BASE="${shared_tmp}/worktrees"
    local project_name
    project_name=$(basename "$shared_project")
    local stale_worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${stale_agent_id}"
    local stale_status_file="${shared_tmp}/status/kapsis-${project_name}-${stale_agent_id}.json"
    create_worktree "$shared_project" "$stale_agent_id" "feature/guard-test-${stale_agent_id}" >/dev/null
    local stale
    stale=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    echo '{"phase": "running", "agent_id": "'"$stale_agent_id"'", "updated_at": "'"$stale"'"}' \
        > "$stale_status_file"

    # Simulate a podman query failure/timeout: point PATH at a fake "podman"
    # binary that always fails, wrapped with the real timeout binary so the
    # guard's timeout-wrapped call path is actually exercised.
    local fake_bin_dir
    fake_bin_dir=$(mktemp -d)
    cat > "$fake_bin_dir/podman" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$fake_bin_dir/podman"

    local output
    output=$(PATH="$fake_bin_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        KAPSIS_DIR="$shared_tmp" "$KAPSIS_ROOT/scripts/kapsis-cleanup.sh" --force 2>&1) || true

    # The complete-phase worktree must still be removed despite the
    # ambiguous entry's podman failure (fail-open, no cross-entry blocking).
    if [[ -d "$complete_worktree_path" ]]; then
        log_fail "podman failure on one entry must not block removal of a complete-phase worktree"
        rm -rf "$fake_bin_dir" "$shared_tmp" 2>/dev/null || true
        return 1
    fi

    # The ambiguous entry degrades to the age heuristic (fail-open) and,
    # being freshly created, is retained -- not deleted outright.
    assert_dir_exists "$stale_worktree_path" \
        "Ambiguous entry should fall back to age heuristic on podman failure, not be deleted"

    rm -rf "$fake_bin_dir" "$shared_tmp" 2>/dev/null || true
    unset output
    return 0
}

test_clean_worktrees_preserves_complete_exit_code_3() {
    log_test "Testing clean_worktrees preserves phase=complete with exit_code=3"

    # Exit code 3 = uncommitted changes remain -- the worktree is deliberately
    # preserved for manual recovery, so the guard must NOT fast-reap it.
    local agent_id
    agent_id=$(printf '%06x' "$(( $$ + 5 ))")
    setup_guard_test "$agent_id" "complete" "" 3

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    # Minimal PATH with no podman -- isolates the exit_code branch from any
    # live-container corroboration on the host.
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force >/dev/null 2>&1 || true

    assert_dir_exists "$GUARD_WORKTREE_PATH" \
        "phase=complete, exit_code=3 worktree must survive kapsis-cleanup --force"

    teardown_guard_test "$agent_id"
}

test_clean_worktrees_preserves_complete_exit_code_6() {
    log_test "Testing clean_worktrees preserves phase=complete with exit_code=6"

    # Exit code 6 = commit failure -- worktree kept with staged changes.
    local agent_id
    agent_id=$(printf '%06x' "$(( $$ + 6 ))")
    setup_guard_test "$agent_id" "complete" "" 6

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force >/dev/null 2>&1 || true

    assert_dir_exists "$GUARD_WORKTREE_PATH" \
        "phase=complete, exit_code=6 worktree must survive kapsis-cleanup --force"

    teardown_guard_test "$agent_id"
}

test_include_active_without_force_rejected() {
    log_test "Testing --include-active without --force is rejected"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    local tmp_dir output
    local exit_code=0
    tmp_dir=$(mktemp -d)
    output=$(KAPSIS_DIR="$tmp_dir" "$cleanup_script" --worktrees --include-active 2>&1) || exit_code=$?
    rm -rf "$tmp_dir" 2>/dev/null || true

    assert_equals "1" "$exit_code" "--include-active without --force should exit 1"
    assert_contains "$output" "requires --force" \
        "Rejection message should explain that --force is required"
}

test_clean_worktrees_include_active_reaps_guarded() {
    log_test "Testing --include-active --force reaps a worktree the guard would retain"

    # phase=running with a fresh heartbeat -- the guard retains this (see
    # test_clean_worktrees_preserves_running_fresh_heartbeat); the operator
    # escape hatch must bypass the guard and reap it anyway.
    local agent_id
    agent_id=$(printf '%06x' "$(( $$ + 7 ))")
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    setup_guard_test "$agent_id" "running" "$now"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force --include-active >/dev/null 2>&1 || true

    if [[ -d "$GUARD_WORKTREE_PATH" ]]; then
        log_fail "--include-active --force should bypass the guard and reap a fresh-heartbeat worktree"
        teardown_guard_test "$agent_id"
        return 1
    fi

    rm -rf "$GUARD_TMP_DIR" 2>/dev/null || true
    return 0
}

test_clean_worktrees_unparseable_name_age_fallback() {
    log_test "Testing unparseable-name worktree with no status file uses the age fallback"

    # Agent id whose trailing 6 chars are NOT lowercase hex, so
    # _worktree_guard_agent_id cannot parse the worktree name (mirrors a
    # user-supplied --agent-id, which launch-agent.sh permits). No status
    # file either -- previously this combination was retained forever.
    local agent_id="notparsezz"
    setup_guard_test "$agent_id" "running" ""
    rm -f "$GUARD_STATUS_FILE"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

    # Fresh worktree: younger than the 168h max age -- must be retained.
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force >/dev/null 2>&1 || true
    assert_dir_exists "$GUARD_WORKTREE_PATH" \
        "Fresh unparseable-name worktree should be retained by the age fallback"

    # Backdate past the 168h max age: the age fallback must now reap it
    # (before the follow-up fix it was permanently un-reapable).
    local old_time=$(($(date +%s) - 8 * 24 * 3600))
    touch -t "$(date -r "$old_time" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old_time" +%Y%m%d%H%M.%S 2>/dev/null)" "$GUARD_WORKTREE_PATH" 2>/dev/null || {
        # Fallback: try GNU touch
        touch -d "@$old_time" "$GUARD_WORKTREE_PATH" 2>/dev/null || true
    }
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KAPSIS_DIR="$GUARD_TMP_DIR" "$cleanup_script" --force >/dev/null 2>&1 || true

    if [[ -d "$GUARD_WORKTREE_PATH" ]]; then
        log_fail "Aged-out unparseable-name worktree should be reaped via the age fallback"
        teardown_guard_test "$agent_id"
        return 1
    fi

    rm -rf "$GUARD_TMP_DIR" 2>/dev/null || true
    return 0
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Worktree Auto-Cleanup (Fix #169, #183, #428)"

    # Setup
    setup_test_project
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

    # gc_stale_worktrees() requires jq; the Issue #428 in-use guard tests
    # below are grep-based (mirroring clean_status()'s dependency-free
    # pattern) and must run regardless of jq availability.
    if command -v jq &>/dev/null; then
        # Run original tests (Fix #169)
        run_test test_cleanup_worktree_removes_worktree
        run_test test_keep_worktree_preserves_worktree
        run_test test_default_cleanup_removes_worktree
        run_test test_gc_cleans_stale_completed_worktrees
        run_test test_gc_preserves_running_worktrees
        run_test test_gc_handles_no_status_dir

        # Run new tests (Fix #183)
        run_test test_cleanup_branch_deletes_agent_branch
        run_test test_cleanup_branch_preserves_protected
        run_test test_cleanup_branch_preserves_checked_out
        run_test test_cleanup_branch_preserves_unpushed
        run_test test_gc_age_cleans_old_worktrees
        run_test test_gc_age_preserves_recent_worktrees
        run_test test_gc_age_zero_disables
        run_test test_cleanup_worktree_with_branch_deletion
        run_test test_cleanup_worktrees_flag_accepted
        run_test test_cleanup_volumes_and_worktrees_combined
        run_test test_cleanup_config_env_override
    else
        log_skip "jq not installed (skipping GC tests that require it)"
    fi

    # Run new tests (Issue #428 -- clean_worktrees() in-use guard)
    run_test test_clean_worktrees_preserves_running_fresh_heartbeat
    run_test test_clean_worktrees_reaps_complete_without_podman
    run_test test_clean_worktrees_skips_running_stale_heartbeat_no_podman_hit
    run_test test_clean_worktrees_podman_failure_does_not_block_other_removals
    run_test test_clean_worktrees_preserves_complete_exit_code_3
    run_test test_clean_worktrees_preserves_complete_exit_code_6
    run_test test_include_active_without_force_rejected
    run_test test_clean_worktrees_include_active_reaps_guarded
    run_test test_clean_worktrees_unparseable_name_age_fallback

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
