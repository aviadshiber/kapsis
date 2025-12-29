#!/usr/bin/env python3
"""
Kapsis Status Library for Python Agents

Provides a Python interface for updating Kapsis status from custom Python agents
(like claude-api agents that use the Anthropic Python SDK directly).

Usage:
    from kapsis_status import KapsisStatus

    status = KapsisStatus()
    status.update("exploring", 30, "Analyzing codebase structure")
    status.update("implementing", 50, "Writing authentication module")
    status.update("testing", 75, "Running unit tests")
    status.complete("All tasks completed successfully")

Environment Variables (set by Kapsis container):
    KAPSIS_STATUS_PROJECT  - Project name
    KAPSIS_STATUS_AGENT_ID - Agent ID
    KAPSIS_STATUS_BRANCH   - Git branch (optional)
    KAPSIS_SANDBOX_MODE    - Sandbox mode (worktree/overlay)
"""

import json
import os
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

# Phase names for semantic status tracking
PHASES = ["exploring", "implementing", "building", "testing", "committing", "completing"]

# Default status directory inside container
DEFAULT_STATUS_DIR = "/kapsis-status"


class KapsisStatus:
    """
    Kapsis status reporter for Python agents.

    Writes status updates to the shared status directory that the host can read.
    """

    def __init__(
        self,
        project: Optional[str] = None,
        agent_id: Optional[str] = None,
        branch: Optional[str] = None,
        sandbox_mode: Optional[str] = None,
        status_dir: Optional[str] = None,
    ):
        """
        Initialize the status reporter.

        Args:
            project: Project name (defaults to KAPSIS_STATUS_PROJECT env var)
            agent_id: Agent ID (defaults to KAPSIS_STATUS_AGENT_ID env var)
            branch: Git branch (defaults to KAPSIS_STATUS_BRANCH env var)
            sandbox_mode: Sandbox mode (defaults to KAPSIS_SANDBOX_MODE env var)
            status_dir: Status directory (defaults to /kapsis-status)
        """
        self.project = project or os.environ.get("KAPSIS_STATUS_PROJECT", "unknown")
        self.agent_id = agent_id or os.environ.get("KAPSIS_STATUS_AGENT_ID", "0")
        self.branch = branch or os.environ.get("KAPSIS_STATUS_BRANCH", "")
        self.sandbox_mode = sandbox_mode or os.environ.get("KAPSIS_SANDBOX_MODE", "overlay")
        self.status_dir = Path(status_dir or os.environ.get("KAPSIS_STATUS_DIR", DEFAULT_STATUS_DIR))

        # Status file path
        self.status_file = self.status_dir / f"kapsis-{self.project}-{self.agent_id}.json"

        # State file for tracking
        self.state_file = self.status_dir / f".state-{self.project}-{self.agent_id}"

        # Track tool usage for progress estimation
        self.tool_counts = {
            "explore": 0,
            "implement": 0,
            "build": 0,
            "test": 0,
            "commit": 0,
        }

        # Initialize status
        self._initialized = False

    def _ensure_initialized(self) -> None:
        """Ensure status directory exists and is writable."""
        if self._initialized:
            return

        try:
            self.status_dir.mkdir(parents=True, exist_ok=True)
            self._initialized = True
        except (OSError, PermissionError) as e:
            print(f"Warning: Cannot create status directory {self.status_dir}: {e}")

    def _write_status(
        self,
        phase: str,
        progress: int,
        message: str,
        exit_code: Optional[int] = None,
    ) -> bool:
        """
        Write status to the status file.

        Args:
            phase: Current phase name
            progress: Progress percentage (0-100)
            message: Status message
            exit_code: Exit code (only for completed status)

        Returns:
            True if write succeeded, False otherwise
        """
        self._ensure_initialized()

        status_data = {
            "phase": phase,
            "progress": max(0, min(100, progress)),
            "message": message,
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "project": self.project,
            "agent_id": self.agent_id,
            "branch": self.branch,
            "sandbox_mode": self.sandbox_mode,
        }

        if exit_code is not None:
            status_data["exit_code"] = exit_code

        try:
            # Write atomically using temp file
            temp_file = self.status_file.with_suffix(".tmp")
            temp_file.write_text(json.dumps(status_data, indent=2) + "\n")
            temp_file.rename(self.status_file)
            return True
        except (OSError, PermissionError) as e:
            print(f"Warning: Cannot write status file: {e}")
            return False

    def update(self, phase: str, progress: int, message: str) -> bool:
        """
        Update status with current phase and progress.

        Args:
            phase: Current phase (exploring, implementing, building, testing, committing)
            progress: Progress percentage (25-90 for running phase)
            message: Description of current activity

        Returns:
            True if update succeeded
        """
        # Validate phase
        if phase not in PHASES:
            print(f"Warning: Unknown phase '{phase}', using 'implementing'")
            phase = "implementing"

        # Clamp progress to running range (25-90)
        progress = max(25, min(90, progress))

        return self._write_status(phase, progress, message)

    def record_tool(self, tool_name: str, command: str = "", file_path: str = "") -> None:
        """
        Record a tool usage for progress tracking.

        Args:
            tool_name: Name of the tool (Read, Write, Edit, Bash, etc.)
            command: Command string (for Bash tools)
            file_path: File path (for file tools)
        """
        # Map tool to category
        category = self._map_tool_to_category(tool_name, command)
        if category in self.tool_counts:
            self.tool_counts[category] += 1

    def _map_tool_to_category(self, tool_name: str, command: str = "") -> str:
        """Map tool name to progress category."""
        tool_lower = tool_name.lower()

        # Exploring tools
        if tool_lower in ["read", "grep", "glob", "search", "find"]:
            return "explore"

        # Implementation tools
        if tool_lower in ["write", "edit", "notebookedit"]:
            return "implement"

        # Bash commands need further analysis
        if tool_lower == "bash":
            cmd_lower = command.lower()

            # Build commands
            if any(b in cmd_lower for b in ["mvn", "maven", "gradle", "npm", "yarn", "cargo", "make", "go build"]):
                return "build"

            # Test commands
            if any(t in cmd_lower for t in ["test", "pytest", "jest", "mocha", "rspec", "cargo test"]):
                return "test"

            # Git commit
            if "git commit" in cmd_lower:
                return "commit"

            return "implement"

        return "implement"

    def calculate_progress(self) -> int:
        """
        Calculate current progress based on tool usage.

        Returns:
            Progress percentage (25-90)
        """
        total = sum(self.tool_counts.values())
        if total == 0:
            return 25

        # Weight by category (later categories = more progress)
        weights = {
            "explore": 0.15,
            "implement": 0.35,
            "build": 0.20,
            "test": 0.20,
            "commit": 0.10,
        }

        # Calculate weighted progress
        weighted_sum = 0
        weighted_total = 0

        for category, count in self.tool_counts.items():
            if count > 0:
                weight = weights.get(category, 0.1)
                # Diminishing returns for repeated tools
                effective_count = min(count, 10)
                weighted_sum += weight * (effective_count / 10)
                weighted_total += weight

        if weighted_total == 0:
            return 25

        # Scale to 25-90 range
        raw_progress = weighted_sum / weighted_total
        return int(25 + (raw_progress * 65))

    def auto_update(self, tool_name: str, command: str = "", file_path: str = "") -> bool:
        """
        Automatically update status based on tool usage.

        This is the recommended method for tracking progress.

        Args:
            tool_name: Name of the tool being used
            command: Command string (for Bash tools)
            file_path: File path (for file tools)

        Returns:
            True if update succeeded
        """
        self.record_tool(tool_name, command, file_path)

        # Determine current phase
        phase = self._determine_phase()

        # Calculate progress
        progress = self.calculate_progress()

        # Generate message
        if file_path:
            message = f"Working on {Path(file_path).name}"
        elif command:
            cmd_preview = command[:50] + "..." if len(command) > 50 else command
            message = f"Running: {cmd_preview}"
        else:
            message = f"Using {tool_name}"

        return self.update(phase, progress, message)

    def _determine_phase(self) -> str:
        """Determine current phase based on tool usage patterns."""
        if self.tool_counts["commit"] > 0:
            return "committing"
        if self.tool_counts["test"] > 0:
            return "testing"
        if self.tool_counts["build"] > 0:
            return "building"
        if self.tool_counts["implement"] > 0:
            return "implementing"
        return "exploring"

    def complete(self, message: str = "Task completed", exit_code: int = 0) -> bool:
        """
        Mark the task as completed.

        Args:
            message: Completion message
            exit_code: Exit code (0 for success)

        Returns:
            True if update succeeded
        """
        progress = 95 if exit_code == 0 else 50
        return self._write_status("completing", progress, message, exit_code)

    def fail(self, message: str = "Task failed", exit_code: int = 1) -> bool:
        """
        Mark the task as failed.

        Args:
            message: Failure message
            exit_code: Exit code (non-zero)

        Returns:
            True if update succeeded
        """
        return self._write_status("completing", 50, message, exit_code or 1)


# Singleton instance for convenience
_default_status: Optional[KapsisStatus] = None


def get_status() -> KapsisStatus:
    """Get the default status instance."""
    global _default_status
    if _default_status is None:
        _default_status = KapsisStatus()
    return _default_status


# Convenience functions
def update(phase: str, progress: int, message: str) -> bool:
    """Update status using default instance."""
    return get_status().update(phase, progress, message)


def auto_update(tool_name: str, command: str = "", file_path: str = "") -> bool:
    """Auto-update status based on tool usage."""
    return get_status().auto_update(tool_name, command, file_path)


def complete(message: str = "Task completed", exit_code: int = 0) -> bool:
    """Mark task as completed."""
    return get_status().complete(message, exit_code)


def fail(message: str = "Task failed", exit_code: int = 1) -> bool:
    """Mark task as failed."""
    return get_status().fail(message, exit_code)


if __name__ == "__main__":
    # Quick test
    status = KapsisStatus()
    status.update("exploring", 30, "Testing Python status library")
    print(f"Status written to: {status.status_file}")
