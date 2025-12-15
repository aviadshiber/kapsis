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

#===============================================================================
# CONTAINER TEST HELPERS
#===============================================================================

# Global container test state
CONTAINER_TEST_ID=""
CONTAINER_TEST_SANDBOX=""
CONTAINER_TEST_UPPER=""

# setup_container_test <test_name>
# Sets up a unique container test environment
setup_container_test() {
    local test_name="${1:-test}"
    CONTAINER_TEST_ID="kapsis-test-${test_name}-$$"
    CONTAINER_TEST_SANDBOX="$HOME/.ai-sandboxes/$CONTAINER_TEST_ID"
    CONTAINER_TEST_UPPER="$CONTAINER_TEST_SANDBOX/upper"

    # Clean any existing sandbox
    rm -rf "$CONTAINER_TEST_SANDBOX"
    mkdir -p "$CONTAINER_TEST_UPPER"
    mkdir -p "$CONTAINER_TEST_SANDBOX/work"

    log_info "Container test setup: $CONTAINER_TEST_ID"
}

# cleanup_container_test
# Cleans up container test resources
cleanup_container_test() {
    if [[ -n "$CONTAINER_TEST_ID" ]]; then
        # Stop container if running
        podman rm -f "$CONTAINER_TEST_ID" 2>/dev/null || true

        # Remove named volumes
        podman volume rm "${CONTAINER_TEST_ID}-m2" 2>/dev/null || true
        podman volume rm "${CONTAINER_TEST_ID}-gradle" 2>/dev/null || true
        podman volume rm "${CONTAINER_TEST_ID}-ge" 2>/dev/null || true

        # Remove sandbox directory
        rm -rf "$CONTAINER_TEST_SANDBOX"

        log_info "Container test cleanup: $CONTAINER_TEST_ID"
    fi
}

# run_in_container <command>
# Runs a command in a test container and captures output
run_in_container() {
    local command="$1"
    local timeout="${2:-30}"

    podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --hostname "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --memory=2g \
        --cpus=2 \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$CONTAINER_TEST_UPPER,workdir=$CONTAINER_TEST_SANDBOX/work" \
        -v "${CONTAINER_TEST_ID}-m2:/home/developer/.m2/repository" \
        -e KAPSIS_AGENT_ID="$CONTAINER_TEST_ID" \
        -e KAPSIS_PROJECT="test" \
        --timeout "$timeout" \
        kapsis-sandbox:latest \
        bash -c "$command" 2>&1
}

# run_in_container_detached <command>
# Runs a container in detached mode (for concurrent tests)
run_in_container_detached() {
    local command="$1"
    local container_name="${2:-$CONTAINER_TEST_ID}"

    podman run -d \
        --name "$container_name" \
        --hostname "$container_name" \
        --userns=keep-id \
        --memory=2g \
        --cpus=2 \
        --security-opt label=disable \
        -v "$TEST_PROJECT:/workspace:O,upperdir=$CONTAINER_TEST_UPPER,workdir=$CONTAINER_TEST_SANDBOX/work" \
        -v "${container_name}-m2:/home/developer/.m2/repository" \
        -e KAPSIS_AGENT_ID="$container_name" \
        -e KAPSIS_PROJECT="test" \
        kapsis-sandbox:latest \
        bash -c "$command" 2>&1
}

# wait_for_container <container_name> <timeout>
# Waits for a container to finish
wait_for_container() {
    local container_name="$1"
    local timeout="${2:-60}"
    local start_time
    start_time=$(date +%s)

    while podman ps -q --filter "name=$container_name" | grep -q .; do
        sleep 1
        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            log_warn "Container $container_name timed out after ${timeout}s"
            podman kill "$container_name" 2>/dev/null || true
            return 1
        fi
    done

    return 0
}

# container_exists <container_name>
# Checks if a container exists (running or stopped)
container_exists() {
    local container_name="$1"
    podman ps -a -q --filter "name=^${container_name}$" | grep -q .
}

# container_is_running <container_name>
# Checks if a container is currently running
container_is_running() {
    local container_name="$1"
    podman ps -q --filter "name=^${container_name}$" | grep -q .
}

# assert_file_in_upper <relative_path> <message>
# Checks if a file exists in the upper (overlay) directory
assert_file_in_upper() {
    local relative_path="$1"
    local message="${2:-File should exist in upper directory}"
    local full_path="$CONTAINER_TEST_UPPER/$relative_path"

    if [[ -f "$full_path" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  Expected file in upper: $relative_path"
        log_info "  Full path: $full_path"
        return 1
    fi
}

# assert_file_not_in_upper <relative_path> <message>
# Checks that a file does NOT exist in the upper directory
assert_file_not_in_upper() {
    local relative_path="$1"
    local message="${2:-File should not exist in upper directory}"
    local full_path="$CONTAINER_TEST_UPPER/$relative_path"

    if [[ ! -f "$full_path" ]]; then
        return 0
    else
        log_fail "$message"
        log_info "  File should not exist in upper: $relative_path"
        return 1
    fi
}

# assert_host_file_unchanged <relative_path> <expected_content> <message>
# Checks that a file on the host has not been modified
assert_host_file_unchanged() {
    local relative_path="$1"
    local expected_content="$2"
    local message="${3:-Host file should be unchanged}"
    local full_path="$TEST_PROJECT/$relative_path"

    if [[ -f "$full_path" ]]; then
        local actual_content
        actual_content=$(cat "$full_path")
        if [[ "$actual_content" == "$expected_content" ]]; then
            return 0
        else
            log_fail "$message"
            log_info "  File content changed: $relative_path"
            return 1
        fi
    else
        log_fail "$message"
        log_info "  File missing on host: $relative_path"
        return 1
    fi
}

# skip_if_no_container
# Skips the test if container prerequisites are not met
skip_if_no_container() {
    if ! command -v podman &> /dev/null; then
        log_skip "Podman not installed"
        return 1
    fi

    if ! podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null | grep -q "running"; then
        log_skip "Podman machine not running"
        return 1
    fi

    if ! podman image exists kapsis-sandbox:latest 2>/dev/null; then
        log_skip "Kapsis image not built"
        return 1
    fi

    return 0
}
