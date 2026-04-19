#!/usr/bin/env bash
#===============================================================================
# Test: Cleanup --repair and store corruption detection (Issue #249)
#
# Verifies:
#   1. --repair flag is parsed and dispatches repair_store()
#   2. --repair sets explicit_action_requested (skips defaults)
#   3. STORE_CORRUPTED variable is declared
#   4. clean_containers() uses podman system check for pre-check
#   5. Corruption detection prints --repair suggestion
#   6. Sandbox cleanup uses find -not -type l for chmod
#   7. repair_store() has Linux platform guard
#   8. --all does NOT trigger repair_store()
#
# Category: validation
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

#===============================================================================
# Static-content assertions on kapsis-cleanup.sh
#===============================================================================

test_store_corrupted_variable_declared() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "STORE_CORRUPTED=false" \
        "STORE_CORRUPTED should be initialized to false"
}

test_clean_repair_variable_declared() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "CLEAN_REPAIR=false" \
        "CLEAN_REPAIR should be initialized to false"
}

test_repair_flag_sets_explicit_action() {
    # Extract only the --repair) case branch at the correct indentation
    # (inside the while/case block, not inside the usage heredoc)
    local branch
    branch=$(awk '
        /^            --repair\)/ {capture=1; next}
        capture && /;;/ {print; capture=0; next}
        capture {print}
    ' "$CLEANUP_SCRIPT")
    assert_contains "$branch" "explicit_action_requested=true" \
        "Branch for --repair should set explicit_action_requested=true"
}

test_corruption_detection_uses_system_check() {
    # clean_containers() should call podman system check --quick as a pre-check
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "podman system check --quick" \
        "clean_containers should run podman system check --quick"
}

test_corruption_prints_repair_suggestion() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "kapsis-cleanup --repair" \
        "Corruption detection should suggest kapsis-cleanup --repair"
}

test_sandbox_chmod_uses_find_not_type_l() {
    # clean_sandboxes() should use find ... -not -type l to avoid following symlinks
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    # shellcheck disable=SC2016  # literal match, not expansion
    assert_contains "$content" 'find "$sandbox" -xdev -not -type l -exec chmod' \
        "clean_sandboxes should use find -xdev -not -type l for symlink-safe chmod"
}

