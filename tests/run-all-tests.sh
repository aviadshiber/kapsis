#!/usr/bin/env bash
#===============================================================================
# Kapsis - Run All Tests
#
# Usage:
#   ./run-all-tests.sh                    # Run all tests
#   ./run-all-tests.sh --category agent   # Run only agent tests
#   ./run-all-tests.sh --quick            # Run quick tests only (no containers)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# CONFIGURATION
#===============================================================================

CATEGORY=""
QUICK_MODE=false
VERBOSE=false

# Test categories and their scripts
declare -A TEST_CATEGORIES=(
    ["agent"]="test-agent-shortcut.sh test-agent-unknown.sh test-agent-config-override.sh test-config-resolution.sh"
    ["filesystem"]="test-cow-isolation.sh test-upper-dir-isolation.sh test-host-unchanged.sh"
    ["maven"]="test-maven-snapshot-block.sh test-maven-deploy-block.sh test-maven-repo-isolation.sh"
    ["cache"]="test-ge-cache-isolation.sh test-parallel-build.sh"
    ["git"]="test-git-new-branch.sh test-git-continue-branch.sh test-git-auto-commit-push.sh test-git-no-push.sh test-git-auto-branch.sh"
    ["integration"]="test-parallel-agents.sh test-full-workflow.sh"
)

# Quick tests (no container required)
QUICK_TESTS="test-agent-shortcut.sh test-agent-unknown.sh test-agent-config-override.sh test-config-resolution.sh"

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
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo ""
            echo "Options:"
            echo "  --category <name>   Run only tests in category"
            echo "  --quick             Run quick tests (no containers)"
            echo "  -v, --verbose       Verbose output"
            echo ""
            echo "Categories: ${!TEST_CATEGORIES[*]}"
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
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                    KAPSIS TEST SUITE                              ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check prerequisites (unless quick mode)
    if [[ "$QUICK_MODE" != "true" ]]; then
        log_info "Checking prerequisites..."
        if ! check_prerequisites; then
            log_fail "Prerequisites not met"
            exit 3
        fi
    else
        log_info "Quick mode - skipping container prerequisites"
    fi

    # Determine which tests to run
    local tests_to_run=""

    if [[ "$QUICK_MODE" == "true" ]]; then
        tests_to_run="$QUICK_TESTS"
        log_info "Running quick tests only"
    elif [[ -n "$CATEGORY" ]]; then
        if [[ -v "TEST_CATEGORIES[$CATEGORY]" ]]; then
            tests_to_run="${TEST_CATEGORIES[$CATEGORY]}"
            log_info "Running category: $CATEGORY"
        else
            log_fail "Unknown category: $CATEGORY"
            log_info "Available categories: ${!TEST_CATEGORIES[*]}"
            exit 1
        fi
    else
        # Run all tests
        for category in "${!TEST_CATEGORIES[@]}"; do
            tests_to_run="$tests_to_run ${TEST_CATEGORIES[$category]}"
        done
        log_info "Running all tests"
    fi

    echo ""

    # Track overall results
    local total_passed=0
    local total_failed=0
    local total_skipped=0

    # Run each test
    for test_script in $tests_to_run; do
        if [[ -f "$SCRIPT_DIR/$test_script" ]]; then
            echo ""
            echo "───────────────────────────────────────────────────────────────────"
            log_info "Running: $test_script"
            echo "───────────────────────────────────────────────────────────────────"

            if "$SCRIPT_DIR/$test_script"; then
                total_passed=$((total_passed + 1))
            else
                total_failed=$((total_failed + 1))
            fi
        else
            log_skip "$test_script (not implemented)"
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
        exit 1
    fi
}

main "$@"
