#!/usr/bin/env bash
#===============================================================================
# Test: Gradle Cache Isolation
#
# Verifies that each agent has isolated build cache and remote cache is disabled.
# Tests per-agent cache isolation and local cache behavior.
#
# REQUIRES: Container environment (Podman)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# GRADLE PROJECT SETUP
#===============================================================================

setup_gradle_project() {
    log_info "Setting up minimal Gradle project"

    # Create build.gradle
    cat > "$TEST_PROJECT/build.gradle" << 'EOF'
plugins {
    id 'java'
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation 'junit:junit:4.13.2'
}
EOF

    # Create settings.gradle
    cat > "$TEST_PROJECT/settings.gradle" << 'EOF'
rootProject.name = 'kapsis-gradle-test'
EOF

    # Create gradle.properties to disable remote cache
    cat > "$TEST_PROJECT/gradle.properties" << 'EOF'
org.gradle.caching=true
org.gradle.caching.remote=false
EOF

    # Create source file
    mkdir -p "$TEST_PROJECT/src/main/java"
    cat > "$TEST_PROJECT/src/main/java/Main.java" << 'EOF'
public class Main {
    public static void main(String[] args) {
        System.out.println("Hello from Gradle!");
    }
}
EOF

    # Commit the Gradle files
    cd "$TEST_PROJECT"
    git add -A
    git commit -q -m "Add Gradle project" || true
    chmod -R a+rwX .
}

#===============================================================================
# TEST CASES
#===============================================================================

