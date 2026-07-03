#!/usr/bin/env bash
#===============================================================================
# Test: Image GC guards in kapsis-cleanup.sh (Issues #418/#421)
#
# Verifies the two mirror-image fixes from the 2026-07-02 Podman outage:
#   1. Issue #418 — clean_images must never remove images that are in use
#      (referenced by any container, running or stopped), must never pass
#      --force to `podman rmi`, must not swallow rmi failures with `|| true`,
#      and must not count skipped/refused removals as cleaned.
#   2. Issue #421 — dangling (<none>) build layers must be reclaimable
#      proactively: standalone --prune-dangling flag, WARNING-tier prune in
#      _vm_remediate, and the dangling prune must survive a degraded podman
#      (it still runs when the in-use query fails — fail-closed applies only
#      to named-image removal).
#
# Behavioral tests drive the real kapsis-cleanup.sh against a PATH-shimmed
# fake `podman` that records every invocation to a call log.
#
# Category: validation
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/test-framework.sh
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

# Fixed fake image IDs. `podman images` emits 12-char IDs; `podman ps -a`
# emits 64-char IDs (12 + 52 filler chars below).
SANDBOX_ID="aaaaaaaaaaaa"
SLACKBOT_ID="bbbbbbbbbbbb"
SLACKBOT_ID_64="bbbbbbbbbbbbcccccccccccccccccccccccccccccccccccccccccccccccccccc"

#===============================================================================
# Fake podman shim
#===============================================================================

# Set up a temp dir with a fake `podman` on PATH that records invocations.
# Sets: TEST_TMP, SHIM_DIR, STATE_DIR, CALL_LOG.
_setup_shim() {
    TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-imggc.XXXXXX")
    SHIM_DIR="$TEST_TMP/bin"
    STATE_DIR="$TEST_TMP/state"
    CALL_LOG="$TEST_TMP/calls.log"
    mkdir -p "$SHIM_DIR" "$STATE_DIR" "$TEST_TMP/kapsis" "$TEST_TMP/logs"
    : > "$CALL_LOG"

    cat > "$SHIM_DIR/podman" <<'SHIM'
#!/usr/bin/env bash
# Fake podman for kapsis-cleanup image GC tests. Records every invocation.
echo "$*" >> "$PODMAN_CALL_LOG"
case "$*" in
    "images --format {{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}")
        printf '%s\n' \
            "localhost/kapsis-sandbox:latest aaaaaaaaaaaa 1.2GB" \
            "localhost/kapsis-slack-bot:latest bbbbbbbbbbbb 800MB"
        ;;
    "ps -a --format {{.ImageID}}")
        if [[ "${FAKE_PS_EXIT:-0}" != "0" ]]; then
            exit "${FAKE_PS_EXIT}"
        fi
        if [[ -n "${FAKE_PS_OUTPUT:-}" ]]; then
            printf '%s\n' "$FAKE_PS_OUTPUT"
        fi
        ;;
    "images -q --filter dangling=true")
        if [[ "${FAKE_DANGLING_EXIT:-0}" != "0" ]]; then
            exit "${FAKE_DANGLING_EXIT}"
        fi
        # After a prune, dangling layers are gone.
        if [[ -f "$PODMAN_STATE_DIR/pruned" ]]; then
            exit 0
        fi
        if [[ -n "${FAKE_DANGLING_IDS:-}" ]]; then
            printf '%s\n' "$FAKE_DANGLING_IDS"
        fi
        ;;
    "image prune -f")
        touch "$PODMAN_STATE_DIR/pruned"
        ;;
    rmi\ *)
        exit "${FAKE_RMI_EXIT:-0}"
        ;;
esac
exit 0
SHIM
    chmod +x "$SHIM_DIR/podman"
}

_teardown_shim() {
    rm -rf "$TEST_TMP"
}

