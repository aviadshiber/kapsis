#!/usr/bin/env bash
#===============================================================================
# Test: Git Remote Utilities (git-remote-utils.sh)
#
# Unit tests for scripts/lib/git-remote-utils.sh - the git URL parsing library.
#
# Tests verify:
#   - detect_git_provider() correctly identifies GitHub/GitLab/Bitbucket
#   - extract_repo_path() parses owner/repo from various URL formats
#   - extract_repo_owner() extracts just the owner
#   - extract_base_url() extracts protocol://domain
#   - validate_repo_path() security validation
#   - generate_pr_url() generates correct PR URLs per provider
#   - get_pr_term() returns PR vs MR per provider
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/git-remote-utils.sh"

#===============================================================================
# detect_git_provider() TESTS
#===============================================================================

test_detect_github_https() {
    log_test "detect_git_provider: identifies GitHub from HTTPS URL"

    local result
    result=$(detect_git_provider "https://github.com/owner/repo.git")

    assert_equals "github" "$result" "Should detect github from HTTPS URL"
}

test_detect_github_ssh() {
    log_test "detect_git_provider: identifies GitHub from SSH URL"

    local result
    result=$(detect_git_provider "git@github.com:owner/repo.git")

    assert_equals "github" "$result" "Should detect github from SSH URL"
}

test_detect_gitlab_https() {
    log_test "detect_git_provider: identifies GitLab from HTTPS URL"

    local result
    result=$(detect_git_provider "https://gitlab.com/owner/repo.git")

    assert_equals "gitlab" "$result" "Should detect gitlab from HTTPS URL"
}

test_detect_gitlab_ssh() {
    log_test "detect_git_provider: identifies GitLab from SSH URL"

    local result
    result=$(detect_git_provider "git@gitlab.com:owner/repo.git")

    assert_equals "gitlab" "$result" "Should detect gitlab from SSH URL"
}

test_detect_bitbucket_cloud_https() {
    log_test "detect_git_provider: identifies Bitbucket Cloud from HTTPS URL"

    local result
    result=$(detect_git_provider "https://bitbucket.org/owner/repo.git")

    assert_equals "bitbucket" "$result" "Should detect bitbucket from HTTPS URL"
}

test_detect_bitbucket_cloud_ssh() {
    log_test "detect_git_provider: identifies Bitbucket Cloud from SSH URL"

    local result
    result=$(detect_git_provider "git@bitbucket.org:owner/repo.git")

    assert_equals "bitbucket" "$result" "Should detect bitbucket from SSH URL"
}

test_detect_bitbucket_server() {
    log_test "detect_git_provider: identifies Bitbucket Server from self-hosted URL"

    local result
    result=$(detect_git_provider "https://git.taboolasyndication.com/scm/proj/repo.git")

    assert_equals "bitbucket-server" "$result" "Should detect bitbucket-server from Taboola URL"
}

test_detect_bitbucket_server_ssh() {
    log_test "detect_git_provider: identifies Bitbucket Server from self-hosted SSH URL"

    local result
    result=$(detect_git_provider "git@bitbucket.mycompany.com:7999/proj/repo.git")

    assert_equals "bitbucket-server" "$result" "Should detect bitbucket-server from SSH URL with bitbucket subdomain"
}

test_detect_unknown_provider() {
    log_test "detect_git_provider: returns 'unknown' for unrecognized URLs"

    local result
    result=$(detect_git_provider "https://mygitserver.internal.local/repo.git")

    assert_equals "unknown" "$result" "Should return unknown for unrecognized host"
}

#===============================================================================
# extract_repo_path() TESTS
#===============================================================================

test_extract_repo_path_https() {
    log_test "extract_repo_path: extracts owner/repo from HTTPS URL"

    local result
    result=$(extract_repo_path "https://github.com/aviadshiber/kapsis.git")

    assert_equals "aviadshiber/kapsis" "$result" "Should extract owner/repo from HTTPS"
}

test_extract_repo_path_ssh() {
    log_test "extract_repo_path: extracts owner/repo from SSH URL"

    local result
    result=$(extract_repo_path "git@github.com:aviadshiber/kapsis.git")

    assert_equals "aviadshiber/kapsis" "$result" "Should extract owner/repo from SSH"
}