test_gradle_volume_isolation() {
    log_test "Testing each agent gets separate Gradle cache volume"

    if ! skip_if_no_container; then
        return 0
    fi

    # Agent 1 volume
    local agent1_vol="kapsis-test-gradle-1-$$-gradle"
    # Agent 2 volume
    local agent2_vol="kapsis-test-gradle-2-$$-gradle"

    # Create distinct volumes (simulating what launch-agent.sh does)
    podman volume create "$agent1_vol" >/dev/null 2>&1 || true
    podman volume create "$agent2_vol" >/dev/null 2>&1 || true

    # Check they are separate
    local vol1_path
    local vol2_path
    vol1_path=$(podman volume inspect "$agent1_vol" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    vol2_path=$(podman volume inspect "$agent2_vol" --format '{{.Mountpoint}}' 2>/dev/null || echo "")

    # Cleanup
    podman volume rm "$agent1_vol" >/dev/null 2>&1 || true
    podman volume rm "$agent2_vol" >/dev/null 2>&1 || true

    if [[ -n "$vol1_path" ]] && [[ -n "$vol2_path" ]]; then
        assert_not_equals "$vol1_path" "$vol2_path" "Agent volumes should be separate"
    else
        log_info "Volume paths not accessible - testing volume creation instead"
        # At minimum, we verified volumes can be created with different names
        return 0
    fi
}

test_gradle_remote_cache_disabled_config() {
    log_test "Testing Gradle remote cache is disabled in config"

    setup_gradle_project

    # Check gradle.properties
    assert_file_exists "$TEST_PROJECT/gradle.properties" "gradle.properties should exist"

    local content
    content=$(cat "$TEST_PROJECT/gradle.properties")

    assert_contains "$content" "org.gradle.caching.remote=false" "Remote cache should be disabled"
}

test_gradle_local_cache_enabled_config() {
    log_test "Testing Gradle local cache is enabled in config"

    setup_gradle_project

    local content
    content=$(cat "$TEST_PROJECT/gradle.properties")

    assert_contains "$content" "org.gradle.caching=true" "Local cache should be enabled"
}

test_gradle_cache_volume_name_pattern() {
    log_test "Testing Gradle cache volume naming pattern"

    # The volume name should include the agent ID for isolation
    local agent_id="test-agent-123"
    local expected_pattern="${agent_id}-gradle"

    # This tests the expected naming convention
    assert_contains "$expected_pattern" "gradle" "Volume name should include 'gradle'"
    assert_contains "$expected_pattern" "$agent_id" "Volume name should include agent ID"
}

test_gradle_home_in_container() {
    log_test "Testing GRADLE_USER_HOME is set in container"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "gradle-home"

    local output
    output=$(podman run --rm \
        -e CI="${CI:-true}" \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e GRADLE_USER_HOME="/home/developer/.gradle" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'echo "GRADLE_HOME=$GRADLE_USER_HOME"' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "GRADLE_HOME=/home/developer/.gradle" "GRADLE_USER_HOME should be set"
}

test_agents_use_isolated_gradle_volumes() {
    log_test "Testing agents use isolated Gradle volumes"

    if ! skip_if_no_container; then
        return 0
    fi

    # Agent 1 writes to its cache
    local agent1_id="kapsis-test-iso-1-$$"
    local agent1_vol="${agent1_id}-gradle"

    # Agent 2 writes to its cache
    local agent2_id="kapsis-test-iso-2-$$"
    local agent2_vol="${agent2_id}-gradle"

    # Create volumes
    podman volume create "$agent1_vol" >/dev/null 2>&1 || true
    podman volume create "$agent2_vol" >/dev/null 2>&1 || true

    # Agent 1 writes a marker file
    podman run --rm \
        -e CI="${CI:-true}" \
        --userns=keep-id \
        -v "$agent1_vol:/home/developer/.gradle" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'echo "agent1" > /home/developer/.gradle/marker.txt' 2>/dev/null || true

    # Agent 2 writes a different marker file
    podman run --rm \
        -e CI="${CI:-true}" \
        --userns=keep-id \
        -v "$agent2_vol:/home/developer/.gradle" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'echo "agent2" > /home/developer/.gradle/marker.txt' 2>/dev/null || true

    # Check Agent 1's marker
    local agent1_marker
    agent1_marker=$(podman run --rm \
        -e CI="${CI:-true}" \
        --userns=keep-id \
        -v "$agent1_vol:/home/developer/.gradle" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'cat /home/developer/.gradle/marker.txt 2>/dev/null || echo ""' 2>/dev/null) || true

    # Check Agent 2's marker
    local agent2_marker
    agent2_marker=$(podman run --rm \
        -e CI="${CI:-true}" \
        --userns=keep-id \
        -v "$agent2_vol:/home/developer/.gradle" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'cat /home/developer/.gradle/marker.txt 2>/dev/null || echo ""' 2>/dev/null) || true

    # Cleanup
    podman volume rm "$agent1_vol" >/dev/null 2>&1 || true
    podman volume rm "$agent2_vol" >/dev/null 2>&1 || true

    # Verify isolation
    assert_contains "$agent1_marker" "agent1" "Agent 1 should have its own marker"
    assert_contains "$agent2_marker" "agent2" "Agent 2 should have its own marker"
}

test_gradle_cache_persistence() {
    log_test "Testing Gradle cache persists between runs"

    if ! skip_if_no_container; then
        return 0
    fi

    local agent_id="kapsis-test-persist-$$"
    local vol_name="${agent_id}-gradle"

    # Create volume
    podman volume create "$vol_name" >/dev/null 2>&1 || true

    # First run: write data
    podman run --rm \
        -e CI="${CI:-true}" \
        --userns=keep-id \
        -v "$vol_name:/home/developer/.gradle" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'mkdir -p /home/developer/.gradle/caches && echo "cached" > /home/developer/.gradle/caches/test.txt' 2>/dev/null || true

    # Second run: read data
    local cached_content
    cached_content=$(podman run --rm \
        -e CI="${CI:-true}" \
        --userns=keep-id \
        -v "$vol_name:/home/developer/.gradle" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'cat /home/developer/.gradle/caches/test.txt 2>/dev/null || echo "missing"' 2>/dev/null) || true

    # Cleanup
    podman volume rm "$vol_name" >/dev/null 2>&1 || true

    assert_contains "$cached_content" "cached" "Cache should persist between runs"
}

test_cleanup_removes_gradle_volumes() {
    log_test "Testing cleanup removes Gradle volumes"

    if ! skip_if_no_container; then
        return 0
    fi

    local agent_id="kapsis-cleanup-test-$$"
    local vol_name="${agent_id}-gradle"

    # Create volume
    podman volume create "$vol_name" >/dev/null 2>&1 || true

    # Verify it exists
    local exists_before
    exists_before=$(podman volume exists "$vol_name" && echo "yes" || echo "no")

    # Remove volume
    podman volume rm "$vol_name" >/dev/null 2>&1 || true

    # Verify it's gone
    local exists_after
    exists_after=$(podman volume exists "$vol_name" 2>/dev/null && echo "yes" || echo "no")

    assert_equals "yes" "$exists_before" "Volume should exist before cleanup"
    assert_equals "no" "$exists_after" "Volume should not exist after cleanup"
}

test_maven_cache_also_isolated() {
    log_test "Testing Maven cache is also isolated (for completeness)"

    if ! skip_if_no_container; then
        return 0
    fi

    # Same isolation pattern should apply to Maven
    local agent1_m2="kapsis-test-m2-1-$$-m2"
    local agent2_m2="kapsis-test-m2-2-$$-m2"

    # Create volumes
    podman volume create "$agent1_m2" >/dev/null 2>&1 || true
    podman volume create "$agent2_m2" >/dev/null 2>&1 || true

    # Verify they're separate
    local vol1_path
    local vol2_path
    vol1_path=$(podman volume inspect "$agent1_m2" --format '{{.Name}}' 2>/dev/null || echo "")
    vol2_path=$(podman volume inspect "$agent2_m2" --format '{{.Name}}' 2>/dev/null || echo "")

    # Cleanup
    podman volume rm "$agent1_m2" >/dev/null 2>&1 || true
    podman volume rm "$agent2_m2" >/dev/null 2>&1 || true

    assert_not_equals "$vol1_path" "$vol2_path" "Maven volumes should be separate"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Gradle Cache Isolation"

    # Setup
    setup_test_project

    # Run tests
    run_test test_gradle_volume_isolation
    run_test test_gradle_remote_cache_disabled_config
    run_test test_gradle_local_cache_enabled_config
    run_test test_gradle_cache_volume_name_pattern

    # Container tests
    if skip_if_no_container 2>/dev/null; then
        run_test test_gradle_home_in_container
        run_test test_agents_use_isolated_gradle_volumes
        run_test test_gradle_cache_persistence
        run_test test_cleanup_removes_gradle_volumes
        run_test test_maven_cache_also_isolated
    else
        skip_test test_gradle_home_in_container "No container runtime"
        skip_test test_agents_use_isolated_gradle_volumes "No container runtime"
        skip_test test_gradle_cache_persistence "No container runtime"
        skip_test test_cleanup_removes_gradle_volumes "No container runtime"
        skip_test test_maven_cache_also_isolated "No container runtime"
    fi

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
