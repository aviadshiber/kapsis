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
CURRENT_TEST=""  # exported for use by test functions
export CURRENT_TEST
FAILED_TESTS=()  # Track names of failed tests for re-run command

# Assertion failure tracking
# Because errexit is suspended inside 'if' statements, assertions returning non-zero
# don't cause the test function to exit. We track failures here and check after.
_ASSERTION_FAILED=false

# Quiet mode - only show pass/fail, suppress verbose output
# Set via: KAPSIS_TEST_QUIET=1 or export before sourcing
QUIET_MODE="${KAPSIS_TEST_QUIET:-false}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
KAPSIS_ROOT="$(dirname "$TESTS_DIR")"
# Use $HOME path for reliable Podman VM filesystem sharing on macOS
TEST_PROJECT="$HOME/.kapsis-test-project"

# Container image name (configurable for CI environments)
# CI sets KAPSIS_IMAGE="kapsis-test:ci", local dev uses kapsis-sandbox:latest
KAPSIS_TEST_IMAGE="${KAPSIS_IMAGE:-kapsis-sandbox:latest}"

#===============================================================================
# CROSS-PLATFORM HELPERS
#===============================================================================
# macOS and Linux have different stat command syntax

_TEST_OS="$(uname)"

# Get file modification time as Unix epoch
get_file_mtime() {
    local file="$1"
    if [[ "$_TEST_OS" == "Darwin" ]]; then
        stat -f "%m" "$file" 2>/dev/null
    else
        stat -c "%Y" "$file" 2>/dev/null
    fi
}

# Get file size in bytes
get_file_size() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo 0
        return
    fi
    if [[ "$_TEST_OS" == "Darwin" ]]; then
        stat -f%z "$file" 2>/dev/null || echo 0
    else
        stat -c%s "$file" 2>/dev/null || echo 0
    fi
}

# Get MD5 hash of file (macOS uses 'md5', Linux uses 'md5sum')
get_file_md5() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi
    if [[ "$_TEST_OS" == "Darwin" ]]; then
        md5 -q "$file" 2>/dev/null
    else
        md5sum "$file" 2>/dev/null | cut -d' ' -f1
    fi
}

#===============================================================================
# OUTPUT FUNCTIONS
#===============================================================================
# In quiet mode, only PASS/FAIL are shown; other output is suppressed

log_test() {
    [[ "$QUIET_MODE" == "true" || "$QUIET_MODE" == "1" ]] && return
    echo -e "${BLUE}[TEST]${NC} $*"
}

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

log_skip() {
    [[ "$QUIET_MODE" == "true" || "$QUIET_MODE" == "1" ]] && return
    echo -e "${YELLOW}[SKIP]${NC} $*"
}

log_info() {
    [[ "$QUIET_MODE" == "true" || "$QUIET_MODE" == "1" ]] && return
    echo -e "${CYAN}[INFO]${NC} $*"
}

# log_quiet - only shown in quiet mode (for minimal output)
log_quiet() {
    [[ "$QUIET_MODE" != "true" && "$QUIET_MODE" != "1" ]] && return
    echo -e "$*"
}

# print_test_header <title>
# Prints a test script header. Suppressed in quiet mode.
print_test_header() {
    _is_quiet && return
    local title="$1"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: $title"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

#===============================================================================
# ASSERTIONS
#===============================================================================

# Helper to check if in quiet mode
_is_quiet() {
    [[ "$QUIET_MODE" == "true" || "$QUIET_MODE" == "1" ]]
}

# Helper to mark assertion as failed and log details
# ALWAYS use this for assertion failures - it ensures consistent failure tracking
# In quiet mode: shows main failure message only (so you know WHY it failed)
# In verbose mode: shows failure message + details (Expected/Actual values)
_log_failure() {
    local message="$1"
    shift

    # Mark that an assertion failed (checked by run_test)
    _ASSERTION_FAILED=true

    # Always show the main failure message - you need to know WHY it failed
    log_fail "$message"

    # In verbose mode, also show the details (Expected/Actual values)
    if ! _is_quiet; then
        for detail in "$@"; do
            log_info "  $detail"
        done
    fi
}

# assert_equals <expected> <actual> <message>
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        _log_failure "$message" "Expected: $expected" "Actual:   $actual"
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
        _log_failure "$message" "Value should not be: $unexpected"
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
        _log_failure "$message" "Looking for: $needle" "In: ${haystack:0:200}..."
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
        _log_failure "$message" "Should not contain: $needle"
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
        _log_failure "$message" "Missing file: $path"
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
        _log_failure "$message" "File exists but shouldn't: $path"
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
        _log_failure "$message" "Missing directory: $path"
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
        _log_failure "$message" "Expected exit code: $expected" "Actual exit code:   $actual"
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
        _log_failure "$message" "Command failed: $command"
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
        _log_failure "$message" "Command should have failed: $command"
        return 1
    fi
}

