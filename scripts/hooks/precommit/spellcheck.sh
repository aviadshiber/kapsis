#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-commit: Spellcheck
#
# Runs codespell on staged files to catch common spelling mistakes.
# Uses .codespellrc for configuration if present.
#
# Exit codes:
#   0 - No spelling errors found
#   1 - Spelling errors found
#   2 - codespell not installed (skipped)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "precommit-spellcheck"
else
    # Fallback logging
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { :; }
fi

# Check if codespell is available
if ! command -v codespell &>/dev/null; then
    log_warn "codespell not installed, skipping spellcheck"
    log_info "Install with: pip install codespell"
    exit 0  # Don't block commit, just warn
fi

# Get staged files
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [[ -z "$STAGED_FILES" ]]; then
    log_debug "No staged files to check"
    exit 0
fi

# Build codespell args
CODESPELL_ARGS=()

# Use config file if exists
if [[ -f "$REPO_ROOT/.codespellrc" ]]; then
    CODESPELL_ARGS+=(--config "$REPO_ROOT/.codespellrc")
fi

# Run codespell on staged files
log_info "Running spellcheck on staged files..."

# Create temp file for staged content
ERRORS_FOUND=0

while IFS= read -r file; do
    # Skip binary files and non-existent files
    [[ ! -f "$REPO_ROOT/$file" ]] && continue

    # Run codespell on the file
    if ! codespell "${CODESPELL_ARGS[@]}" "$REPO_ROOT/$file" 2>/dev/null; then
        ERRORS_FOUND=1
    fi
done <<< "$STAGED_FILES"

if [[ "$ERRORS_FOUND" -eq 1 ]]; then
    log_error "Spelling errors found. Fix them before committing."
    log_info "To ignore a word, add it to .codespellrc ignore list"
    exit 1
fi

log_info "Spellcheck passed"
exit 0
