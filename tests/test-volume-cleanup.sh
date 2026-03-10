#!/usr/bin/env bash
#===============================================================================
# Test: Volume and Image Cleanup (Fix #191)
#
# Verifies that cleanup enhancements work correctly:
# - --images flag parsing
# - --all includes images
# - Volume pattern matching
# - Dry-run mode for images
# - Auto-cleanup volume function
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests
# shellcheck disable=SC2016  # Single-quoted strings are intentional for literal matching

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_cleanup_script_has_images_flag() {
    log_test "Testing --images flag is documented in usage"

    local usage_output
    usage_output=$("$CLEANUP_SCRIPT" --help 2>&1 || true)

    assert_contains "$usage_output" "--images" "Usage should document --images flag"
}

test_cleanup_images_flag_parsing() {
    log_test "Testing --images flag sets CLEAN_IMAGES variable"

    # Source the script to test parsing (grep for the flag in arg parser)
    local content
    content=$(cat "$CLEANUP_SCRIPT")

    assert_contains "$content" "--images)" "Arg parser should handle --images"
    assert_contains "$content" "CLEAN_IMAGES=true" "Should set CLEAN_IMAGES=true"
}

test_cleanup_all_includes_images() {
    log_test "Testing --all flag triggers image cleanup"

    local content
    content=$(cat "$CLEANUP_SCRIPT")

    assert_contains "$content" 'CLEAN_IMAGES" == "true" ]] || [[ "$CLEAN_ALL" == "true"' \
        "--all should trigger clean_images"
}

test_cleanup_images_dry_run_support() {
    log_test "Testing clean_images respects DRY_RUN flag"

    local content
    content=$(cat "$CLEANUP_SCRIPT")

    # Verify clean_images checks DRY_RUN before removing
    assert_contains "$content" 'DRY_RUN" == "true"' "clean_images should check DRY_RUN"
    assert_contains "$content" "Kapsis Images" "Should have Kapsis Images section header"
}

test_cleanup_volumes_pattern_matching() {
    log_test "Testing volume pattern matches kapsis-* naming"

    local content
    content=$(cat "$CLEANUP_SCRIPT")

    # Verify the grep pattern used for volume detection
    assert_contains "$content" 'grep -E "^kapsis-"' "Should filter volumes by kapsis- prefix"
}

test_launch_has_keep_volumes_flag() {
    log_test "Testing launch-agent.sh has --keep-volumes flag"

    local content
    content=$(cat "$LAUNCH_SCRIPT")

    assert_contains "$content" "--keep-volumes)" "Arg parser should handle --keep-volumes"
    assert_contains "$content" "KEEP_VOLUMES=true" "Should set KEEP_VOLUMES=true"
}

test_launch_has_cleanup_agent_volumes() {
    log_test "Testing launch-agent.sh has cleanup_agent_volumes function"

    local content
    content=$(cat "$LAUNCH_SCRIPT")

    assert_contains "$content" "cleanup_agent_volumes()" "Should define cleanup_agent_volumes function"
    assert_contains "$content" "podman volume rm" "Should remove volumes"
}

test_launch_auto_cleanup_invocation() {
    log_test "Testing auto-cleanup is invoked after session end"

    local content
    content=$(cat "$LAUNCH_SCRIPT")

    assert_contains "$content" 'KEEP_VOLUMES" != "true"' "Should check KEEP_VOLUMES flag"
    assert_contains "$content" 'cleanup_agent_volumes "$AGENT_ID"' "Should call cleanup with agent ID"
}

test_clean_images_function_exists() {
    log_test "Testing clean_images function exists in cleanup script"

    local content
    content=$(cat "$CLEANUP_SCRIPT")

    assert_contains "$content" "clean_images()" "Should define clean_images function"
    assert_contains "$content" "podman rmi" "Should use podman rmi to remove images"
    assert_contains "$content" "podman image prune" "Should prune dangling images"
}

test_cleanup_keep_volumes_documented() {
    log_test "Testing --keep-volumes is documented in usage"

    local usage_output
    usage_output=$(head -250 "$LAUNCH_SCRIPT")

    assert_contains "$usage_output" "--keep-volumes" "Usage should document --keep-volumes flag"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Volume and Image Cleanup (Fix #191)"

    run_test test_cleanup_script_has_images_flag
    run_test test_cleanup_images_flag_parsing
    run_test test_cleanup_all_includes_images
    run_test test_cleanup_images_dry_run_support
    run_test test_cleanup_volumes_pattern_matching
    run_test test_launch_has_keep_volumes_flag
    run_test test_launch_has_cleanup_agent_volumes
    run_test test_launch_auto_cleanup_invocation
    run_test test_clean_images_function_exists
    run_test test_cleanup_keep_volumes_documented

    print_summary
}

main "$@"