# Run the real kapsis-cleanup.sh with the fake podman shim first on PATH.
# FAKE_* knobs are exported by prefixing them on the caller's function call.
# Captures combined output in RUN_OUTPUT and the exit status in RUN_RC;
# always returns 0. Callers must invoke this directly (NOT inside a
# command substitution) — a $(...) subshell would discard both variables.
RUN_RC=0
RUN_OUTPUT=""
_run_cleanup() {
    RUN_RC=0
    RUN_OUTPUT=$(
        PODMAN_CALL_LOG="$CALL_LOG" \
        PODMAN_STATE_DIR="$STATE_DIR" \
        KAPSIS_DIR="$TEST_TMP/kapsis" \
        KAPSIS_LOG_DIR="$TEST_TMP/logs" \
        PATH="$SHIM_DIR:$PATH" \
            bash "$CLEANUP_SCRIPT" "$@" 2>&1
    ) || RUN_RC=$?
}

#===============================================================================
# Behavioral tests
#===============================================================================

# Issue #418: an image referenced by ANY container must never be passed to rmi.
test_in_use_image_skipped() {
    _setup_shim

    FAKE_PS_OUTPUT="$SLACKBOT_ID_64" KAPSIS_IMAGE_KEEP_PATTERNS='' \
        _run_cleanup --images --force
    local output="$RUN_OUTPUT"

    if grep -q "rmi $SLACKBOT_ID" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "In-use image was passed to rmi" "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    if ! grep -q "rmi $SANDBOX_ID" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "Not-in-use image was NOT passed to rmi" "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "[SKIPPED]" "In-use image should be reported as [SKIPPED]"
    assert_contains "$output" "in use" "Skip reason should be 'in use'"

    _teardown_shim
}

# Default keep-patterns protect service images even when not in use.
test_keep_patterns_default_protects_service_images() {
    _setup_shim

    _run_cleanup --images --force
    local output="$RUN_OUTPUT"

    if grep -q "rmi $SLACKBOT_ID" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "kapsis-slack-bot removed despite default keep-patterns" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    if grep -q "rmi $SANDBOX_ID" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "kapsis-sandbox removed despite default keep-patterns" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "protected by keep-patterns" \
        "Protected images should be reported with the keep-patterns reason"

    _teardown_shim
}

# Explicitly-empty KAPSIS_IMAGE_KEEP_PATTERNS disables protection
# (proves the unset-vs-empty ${VAR-default} semantics).
test_keep_patterns_empty_disables_protection() {
    _setup_shim

    KAPSIS_IMAGE_KEEP_PATTERNS='' _run_cleanup --images --force

    if ! grep -q "rmi $SANDBOX_ID" "$CALL_LOG" || ! grep -q "rmi $SLACKBOT_ID" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "Empty KAPSIS_IMAGE_KEEP_PATTERNS should disable protection" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi

    _teardown_shim
}

# Fail-closed invariant: when `podman ps -a` fails, ZERO rmi calls happen —
# but the dangling prune still runs (it is natively in-use-safe).
test_fail_closed_on_ps_failure() {
    _setup_shim

    FAKE_PS_EXIT=1 KAPSIS_IMAGE_KEEP_PATTERNS='' \
        FAKE_DANGLING_IDS=$'dddddddddddd\neeeeeeeeeeee' \
        _run_cleanup --images --force
    local output="$RUN_OUTPUT"

    if grep -q "^rmi " "$CALL_LOG"; then
        _teardown_shim
        _log_failure "rmi was invoked despite in-use query failure (must fail closed)" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "fail-closed" \
        "A fail-closed warning must be printed when the in-use query fails"
    assert_equals "0" "$RUN_RC" "Script must still exit 0 on fail-closed path"
    if ! grep -q "image prune -f" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "Dangling prune must still run when the in-use query fails" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi

    _teardown_shim
}