# assert_true <condition> <message>
# Evaluates a bash condition and passes if it's true
# Example: assert_true "[[ -x '$file' ]]" "File should be executable"
assert_true() {
    local condition="$1"
    local message="${2:-Condition should be true}"

    if eval "$condition"; then
        return 0
    else
        _log_failure "$message" "Condition failed: $condition"
        return 1
    fi
}

# assert_false <condition> <message>
# Evaluates a bash condition and passes if it's false
# Example: assert_false "[[ -f '$file' ]]" "File should not exist"
assert_false() {
    local condition="$1"
    local message="${2:-Condition should be false}"

    if ! eval "$condition"; then
        return 0
    else
        _log_failure "$message" "Condition should have been false: $condition"
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

    # Reset assertion failure tracking
    _ASSERTION_FAILED=false

    if ! _is_quiet; then
        log_test "Running: $test_func"
    fi

    # Run the test function
    local test_exit_code=0
    $test_func || test_exit_code=$?

    # Check both explicit return code AND assertion failures
    # (errexit is suspended inside 'if', so assertions return 1 but don't exit)
    if [[ $test_exit_code -eq 0 ]] && [[ "$_ASSERTION_FAILED" != "true" ]]; then
        log_pass "$test_func"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_fail "$test_func"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_func")
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
# Shows test results. In quiet mode, also shows re-run command for failed tests.
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

        # Show failed tests list
        if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
            echo ""
            echo "Failed tests:"
            for test in "${FAILED_TESTS[@]}"; do
                echo -e "  ${RED}✗${NC} $test"
            done

            # In quiet mode, suggest re-running with verbose output
            if _is_quiet; then
                echo ""
                echo "Re-run with full output to see details:"
                echo "  $0"
            fi
        fi
        return 1
    fi
}

# get_failed_tests
# Returns space-separated list of failed test function names
get_failed_tests() {
    echo "${FAILED_TESTS[*]}"
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

    # Make directories writable for fuse-overlayfs compatibility
    # With --userns=keep-id, fuse-overlayfs needs write permission on directories
    # to perform copy-up operations when creating files in existing directories
    chmod -R a+rwX .

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

    # Check Kapsis image (use KAPSIS_IMAGE env var if set)
    local image_name="${KAPSIS_IMAGE:-$KAPSIS_TEST_IMAGE}"
    if ! podman image exists "$image_name" 2>/dev/null; then
        missing+=("$image_name image (run ./scripts/build-image.sh)")
    fi

    # Check Podman machine (macOS only - Linux runs Podman natively)
    if [[ "$(uname)" == "Darwin" ]]; then
        if ! podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null | grep -q "running"; then
            missing+=("podman machine (run: podman machine start)")
        fi
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
# Results are exported for use by callers:
#   CAPTURED_STDOUT - captured standard output
#   CAPTURED_STDERR - captured standard error
#   CAPTURED_EXIT_CODE - exit code of the command
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
    export CAPTURED_STDOUT CAPTURED_STDERR CAPTURED_EXIT_CODE

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

    # Make upper and work directories world-writable for rootless Podman
    # Even with --userns=keep-id, overlay mount internals may need broader permissions
    chmod 777 "$CONTAINER_TEST_UPPER" "$CONTAINER_TEST_SANDBOX/work"

    log_info "Container test setup: $CONTAINER_TEST_ID"
}

# get_workspace_mount_args <container_id> <sandbox_path>
# Returns the appropriate volume mount arguments for the current isolation mode
# Usage: eval "podman run $(get_workspace_mount_args mycontainer /path/to/sandbox) ..."
get_workspace_mount_args() {
    local container_id="$1"
    local sandbox_path="${2:-$HOME/.ai-sandboxes/$container_id}"

    if [[ "${KAPSIS_USE_FUSE_OVERLAY:-}" == "true" ]]; then
        # fuse-overlayfs: true Copy-on-Write inside container
        echo "--device /dev/fuse --cap-add SYS_ADMIN -v '$TEST_PROJECT:/lower:ro' -v '${container_id}-overlay:/overlay' -e KAPSIS_USE_FUSE_OVERLAY=true"
    else
        # Native overlay (Linux)
        echo "-v '$TEST_PROJECT:/workspace:O,upperdir=$sandbox_path/upper,workdir=$sandbox_path/work'"
    fi
}

