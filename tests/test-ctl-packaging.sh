#!/usr/bin/env bash
#===============================================================================
# Test: kapsis-ctl packaging scope-cut (Issue #429)
#
# Static/grep-only assertions against tracked files — no `go build`, no
# podman, no `brew` invocation. Locks in the design decision that kapsis-ctl
# (issue #266) is packaged for macOS ONLY, staged into Homebrew's libexec/bin
# (never a public bin/ symlink), and deliberately excluded from RPM/Debian
# packaging because there is no Linux consumer
# (scripts/lib/podman-health.sh's `is_linux` early-return in
# `maybe_autoheal_podman_vm`, plus launch-agent.sh's additional `is_macos`
# gate on that function's only caller).
#
# This test exists so a future contributor doesn't mechanically "complete"
# the packaging onto RPM/deb via the Release Artifact Rule without
# re-checking for a real consumer first.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

FORMULA_FILE="$KAPSIS_ROOT/packaging/homebrew/kapsis.rb"
RPM_SPEC="$KAPSIS_ROOT/packaging/rpm/kapsis.spec"
DEBIAN_RULES="$KAPSIS_ROOT/packaging/debian/debian/rules"
RELEASE_WORKFLOW="$KAPSIS_ROOT/.github/workflows/release.yml"
MAIN_GO="$KAPSIS_ROOT/cmd/kapsis-ctl/main.go"
PODMAN_HEALTH="$KAPSIS_ROOT/scripts/lib/podman-health.sh"

#===============================================================================
# TEST CASES
#===============================================================================

# _on_macos_line_ranges <file>
# Print the line range of every top-level `on_macos do` ... `end` block as
# "start:end", one per line. The closing `end` is found by tracking nested
# do/end pairs (on_arm/on_intel/resource blocks), pure text — no `brew`.
_on_macos_line_ranges() {
    local file="$1"
    awk '
        depth == 0 && /^[[:space:]]*on_macos do[[:space:]]*$/ {
            start = NR
            depth = 1
            next
        }
        depth > 0 && /(^|[[:space:]])do[[:space:]]*$/ { depth++; next }
        depth > 0 && /^[[:space:]]*end[[:space:]]*$/ {
            depth--
            if (depth == 0) print start ":" NR
        }
    ' "$file"
}

test_homebrew_formula_has_both_ctl_marker_pairs() {
    log_test "kapsis.rb declares both KAPSIS_CTL_DARWIN_* marker pairs inside on_macos"

    assert_file_contains "$FORMULA_FILE" "KAPSIS_CTL_DARWIN_ARM64_MARKER_START" \
        "Missing darwin-arm64 start marker"
    assert_file_contains "$FORMULA_FILE" "KAPSIS_CTL_DARWIN_ARM64_MARKER_END" \
        "Missing darwin-arm64 end marker"
    assert_file_contains "$FORMULA_FILE" "KAPSIS_CTL_DARWIN_X64_MARKER_START" \
        "Missing darwin-x64 start marker"
    assert_file_contains "$FORMULA_FILE" "KAPSIS_CTL_DARWIN_X64_MARKER_END" \
        "Missing darwin-x64 end marker"

    # The markers must not merely exist somewhere in the formula — the
    # resource blocks they delimit must be nested inside an on_macos block,
    # or brew would fetch the darwin binaries on Linux too.
    local on_macos_ranges
    on_macos_ranges="$(_on_macos_line_ranges "$FORMULA_FILE")"
    assert_not_empty "$on_macos_ranges" \
        "kapsis.rb should contain at least one on_macos block"

    local marker marker_line range_start range_end inside
    for marker in \
        KAPSIS_CTL_DARWIN_ARM64_MARKER_START \
        KAPSIS_CTL_DARWIN_ARM64_MARKER_END \
        KAPSIS_CTL_DARWIN_X64_MARKER_START \
        KAPSIS_CTL_DARWIN_X64_MARKER_END; do
        marker_line="$(grep -n -F "$marker" "$FORMULA_FILE" | cut -d: -f1 | head -n 1)"
        # Existence already asserted above; guard against an empty line number
        # so the arithmetic below cannot blow up mid-test.
        [[ -n "$marker_line" ]] || continue
        inside=false
        while IFS=':' read -r range_start range_end; do
            [[ -n "$range_start" && -n "$range_end" ]] || continue
            if (( marker_line > range_start && marker_line < range_end )); then
                inside=true
                break
            fi
        done <<< "$on_macos_ranges"
        if [[ "$inside" != "true" ]]; then
            _log_failure "$marker must be nested inside an on_macos block" \
                "Marker at line $marker_line" \
                "on_macos block ranges: ${on_macos_ranges//$'\n'/ }"
            return 1
        fi
    done

    # No Linux marker pair should exist — no code-backed consumer.
    assert_file_not_contains "$FORMULA_FILE" "KAPSIS_CTL_LINUX_ARM64_MARKER_START" \
        "Must not declare a Linux kapsis-ctl marker (no consumer)"
    assert_file_not_contains "$FORMULA_FILE" "KAPSIS_CTL_LINUX_X64_MARKER_START" \
        "Must not declare a Linux kapsis-ctl marker (no consumer)"
}

