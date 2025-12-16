#!/usr/bin/env bash
#===============================================================================
# Test: Dry Run Completeness
#
# Verifies that --dry-run output shows all configuration details.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_dry_run_shows_agent() {
    log_test "Testing dry-run shows agent name"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "Agent:" "Should show Agent line"
    assert_contains "$output" "CLAUDE" "Should show agent name"
}

test_dry_run_shows_instance_id() {
    log_test "Testing dry-run shows instance ID"

    local output
    output=$("$LAUNCH_SCRIPT" 42 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "Instance ID:" "Should show Instance ID line"
    assert_contains "$output" "42" "Should show correct instance ID"
}

test_dry_run_shows_project_path() {
    log_test "Testing dry-run shows project path"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "Project:" "Should show Project line"
    assert_contains "$output" "$TEST_PROJECT" "Should show project path"
}

test_dry_run_shows_image() {
    log_test "Testing dry-run shows container image"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "Image:" "Should show Image line"
    assert_contains "$output" "kapsis-sandbox" "Should show image name"
}

test_dry_run_shows_resources() {
    log_test "Testing dry-run shows resource limits"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "Resources:" "Should show Resources line"
    assert_contains "$output" "RAM" "Should show memory"
    assert_contains "$output" "CPUs" "Should show CPUs"
}

test_dry_run_shows_task() {
    log_test "Testing dry-run shows task description"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "fix the failing tests" --dry-run 2>&1) || true

    assert_contains "$output" "Task:" "Should show Task line"
    assert_contains "$output" "fix the failing" "Should show task text"
}

test_dry_run_shows_branch() {
    log_test "Testing dry-run shows branch when specified"

    # Initialize git repo for branch test
    cd "$TEST_PROJECT"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch .gitkeep
    git add .
    git commit -q -m "init"
    cd - > /dev/null

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --branch "feature/test-123" --dry-run 2>&1) || true

    assert_contains "$output" "Branch:" "Should show Branch line"
    assert_contains "$output" "feature/test-123" "Should show branch name"
}

test_dry_run_shows_podman_command() {
    log_test "Testing dry-run shows podman command"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "DRY RUN" "Should indicate dry run"
    assert_contains "$output" "podman run" "Should show podman command"
}

test_dry_run_shows_volume_mounts() {
    log_test "Testing dry-run shows volume mounts"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "-v" "Should show volume mount flags"
    assert_contains "$output" "/workspace" "Should show workspace mount"
}

test_dry_run_shows_env_vars() {
    log_test "Testing dry-run shows environment variables"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "KAPSIS_AGENT_ID" "Should show agent ID env var"
    assert_contains "$output" "KAPSIS_PROJECT" "Should show project env var"
}

test_dry_run_shows_memory_limit() {
    log_test "Testing dry-run shows memory limit in command"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "--memory=" "Should show memory limit flag"
}

test_dry_run_shows_cpu_limit() {
    log_test "Testing dry-run shows CPU limit in command"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "--cpus=" "Should show CPU limit flag"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Dry Run Completeness"

    # Setup
    setup_test_project

    # Run tests
    run_test test_dry_run_shows_agent
    run_test test_dry_run_shows_instance_id
    run_test test_dry_run_shows_project_path
    run_test test_dry_run_shows_image
    run_test test_dry_run_shows_resources
    run_test test_dry_run_shows_task
    run_test test_dry_run_shows_branch
    run_test test_dry_run_shows_podman_command
    run_test test_dry_run_shows_volume_mounts
    run_test test_dry_run_shows_env_vars
    run_test test_dry_run_shows_memory_limit
    run_test test_dry_run_shows_cpu_limit

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
