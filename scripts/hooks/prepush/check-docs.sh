#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-push: Check Documentation
#
# Verifies that documentation is updated when relevant files change.
# Non-blocking - warns but doesn't prevent push.
#
# Checks:
#   - scripts/*.sh changes -> docs/*.md should be touched
#   - New scripts -> should be mentioned in README or docs
#   - Config changes -> CONFIG-REFERENCE.md should be updated
#
# Exit codes:
#   0 - Always (non-blocking)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "prepush-check-docs"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_debug() { :; }
fi

# Get changed files compared to main
CHANGED_FILES=$(git diff origin/main --name-only 2>/dev/null || git diff HEAD~1 --name-only 2>/dev/null || true)

if [[ -z "$CHANGED_FILES" ]]; then
    log_debug "No changed files to check"
    exit 0
fi

DOCS_WARNINGS=()

# Check if docs were touched
DOCS_CHANGED=$(echo "$CHANGED_FILES" | grep -E '^docs/|^README\.md$|^CONTRIBUTING\.md$' || true)

# Check for script changes
SCRIPTS_CHANGED=$(echo "$CHANGED_FILES" | grep -E '^scripts/.*\.sh$' || true)

if [[ -n "$SCRIPTS_CHANGED" && -z "$DOCS_CHANGED" ]]; then
    DOCS_WARNINGS+=("Scripts modified but no documentation updated")
fi

# Check for new scripts (added, not modified)
NEW_SCRIPTS=$(git diff origin/main --name-only --diff-filter=A 2>/dev/null | grep -E '^scripts/.*\.sh$' || true)

for script in $NEW_SCRIPTS; do
    SCRIPT_NAME=$(basename "$script" .sh)

    # Check if mentioned in README
    if ! grep -q "$SCRIPT_NAME" "$REPO_ROOT/README.md" 2>/dev/null; then
        DOCS_WARNINGS+=("New script '$script' not mentioned in README.md")
    fi
done

# Check for config changes
CONFIG_CHANGED=$(echo "$CHANGED_FILES" | grep -E '^configs/.*\.yaml$|^configs/.*\.yml$' || true)
CONFIG_REF_CHANGED=$(echo "$DOCS_CHANGED" | grep 'CONFIG-REFERENCE.md' || true)

if [[ -n "$CONFIG_CHANGED" && -z "$CONFIG_REF_CHANGED" ]]; then
    DOCS_WARNINGS+=("Config files changed but CONFIG-REFERENCE.md not updated")
fi

# Check for lib changes
LIB_CHANGED=$(echo "$CHANGED_FILES" | grep -E '^scripts/lib/.*\.sh$' || true)

if [[ -n "$LIB_CHANGED" && -z "$DOCS_CHANGED" ]]; then
    DOCS_WARNINGS+=("Library files changed - consider updating documentation")
fi

# Report warnings
if [[ ${#DOCS_WARNINGS[@]} -gt 0 ]]; then
    log_warn "Documentation may need updates:"
    for warning in "${DOCS_WARNINGS[@]}"; do
        echo "  - $warning"
    done
    log_info "Consider updating relevant docs before merge"
else
    log_debug "Documentation check passed"
fi

# Always exit 0 - this is non-blocking
exit 0
