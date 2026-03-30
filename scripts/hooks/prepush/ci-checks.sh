#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-push: CI Parity Checks
#
# Runs the same checks that CI runs locally before push, catching failures
# before they reach GitHub Actions. Mirrors jobs in .github/workflows/ci.yml:
#
#   1. ShellCheck — lint modified shell scripts
#   2. Quick tests — non-container test suite
#   3. Config validation — YAML config schema check (when configs/ changed)
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed (blocks push)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "ci-checks"
else
    log_info()    { echo "[INFO] $*"; }
    log_warn()    { echo "[WARN] $*"; }
    log_error()   { echo "[ERROR] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
fi

FAILED=0

#-------------------------------------------------------------------------------
# 1. ShellCheck
#-------------------------------------------------------------------------------
log_info "Running ShellCheck on modified shell scripts..."

if ! command -v shellcheck &>/dev/null; then
    log_warn "shellcheck not found — skipping lint (install: brew install shellcheck)"
else
    # Collect modified .sh files (staged + unstaged), deduplicated.
    # Avoid mapfile (bash 4+) for macOS bash 3.2 compatibility.
    SCRIPTS=()
    while IFS= read -r f; do
        [[ -n "$f" && -f "$REPO_ROOT/$f" ]] && SCRIPTS+=("$REPO_ROOT/$f")
    done < <(
        { git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached HEAD 2>/dev/null; } \
            | grep '\.sh$' | sort -u || true
    )

    if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
        log_info "  No modified shell scripts to lint"
    else
        log_info "  Linting ${#SCRIPTS[@]} script(s)..."
        if shellcheck "${SCRIPTS[@]}"; then
            log_success "  ShellCheck passed"
        else
            log_error "  ShellCheck failed — fix errors before pushing"
            FAILED=1
        fi
    fi
fi

echo ""

#-------------------------------------------------------------------------------
# 2. Quick tests
#-------------------------------------------------------------------------------
log_info "Running quick tests (no container required)..."

if [[ ! -x "$REPO_ROOT/tests/run-all-tests.sh" ]]; then
    log_warn "  tests/run-all-tests.sh not found — skipping"
else
    if "$REPO_ROOT/tests/run-all-tests.sh" --quick; then
        log_success "  Quick tests passed"
    else
        log_error "  Quick tests failed — fix before pushing"
        FAILED=1
    fi
fi

echo ""

#-------------------------------------------------------------------------------
# 3. Config YAML validation (only when configs/ changed)
#-------------------------------------------------------------------------------
CONFIGS_CHANGED=$(git diff --name-only HEAD 2>/dev/null | grep '^configs/' || true)

if [[ -n "$CONFIGS_CHANGED" ]]; then
    log_info "Configs changed — validating YAML schemas..."

    if [[ -x "$REPO_ROOT/scripts/lib/config-verifier.sh" ]]; then
        if "$REPO_ROOT/scripts/lib/config-verifier.sh" --all --test; then
            log_success "  Config validation passed"
        else
            log_error "  Config validation failed — fix before pushing"
            FAILED=1
        fi
    else
        log_warn "  config-verifier.sh not found — skipping"
    fi
else
    log_info "No config changes — skipping YAML validation"
fi

echo ""

#-------------------------------------------------------------------------------
# Result
#-------------------------------------------------------------------------------
if [[ $FAILED -ne 0 ]]; then
    log_error "CI checks failed. Fix the issues above, then push again."
    log_error "To skip these checks (emergency only): git push --no-verify"
    exit 1
fi

log_success "All CI checks passed"
exit 0