test_extract_repo_path_no_git_suffix() {
    log_test "extract_repo_path: handles URLs without .git suffix"

    local result
    result=$(extract_repo_path "https://github.com/aviadshiber/kapsis")

    assert_equals "aviadshiber/kapsis" "$result" "Should handle URLs without .git suffix"
}

test_extract_repo_path_bitbucket_server() {
    log_test "extract_repo_path: extracts from Bitbucket Server URL"

    local result
    result=$(extract_repo_path "https://git.taboolasyndication.com/scm/proj/repo.git")

    assert_equals "proj/repo" "$result" "Should extract project/repo from Bitbucket Server"
}

#===============================================================================
# extract_repo_owner() TESTS
#===============================================================================

test_extract_owner_https() {
    log_test "extract_repo_owner: extracts owner from HTTPS URL"

    local result
    result=$(extract_repo_owner "https://github.com/aviadshiber/kapsis.git")

    assert_equals "aviadshiber" "$result" "Should extract owner from HTTPS"
}

test_extract_owner_ssh() {
    log_test "extract_repo_owner: extracts owner from SSH URL"

    local result
    result=$(extract_repo_owner "git@github.com:aviadshiber/kapsis.git")

    assert_equals "aviadshiber" "$result" "Should extract owner from SSH"
}

#===============================================================================
# extract_base_url() TESTS
#===============================================================================

test_extract_base_url_https() {
    log_test "extract_base_url: extracts domain from HTTPS URL"

    local result
    result=$(extract_base_url "https://github.com/aviadshiber/kapsis.git")

    assert_equals "https://github.com" "$result" "Should extract https://domain"
}

test_extract_base_url_ssh() {
    log_test "extract_base_url: extracts domain from SSH URL"

    local result
    result=$(extract_base_url "git@github.com:aviadshiber/kapsis.git")

    assert_equals "https://github.com" "$result" "Should convert SSH to HTTPS domain"
}

test_extract_base_url_bitbucket_server() {
    log_test "extract_base_url: extracts from Bitbucket Server URL"

    local result
    result=$(extract_base_url "https://git.taboolasyndication.com/scm/proj/repo.git")

    assert_equals "https://git.taboolasyndication.com" "$result" "Should extract self-hosted domain"
}

#===============================================================================
# validate_repo_path() TESTS
#===============================================================================

test_validate_repo_path_valid() {
    log_test "validate_repo_path: accepts valid owner/repo format"

    if validate_repo_path "aviadshiber/kapsis"; then
        log_pass "Valid path accepted"
    else
        log_fail "Valid path rejected"
        return 1
    fi
}

test_validate_repo_path_with_dots_hyphens() {
    log_test "validate_repo_path: accepts dots and hyphens"

    if validate_repo_path "my-org.github/my-repo.js"; then
        log_pass "Path with dots/hyphens accepted"
    else
        log_fail "Path with dots/hyphens rejected"
        return 1
    fi
}

test_validate_repo_path_rejects_traversal() {
    log_test "validate_repo_path: rejects path traversal"

    if validate_repo_path "../../../etc/passwd"; then
        log_fail "Path traversal should be rejected"
        return 1
    else
        log_pass "Path traversal rejected"
    fi
}

test_validate_repo_path_rejects_spaces() {
    log_test "validate_repo_path: rejects spaces"

    if validate_repo_path "owner/repo name"; then
        log_fail "Path with spaces should be rejected"
        return 1
    else
        log_pass "Path with spaces rejected"
    fi
}

test_validate_repo_path_rejects_multiple_slashes() {
    log_test "validate_repo_path: rejects multiple slashes"

    if validate_repo_path "owner/sub/repo"; then
        log_fail "Path with multiple slashes should be rejected"
        return 1
    else
        log_pass "Multiple slashes rejected"
    fi
}

#===============================================================================
# generate_pr_url() TESTS
#===============================================================================

test_generate_pr_url_github() {
    log_test "generate_pr_url: generates correct GitHub PR URL"

    local result
    result=$(generate_pr_url "https://github.com/aviadshiber/kapsis.git" "feature/test-branch")

    assert_equals "https://github.com/aviadshiber/kapsis/compare/feature/test-branch?expand=1" "$result" \
        "Should generate GitHub compare URL"
}

