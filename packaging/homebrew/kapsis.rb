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
  url "https://github.com/aviadshiber/kapsis/archive/refs/tags/v2.36.2.tar.gz"
  sha256 "fed203c51bf00a32e57ac2af5e7f94f857365852f03aa69882e2f6641a64c6d9"
  version "2.36.2"
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
  depends_on "coreutils"  # provides `timeout` for push hang prevention

  # Podman is the container runtime - required but not a Homebrew dependency
  # Users must install it separately (brew install podman on macOS)

  # Per-platform kapsis-dashboard binaries.
  #
  # These resources reference release assets produced by the
  # `compile-dashboard` job in .github/workflows/release.yml. The CI
  # `Update Homebrew formula` step patches each block's url + sha256
  # after the release is created (it sha256sums the local artifact
  # uploaded by compile-dashboard, NOT the published release URL, to
  # close the TOCTOU window). The marker comments are load-bearing —
  # do not remove or change their wording.
  #
  # Placeholder sha256 = 64 zeros. `brew audit` will reject this until
  # CI patches it; that is intentional — `brew install` against an
  # un-patched formula must fail loudly rather than silently install
  # nothing.
  on_macos do
    on_arm do
      # DASHBOARD_DARWIN_ARM64_MARKER_START
      resource "kapsis-dashboard" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.36.2/kapsis-dashboard-darwin-arm64"
        sha256 "5d7a2aa8111b0c7e83155630fdee7afafc9d94c0d2c4dbfbbdf129a6365d1ab0"
      end
      # DASHBOARD_DARWIN_ARM64_MARKER_END
    end
    on_intel do
      # DASHBOARD_DARWIN_X64_MARKER_START
      resource "kapsis-dashboard" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.36.2/kapsis-dashboard-darwin-x64"
        sha256 "a0afd9b8f06dc0054f647b59482551869190ce18f62a3e29b4a9d7a1d969d9b4"
      end
      # DASHBOARD_DARWIN_X64_MARKER_END
    end
  end
  on_linux do
    on_arm do
      # DASHBOARD_LINUX_ARM64_MARKER_START
      resource "kapsis-dashboard" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.36.2/kapsis-dashboard-linux-arm64"
        sha256 "de42465c70089de4b18eac330e41737f523a6fb4d5864ccd9c63e0c6f6a1e489"
      end
      # DASHBOARD_LINUX_ARM64_MARKER_END
    end
    on_intel do
      # DASHBOARD_LINUX_X64_MARKER_START
      resource "kapsis-dashboard" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.36.2/kapsis-dashboard-linux-x64"
        sha256 "3953685807270ccdbfe959f034a978c9f4452d5dbc75cfff7fe7b49f085e4219"
      end
      # DASHBOARD_LINUX_X64_MARKER_END
    end
  end

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
      scripts/kapsis-recovery-action.sh
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
      "kapsis-recovery-action" => "scripts/kapsis-recovery-action.sh",
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

    # Install the kapsis-dashboard binary from the per-platform release
    # asset selected by the on_macos/on_linux + on_arm/on_intel resource
    # blocks above. The asset is downloaded by Homebrew (sha256-verified
    # against the formula) at install time.
    resource("kapsis-dashboard").stage do
      bin_dir = libexec/"dashboard/bin"
      bin_dir.mkpath
      # The staged file has the per-target suffix (e.g. kapsis-dashboard-darwin-arm64);
      # rename to the generic name the bin symlink expects.
      staged = Dir["kapsis-dashboard-*"].first
      odie "kapsis-dashboard resource downloaded but no binary found" unless staged
      cp staged, bin_dir/"kapsis-dashboard"
      chmod 0755, bin_dir/"kapsis-dashboard"
    end
    bin.install_symlink libexec/"dashboard/bin/kapsis-dashboard"
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

    # Verify kapsis-dashboard binary was installed and is runnable.
    assert_predicate bin/"kapsis-dashboard", :exist?,
      "kapsis-dashboard binary should be installed"
    assert_predicate bin/"kapsis-dashboard", :executable?,
      "kapsis-dashboard binary should be executable"
    # --version is the only flag that exits 0 without binding a port.
    # Pass explicit exit code 0 so any non-zero exit produces a clear
    # failure instead of an opaque pattern-match miss.
    assert_match(/\d+\.\d+\.\d+/,
      shell_output("#{bin}/kapsis-dashboard --version", 0))

    # Verify kapsis-recovery-action wrapper is installed and its --help
    # smoke check works. Catches the same packaging-skip class of bug
    # the dashboard test above is designed to catch (see #372).
    assert_predicate bin/"kapsis-recovery-action", :exist?,
      "kapsis-recovery-action wrapper should be installed"
    assert_match "Usage:",
      shell_output("#{bin}/kapsis-recovery-action --help 2>&1", 0)
  end
end