test_homebrew_formula_stages_libexec_only_no_public_symlink() {
    log_test "kapsis.rb stages kapsis-ctl into libexec/bin, never a public bin/ symlink"

    assert_file_contains "$FORMULA_FILE" 'libexec/"bin"' \
        "install should stage kapsis-ctl under libexec/bin"
    assert_file_contains "$FORMULA_FILE" 'ctl_bin_dir/"kapsis-ctl"' \
        "install should write the binary as libexec/bin/kapsis-ctl"

    # There must be no bin.install_symlink referencing kapsis-ctl anywhere
    # in the formula (grep -F on the whole file, not scoped to one line,
    # since the guardrail is file-wide: never expose it publicly).
    if grep -F "bin.install_symlink" "$FORMULA_FILE" | grep -qF "kapsis-ctl"; then
        _log_failure "kapsis-ctl must not be exposed via bin.install_symlink" \
            "Found a bin.install_symlink referencing kapsis-ctl in $FORMULA_FILE"
        return 1
    fi
    return 0
}

test_main_go_version_is_build_time_stamped() {
    log_test "main.go's --version is a build-time-stamped variable, not a hardcoded literal"

    assert_file_not_contains "$MAIN_GO" 'kapsis-ctl phase-2 (issue #266)' \
        "Old hardcoded version literal should be removed"
    assert_file_contains "$MAIN_GO" 'var version = "dev"' \
        "main.go should declare a package-scope version variable defaulting to dev"
    assert_file_contains "$MAIN_GO" 'fmt.Printf("kapsis-ctl %s\n", version)' \
        "--version should print the stamped version variable"
}

test_release_workflow_has_compile_ctl_job() {
    log_test "release.yml defines a compile-ctl job for kapsis-ctl"

    assert_file_contains "$RELEASE_WORKFLOW" "compile-ctl:" \
        "release.yml should define a compile-ctl job"
    assert_file_contains "$RELEASE_WORKFLOW" "kapsis-ctl-darwin-arm64" \
        "release.yml should build/reference the darwin-arm64 kapsis-ctl artifact"
    assert_file_contains "$RELEASE_WORKFLOW" "kapsis-ctl-darwin-x64" \
        "release.yml should build/reference the darwin-x64 kapsis-ctl artifact"

    # No Linux kapsis-ctl artifact should be built.
    assert_file_not_contains "$RELEASE_WORKFLOW" "kapsis-ctl-linux" \
        "release.yml must not build a Linux kapsis-ctl artifact (no consumer)"
}

test_rpm_and_debian_do_not_install_ctl() {
    log_test "rpm.spec and debian/rules contain no kapsis-ctl install/%files references, only a comment"

    assert_file_not_contains "$RPM_SPEC" "buildroot}%{_bindir}/kapsis-ctl" \
        "rpm.spec must not install kapsis-ctl"
    assert_file_not_contains "$RPM_SPEC" "%{_bindir}/kapsis-ctl" \
        "rpm.spec %files must not list kapsis-ctl"
    assert_file_contains "$RPM_SPEC" "kapsis-ctl" \
        "rpm.spec should still mention kapsis-ctl in an explanatory comment"

    assert_file_not_contains "$DEBIAN_RULES" "usr/bin/kapsis-ctl" \
        "debian/rules must not install kapsis-ctl"
    assert_file_contains "$DEBIAN_RULES" "kapsis-ctl" \
        "debian/rules should still mention kapsis-ctl in an explanatory comment"
}

test_podman_health_failed_branch_uses_log_warn() {
    log_test "podman-health.sh's 'kapsis-ctl found but failed' branch logs at WARN, not DEBUG"

    assert_file_contains "$PODMAN_HEALTH" 'log_warn "count_running_kapsis_containers: kapsis-ctl found but failed' \
        "The found-but-failed branch should call log_warn"

    # The 'not found' path (kapsis-ctl binary absent) must remain unchanged
    # at DEBUG — only the found-but-failed branch's severity changed.
    assert_file_not_contains "$PODMAN_HEALTH" 'log_debug "count_running_kapsis_containers: kapsis-ctl failed' \
        "The old DEBUG-level found-but-failed message should no longer exist"
}

test_podman_health_has_one_shot_warn_guard() {
    log_test "podman-health.sh guards the found-but-failed WARN with a one-shot flag"

    assert_file_contains "$PODMAN_HEALTH" "_KAPSIS_CTL_FAILED_WARNED" \
        "Expected a one-shot guard variable for the found-but-failed WARN"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "kapsis-ctl Packaging Scope-Cut (Issue #429)"

    run_test test_homebrew_formula_has_both_ctl_marker_pairs
    run_test test_homebrew_formula_stages_libexec_only_no_public_symlink
    run_test test_main_go_version_is_build_time_stamped
    run_test test_release_workflow_has_compile_ctl_job
    run_test test_rpm_and_debian_do_not_install_ctl
    run_test test_podman_health_failed_branch_uses_log_warn
    run_test test_podman_health_has_one_shot_warn_guard

    print_summary
}

main "$@"
