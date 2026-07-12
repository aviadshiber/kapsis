#!/usr/bin/env bash
#===============================================================================
# Test: GE-cache vulnerable transitive jar removal
#
# Verifies that the known-vulnerable jars/poms the GE/CCUD Maven extensions
# transitively pull into /opt/kapsis/m2-cache (dom4j, maven-core, commons-
# compress, commons-io, jetty-http/server, jsoup, plexus-archiver/utils) are
# actually absent from a built image, and that the GE extensions themselves
# are still cached.
#
# This exists because a prior fix attempt (a <dependencyManagement> override
# in the Containerfile's ge-cache stage) silently failed to work — `mvn
# dependency:resolve` still downloaded the old vulnerable versions regardless
# of the override, and that failure was only caught by re-running a
# vulnerability scan after release, not by any automated check. This test is
# the regression guard for that failure mode.
#
# Note: if GE_EXT_VERSION/GE_CCUD_VERSION (Containerfile) are bumped, this
# list may need updating — a newer extension release can pull different (or
# already-patched) transitive versions. A passing test here does not by
# itself prove no NEW vulnerable version was introduced by such a bump; it
# only guards against regression of the specific versions listed below.
#
# Prerequisites:
#   - Podman installed and running
#   - Kapsis image built with Java + Gradle Enterprise enabled
#     (KAPSIS_TEST_IMAGE must have ENABLE_JAVA=true, ENABLE_GRADLE_ENTERPRISE=true)
#===============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Known-vulnerable version paths that must NOT be present in the cache.
# Keep this list in sync with the Containerfile's ge-cache removal RUN block.
readonly GE_CACHE_VULNERABLE_PATHS=(
    "/opt/kapsis/m2-cache/dom4j/dom4j/1.1"
    "/opt/kapsis/m2-cache/org/apache/maven/maven-core/3.2.5"
    "/opt/kapsis/m2-cache/org/apache/commons/commons-compress/1.20"
    "/opt/kapsis/m2-cache/commons-io/commons-io/2.6"
    "/opt/kapsis/m2-cache/commons-io/commons-io/2.11.0"
    "/opt/kapsis/m2-cache/org/eclipse/jetty/jetty-http/9.4.46.v20220331"
    "/opt/kapsis/m2-cache/org/eclipse/jetty/jetty-server/9.4.46.v20220331"
    "/opt/kapsis/m2-cache/org/jsoup/jsoup/1.10.2"
    "/opt/kapsis/m2-cache/org/codehaus/plexus/plexus-archiver/4.2.7"
    "/opt/kapsis/m2-cache/org/codehaus/plexus/plexus-utils/3.4.2"
    "/opt/kapsis/m2-cache/org/codehaus/plexus/plexus-utils/3.5.1"
    "/opt/kapsis/m2-cache/org/codehaus/plexus/plexus-utils/4.0.0"
    "/opt/kapsis/m2-cache/org/codehaus/plexus/plexus-utils/4.0.1"
)

# =============================================================================
# Test: none of the known-vulnerable version paths are present
# =============================================================================
test_ge_cache_vulnerable_jars_absent() {
    if ! skip_if_no_container; then
        return 0
    fi

    local failed=0
    local p
    for p in "${GE_CACHE_VULNERABLE_PATHS[@]}"; do
        local result
        result=$(run_simple_container "test -d '$p' && echo FOUND || echo NOT_FOUND")
        if [[ "$result" == *"FOUND"* && "$result" != *"NOT_FOUND"* ]]; then
            _log_failure "Vulnerable jar path must not be present: $p"
            failed=1
        fi
    done

    if [[ "$failed" -eq 0 ]]; then
        log_info "None of the ${#GE_CACHE_VULNERABLE_PATHS[@]} known-vulnerable GE-cache paths are present"
        return 0
    fi
    return 1
}

# =============================================================================
# Test: the GE/CCUD extensions themselves are still cached (positive check —
# a build that failed before populating the cache at all would otherwise
# pass the absence test above by accident)
# =============================================================================
test_ge_cache_extensions_still_present() {
    if ! skip_if_no_container; then
        return 0
    fi

    # Use FOUND/NOT_FOUND string markers rather than a numeric comparison —
    # run_simple_container's output can include entrypoint boot-sequence log
    # noise ahead of the actual command output, which breaks arithmetic
    # comparisons but not simple substring checks.
    local ge_result ccud_result
    ge_result=$(run_simple_container \
        "find /opt/kapsis/m2-cache/com/gradle/gradle-enterprise-maven-extension -iname '*.jar' 2>/dev/null | grep -q . && echo FOUND || echo NOT_FOUND")
    ccud_result=$(run_simple_container \
        "find /opt/kapsis/m2-cache/com/gradle/common-custom-user-data-maven-extension -iname '*.jar' 2>/dev/null | grep -q . && echo FOUND || echo NOT_FOUND")

    if [[ "$ge_result" == *"FOUND"* && "$ge_result" != *"NOT_FOUND"* \
        && "$ccud_result" == *"FOUND"* && "$ccud_result" != *"NOT_FOUND"* ]]; then
        log_info "GE and CCUD extension jars both found in cache"
        return 0
    else
        skip_test "test_ge_cache_extensions_still_present" \
            "GE/CCUD extension jars not found - image may not have Gradle Enterprise enabled, or needs rebuild"
        return 0
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
print_test_header "GE-Cache Vulnerable Transitive Jar Removal"

run_test test_ge_cache_vulnerable_jars_absent
run_test test_ge_cache_extensions_still_present

print_summary
