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
  url "https://github.com/aviadshiber/kapsis/archive/refs/tags/v0.8.14.tar.gz"
  sha256 "73b9169985177b26a2ba3a2b84c10447a050e8166c14998f8f43ff95e75c7157"
  version "0.8.14"
  # RELEASE_VERSION_MARKER_END

  # Homebrew livecheck - detects new releases automatically
  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on "bash" => "3.2"
  depends_on "git" => "2.0"
  depends_on "jq"
  depends_on "yq"

  # Podman is the container runtime - required but not a Homebrew dependency
  # Users must install it separately (brew install podman on macOS)

  def install
    # Install main scripts
    bin.install "scripts/launch-agent.sh" => "kapsis"
    bin.install "scripts/build-image.sh" => "kapsis-build"
    bin.install "scripts/kapsis-cleanup.sh" => "kapsis-cleanup"
    bin.install "scripts/kapsis-status.sh" => "kapsis-status"
    bin.install "setup.sh" => "kapsis-setup"
    bin.install "quick-start.sh" => "kapsis-quick"

    # Install library files
    (libexec/"lib").install Dir["scripts/lib/*.sh"]

    # Install configuration templates
    (share/"kapsis/configs").install Dir["configs/**/*"]
    (share/"kapsis").install "agent-sandbox.yaml.template"
    (share/"kapsis").install "Containerfile"
    (share/"kapsis/maven").install "maven/isolated-settings.xml"

    # Install additional scripts needed by main scripts
    (libexec/"scripts").install "scripts/entrypoint.sh"
    (libexec/"scripts").install "scripts/worktree-manager.sh"
    (libexec/"scripts").install "scripts/post-container-git.sh"
    (libexec/"scripts").install "scripts/post-exit-git.sh"
    (libexec/"scripts").install "scripts/preflight-check.sh"
    (libexec/"scripts").install "scripts/init-git-branch.sh"
    (libexec/"scripts").install "scripts/merge-changes.sh"
    (libexec/"scripts").install "scripts/switch-java.sh"
    (libexec/"scripts").install "scripts/build-agent-image.sh"

    # Create wrapper scripts that set up the environment
    (bin/"kapsis").write_env_script libexec/"kapsis-wrapper.sh",
      KAPSIS_HOME: share/"kapsis",
      KAPSIS_LIB: libexec/"lib",
      KAPSIS_SCRIPTS: libexec/"scripts"

    # Install the wrapper script
    (libexec/"kapsis-wrapper.sh").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      export KAPSIS_HOME="${KAPSIS_HOME:-#{share}/kapsis}"
      export KAPSIS_LIB="${KAPSIS_LIB:-#{libexec}/lib}"
      export KAPSIS_SCRIPTS="${KAPSIS_SCRIPTS:-#{libexec}/scripts}"
      exec "#{libexec}/scripts/launch-agent.sh" "$@"
    EOS

    # Move launch-agent.sh to libexec and install wrapper
    mv bin/"kapsis", libexec/"scripts/launch-agent.sh"

    (bin/"kapsis").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      export KAPSIS_HOME="#{share}/kapsis"
      export KAPSIS_LIB="#{libexec}/lib"
      export KAPSIS_SCRIPTS="#{libexec}/scripts"
      exec "#{libexec}/scripts/launch-agent.sh" "$@"
    EOS

    # Fix remaining binaries to use correct paths
    %w[kapsis-build kapsis-cleanup kapsis-status kapsis-setup kapsis-quick].each do |cmd|
      inreplace bin/cmd, /^(SCRIPT_DIR=).*$/, "\\1\"#{libexec}/scripts\""
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
    # Test that kapsis command works
    assert_match "Usage:", shell_output("#{bin}/kapsis --help 2>&1", 1)

    # Test that setup script validates correctly
    assert_match "Kapsis", shell_output("#{bin}/kapsis-setup --check 2>&1", 1)
  end
end