test_repair_linux_guard() {
    # repair_store() should check for Linux and provide direct instructions
    local snippet
    snippet=$(sed -n '/^repair_store()/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$snippet" "is_linux" \
        "repair_store should contain is_linux platform guard"
    assert_contains "$snippet" "podman system check --repair --force" \
        "repair_store should reference podman system check --repair --force"
}

test_repair_stage2_uses_machine_rm() {
    # Stage 2 should use podman machine rm, not SSH+rm-rf
    local snippet
    snippet=$(sed -n '/^repair_store()/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$snippet" "podman machine rm -f" \
        "repair_store stage 2 should use podman machine rm -f"
    assert_contains "$snippet" "podman machine init" \
        "repair_store stage 2 should run podman machine init"
    assert_contains "$snippet" "podman machine start" \
        "repair_store stage 2 should run podman machine start"
}

test_repair_in_usage_help() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "--repair" \
        "usage() should document --repair flag"
    assert_contains "$content" "Store repair" \
        "WHAT GETS CLEANED should include Store repair"
}

test_summary_shows_corruption_warning() {
    # print_summary() should check STORE_CORRUPTED and warn
    local snippet
    snippet=$(sed -n '/^print_summary()/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$snippet" "STORE_CORRUPTED" \
        "print_summary should check STORE_CORRUPTED flag"
}

test_health_check_skipped_in_dry_run() {
    # The podman system check --quick should be gated by DRY_RUN != true
    local snippet
    snippet=$(sed -n '/^clean_containers()/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$snippet" 'DRY_RUN" != "true"' \
        "Health check should be gated by DRY_RUN"
}

test_podman_rm_uses_timeout() {
    # podman rm should be wrapped with timeout to avoid hanging on corrupted store
    local snippet
    snippet=$(sed -n '/^clean_containers()/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$snippet" "timeout 30 podman rm" \
        "podman rm should use timeout wrapper"
}

test_repair_uses_machine_name_variable() {
    # repair_store should use a configurable machine name, not hardcoded
    local snippet
    snippet=$(sed -n '/^repair_store()/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$snippet" "KAPSIS_PODMAN_MACHINE" \
        "repair_store should use KAPSIS_PODMAN_MACHINE variable"
}

test_sanity_check_uses_podman_info() {
    # Post-repair sanity check should use podman info (no network dependency)
    local snippet
    snippet=$(sed -n '/^repair_store()/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$snippet" "podman info" \
        "repair_store sanity check should use podman info"
}

#===============================================================================
# Behavioral runtime tests (no container)
#===============================================================================

# Helper: invoke kapsis-cleanup.sh with cleanup functions stubbed out, so we
# can observe which ones ran based on marker files. Reuses the pattern from
# test-cleanup-vm-health.sh.
_invoke_cleanup() {
    local marker_dir="$1"
    shift

    local stub_file="$marker_dir/stubs.sh"
    cat > "$stub_file" <<'STUBS'
clean_worktrees()      { touch "$MARKER_DIR/clean_worktrees"; }
clean_sandboxes()      { touch "$MARKER_DIR/clean_sandboxes"; }
clean_status()         { touch "$MARKER_DIR/clean_status"; }
clean_sanitized_git()  { touch "$MARKER_DIR/clean_sanitized_git"; }
clean_audit()          { touch "$MARKER_DIR/clean_audit"; }
clean_containers()     { touch "$MARKER_DIR/clean_containers"; }
clean_volumes()        { touch "$MARKER_DIR/clean_volumes"; }
clean_images()         { touch "$MARKER_DIR/clean_images"; }
clean_logs()           { touch "$MARKER_DIR/clean_logs"; }
clean_ssh_cache()      { touch "$MARKER_DIR/clean_ssh_cache"; }
clean_branches()       { touch "$MARKER_DIR/clean_branches"; }
vm_health_check()      { touch "$MARKER_DIR/vm_health_check"; }
repair_store()         { touch "$MARKER_DIR/repair_store"; }
print_summary()        { :; }
confirm()              { return 0; }
STUBS

    MARKER_DIR="$marker_dir" bash -c '
        set +e
        script_body=$(sed "s|^main \"\\\$@\"$|# main invocation suppressed|" "'"$CLEANUP_SCRIPT"'")
        # shellcheck disable=SC1090
        source /dev/stdin <<< "$script_body"
        source "'"$stub_file"'"
        main "$@"
    ' -- "$@" >/dev/null 2>&1 || true
}

test_repair_flag_recognized() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-249-parse.XXXXXX")

    # --repair --dry-run should parse and invoke repair_store
    _invoke_cleanup "$marker_dir" --repair --dry-run

    assert_file_exists "$marker_dir/repair_store" \
        "--repair --dry-run should invoke repair_store()"

    rm -rf "$marker_dir"
}

test_repair_invokes_repair_store() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-249-invoke.XXXXXX")

    _invoke_cleanup "$marker_dir" --repair --force

    assert_file_exists "$marker_dir/repair_store" \
        "--repair --force should invoke repair_store()"

    rm -rf "$marker_dir"
}

test_repair_skips_defaults() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-249-skip.XXXXXX")

    _invoke_cleanup "$marker_dir" --repair --force --dry-run

    assert_file_exists     "$marker_dir/repair_store"        "--repair should invoke repair_store"
    assert_file_not_exists "$marker_dir/clean_worktrees"     "--repair alone must NOT trigger clean_worktrees"
    assert_file_not_exists "$marker_dir/clean_sandboxes"     "--repair alone must NOT trigger clean_sandboxes"
    assert_file_not_exists "$marker_dir/clean_status"        "--repair alone must NOT trigger clean_status"
    assert_file_not_exists "$marker_dir/clean_sanitized_git" "--repair alone must NOT trigger clean_sanitized_git"
    assert_file_not_exists "$marker_dir/clean_audit"         "--repair alone must NOT trigger clean_audit"
    assert_file_not_exists "$marker_dir/clean_containers"    "--repair alone must NOT trigger clean_containers"
    assert_file_not_exists "$marker_dir/clean_volumes"       "--repair alone must NOT trigger clean_volumes"
    assert_file_not_exists "$marker_dir/clean_images"        "--repair alone must NOT trigger clean_images"
    assert_file_not_exists "$marker_dir/clean_logs"          "--repair alone must NOT trigger clean_logs"
    assert_file_not_exists "$marker_dir/clean_branches"      "--repair alone must NOT trigger clean_branches"

    rm -rf "$marker_dir"
}

test_all_flag_excludes_repair() {
    local marker_dir
    marker_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-249-all.XXXXXX")

    _invoke_cleanup "$marker_dir" --all --force --dry-run

    assert_file_not_exists "$marker_dir/repair_store" \
        "--all must NOT trigger repair_store (repair is not routine cleanup)"

    rm -rf "$marker_dir"
}

#===============================================================================
# Runner
#===============================================================================

run_test test_store_corrupted_variable_declared
run_test test_clean_repair_variable_declared
run_test test_repair_flag_sets_explicit_action
run_test test_corruption_detection_uses_system_check
run_test test_corruption_prints_repair_suggestion
run_test test_sandbox_chmod_uses_find_not_type_l
run_test test_repair_linux_guard
run_test test_repair_stage2_uses_machine_rm
run_test test_repair_in_usage_help
run_test test_summary_shows_corruption_warning
run_test test_health_check_skipped_in_dry_run
run_test test_podman_rm_uses_timeout
run_test test_repair_uses_machine_name_variable
run_test test_sanity_check_uses_podman_info
run_test test_repair_flag_recognized
run_test test_repair_invokes_repair_store
run_test test_repair_skips_defaults
run_test test_all_flag_excludes_repair

print_summary
