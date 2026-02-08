#!/usr/bin/env bash
#===============================================================================
# Kapsis - Run All Tests
#
# Usage:
#   ./run-all-tests.sh                    # Run all tests
#   ./run-all-tests.sh -q                 # Quiet mode (pass/fail only)
#   ./run-all-tests.sh --category agent   # Run only agent tests
#   ./run-all-tests.sh --quick            # Run quick tests only (no containers)
#===============================================================================

set -euo pipefail

# Get the tests directory and source framework
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"

#===============================================================================
# CONFIGURATION
#===============================================================================

CATEGORY=""
QUICK_MODE=false
export VERBOSE=false
QUIET_MODE_FLAG=false
FAILED_SCRIPTS=()  # Track failed test scripts for re-run command

# Test categories (Bash 3.2 compatible)
get_tests_for_category() {
    local category="$1"
    case "$category" in
        agent)
            echo "test-agent-shortcut.sh test-agent-unknown.sh test-agent-config-override.sh test-config-resolution.sh test-agent-profile-loading.sh test-agent-auth-requirements.sh test-agent-config-mounts.sh test-agent-image-build.sh test-containerfile.sh"
            ;;
        validation)
            echo "test-input-validation.sh test-path-spaces.sh test-dry-run-completeness.sh test-preflight-check.sh test-version-fetch.sh test-version-management.sh test-post-container-exit-code.sh"
            ;;
        status)
            echo "test-status-reporting.sh test-status-hooks.sh"
            ;;
        filesystem)
            echo "test-cow-isolation.sh test-host-unchanged.sh"
            ;;
        maven)
            echo "test-maven-snapshot-block.sh test-maven-auth.sh test-gradle-cache-isolation.sh"
            ;;
        security)
            echo "test-security-no-root.sh test-agent-id-unique.sh test-env-api-keys.sh test-container-libs.sh test-ssh-keychain.sh test-keychain-retrieval.sh test-ssh-cache-cleanup.sh test-keychain-platform.sh test-config-security.sh test-network-isolation.sh test-scope-validation.sh"
            ;;
        git)
            echo "test-git-new-branch.sh test-git-auto-commit-push.sh test-worktree-isolation.sh test-push-verification.sh test-git-excludes.sh test-validate-staged-files.sh test-coauthor-fork.sh"
            ;;
        cleanup)
            echo "test-cleanup-sandbox.sh"
            ;;
        integration)
            echo "test-parallel-agents.sh test-full-workflow.sh"
            ;;
        libs)
            echo "test-compat.sh test-logging.sh test-json-utils.sh test-git-remote-utils.sh test-progress-display.sh"
            ;;
        hooks)
            echo "test-precommit-spellcheck.sh test-precommit-check-tests.sh test-prepush-orchestrator.sh"
            ;;
        *)
            return 1
            ;;
    esac
}

ALL_CATEGORIES="libs agent validation status filesystem maven security git cleanup integration hooks"

# Quick tests (no container required)
# These tests either don't need a container or gracefully skip container-dependent tests
QUICK_TESTS="test-compat.sh test-logging.sh test-json-utils.sh test-git-remote-utils.sh test-agent-shortcut.sh test-agent-unknown.sh test-agent-config-override.sh test-config-resolution.sh test-input-validation.sh test-path-spaces.sh test-dry-run-completeness.sh test-status-reporting.sh test-status-hooks.sh test-preflight-check.sh test-push-verification.sh test-ssh-keychain.sh test-agent-profile-loading.sh test-agent-auth-requirements.sh test-keychain-retrieval.sh test-ssh-cache-cleanup.sh test-keychain-platform.sh test-agent-config-mounts.sh test-gradle-cache-isolation.sh test-agent-image-build.sh test-version-fetch.sh test-version-management.sh test-git-excludes.sh test-validate-staged-files.sh test-coauthor-fork.sh test-config-security.sh test-post-container-exit-code.sh test-network-isolation.sh test-scope-validation.sh test-precommit-spellcheck.sh test-precommit-check-tests.sh test-prepush-orchestrator.sh test-containerfile.sh"

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --category)
            CATEGORY="$2"
            shift 2
            ;;
        --quick)
            QUICK_MODE=true
            shift
            ;;
        -q|--quiet)
            QUIET_MODE_FLAG=true
            export KAPSIS_TEST_QUIET=true
            shift
            ;;
        -v|--verbose)
            export VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo ""
            echo "Options:"
            echo "  --category <name>   Run only tests in category"
            echo "  --quick             Run quick tests (no containers)"
            echo "  -q, --quiet         Quiet mode (only show pass/fail)"
            echo "  -v, --verbose       Verbose output"
            echo ""
            echo "Categories: $ALL_CATEGORIES"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

