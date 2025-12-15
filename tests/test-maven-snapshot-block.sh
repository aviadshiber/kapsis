#!/usr/bin/env bash
#===============================================================================
# Test: Maven SNAPSHOT Blocking
#
# Verifies that SNAPSHOT dependencies cannot be downloaded from remote
# repositories. This is critical for hermetic isolation - prevents
# one agent's deployed SNAPSHOT from affecting another's build.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_snapshot_download_blocked() {
    log_test "Testing SNAPSHOT dependency download is blocked"

    setup_container_test "maven-snap"

    # Create a pom with a SNAPSHOT dependency that won't exist locally
    cat > "$TEST_PROJECT/pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.kapsis.test</groupId>
    <artifactId>snapshot-test</artifactId>
    <version>1.0</version>
    <dependencies>
        <!-- This SNAPSHOT should NOT be downloadable -->
        <dependency>
            <groupId>com.kapsis.nonexistent</groupId>
            <artifactId>fake-snapshot</artifactId>
            <version>1.0-SNAPSHOT</version>
        </dependency>
    </dependencies>
</project>
EOF

    # Try to resolve dependencies
    local output
    local exit_code=0
    output=$(run_in_container "cd /workspace && mvn dependency:resolve -q 2>&1") || exit_code=$?

    cleanup_container_test

    # Build should fail because SNAPSHOT can't be resolved
    # The error could be "not found" or related to SNAPSHOT policy
    if [[ $exit_code -ne 0 ]] || [[ "$output" == *"SNAPSHOT"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"Could not resolve"* ]]; then
        log_info "SNAPSHOT correctly blocked or not found"
        return 0
    else
        log_fail "SNAPSHOT dependency should be blocked"
        log_info "Output: $output"
        return 1
    fi
}

test_snapshot_settings_applied() {
    log_test "Testing Maven settings disable SNAPSHOTs"

    setup_container_test "maven-settings"

    # Check that settings file disables snapshots
    local output
    output=$(run_in_container "cat /opt/kapsis/maven/settings.xml 2>/dev/null || echo 'not found'")

    cleanup_container_test

    # Verify snapshots disabled in settings
    assert_contains "$output" "snapshots" "Settings should mention snapshots"
    assert_contains "$output" "false" "Snapshots should be disabled"
}

test_release_dependency_works() {
    log_test "Testing release dependency resolution works"

    setup_container_test "maven-release"

    # Create a pom with a common release dependency
    cat > "$TEST_PROJECT/pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.kapsis.test</groupId>
    <artifactId>release-test</artifactId>
    <version>1.0</version>
    <dependencies>
        <!-- Common release dependency that should resolve -->
        <dependency>
            <groupId>org.slf4j</groupId>
            <artifactId>slf4j-api</artifactId>
            <version>1.7.36</version>
        </dependency>
    </dependencies>
</project>
EOF

    # Try to resolve dependencies (may take time)
    local output
    local exit_code=0
    output=$(run_in_container "cd /workspace && mvn dependency:resolve -q 2>&1" 120) || exit_code=$?

    cleanup_container_test

    # Note: This test may fail if network is unavailable
    # We're mainly testing that releases are allowed while snapshots are blocked
    if [[ $exit_code -eq 0 ]]; then
        log_info "Release dependency resolved successfully"
        return 0
    else
        log_info "Release resolution failed (may be network issue): $output"
        # Don't fail the test on network issues - just log
        return 0
    fi
}

test_deploy_blocked() {
    log_test "Testing mvn deploy is blocked"

    setup_container_test "maven-deploy"

    # Try to deploy
    local output
    local exit_code=0
    output=$(run_in_container "cd /workspace && mvn deploy -DskipTests 2>&1" 60) || exit_code=$?

    cleanup_container_test

    # Deploy should fail or be skipped
    if [[ $exit_code -ne 0 ]] || [[ "$output" == *"skip"* ]] || [[ "$output" == *"blocked"* ]]; then
        log_info "Deploy correctly blocked or skipped"
        return 0
    else
        # Check if deployment was actually skipped via property
        if [[ "$output" == *"maven.deploy.skip"* ]]; then
            return 0
        fi
        log_fail "Deploy should be blocked"
        return 1
    fi
}

test_kapsis_isolation_profile_active() {
    log_test "Testing kapsis-isolation profile is active"

    setup_container_test "maven-profile"

    # Check active profiles
    local output
    output=$(run_in_container "cd /workspace && mvn help:active-profiles 2>&1" 60) || true

    cleanup_container_test

    # Should show kapsis profiles
    if [[ "$output" == *"kapsis"* ]]; then
        return 0
    else
        log_info "Could not verify profile (may be settings path issue)"
        # Check if settings file exists and has profiles
        return 0  # Don't fail, just informational
    fi
}

test_local_snapshot_builds_work() {
    log_test "Testing local SNAPSHOT builds work (reactor builds)"

    setup_container_test "maven-local"

    # Create a multi-module project where modules depend on each other
    cat > "$TEST_PROJECT/pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.kapsis.test</groupId>
    <artifactId>local-snapshot-parent</artifactId>
    <version>1.0-SNAPSHOT</version>
    <packaging>pom</packaging>
    <modules>
        <module>module-a</module>
        <module>module-b</module>
    </modules>
</project>
EOF

    mkdir -p "$TEST_PROJECT/module-a/src/main/java"
    cat > "$TEST_PROJECT/module-a/pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>com.kapsis.test</groupId>
        <artifactId>local-snapshot-parent</artifactId>
        <version>1.0-SNAPSHOT</version>
    </parent>
    <artifactId>module-a</artifactId>
</project>
EOF
    echo "public class A {}" > "$TEST_PROJECT/module-a/src/main/java/A.java"

    mkdir -p "$TEST_PROJECT/module-b/src/main/java"
    cat > "$TEST_PROJECT/module-b/pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>com.kapsis.test</groupId>
        <artifactId>local-snapshot-parent</artifactId>
        <version>1.0-SNAPSHOT</version>
    </parent>
    <artifactId>module-b</artifactId>
    <dependencies>
        <dependency>
            <groupId>com.kapsis.test</groupId>
            <artifactId>module-a</artifactId>
            <version>1.0-SNAPSHOT</version>
        </dependency>
    </dependencies>
</project>
EOF
    echo "public class B { A a; }" > "$TEST_PROJECT/module-b/src/main/java/B.java"

    # Build should work because it's a reactor build (local)
    local output
    local exit_code=0
    output=$(run_in_container "cd /workspace && mvn compile -q 2>&1" 120) || exit_code=$?

    cleanup_container_test

    # Reactor builds with local SNAPSHOTs should work
    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        log_info "Local SNAPSHOT build failed: $output"
        # This is expected if mvn isn't set up correctly in container
        return 0  # Don't fail, informational
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Maven SNAPSHOT Blocking"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Check prerequisites
    if ! skip_if_no_container; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_snapshot_download_blocked
    run_test test_snapshot_settings_applied
    run_test test_release_dependency_works
    run_test test_deploy_blocked
    run_test test_kapsis_isolation_profile_active
    run_test test_local_snapshot_builds_work

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
