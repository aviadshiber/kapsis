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

# Helper function to create a temp git repo with minimal config and initial commit
create_temp_git_repo() {
    local temp_repo
    temp_repo=$(mktemp -d)
    cd "$temp_repo"
    git init -q
    git config user.email "testuser@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git config tag.gpgsign false
    # Create initial commit so subsequent commits work reliably
    echo "init" > .gitkeep
    git add .gitkeep
    git commit -q -m "initial commit"
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

test_build_coauthor_trailers_duplicate_in_list() {
    log_test "Testing deduplication of duplicate entries in co-authors list"

    local temp_repo
    temp_repo=$(create_temp_git_repo)

    source "$POST_CONTAINER_GIT"

    # Same email appears twice in the list
    local result
    result=$(build_coauthor_trailers "Aviad Shiber <aviadshiber@gmail.com>|Aviad Shiber <aviadshiber@gmail.com>" "$temp_repo")

    rm -rf "$temp_repo"

    # Should only appear once
    local count
    count=$(echo "$result" | grep -c "aviadshiber@gmail.com" || echo "0")
    if [[ "$count" -ne 1 ]]; then
        log_error "Expected 1 occurrence, got: $count"
        return 1
    fi
    log_info "Duplicate entries correctly deduplicated"
}

test_build_coauthor_trailers_already_in_message() {
    log_test "Testing deduplication against commit message template"

    local temp_repo
    temp_repo=$(create_temp_git_repo)

    source "$POST_CONTAINER_GIT"

    # Commit message already contains the co-author email
    local commit_msg="feat: test

Co-authored-by: Aviad Shiber <aviadshiber@gmail.com>"

    local result
    result=$(build_coauthor_trailers "Aviad Shiber <aviadshiber@gmail.com>" "$temp_repo" "$commit_msg")

    rm -rf "$temp_repo"

    # Should be empty (co-author already in message)
    if [[ -n "$result" ]]; then
        log_error "Expected empty result when co-author already in message, got: $result"
        return 1
    fi
    log_info "Co-author in commit message correctly deduplicated"
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
    # Note: branch is now quoted for shell safety
    assert_contains "$result" "git push -u fork 'feature/test'" \
        "Should include push to fork command with quoted branch"
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
    assert_contains "$result" "'my-branch'" \
        "Should include quoted branch name"
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
# TEST CASES: Attribution Templates
#===============================================================================

test_config_attribution_parsing() {
    log_test "Testing git.attribution config parsing with yq"

    if ! command -v yq &>/dev/null; then
        log_warn "yq not installed — skipping attribution parsing test"
        return 0
    fi

    local config_file="$KAPSIS_ROOT/configs/claude.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_warn "Config file not found: $config_file"
        return 0
    fi

    local commit_attr
    commit_attr=$(yq -r '.git.attribution.commit' "$config_file" 2>/dev/null || echo "null")

    assert_contains "$commit_attr" "Generated by Kapsis" \
        "Should parse attribution.commit from config"
    assert_contains "$commit_attr" "{version}" \
        "Attribution should include {version} placeholder"
    assert_contains "$commit_attr" "{agent_id}" \
        "Attribution should include {agent_id} placeholder"

    local pr_attr
    pr_attr=$(yq -r '.git.attribution.pr' "$config_file" 2>/dev/null || echo "null")
    assert_contains "$pr_attr" "Generated by Kapsis" \
        "Should parse attribution.pr from config"
    assert_contains "$pr_attr" "(https://github.com/aviadshiber/kapsis)" \
        "PR attribution should include markdown link to repo"
}

test_attribution_placeholder_substitution() {
    log_test "Testing placeholder substitution in attribution template"

    local template="[Generated by Kapsis](https://github.com/aviadshiber/kapsis) v{version}
Agent: {agent_id}
Branch: {branch}
Worktree: {worktree}"

    local version="2.16.6"
    local agent_id="abc123"
    local branch="feature/test"
    local worktree="my-worktree"

    # Simulate launch-agent.sh's substitution logic
    local result="$template"
    result="${result//\{version\}/$version}"
    result="${result//\{agent_id\}/$agent_id}"
    result="${result//\{branch\}/$branch}"
    result="${result//\{worktree\}/$worktree}"

    assert_contains "$result" "v2.16.6" "Should substitute {version}"
    assert_contains "$result" "Agent: abc123" "Should substitute {agent_id}"
    assert_contains "$result" "Branch: feature/test" "Should substitute {branch}"
    assert_contains "$result" "Worktree: my-worktree" "Should substitute {worktree}"
    # Ensure no placeholders remain
    assert_not_contains "$result" "{version}" "No residual {version} placeholder"
    assert_not_contains "$result" "{agent_id}" "No residual {agent_id} placeholder"
    assert_not_contains "$result" "{branch}" "No residual {branch} placeholder"
    assert_not_contains "$result" "{worktree}" "No residual {worktree} placeholder"
}

test_attribution_commit_uses_env_var() {
    log_test "Testing commit_changes uses KAPSIS_ATTRIBUTION_COMMIT env var"

    local saved_dir="$SCRIPT_DIR"
    local temp_repo
    temp_repo=$(create_temp_git_repo)
    cd "$temp_repo"
    echo "hello" > file.txt
    git add file.txt

    source "$POST_CONTAINER_GIT"

    # Inject a custom attribution via env
    export KAPSIS_ATTRIBUTION_COMMIT="CUSTOM-ATTR v1.2.3"
    export KAPSIS_AGENT_TYPE="codex-cli"

    commit_changes "$temp_repo" "feat: my change" "test-agent" "" >/dev/null 2>&1 || true

    local last_msg
    last_msg=$(git -C "$temp_repo" log -1 --format=%B 2>/dev/null || echo "")

    unset KAPSIS_ATTRIBUTION_COMMIT
    unset KAPSIS_AGENT_TYPE
    cd "$saved_dir"
    rm -rf "$temp_repo"

    assert_contains "$last_msg" "feat: my change" \
        "Commit subject should be preserved"
    assert_contains "$last_msg" "CUSTOM-ATTR v1.2.3" \
        "Commit should contain attribution from KAPSIS_ATTRIBUTION_COMMIT env"
}

test_attribution_empty_disables() {
    log_test "Testing empty KAPSIS_ATTRIBUTION_COMMIT disables attribution"

    local saved_dir="$SCRIPT_DIR"
    local temp_repo
    temp_repo=$(create_temp_git_repo)
    cd "$temp_repo"
    echo "hello" > file.txt
    git add file.txt

    source "$POST_CONTAINER_GIT"

    # Empty string must disable the attribution block
    export KAPSIS_ATTRIBUTION_COMMIT=""
    export KAPSIS_AGENT_TYPE="codex-cli"

    commit_changes "$temp_repo" "feat: my change" "test-agent" "" >/dev/null 2>&1 || true

    local last_msg
    last_msg=$(git -C "$temp_repo" log -1 --format=%B 2>/dev/null || echo "")

    unset KAPSIS_ATTRIBUTION_COMMIT
    unset KAPSIS_AGENT_TYPE
    cd "$saved_dir"
    rm -rf "$temp_repo"

    assert_contains "$last_msg" "feat: my change" \
        "Commit subject should be preserved"
    assert_not_contains "$last_msg" "Generated by Kapsis" \
        "Empty KAPSIS_ATTRIBUTION_COMMIT should suppress attribution"
}

test_attribution_claude_skip_duplicate() {
    log_test "Testing Claude agent skips duplicate attribution when already in message"

    local saved_dir="$SCRIPT_DIR"

    # Test all Claude agent type variants
    local claude_types=("claude-cli" "claude" "claude-code")
    for agent_type in "${claude_types[@]}"; do
        local temp_repo
        temp_repo=$(create_temp_git_repo)
        cd "$temp_repo"
        echo "hello" > file.txt
        git add file.txt

        source "$POST_CONTAINER_GIT"

        export KAPSIS_ATTRIBUTION_COMMIT="[Generated by Kapsis](https://github.com/aviadshiber/kapsis) v1.0"
        export KAPSIS_AGENT_TYPE="$agent_type"

        # Commit message already contains the Kapsis signature (as if Claude already appended it)
        local preset_msg="feat: change

[Generated by Kapsis](https://github.com/aviadshiber/kapsis) v1.0"

        commit_changes "$temp_repo" "$preset_msg" "test-agent" "" >/dev/null 2>&1 || true

        local last_msg
        last_msg=$(git -C "$temp_repo" log -1 --format=%B 2>/dev/null || echo "")

        unset KAPSIS_ATTRIBUTION_COMMIT KAPSIS_AGENT_TYPE
        cd "$saved_dir"
        rm -rf "$temp_repo"

        # Verify subject is preserved
        assert_contains "$last_msg" "feat: change" \
            "Commit subject should be preserved for $agent_type"

        # Count occurrences — should be exactly 1 (not duplicated)
        local count
        count=$(echo "$last_msg" | grep -c "Generated by Kapsis" || echo "0")
        if [[ "$count" -ne 1 ]]; then
            log_error "Expected exactly 1 'Generated by Kapsis' for $agent_type, got: $count"
            log_error "Commit message: $last_msg"
            return 1
        fi
    done
    log_info "Claude attribution correctly deduplicated for all variants"
}

test_attribution_unset_uses_default() {
    log_test "Testing unset KAPSIS_ATTRIBUTION_COMMIT falls back to default"

    local saved_dir="$SCRIPT_DIR"
    local temp_repo
    temp_repo=$(create_temp_git_repo)
    cd "$temp_repo"
    echo "hello" > file.txt
    git add file.txt

    source "$POST_CONTAINER_GIT"

    # Ensure KAPSIS_ATTRIBUTION_COMMIT is truly unset (not empty)
    unset KAPSIS_ATTRIBUTION_COMMIT
    export KAPSIS_AGENT_TYPE="codex-cli"

    commit_changes "$temp_repo" "feat: default attr" "test-agent" "" >/dev/null 2>&1 || true

    local last_msg
    last_msg=$(git -C "$temp_repo" log -1 --format=%B 2>/dev/null || echo "")

    unset KAPSIS_AGENT_TYPE
    cd "$saved_dir"
    rm -rf "$temp_repo"

    assert_contains "$last_msg" "Generated by Kapsis" \
        "Unset KAPSIS_ATTRIBUTION_COMMIT should use default attribution"
}

#===============================================================================
# TEST CASES: CLI --co-author Flag
#===============================================================================

test_cli_co_author_merge() {
    log_test "Testing CLI co-authors merge with config co-authors (pipe-separated)"

    # Simulate the merge logic from launch-agent.sh parse_config()
    local GIT_CO_AUTHORS="Config Person <config@test.com>"
    local CLI_CO_AUTHORS=("CLI One <cli1@test.com>" "CLI Two <cli2@test.com>")

    for c in "${CLI_CO_AUTHORS[@]}"; do
        if [[ -n "${GIT_CO_AUTHORS:-}" ]]; then
            GIT_CO_AUTHORS+="|$c"
        else
            GIT_CO_AUTHORS="$c"
        fi
    done

    assert_contains "$GIT_CO_AUTHORS" "Config Person <config@test.com>" \
        "Merged list keeps config co-author"
    assert_contains "$GIT_CO_AUTHORS" "CLI One <cli1@test.com>" \
        "Merged list includes first CLI co-author"
    assert_contains "$GIT_CO_AUTHORS" "CLI Two <cli2@test.com>" \
        "Merged list includes second CLI co-author"

    # Pipe-separator count: 2 pipes for 3 entries
    local pipe_count
    pipe_count=$(echo "$GIT_CO_AUTHORS" | tr -cd '|' | wc -c | tr -d ' ')
    assert_equals "$pipe_count" "2" "Should have 2 pipe separators for 3 co-authors"
}

test_cli_co_author_empty_config_merge() {
    log_test "Testing CLI co-authors when config has none"

    local GIT_CO_AUTHORS=""
    local CLI_CO_AUTHORS=("Solo <solo@test.com>")

    for c in "${CLI_CO_AUTHORS[@]}"; do
        if [[ -n "${GIT_CO_AUTHORS:-}" ]]; then
            GIT_CO_AUTHORS+="|$c"
        else
            GIT_CO_AUTHORS="$c"
        fi
    done

    assert_equals "$GIT_CO_AUTHORS" "Solo <solo@test.com>" \
        "Single CLI co-author should not be prefixed with pipe"
}

test_cli_co_author_format_validation() {
    log_test "Testing --co-author format validation regex"

    # The tightened regex from launch-agent.sh parse_args:
    # ^[[:alnum:][:space:].'",_-]+\ \<[^\>]+@[^\>]+\>$
    local valid_inputs=(
        "Jane Doe <jane@example.com>"
        "X <x@y.z>"
        "Aviad Shiber <aviadshiber@gmail.com>"
        "O'Brien <obrien@sub.domain.com>"
        "A B <a+tag@example.com>"
    )
    local invalid_inputs=(
        "no-angle-brackets@test.com"
        "Name without email"
        "Name <no-at-sign>"
        ""
        "Name <@nodomain>"
        "Name <user@>"
    )

    # Use the actual tightened regex from launch-agent.sh
    for input in "${valid_inputs[@]}"; do
        if [[ ! "$input" =~ ^[[:alnum:][:space:].\'\",_-]+\ \<[^\>]+@[^\>]+\>$ ]]; then
            log_error "Valid input rejected: $input"
            return 1
        fi
    done
    for input in "${invalid_inputs[@]}"; do
        if [[ "$input" =~ ^[[:alnum:][:space:].\'\",_-]+\ \<[^\>]+@[^\>]+\>$ ]]; then
            log_error "Invalid input accepted: $input"
            return 1
        fi
    done
    log_info "Format validation correct for all inputs"
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
    run_test test_build_coauthor_trailers_duplicate_in_list
    run_test test_build_coauthor_trailers_already_in_message

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

    # Attribution tests
    run_test test_config_attribution_parsing
    run_test test_attribution_placeholder_substitution
    run_test test_attribution_commit_uses_env_var
    run_test test_attribution_empty_disables
    run_test test_attribution_claude_skip_duplicate
    run_test test_attribution_unset_uses_default

    # CLI --co-author flag tests
    run_test test_cli_co_author_merge
    run_test test_cli_co_author_empty_config_merge
    run_test test_cli_co_author_format_validation

    # Summary
    print_summary
}

main "$@"