# get_workspace_init_command
# Returns command prefix to initialize workspace
get_workspace_init_command() {
    # fuse-overlayfs setup is handled by entrypoint.sh when KAPSIS_USE_FUSE_OVERLAY=true
    echo "cd /workspace;"
}

# cleanup_container_test
# Cleans up container test resources
cleanup_container_test() {
    if [[ -n "$CONTAINER_TEST_ID" ]]; then
        # Stop container if running
        podman rm -f "$CONTAINER_TEST_ID" 2>/dev/null || true

        # Remove named volumes (m2 cache, fuse-overlayfs overlay volume, and legacy upper/work)
        # Redirect both stdout and stderr to suppress volume name output
        podman volume rm "${CONTAINER_TEST_ID}-m2" >/dev/null 2>&1 || true
        podman volume rm "${CONTAINER_TEST_ID}-overlay" >/dev/null 2>&1 || true
        # Legacy volume names (for backward compatibility during transition)
        podman volume rm "${CONTAINER_TEST_ID}-upper" >/dev/null 2>&1 || true
        podman volume rm "${CONTAINER_TEST_ID}-work" >/dev/null 2>&1 || true
        podman volume rm "${CONTAINER_TEST_ID}-gradle" >/dev/null 2>&1 || true
        podman volume rm "${CONTAINER_TEST_ID}-ge" >/dev/null 2>&1 || true
        podman volume rm "${CONTAINER_TEST_ID}-workspace" >/dev/null 2>&1 || true

        # Remove sandbox directory (for native overlay mode)
        # Fix work dir permissions first (overlay creates d--------- dirs)
        if [[ -n "$CONTAINER_TEST_SANDBOX" ]] && [[ -d "$CONTAINER_TEST_SANDBOX" ]]; then
            find "$CONTAINER_TEST_SANDBOX" -type d -perm 000 -exec chmod 755 {} \; 2>/dev/null || true
            rm -rf "$CONTAINER_TEST_SANDBOX" 2>/dev/null || true
        fi

        log_info "Container test cleanup: $CONTAINER_TEST_ID"
    fi
}

# run_in_container <command>
# Runs a command in a test container and captures output
# Uses fuse-overlayfs on macOS (native overlay is read-only with virtio-fs)
run_in_container() {
    local command="$1"
    local timeout="${2:-30}"

    # Check if we need to use fuse-overlayfs (macOS workaround for true CoW)
    if [[ "${KAPSIS_USE_FUSE_OVERLAY:-}" == "true" ]]; then
        # fuse-overlayfs: true Copy-on-Write inside container
        # IMPORTANT: Use single volume for both upper and work directories
        # upperdir and workdir MUST be on the same filesystem to avoid EXDEV errors
        # (see: https://docs.kernel.org/filesystems/overlayfs.html)
        podman run --rm \
            --name "$CONTAINER_TEST_ID" \
            --hostname "$CONTAINER_TEST_ID" \
            --userns=keep-id \
            --memory=2g \
            --cpus=2 \
            --device /dev/fuse \
            --cap-add SYS_ADMIN \
            --security-opt label=disable \
            -v "$TEST_PROJECT:/lower:ro" \
            -v "${CONTAINER_TEST_ID}-overlay:/overlay" \
            -v "${CONTAINER_TEST_ID}-m2:/home/developer/.m2/repository" \
            -e KAPSIS_AGENT_ID="$CONTAINER_TEST_ID" \
            -e KAPSIS_PROJECT="test" \
            -e KAPSIS_USE_FUSE_OVERLAY=true \
            --timeout "$timeout" \
            $KAPSIS_TEST_IMAGE \
            bash -c "$command" 2>&1
    else
        # Native overlay mode - only used when check_overlay_rw_support() passes
        # SECURITY: Always use --userns=keep-id for rootless, non-privileged containers
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
            $KAPSIS_TEST_IMAGE \
            bash -c "$command" 2>&1
    fi
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
        $KAPSIS_TEST_IMAGE \
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

    if [[ "${KAPSIS_USE_FUSE_OVERLAY:-}" == "true" ]]; then
        # fuse-overlayfs: check file in overlay volume (upper subdir)
        # Named volume must be checked from inside a container
        local result
        result=$(podman run --rm \
            -v "${CONTAINER_TEST_ID}-overlay:/overlay:ro" \
            $KAPSIS_TEST_IMAGE \
            bash -c "test -f '/overlay/upper/$relative_path' && echo EXISTS || echo NOTFOUND" 2>&1)

        if [[ "$result" == *"EXISTS"* ]]; then
            return 0
        else
            _log_failure "$message" "Expected file in upper: $relative_path"
            return 1
        fi
    else
        # Native overlay: check file in upper directory on host
        local full_path="$CONTAINER_TEST_UPPER/$relative_path"

        if [[ -f "$full_path" ]]; then
            return 0
        else
            _log_failure "$message" "Expected file in upper: $relative_path" "Full path: $full_path"
            return 1
        fi
    fi
}