# Regression for the `|| true` misreport in #418: a refused rmi must be
# reported as [SKIPPED], not counted as cleaned, and must not crash the
# script under set -euo pipefail.
test_rmi_refusal_not_counted_as_cleaned() {
    _setup_shim

    FAKE_RMI_EXIT=1 KAPSIS_IMAGE_KEEP_PATTERNS='' \
        _run_cleanup --images --force
    local output="$RUN_OUTPUT"

    assert_contains "$output" "[SKIPPED]" "Refused rmi should print [SKIPPED]"
    assert_contains "$output" "rmi refused" "Skip reason should mention rmi refusal"
    assert_contains "$output" "Cleaned: 0 items" \
        "Summary must not count refused removals as cleaned"
    assert_not_contains "$output" "[CLEANED] Removed image" \
        "No image should be reported as removed when every rmi is refused"
    assert_equals "0" "$RUN_RC" "Script must exit 0 despite rmi refusals"

    _teardown_shim
}

# In-use matching must work across podman ID formats: sha256:-prefixed and
# full-64-char IDs from `ps -a` vs 12-char IDs from `images`.
test_id_format_normalization() {
    _setup_shim

    FAKE_PS_OUTPUT="sha256:$SLACKBOT_ID_64" KAPSIS_IMAGE_KEEP_PATTERNS='' \
        _run_cleanup --images --force
    local output="$RUN_OUTPUT"

    if grep -q "rmi $SLACKBOT_ID" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "sha256:-prefixed in-use ID did not match its 12-char image ID" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "in use" \
        "Normalized ID match should report the image as in use"

    _teardown_shim
}

# --dry-run must make no podman mutation calls while printing [DRY-RUN]
# lines for both named images and the dangling prune.
test_dry_run_makes_no_mutations() {
    _setup_shim

    KAPSIS_IMAGE_KEEP_PATTERNS='' FAKE_DANGLING_IDS='dddddddddddd' \
        _run_cleanup --images --force --dry-run
    local output="$RUN_OUTPUT"

    if grep -q "^rmi " "$CALL_LOG" || grep -q "image prune" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "--dry-run performed a podman mutation" "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "[DRY-RUN]" "Dry run should print [DRY-RUN] lines"
    assert_contains "$output" "Would remove image" \
        "Dry run should show would-remove lines for named images"
    assert_contains "$output" "Would prune 1 dangling image(s)" \
        "Dry run should show the would-prune line for dangling layers"

    _teardown_shim
}

# Standalone --prune-dangling: prunes exactly once, never touches named
# images, and reports the pruned count.
test_prune_dangling_flag_standalone() {
    _setup_shim

    FAKE_DANGLING_IDS=$'dddddddddddd\neeeeeeeeeeee\nffffffffffff' \
        _run_cleanup --prune-dangling --force
    local output="$RUN_OUTPUT"

    local prune_calls
    prune_calls=$(grep -c "image prune -f" "$CALL_LOG" || true)
    assert_equals "1" "$prune_calls" "--prune-dangling must invoke 'image prune -f' exactly once"
    if grep -q "^rmi " "$CALL_LOG"; then
        _teardown_shim
        _log_failure "--prune-dangling must never invoke rmi on named images" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "Pruned 3 dangling image(s)" \
        "--prune-dangling should report the pruned count"

    # With zero dangling images, prune must not be invoked at all.
    _teardown_shim
    _setup_shim
    _run_cleanup --prune-dangling --force
    output="$RUN_OUTPUT"
    if grep -q "image prune" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "prune invoked despite zero dangling images" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "No dangling images to prune" \
        "Zero dangling images should be reported as nothing to prune"

    _teardown_shim
}

# Fail-closed when the dangling query itself fails: no prune, warning, exit 0.
test_prune_query_fail_closed() {
    _setup_shim

    FAKE_DANGLING_EXIT=1 _run_cleanup --prune-dangling --force
    local output="$RUN_OUTPUT"

    if grep -q "image prune" "$CALL_LOG"; then
        _teardown_shim
        _log_failure "prune ran despite dangling-query failure (must fail closed)" \
            "Call log: $(cat "$CALL_LOG")"
        return 1
    fi
    assert_contains "$output" "Could not enumerate dangling images" \
        "A warning must be logged when the dangling query fails"
    assert_equals "0" "$RUN_RC" "Script must exit 0 when the dangling query fails"

    _teardown_shim
}

#===============================================================================
# Static-content assertions on kapsis-cleanup.sh
#===============================================================================

