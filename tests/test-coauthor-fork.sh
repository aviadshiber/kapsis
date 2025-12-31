#!/usr/bin/env bash
#===============================================================================
# Test: Co-Author and Fork Workflow
#
# Verifies the co-author deduplication and fork workflow fallback features.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the post-container-git script functions for unit testing
POST_CONTAINER_GIT="$KAPSIS_ROOT/scripts/post-container-git.sh"

# Helper function to create a temp git repo with minimal config
create_temp_git_repo() {
    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git config user.email "testuser@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git config tag.gpgsign false
    echo "$temp_repo"
}

#===============================================================================
# TEST CASES: Co-Author Functionality
#===============================================================================

test_build_coauthor_trailers_single() {
    log_test "Testing single co-author trailer generation"

    # Create a temp git repo for the test
    local temp_repo
    temp_repo=$(create_temp_git_repo)

    # Source the function
    source "$POST_CONTAINER_GIT"

    # Test with a single co-author
    local result
    result=$(build_coauthor_trailers "Aviad Shiber <aviadshiber@gmail.com>" "$temp_repo")

    # Cleanup
    rm -rf "$temp_repo"

    assert_contains "$result" "Co-authored-by: Aviad Shiber <aviadshiber@gmail.com>" \
        "Should generate co-author trailer"
}

test_build_coauthor_trailers_multiple() {
    log_test "Testing multiple co-author trailers generation"

    local temp_repo
    temp_repo=$(create_temp_git_repo)

    source "$POST_CONTAINER_GIT"

    # Test with multiple co-authors (pipe-separated)
    local result
    result=$(build_coauthor_trailers "Author One <one@test.com>|Author Two <two@test.com>" "$temp_repo")

    rm -rf "$temp_repo"

    assert_contains "$result" "Co-authored-by: Author One <one@test.com>" \
        "Should include first co-author"
    assert_contains "$result" "Co-authored-by: Author Two <two@test.com>" \
        "Should include second co-author"
}

test_build_coauthor_trailers_dedup() {
    log_test "Testing co-author deduplication against git config user"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    # Set the git user to the same as the co-author
    git config user.email "aviadshiber@gmail.com"
    git config user.name "Aviad Shiber"
    git config commit.gpgsign false

    source "$POST_CONTAINER_GIT"

    # The co-author is the same as git user - should be skipped
    local result
    result=$(build_coauthor_trailers "Aviad Shiber <aviadshiber@gmail.com>" "$temp_repo")

    rm -rf "$temp_repo"

    # Result should be empty (co-author deduplicated)
    if [[ -n "$result" ]]; then
        log_error "Expected empty result for deduplicated co-author, got: $result"
        return 1
    fi
    log_info "Co-author correctly deduplicated"
}

test_build_coauthor_trailers_partial_dedup() {
    log_test "Testing partial deduplication with multiple co-authors"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git config user.email "one@test.com"
    git config user.name "Author One"
    git config commit.gpgsign false

    source "$POST_CONTAINER_GIT"

    # First co-author matches git user, second doesn't
    local result
    result=$(build_coauthor_trailers "Author One <one@test.com>|Author Two <two@test.com>" "$temp_repo")

    rm -rf "$temp_repo"

    # Should NOT include first author (deduplicated)
    assert_not_contains "$result" "Author One" \
        "Should deduplicate first co-author matching git user"
    # Should include second author
    assert_contains "$result" "Co-authored-by: Author Two <two@test.com>" \
        "Should include second co-author"
}

test_build_coauthor_trailers_empty() {
    log_test "Testing empty co-author list"

    local temp_repo
    temp_repo=$(create_temp_git_repo)

    source "$POST_CONTAINER_GIT"

    local result
    result=$(build_coauthor_trailers "" "$temp_repo")

    rm -rf "$temp_repo"

    if [[ -n "$result" ]]; then
        log_error "Expected empty result for empty input, got: $result"
        return 1
    fi
    log_info "Empty input handled correctly"
}

#===============================================================================
# TEST CASES: Fork Workflow
#===============================================================================

test_is_github_repo_https() {
    log_test "Testing GitHub repo detection for HTTPS URL"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git remote add origin "https://github.com/aviadshiber/kapsis.git"

    source "$POST_CONTAINER_GIT"

    if is_github_repo "$temp_repo" "origin"; then
        log_info "Correctly detected GitHub HTTPS repo"
    else
        rm -rf "$temp_repo"
        log_error "Failed to detect GitHub HTTPS repo"
        return 1
    fi

    rm -rf "$temp_repo"
}

test_is_github_repo_ssh() {
    log_test "Testing GitHub repo detection for SSH URL"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git remote add origin "git@github.com:aviadshiber/kapsis.git"

    source "$POST_CONTAINER_GIT"

    if is_github_repo "$temp_repo" "origin"; then
        log_info "Correctly detected GitHub SSH repo"
    else
        rm -rf "$temp_repo"
        log_error "Failed to detect GitHub SSH repo"
        return 1
    fi

    rm -rf "$temp_repo"
}

test_is_github_repo_not_github() {
    log_test "Testing non-GitHub repo detection"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git remote add origin "https://gitlab.com/user/repo.git"

    source "$POST_CONTAINER_GIT"

    if is_github_repo "$temp_repo" "origin"; then
        rm -rf "$temp_repo"
        log_error "Incorrectly detected GitLab as GitHub"
        return 1
    else
        log_info "Correctly identified non-GitHub repo"
    fi

    rm -rf "$temp_repo"
}

