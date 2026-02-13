#!/usr/bin/env bash
#===============================================================================
# Kapsis Quick Start - Launch Claude Code Agent
#
# This script simplifies launching Claude Code agents with your config.
# Agent IDs are automatically generated (6-character UUID).
#
# Usage:
#   ./quick-start.sh <agent-id> <project> <branch> [spec-file]
#
# Examples:
#   ./quick-start.sh 1 products feature/DEV-123
#   ./quick-start.sh 1 products feature/DEV-123 my-task.md
#   ./quick-start.sh 1 daredevil-ui feature/DEV-456 configs/specs/feature.md
#
# For parallel agents on same project:
#   ./quick-start.sh 1 products feature/DEV-123-auth &
#   ./quick-start.sh 2 products feature/DEV-123-api &
#   ./quick-start.sh 3 products feature/DEV-123-tests &
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging library
source "$SCRIPT_DIR/scripts/lib/logging.sh"
log_init "quick-start"

# Colors for user prompts (logging uses its own colors)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    local cmd_name="${KAPSIS_CMD_NAME:-$0}"
    echo ""
    echo "Usage: $cmd_name <agent-id> <project> <branch> [spec-file]"
    echo ""
    echo "Arguments:"
    echo "  agent-id   Unique identifier (1, 2, 3, etc.)"
    echo "  project    Project name or path (my-app, ~/git/myrepo, /full/path)"
    echo "  branch     Git branch name (feature/ABC-123)"
    echo "  spec-file  Optional: Task specification file (default: prompt)"
    echo ""
    echo "Examples:"
    echo "  $cmd_name 1 my-project feature/ABC-123"
    echo "  $cmd_name 1 ~/git/my-project feature/ABC-123 task.md"
    echo "  $cmd_name 2 /path/to/repo feature/DEV-456"
    echo ""
    echo "Project resolution:"
    echo "  my-app     -> ~/git/my-app (simple names resolve to ~/git/)"
    echo "  ~/project  -> ~/project (tilde expansion)"
    echo "  /abs/path  -> /abs/path (absolute paths)"
    echo ""
    exit 1
}

# Check args
if [[ $# -lt 3 ]]; then
    usage
fi

AGENT_ID="$1"
PROJECT="$2"
BRANCH="$3"
SPEC_FILE="${4:-}"

log_debug "Arguments parsed:"
log_debug "  AGENT_ID=$AGENT_ID"
log_debug "  PROJECT=$PROJECT"
log_debug "  BRANCH=$BRANCH"
log_debug "  SPEC_FILE=$SPEC_FILE"

# Project shortcuts - customize these for your organization
# Any name not matching a shortcut is treated as a path under ~/git/
case "$PROJECT" in
    # Add your own shortcuts here:
    # my-monorepo)
    #     PROJECT_PATH="$HOME/git/my-monorepo"
    #     ;;
    # frontend)
    #     PROJECT_PATH="$HOME/git/frontend-app"
    #     ;;
    *)
        # Treat as path or ~/git/<name>
        if [[ "$PROJECT" == ~* ]]; then
            PROJECT_PATH="${PROJECT/#\~/$HOME}"
        elif [[ "$PROJECT" == /* ]]; then
            PROJECT_PATH="$PROJECT"
        else
            PROJECT_PATH="$HOME/git/$PROJECT"
        fi
        ;;
esac

# Validate project path
if [[ ! -d "$PROJECT_PATH" ]]; then
    echo -e "${YELLOW}Warning: Project path does not exist: $PROJECT_PATH${NC}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Handle spec file
if [[ -z "$SPEC_FILE" ]]; then
    echo ""
    echo -e "${CYAN}No spec file provided. Creating temporary task spec...${NC}"
    echo ""
    SPEC_FILE=$(mktemp /tmp/kapsis-spec-XXXXXX.md)

    cat > "$SPEC_FILE" << 'EOF'
# Task Specification

## Objective
[Describe what you want to accomplish]

## Requirements
- Requirement 1
- Requirement 2

## Context
- Branch: {branch}
- Project: {project}

## Notes
- Run tests before committing
- Follow project coding conventions
EOF

    echo -e "${YELLOW}Opening spec file in editor...${NC}"
    echo -e "${YELLOW}Save and close the editor when done.${NC}"
    echo ""

    # Use default editor or vim
    ${EDITOR:-vim} "$SPEC_FILE"

    echo ""
    echo -e "${GREEN}Spec file ready: $SPEC_FILE${NC}"
fi

# Validate spec file
if [[ ! -f "$SPEC_FILE" ]]; then
    echo "Error: Spec file not found: $SPEC_FILE"
    exit 1
fi

# Summary
echo ""
echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ LAUNCHING KAPSIS AGENT                                             │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""
echo -e "  Agent ID:   ${GREEN}$AGENT_ID${NC}"
echo -e "  Project:    ${GREEN}$PROJECT_PATH${NC}"
echo -e "  Branch:     ${GREEN}$BRANCH${NC}"
echo -e "  Spec File:  ${GREEN}$SPEC_FILE${NC}"
echo -e "  Config:     ${GREEN}$SCRIPT_DIR/configs/aviad-claude.yaml${NC}"
echo ""

# Confirm
read -p "Launch agent? (Y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Launch
echo ""
log_info "Starting agent..."
log_debug "Launching: $SCRIPT_DIR/scripts/launch-agent.sh $AGENT_ID $PROJECT_PATH --config $SCRIPT_DIR/configs/aviad-claude.yaml --branch $BRANCH --spec $SPEC_FILE"
echo ""

exec "$SCRIPT_DIR/scripts/launch-agent.sh" "$AGENT_ID" "$PROJECT_PATH" \
    --config "$SCRIPT_DIR/configs/aviad-claude.yaml" \
    --branch "$BRANCH" \
    --spec "$SPEC_FILE"