# The swallowed-exit-code pattern from #418 must be gone, the new guards
# present, and clean_images must never pass --force to rmi.
test_static_no_swallowed_rmi() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")

    # shellcheck disable=SC2016 # literal substring match, not expansion
    assert_not_contains "$content" 'podman rmi "$image_id" &>/dev/null || true' \
        "The swallowed-rmi pattern must be removed from kapsis-cleanup.sh"
    assert_contains "$content" "_get_inuse_image_ids" \
        "_get_inuse_image_ids helper must exist"
    assert_contains "$content" "_prune_dangling_layers" \
        "_prune_dangling_layers helper must exist"
    assert_contains "$content" "KAPSIS_IMAGE_KEEP_PATTERNS" \
        "KAPSIS_IMAGE_KEEP_PATTERNS must be honored"

    # No `rmi ... --force` anywhere in clean_images.
    local clean_images_body
    clean_images_body=$(awk '/^clean_images\(\)/,/^}/' "$CLEANUP_SCRIPT")
    if echo "$clean_images_body" | grep -E 'rmi.*--force' >/dev/null; then
        _log_failure "clean_images passes --force to rmi" "Found rmi --force in clean_images"
        return 1
    fi
    return 0
}

# _vm_remediate must prune dangling layers at WARNING (any non-HEALTHY state)
# while the heavier clean_images stays gated to CRITICAL.
test_static_vm_remediate_warning_tier() {
    local body
    body=$(awk '/^_vm_remediate\(\)/,/^}/' "$CLEANUP_SCRIPT")

    # shellcheck disable=SC2016 # literal substring match, not expansion
    assert_contains "$body" '"$VM_HEALTH_STATUS" != "HEALTHY"' \
        "_vm_remediate must have a non-HEALTHY (WARNING-tier) guard"
    assert_contains "$body" "_prune_dangling_layers" \
        "_vm_remediate must call _prune_dangling_layers proactively"
    # shellcheck disable=SC2016
    assert_contains "$body" '"$VM_HEALTH_STATUS" == "CRITICAL"' \
        "_vm_remediate must keep the CRITICAL gate"
    assert_contains "$body" "clean_images" \
        "_vm_remediate must still call clean_images (at CRITICAL)"

    # The WARNING-tier block (up to its closing fi) must call
    # _prune_dangling_layers but NOT the heavier clean_images.
    local warning_block
    warning_block=$(echo "$body" | awk '/!= "HEALTHY"/ {capture=1} capture {print} capture && /^    fi/ {exit}')
    assert_contains "$warning_block" "_prune_dangling_layers" \
        "WARNING-tier block must call _prune_dangling_layers"
    assert_not_contains "$warning_block" "clean_images" \
        "WARNING-tier block must NOT call clean_images (CRITICAL-only)"
}

# The --prune-dangling flag must register as an explicit action so it does
# not trigger the default cleanup set (mirrors
# test_explicit_action_requested_set_by_action_flags in
# test-cleanup-vm-health.sh).
test_static_flag_registration() {
    local branch
    branch=$(awk -v pat="--prune-dangling)" '
        $0 ~ pat {capture=1; next}
        capture && /;;/ {capture=0}
        capture {print}
    ' "$CLEANUP_SCRIPT")
    assert_contains "$branch" "explicit_action_requested=true" \
        "--prune-dangling branch must set explicit_action_requested=true"
    assert_contains "$branch" "PRUNE_DANGLING=true" \
        "--prune-dangling branch must set PRUNE_DANGLING=true"
}

#===============================================================================
# Runner
#===============================================================================

run_test test_in_use_image_skipped
run_test test_keep_patterns_default_protects_service_images
run_test test_keep_patterns_empty_disables_protection
run_test test_fail_closed_on_ps_failure
run_test test_rmi_refusal_not_counted_as_cleaned
run_test test_id_format_normalization
run_test test_dry_run_makes_no_mutations
run_test test_prune_dangling_flag_standalone
run_test test_prune_query_fail_closed
run_test test_static_no_swallowed_rmi
run_test test_static_vm_remediate_warning_tier
run_test test_static_flag_registration

print_summary