test_generate_pr_url_gitlab() {
    log_test "generate_pr_url: generates correct GitLab MR URL"

    local result
    result=$(generate_pr_url "https://gitlab.com/myorg/myrepo.git" "feature/test")

    assert_equals "https://gitlab.com/myorg/myrepo/-/merge_requests/new?merge_request[source_branch]=feature/test" "$result" \
        "Should generate GitLab MR URL"
}

test_generate_pr_url_bitbucket_cloud() {
    log_test "generate_pr_url: generates correct Bitbucket Cloud PR URL"

    local result
    result=$(generate_pr_url "https://bitbucket.org/myteam/myrepo.git" "feature/new")

    assert_equals "https://bitbucket.org/myteam/myrepo/pull-requests/new?source=feature/new" "$result" \
        "Should generate Bitbucket Cloud PR URL"
}

test_generate_pr_url_bitbucket_server() {
    log_test "generate_pr_url: generates correct Bitbucket Server PR URL"

    local result
    result=$(generate_pr_url "https://git.taboolasyndication.com/scm/proj/repo.git" "DEV-123-feature")

    assert_equals "https://git.taboolasyndication.com/proj/repo/pull-requests/new?source=DEV-123-feature" "$result" \
        "Should generate Bitbucket Server PR URL"
}

test_generate_pr_url_unknown() {
    log_test "generate_pr_url: returns empty for unknown provider"

    local result
    result=$(generate_pr_url "https://unknown.server.local/repo.git" "branch")

    assert_equals "" "$result" "Should return empty for unknown provider"
}

#===============================================================================
# get_pr_term() TESTS
#===============================================================================

test_get_pr_term_github() {
    log_test "get_pr_term: returns 'PR' for GitHub"

    local result
    result=$(get_pr_term "https://github.com/owner/repo.git")

    assert_equals "PR" "$result" "GitHub should use 'PR'"
}

test_get_pr_term_gitlab() {
    log_test "get_pr_term: returns 'MR' for GitLab"

    local result
    result=$(get_pr_term "https://gitlab.com/owner/repo.git")

    assert_equals "MR" "$result" "GitLab should use 'MR'"
}

test_get_pr_term_bitbucket() {
    log_test "get_pr_term: returns 'PR' for Bitbucket"

    local result
    result=$(get_pr_term "https://bitbucket.org/owner/repo.git")

    assert_equals "PR" "$result" "Bitbucket should use 'PR'"
}

#===============================================================================
# TEST RUNNER
#===============================================================================

main() {
    print_test_header "Git Remote Utilities (git-remote-utils.sh)"

    # detect_git_provider tests
    run_test test_detect_github_https
    run_test test_detect_github_ssh
    run_test test_detect_gitlab_https
    run_test test_detect_gitlab_ssh
    run_test test_detect_bitbucket_cloud_https
    run_test test_detect_bitbucket_cloud_ssh
    run_test test_detect_bitbucket_server
    run_test test_detect_bitbucket_server_ssh
    run_test test_detect_unknown_provider

    # extract_repo_path tests
    run_test test_extract_repo_path_https
    run_test test_extract_repo_path_ssh
    run_test test_extract_repo_path_no_git_suffix
    run_test test_extract_repo_path_bitbucket_server

    # extract_repo_owner tests
    run_test test_extract_owner_https
    run_test test_extract_owner_ssh

    # extract_base_url tests
    run_test test_extract_base_url_https
    run_test test_extract_base_url_ssh
    run_test test_extract_base_url_bitbucket_server

    # validate_repo_path tests
    run_test test_validate_repo_path_valid
    run_test test_validate_repo_path_with_dots_hyphens
    run_test test_validate_repo_path_rejects_traversal
    run_test test_validate_repo_path_rejects_spaces
    run_test test_validate_repo_path_rejects_multiple_slashes

    # generate_pr_url tests
    run_test test_generate_pr_url_github
    run_test test_generate_pr_url_gitlab
    run_test test_generate_pr_url_bitbucket_cloud
    run_test test_generate_pr_url_bitbucket_server
    run_test test_generate_pr_url_unknown

    # get_pr_term tests
    run_test test_get_pr_term_github
    run_test test_get_pr_term_gitlab
    run_test test_get_pr_term_bitbucket

    # Print summary
    print_summary
}

main "$@"
