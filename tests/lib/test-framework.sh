#!/usr/bin/env bash
#===============================================================================
# Kapsis Test Framework
#
# Provides common utilities for writing and running tests.
#===============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
KAPSIS_ROOT="$(dirname "$TESTS_DIR")"
TEST_PROJECT="/tmp/kapsis-test-project"

#===============================================================================
# OUTPUT FUNCTIONS
#===============================================================================
log_test() { echo -e "${BLUE}[TEST]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; }
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }

#===============================================================================
# ASSERTIONS
#===============================================================================

# assert_equals <expected> <actual> <message>
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Expected: $expected"
        log_info "  Actual:   $actual"
        return 1
    fi
}

# assert_not_equals <unexpected> <actual> <message>
assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"

    if [[ "$unexpected" != "$actual" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Value should not be: $unexpected"
        return 1
    fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Looking for: $needle"
        log_info "  In: ${haystack:0:200}..."
        return 1
    fi
}

# assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Should not contain: $needle"
        return 1
    fi
}

# assert_file_exists <path> <message>
assert_file_exists() {
    local path="$1"
    local message="${2:-File should exist}"

    if [[ -f "$path" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Missing file: $path"
        return 1
    fi
}

# assert_file_not_exists <path> <message>
assert_file_not_exists() {
    local path="$1"
    local message="${2:-File should not exist}"

    if [[ ! -f "$path" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  File exists but shouldn't: $path"
        return 1
    fi
}

# assert_dir_exists <path> <message>
assert_dir_exists() {
    local path="$1"
    local message="${2:-Directory should exist}"

    if [[ -d "$path" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Missing directory: $path"
        return 1
    fi
}

# assert_exit_code <expected> <actual> <message>
assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Exit code should match}"

    if [[ "$expected" -eq "$actual" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Expected exit code: $expected"
        log_info "  Actual exit code:   $actual"
        return 1
    fi
}

# assert_command_succeeds <command> <message>
assert_command_succeeds() {
    local command="$1"
    local message="${2:-Command should succeed}"

    if eval "$command" >/dev/null 2>&1; then
        return 0
    else
        log_fail "$message"
        log_info "  Command failed: $command"
        return 1
    fi
}

# assert_command_fails <command> <message>
assert_command_fails() {
    local command="$1"
    local message="${2:-Command should fail}"

    if ! eval "$command" >/dev/null 2>&1; then
        return 0
    else
        log_fail "$message"
        log_info "  Command should have failed: $command"
        return 1
    fi
}

#===============================================================================
# TEST EXECUTION
#===============================================================================

# run_test <test_function>
run_test() {
    local test_func="$1"
    CURRENT_TEST="$test_func"
    TESTS_RUN=$((TESTS_RUN + 1))

    log_test "Running: $test_func"

    if $test_func; then
        log_pass "$test_func"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_fail "$test_func"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# skip_test <test_function> <reason>
skip_test() {
    local test_func="$1"
    local reason="${2:-No reason given}"

    log_skip "$test_func: $reason"
}

# print_summary
print_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST SUMMARY"
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Total:  $TESTS_RUN"
    echo -e "  Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "  Failed: ${RED}$TESTS_FAILED${NC}"
    echo "═══════════════════════════════════════════════════════════════════"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

#===============================================================================
# SETUP/TEARDOWN
#===============================================================================

# setup_test_project
setup_test_project() {
    log_info "Setting up test project at $TEST_PROJECT"

    rm -rf "$TEST_PROJECT"
    mkdir -p "$TEST_PROJECT"
    cd "$TEST_PROJECT"

    # Initialize git repo
    git init -q
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"

    # Create minimal Maven project
    cat > pom.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.kapsis</groupId>
    <artifactId>test-project</artifactId>
    <version>1.0-SNAPSHOT</version>
    <packaging>jar</packaging>
</project>
EOF

    mkdir -p src/main/java
    cat > src/main/java/Main.java << 'EOF'
public class Main {
    public static void main(String[] args) {
        System.out.println("Hello Kapsis!");
    }
}
EOF

    # Initial commit
    git add -A
    git commit -q -m "Initial test project"

    log_info "Test project ready"
}

# cleanup_test_project
cleanup_test_project() {
    log_info "Cleaning up test project"
    rm -rf "$TEST_PROJECT"
}

# cleanup_sandboxes
cleanup_sandboxes() {
    log_info "Cleaning up sandboxes"
    rm -rf "$HOME/.ai-sandboxes/test-project-"*
}

#===============================================================================
# PREREQUISITES CHECK
#===============================================================================

# check_prerequisites
check_prerequisites() {
    local missing=()

    # Check Podman
    if ! command -v podman &> /dev/null; then
        missing+=("podman")
    fi

    # Check yq
    if ! command -v yq &> /dev/null; then
        missing+=("yq")
    fi

    # Check Kapsis image
    if ! podman image exists kapsis-sandbox:latest 2>/dev/null; then
        missing+=("kapsis-sandbox image (run ./scripts/build-image.sh)")
    fi

    # Check Podman machine
    if ! podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null | grep -q "running"; then
        missing+=("podman machine (run: podman machine start)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_fail "Missing prerequisites:"
        for item in "${missing[@]}"; do
            echo "  - $item"
        done
        return 3
    fi

    log_info "All prerequisites met"
    return 0
}

#===============================================================================
# HELPERS
#===============================================================================

# capture_output <command>
# Captures stdout, stderr, and exit code
capture_output() {
    local cmd="$1"
    local stdout_file
    local stderr_file

    stdout_file=$(mktemp)
    stderr_file=$(mktemp)

    set +e
    eval "$cmd" > "$stdout_file" 2> "$stderr_file"
    local exit_code=$?
    set -e

    CAPTURED_STDOUT=$(cat "$stdout_file")
    CAPTURED_STDERR=$(cat "$stderr_file")
    CAPTURED_EXIT_CODE=$exit_code

    rm -f "$stdout_file" "$stderr_file"
}

# get_config_value <file> <path>
get_config_value() {
    local file="$1"
    local path="$2"
    yq -r "$path" "$file" 2>/dev/null || echo ""
}