# assert_file_not_in_upper <relative_path> <message>
# Checks that a file does NOT exist in the upper directory (was not modified)
assert_file_not_in_upper() {
    local relative_path="$1"
    local message="${2:-File should not exist in upper directory}"

    if [[ "${KAPSIS_USE_FUSE_OVERLAY:-}" == "true" ]]; then
        # fuse-overlayfs: check file NOT in overlay volume (upper subdir)
        # Named volume must be checked from inside a container
        local result
        result=$(podman run --rm \
            -v "${CONTAINER_TEST_ID}-overlay:/overlay:ro" \
            $KAPSIS_TEST_IMAGE \
            bash -c "test -f '/overlay/upper/$relative_path' && echo EXISTS || echo NOTFOUND" 2>&1)

        if [[ "$result" == *"NOTFOUND"* ]]; then
            return 0
        else
            _log_failure "$message" "File should not exist in upper: $relative_path"
            return 1
        fi
    else
        # Native overlay: check file in upper directory on host
        local full_path="$CONTAINER_TEST_UPPER/$relative_path"

        if [[ ! -f "$full_path" ]]; then
            return 0
        else
            _log_failure "$message" "File should not exist in upper: $relative_path"
            return 1
        fi
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
            _log_failure "$message" "File content changed: $relative_path"
            return 1
        fi
    else
        _log_failure "$message" "File missing on host: $relative_path"
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

    # Check Podman machine (macOS only - Linux runs Podman natively)
    if [[ "$(uname)" == "Darwin" ]]; then
        if ! podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null | grep -q "running"; then
            log_skip "Podman machine not running"
            return 1
        fi
    fi

    # Check Kapsis image (use KAPSIS_IMAGE env var if set, for CI compatibility)
    local image_name="${KAPSIS_IMAGE:-$KAPSIS_TEST_IMAGE}"
    if ! podman image exists "$image_name" 2>/dev/null; then
        log_skip "Kapsis image not built ($image_name)"
        return 1
    fi

    return 0
}

# check_overlay_rw_support
# Checks if native overlay mounts are read-write with --userns=keep-id (rootless security)
# On macOS with virtio-fs, native overlay is read-only, so we fall back to fuse-overlayfs.
# On Linux CI, native overlay with host directories has permission issues when combined
# with the entrypoint script - so we use fuse-overlayfs with named volumes instead.
#
# SECURITY: Always use --userns=keep-id to ensure the solution maintains
# the rootless, non-privileged container model that Kapsis requires for agent sandboxing.
check_overlay_rw_support() {
    # On Linux (except macOS), use fuse-overlayfs for reliable operation
    # Native overlay with --userns=keep-id has permission issues with host directories
    # when running through the entrypoint (works without entrypoint but fails with it)
    if [[ "$_TEST_OS" != "Darwin" ]]; then
        log_info "Linux detected - using fuse-overlayfs for reliable rootless operation"
        return 1
    fi

    # On macOS, test if native overlay works (typically read-only with virtio-fs)
    local test_dir="$HOME/.kapsis-overlay-test-$$"
    mkdir -p "$test_dir/lower" "$test_dir/upper" "$test_dir/work"
    chmod 777 "$test_dir/lower" "$test_dir/upper" "$test_dir/work"
    echo "test" > "$test_dir/lower/test.txt"

    # Try to write via native overlay mount with --userns=keep-id (rootless security model)
    # Override entrypoint to avoid its verbose output interfering with our test
    local result
    result=$(podman run --rm \
        --userns=keep-id \
        --security-opt label=disable \
        --entrypoint="" \
        -v "$test_dir/lower:/workspace:O,upperdir=$test_dir/upper,workdir=$test_dir/work" \
        $KAPSIS_TEST_IMAGE \
        bash -c "echo 'write test' > /workspace/write-test.txt 2>&1 && echo SUCCESS || echo FAILED" 2>&1) || true

    # Debug: show what happened
    log_info "Overlay write test result: $result"

    # Cleanup - fix work dir permissions first (overlay creates d--------- dirs)
    find "$test_dir" -type d -perm 000 -exec chmod 755 {} \; 2>/dev/null || true
    rm -rf "$test_dir"

    if [[ "$result" == *"SUCCESS"* ]]; then
        log_info "Native overlay is writable with --userns=keep-id - using native overlay mode"
        return 0
    else
        log_info "Native overlay failed with --userns=keep-id - will use fuse-overlayfs"
        return 1
    fi
}

