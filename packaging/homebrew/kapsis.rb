# typed: false
# frozen_string_literal: true

# Homebrew formula for Kapsis - AI Agent Sandbox
# For use in a custom tap: homebrew-kapsis
class Kapsis < Formula
  desc "Hermetically isolated AI agent sandbox for running AI coding agents in parallel"
  homepage "https://github.com/aviadshiber/kapsis"
  license "MIT"
  head "https://github.com/aviadshiber/kapsis.git", branch: "main"

  # Stable release - automatically updated by CI on each release
  # RELEASE_VERSION_MARKER_START - Do not remove, used by CI
  url "https://github.com/aviadshiber/kapsis/archive/refs/tags/v1.5.8.tar.gz"
  sha256 "6bf29717bc9872f6f62566f72507f4885d601961acfa44e5b4e8bd86060bfe05"
  version "1.5.8"
  # RELEASE_VERSION_MARKER_END

  # Homebrew livecheck - detects new releases automatically
  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on "bash"
  depends_on "git"
  depends_on "jq"
  depends_on "yq"

  # Podman is the container runtime - required but not a Homebrew dependency
  # Users must install it separately (brew install podman on macOS)

  def install
    # Install everything to libexec, then create wrappers
    libexec.install Dir["*"]

    # Verify critical scripts are installed (fixes #106)
    critical_scripts = %w[
      scripts/launch-agent.sh
      scripts/build-image.sh
      scripts/post-container-git.sh
      scripts/entrypoint.sh
      scripts/worktree-manager.sh
      scripts/kapsis-cleanup.sh
      scripts/kapsis-status.sh
      scripts/lib/logging.sh
      scripts/lib/status.sh
      scripts/lib/constants.sh
    ]
    critical_scripts.each do |script|
      odie "Missing critical script: #{script}" unless (libexec/script).exist?
    end

    # Create wrapper scripts for main commands
    {
      "kapsis" => "scripts/launch-agent.sh",
      "kapsis-build" => "scripts/build-image.sh",
      "kapsis-cleanup" => "scripts/kapsis-cleanup.sh",
      "kapsis-status" => "scripts/kapsis-status.sh",
      "kapsis-setup" => "setup.sh",
      "kapsis-quick" => "quick-start.sh",
    }.each do |cmd, script|
      (bin/cmd).write <<~EOS
        #!/usr/bin/env bash
        set -euo pipefail
        export KAPSIS_HOME="#{libexec}"
        export KAPSIS_LIB="#{libexec}/scripts/lib"
        export KAPSIS_SCRIPTS="#{libexec}/scripts"
        export KAPSIS_CMD_NAME="#{cmd}"
        exec "#{libexec}/#{script}" "$@"
      EOS
    end
  end

  def caveats
    <<~EOS
      Kapsis requires Podman for container isolation.

      To install Podman on macOS:
        brew install podman
        podman machine init
        podman machine start

      To install Podman on Linux:
        # Debian/Ubuntu
        sudo apt install podman

        # Fedora
        sudo dnf install podman

      After installing Podman, run setup:
        kapsis-setup --all

      Quick start:
        kapsis 1 /path/to/project --agent claude --task "Your task"

      Documentation: https://github.com/aviadshiber/kapsis
    EOS
  end

  test do
    # Test that kapsis command works (--help returns exit code 0 per Unix convention)
    assert_match "Usage:", shell_output("#{bin}/kapsis --help 2>&1", 0)

    # Verify sample of critical scripts exist and are executable (fixes #106)
    # Tests representative scripts: main entry point, post-container handler, and library
    %w[
      scripts/launch-agent.sh
      scripts/post-container-git.sh
      scripts/lib/logging.sh
    ].each do |script|
      assert_predicate libexec/script, :exist?,
        "#{script} should be installed"
      assert_predicate libexec/script, :executable?,
        "#{script} should be executable"
    end
  end
end