#===============================================================================
# MAIN
#===============================================================================

main() {
    # Header (suppress in quiet mode)
    if [[ "$QUIET_MODE_FLAG" != "true" ]]; then
        echo ""
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║                    KAPSIS TEST SUITE                              ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Check prerequisites (unless quick mode)
    if [[ "$QUICK_MODE" != "true" ]]; then
        if [[ "$QUIET_MODE_FLAG" != "true" ]]; then
            log_info "Checking prerequisites..."
        fi
        if ! check_prerequisites; then
            log_fail "Prerequisites not met"
            exit 3
        fi
    else
        # Export KAPSIS_QUICK_TESTS for individual tests to detect quick mode
        export KAPSIS_QUICK_TESTS=1
        if [[ "$QUIET_MODE_FLAG" != "true" ]]; then
            log_info "Quick mode - skipping container prerequisites"
        fi
    fi

    # Determine which tests to run
    local tests_to_run=""

    if [[ "$QUICK_MODE" == "true" ]]; then
        tests_to_run="$QUICK_TESTS"
        [[ "$QUIET_MODE_FLAG" != "true" ]] && log_info "Running quick tests only"
    elif [[ -n "$CATEGORY" ]]; then
        tests_to_run=$(get_tests_for_category "$CATEGORY") || {
            log_fail "Unknown category: $CATEGORY"
            log_info "Available categories: $ALL_CATEGORIES"
            exit 1
        }
        [[ "$QUIET_MODE_FLAG" != "true" ]] && log_info "Running category: $CATEGORY"
    else
        # Run all tests
        for category in $ALL_CATEGORIES; do
            tests_to_run="$tests_to_run $(get_tests_for_category "$category")"
        done
        [[ "$QUIET_MODE_FLAG" != "true" ]] && log_info "Running all tests"
    fi

    [[ "$QUIET_MODE_FLAG" != "true" ]] && echo ""

    # Track overall results
    local total_passed=0
    local total_failed=0
    local total_skipped=0

    # Run each test script
    for test_script in $tests_to_run; do
        if [[ -f "$TESTS_DIR/$test_script" ]]; then
            if [[ "$QUIET_MODE_FLAG" != "true" ]]; then
                echo ""
                echo "───────────────────────────────────────────────────────────────────"
                log_info "Running: $test_script"
                echo "───────────────────────────────────────────────────────────────────"
            fi

            # Run test with quiet mode passed via env var
            if KAPSIS_TEST_QUIET="$QUIET_MODE_FLAG" "$TESTS_DIR/$test_script"; then
                total_passed=$((total_passed + 1))
            else
                total_failed=$((total_failed + 1))
                FAILED_SCRIPTS+=("$test_script")
            fi
        else
            [[ "$QUIET_MODE_FLAG" != "true" ]] && log_skip "$test_script (not implemented)"
            total_skipped=$((total_skipped + 1))
        fi
    done

    # Print overall summary
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                    OVERALL SUMMARY                                ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Test Scripts Run:    $((total_passed + total_failed))"
    echo -e "  Passed:              ${GREEN}$total_passed${NC}"
    echo -e "  Failed:              ${RED}$total_failed${NC}"
    echo -e "  Skipped:             ${YELLOW}$total_skipped${NC}"
    echo ""

    if [[ $total_failed -eq 0 ]]; then
        echo -e "${GREEN}All test scripts passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some test scripts failed.${NC}"

        # Show failed scripts and re-run command
        if [[ ${#FAILED_SCRIPTS[@]} -gt 0 ]]; then
            echo ""
            echo "Failed test scripts:"
            for script in "${FAILED_SCRIPTS[@]}"; do
                echo -e "  ${RED}✗${NC} $script"
            done

            echo ""
            echo "Re-run failed scripts with full output:"
            for script in "${FAILED_SCRIPTS[@]}"; do
                echo "  $TESTS_DIR/$script"
            done
        fi
        exit 1
    fi
}

main "$@"