# skip_if_no_overlay_rw
# Checks for overlay support. If not available, enables fuse-overlayfs for true CoW.
skip_if_no_overlay_rw() {
    if ! skip_if_no_container; then
        return 1
    fi

    if ! check_overlay_rw_support; then
        log_info "Overlay mounts read-only - using fuse-overlayfs for true Copy-on-Write"
        export KAPSIS_USE_FUSE_OVERLAY=true
    fi

    return 0
}

# run_podman_isolated <container_id> <command> [additional_podman_args...]
# Runs a podman container with the correct isolation mode (native overlay or fuse-overlayfs)
# This is the recommended way to run isolated containers in tests.
run_podman_isolated() {
    local container_id="$1"
    local command="$2"
    shift 2

    local sandbox="$HOME/.ai-sandboxes/$container_id"
    mkdir -p "$sandbox/upper" "$sandbox/work"
    # Make directories world-writable for rootless Podman without --userns=keep-id
    chmod 777 "$sandbox/upper" "$sandbox/work"

    if [[ "${KAPSIS_USE_FUSE_OVERLAY:-}" == "true" ]]; then
        # fuse-overlayfs: true Copy-on-Write inside container
        # IMPORTANT: Use single volume for both upper and work directories
        # upperdir and workdir MUST be on the same filesystem to avoid EXDEV errors
        podman run --rm \
            --name "$container_id" \
            --hostname "$container_id" \
            --userns=keep-id \
            --device /dev/fuse \
            --cap-add SYS_ADMIN \
            --security-opt label=disable \
            -v "$TEST_PROJECT:/lower:ro" \
            -v "${container_id}-overlay:/overlay" \
            -v "${container_id}-m2:/home/developer/.m2/repository" \
            -e KAPSIS_AGENT_ID="$container_id" \
            -e KAPSIS_USE_FUSE_OVERLAY=true \
            "$@" \
            $KAPSIS_TEST_IMAGE \
            bash -c "$command" 2>&1
    else
        # Native overlay mode - only used when check_overlay_rw_support() passes
        # SECURITY: Always use --userns=keep-id for rootless, non-privileged containers
        podman run --rm \
            --name "$container_id" \
            --hostname "$container_id" \
            --userns=keep-id \
            --security-opt label=disable \
            -v "$TEST_PROJECT:/workspace:O,upperdir=$sandbox/upper,workdir=$sandbox/work" \
            -v "${container_id}-m2:/home/developer/.m2/repository" \
            -e KAPSIS_AGENT_ID="$container_id" \
            "$@" \
            $KAPSIS_TEST_IMAGE \
            bash -c "$command" 2>&1
    fi
}

# cleanup_isolated_container <container_id>
# Cleans up an isolated container and its resources
cleanup_isolated_container() {
    local container_id="$1"
    local sandbox="$HOME/.ai-sandboxes/$container_id"

    # Stop container if running
    podman rm -f "$container_id" 2>/dev/null || true

    # Remove named volumes (suppress stdout to avoid noise in quiet mode)
    podman volume rm "${container_id}-m2" >/dev/null 2>&1 || true
    podman volume rm "${container_id}-overlay" >/dev/null 2>&1 || true
    # Legacy volume names (for backward compatibility)
    podman volume rm "${container_id}-upper" >/dev/null 2>&1 || true
    podman volume rm "${container_id}-work" >/dev/null 2>&1 || true

    # Remove sandbox directory (for native overlay mode)
    # Fix work dir permissions first (fuse-overlayfs creates d--------- dirs)
    if [[ -d "$sandbox" ]]; then
        find "$sandbox" -type d -perm 000 -exec chmod 755 {} \; 2>/dev/null || true
        rm -rf "$sandbox" 2>/dev/null || true
    fi
}