test_generate_fork_fallback() {
    log_test "Testing fork fallback command generation"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git remote add origin "https://github.com/aviadshiber/kapsis.git"

    source "$POST_CONTAINER_GIT"

    local result
    result=$(generate_fork_fallback "$temp_repo" "feature/test" "origin")

    rm -rf "$temp_repo"

    assert_contains "$result" "gh repo fork" \
        "Should include gh repo fork command"
    assert_contains "$result" "aviadshiber/kapsis" \
        "Should include repo path"
    assert_contains "$result" "git push -u fork feature/test" \
        "Should include push to fork command"
}

test_generate_fork_fallback_ssh() {
    log_test "Testing fork fallback for SSH URL"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git remote add origin "git@github.com:someuser/somerepo.git"

    source "$POST_CONTAINER_GIT"

    local result
    result=$(generate_fork_fallback "$temp_repo" "my-branch" "origin")

    rm -rf "$temp_repo"

    assert_contains "$result" "someuser/somerepo" \
        "Should extract repo from SSH URL"
    assert_contains "$result" "my-branch" \
        "Should include branch name"
}

test_generate_fork_fallback_not_github() {
    log_test "Testing fork fallback returns empty for non-GitHub"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git remote add origin "https://gitlab.com/user/repo.git"

    source "$POST_CONTAINER_GIT"

    local result
    result=$(generate_fork_fallback "$temp_repo" "feature/test" "origin" 2>/dev/null || echo "")

    rm -rf "$temp_repo"

    # For non-GitHub repos, generate_fork_fallback returns error (no output)
    if [[ -z "$result" ]]; then
        log_info "Correctly returned empty for non-GitHub repo"
    else
        log_error "Expected empty result for non-GitHub repo, got: $result"
        return 1
    fi
}

test_generate_fork_pr_url() {
    log_test "Testing fork PR URL generation"

    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git remote add origin "https://github.com/aviadshiber/kapsis.git"

    source "$POST_CONTAINER_GIT"

    local result
    result=$(generate_fork_pr_url "$temp_repo" "feature/awesome" "origin")

    rm -rf "$temp_repo"

    assert_contains "$result" "github.com/aviadshiber/kapsis/compare" \
        "Should include upstream repo compare URL"
    assert_contains "$result" "feature/awesome" \
        "Should include branch name"
}

#===============================================================================
# TEST CASES: Kapsis Version
#===============================================================================

test_get_kapsis_version() {
    log_test "Testing Kapsis version retrieval"

    source "$POST_CONTAINER_GIT"

    local result
    result=$(get_kapsis_version)

    # Should return something (version or "dev")
    if [[ -z "$result" ]]; then
        log_error "get_kapsis_version returned empty"
        return 1
    fi

    log_info "Kapsis version: $result"
    # Version should be semver-like or "dev"
    if [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || [[ "$result" == "dev" ]] || [[ "$result" =~ ^v[0-9]+ ]]; then
        log_info "Version format is valid"
    else
        log_warn "Version format unusual but accepting: $result"
    fi
}

#===============================================================================
# TEST CASES: Config Parsing
#===============================================================================

test_config_co_authors_parsing() {
    log_test "Testing co-authors config parsing with yq"

    if ! command -v yq &>/dev/null; then
        log_info "yq not installed, skipping config parsing test"
        return 0
    fi

    local config_file="$KAPSIS_ROOT/configs/claude.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_warn "Config file not found: $config_file"
        return 0
    fi

    local result
    result=$(yq -r '.git.co_authors[]' "$config_file" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || echo "")

    assert_contains "$result" "aviadshiber@gmail.com" \
        "Should parse co-author email from config"
}

test_config_fork_workflow_parsing() {
    log_test "Testing fork workflow config parsing with yq"

    if ! command -v yq &>/dev/null; then
        log_info "yq not installed, skipping config parsing test"
        return 0
    fi

    local config_file="$KAPSIS_ROOT/configs/claude.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_warn "Config file not found: $config_file"
        return 0
    fi

    local enabled
    enabled=$(yq -r '.git.fork_workflow.enabled // "false"' "$config_file")

    local fallback
    fallback=$(yq -r '.git.fork_workflow.fallback // "fork"' "$config_file")

    assert_equals "$enabled" "false" "Fork workflow should be disabled by default"
    assert_equals "$fallback" "fork" "Fork fallback should be 'fork' by default"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Co-Author and Fork Workflow"

    # Note: We don't use setup_test_project because these unit tests
    # create their own temp git repos and don't need the full Maven project setup.
    # KAPSIS_ROOT is already set by the test framework.

    # Co-author tests
    run_test test_build_coauthor_trailers_single
    run_test test_build_coauthor_trailers_multiple
    run_test test_build_coauthor_trailers_dedup
    run_test test_build_coauthor_trailers_partial_dedup
    run_test test_build_coauthor_trailers_empty

    # Fork workflow tests
    run_test test_is_github_repo_https
    run_test test_is_github_repo_ssh
    run_test test_is_github_repo_not_github
    run_test test_generate_fork_fallback
    run_test test_generate_fork_fallback_ssh
    run_test test_generate_fork_fallback_not_github
    run_test test_generate_fork_pr_url

    # Version test
    run_test test_get_kapsis_version

    # Config parsing tests
    run_test test_config_co_authors_parsing
    run_test test_config_fork_workflow_parsing

    # Summary
    print_summary
}

main "$@"
