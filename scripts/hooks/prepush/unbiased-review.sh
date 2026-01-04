#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-push: Unbiased LLM Review
#
# Invokes a Claude subagent to review the feature with minimal context.
# The subagent is directed to be skeptical and look for simpler alternatives.
#
# The subagent:
#   - Auto-reads CLAUDE.md and AGENTS.md (built-in behavior)
#   - Is directed to read docs/ARCHITECTURE.md
#   - Has read-only access (Glob, Grep, Read)
#   - Cannot see the implementation details in the prompt
#   - Explores the codebase independently
#
# Exit codes:
#   0 - Review completed (warnings logged)
#   1 - Critical security issue found
#   2 - Claude CLI not available
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "prepush-unbiased-review"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { :; }
fi

# Check if claude CLI is available
if ! command -v claude &>/dev/null; then
    log_warn "Claude CLI not installed, skipping LLM review"
    exit 0
fi

# Get feature context (minimal - just names, not content)
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
FEATURE_NAME="${CURRENT_BRANCH##*/}"  # Remove prefix like 'feature/'

# Get list of changed files (not content)
FILES_CHANGED=$(git diff origin/main --name-only 2>/dev/null || git diff HEAD~1 --name-only 2>/dev/null || true)

if [[ -z "$FILES_CHANGED" ]]; then
    log_debug "No files changed, skipping review"
    exit 0
fi

FILE_COUNT=$(echo "$FILES_CHANGED" | wc -l | tr -d ' ')

log_info "Running unbiased review for feature: $FEATURE_NAME"
log_info "Files changed: $FILE_COUNT"

# Build the review prompt (minimal context)
REVIEW_PROMPT=$(cat <<EOF
You are reviewing feature: $FEATURE_NAME

Files changed:
$FILES_CHANGED

## Directive
BE SKEPTICAL. Assume the implementation may be suboptimal or insecure.
Also read docs/ARCHITECTURE.md for deeper context.

### Design Review
1. Does the change align with Kapsis architecture?
2. Is the code modular and easy to change?
3. Look for existing patterns that could be reused
4. Consider: Is there a more efficient solution?
5. Check: Are docs updated if needed?

### Security Review (/security-review)
6. Check for command injection (unquoted variables in Bash)
7. Check for path traversal vulnerabilities
8. Verify no secrets/credentials hardcoded
9. Check file permissions are appropriate
10. Verify input validation on user-provided data

Report format:
- Security issues (CRITICAL if found)
- Architecture alignment issues (if any)
- Design concerns (if any)
- Simpler alternatives (if found)
- Missing docs (if any)

Keep response concise. Focus on actionable items.
EOF
)

# Run the review with limited tools
log_info "Invoking Claude for review..."

# Use timeout to prevent hanging
REVIEW_OUTPUT=$(timeout 120 claude --print --allowedTools 'Glob,Grep,Read' <<< "$REVIEW_PROMPT" 2>&1 || true)

# Always display the full review output
if [[ -n "$REVIEW_OUTPUT" ]]; then
    log_info "Review completed:"
    echo "---"
    echo "$REVIEW_OUTPUT"
    echo "---"
fi

# Check for critical issues (pattern: "CRITICAL:" or "CRITICAL -" indicating actual findings)
# Avoid false positives from "No critical issues" or "Critical | 0"
HAS_CRITICAL=false
if echo "$REVIEW_OUTPUT" | grep -qiE "CRITICAL[[:space:]]*[:=-]|CRITICAL[[:space:]]+issue[s]?[[:space:]]+found"; then
    # Double-check it's not a "no critical" statement
    if ! echo "$REVIEW_OUTPUT" | grep -qi "no critical\|critical.*0\|0.*critical"; then
        HAS_CRITICAL=true
    fi
fi

if [[ "$HAS_CRITICAL" == "true" ]]; then
    log_error "Critical issues found - address before pushing"
    exit 1
fi

log_info "Review finished"
exit 0