#===============================================================================
# WORKTREE TEST HELPERS
#===============================================================================

# Global worktree test state
WORKTREE_TEST_ID=""
WORKTREE_TEST_PATH=""
WORKTREE_SANITIZED_GIT=""

# setup_worktree_test <test_name> <branch>
# Sets up a worktree test environment
setup_worktree_test() {
    local test_name="${1:-test}"
    local branch="${2:-feature/test-$test_name}"

    WORKTREE_TEST_ID="kapsis-wt-test-${test_name}-$$"
    WORKTREE_TEST_PATH="$HOME/.kapsis/worktrees/test-project-${WORKTREE_TEST_ID}"
    WORKTREE_SANITIZED_GIT="$HOME/.kapsis/sanitized-git/${WORKTREE_TEST_ID}"

    log_info "Worktree test setup: $WORKTREE_TEST_ID"

    # Source worktree manager
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

    # Create worktree
    WORKTREE_TEST_PATH=$(create_worktree "$TEST_PROJECT" "$WORKTREE_TEST_ID" "$branch")

    # Create sanitized git
    WORKTREE_SANITIZED_GIT=$(prepare_sanitized_git "$WORKTREE_TEST_PATH" "$WORKTREE_TEST_ID" "$TEST_PROJECT")

    log_info "  Worktree: $WORKTREE_TEST_PATH"
    log_info "  Sanitized git: $WORKTREE_SANITIZED_GIT"
}

# run_in_worktree_container <command> [extra_args...]
# Runs a command in a worktree-mode container
run_in_worktree_container() {
    local command="$1"
    shift

    local objects_path="$TEST_PROJECT/.git/objects"

    podman run --rm \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$WORKTREE_TEST_PATH:/workspace" \
        -v "$WORKTREE_SANITIZED_GIT:/workspace/.git-safe:ro" \
        -v "$objects_path:/workspace/.git-objects:ro" \
        -v "${WORKTREE_TEST_ID}-m2:/home/developer/.m2/repository" \
        -e KAPSIS_AGENT_ID="$WORKTREE_TEST_ID" \
        -e KAPSIS_SANDBOX_MODE="worktree" \
        -e KAPSIS_WORKTREE_MODE="true" \
        "$@" \
        $KAPSIS_TEST_IMAGE \
        bash -c "$command" 2>&1
}

# cleanup_worktree_test
# Cleans up a worktree test environment
cleanup_worktree_test() {
    if [[ -z "$WORKTREE_TEST_ID" ]]; then
        return
    fi

    log_info "Worktree test cleanup: $WORKTREE_TEST_ID"

    # Source worktree manager if not already
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh" 2>/dev/null || true

    # Cleanup worktree and sanitized git
    cleanup_worktree "$TEST_PROJECT" "$WORKTREE_TEST_ID" 2>/dev/null || true

    # Remove any named volumes (suppress stdout to avoid noise in quiet mode)
    podman volume rm "${WORKTREE_TEST_ID}-m2" >/dev/null 2>&1 || true

    # Reset state
    WORKTREE_TEST_ID=""
    WORKTREE_TEST_PATH=""
    WORKTREE_SANITIZED_GIT=""
}

# assert_worktree_exists <path> <message>
# Asserts that a worktree exists at the given path
assert_worktree_exists() {
    local path="$1"
    local message="${2:-Worktree should exist}"

    if [[ -d "$path" ]] && [[ -f "$path/.git" ]]; then
        return 0
    else
        _log_failure "$message" "Expected worktree at: $path"
        return 1
    fi
}

# assert_sanitized_git_secure <path> <message>
# Asserts that a sanitized git directory is properly secured
assert_sanitized_git_secure() {
    local path="$1"
    local message="${2:-Sanitized git should be secure}"

    # Check hooks directory is empty
    local hooks_count
    hooks_count=$(find "$path/hooks" -type f 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$hooks_count" -gt 0 ]]; then
        _log_failure "$message - hooks directory not empty" "Found $hooks_count hook files"
        return 1
    fi

    # Check config exists
    if [[ ! -f "$path/config" ]]; then
        _log_failure "$message - no config file"
        return 1
    fi

    return 0
}
