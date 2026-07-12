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
  url "https://github.com/aviadshiber/kapsis/archive/refs/tags/v2.38.1.tar.gz"
  sha256 "df856d0f7317657160c87f00100aaafe250e3ce6eb4c9ebeb992fa00c359533d"
  version "2.38.1"
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
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.38.1/kapsis-dashboard-darwin-arm64"
        sha256 "aec1fbec8f974e60ad5f327617e86df72616a7a4ba81b577f5827e8a504f93b3"
      end
      # DASHBOARD_DARWIN_ARM64_MARKER_END
    end
    on_intel do
      # DASHBOARD_DARWIN_X64_MARKER_START
      resource "kapsis-dashboard" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.38.1/kapsis-dashboard-darwin-x64"
        sha256 "b8795aecb0e649c3f50474da2e512b28022de1c07adc5f5c8c6c865b293a1839"
      end
      # DASHBOARD_DARWIN_X64_MARKER_END
    end
  end
  on_linux do
    on_arm do
      # DASHBOARD_LINUX_ARM64_MARKER_START
      resource "kapsis-dashboard" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.38.1/kapsis-dashboard-linux-arm64"
        sha256 "514302eab03544a5aaada96ee7a7beb9fa46769b8919975b5af7aa0bccf5d471"
      end
      # DASHBOARD_LINUX_ARM64_MARKER_END
    end
    on_intel do
      # DASHBOARD_LINUX_X64_MARKER_START
      resource "kapsis-dashboard" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.38.1/kapsis-dashboard-linux-x64"
        sha256 "f4864dee316dcecbc429014685969f4c2f4bb86d1d33bb3a1d63b21a52fd1252"
      end
      # DASHBOARD_LINUX_X64_MARKER_END
    end
  end

  # kapsis-ctl (issue #266) is a host-side, Podman-socket-touching internal
  # helper consumed only by scripts/lib/podman-health.sh's macOS-only
  # auto-heal path (podman-health.sh's `is_linux` early-return in
  # `maybe_autoheal_podman_vm`, plus launch-agent.sh's additional
  # `is_macos` gate on that function's only caller). There is no Linux
  # consumer today, so only darwin-arm64/darwin-x64 resources are declared
  # here — do not add on_linux blocks without a real, code-backed consumer.
  #
  # Staged into libexec/bin/kapsis-ctl (NOT bin/) deliberately: it is not a
  # supported public command, just an implementation detail that
  # podman-health.sh discovers via its existing relative-path lookup
  # (`${_self_dir}/../../bin/kapsis-ctl`, which resolves to
  # libexec/bin/kapsis-ctl since `install` below sets KAPSIS_LIB to
  # libexec/scripts/lib for every wrapper). Do not add a bin.install_symlink
  # for it.
  on_macos do
    on_arm do
      # KAPSIS_CTL_DARWIN_ARM64_MARKER_START
      resource "kapsis-ctl" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.38.1/kapsis-ctl-darwin-arm64"
        sha256 "d637687d2608ee7c7451af2132cb2ebf51a96a2a1f13ecad36d8b92d6ed2fed8"
      end
      # KAPSIS_CTL_DARWIN_ARM64_MARKER_END
    end
    on_intel do
      # KAPSIS_CTL_DARWIN_X64_MARKER_START
      resource "kapsis-ctl" do
        url "https://github.com/aviadshiber/kapsis/releases/download/v2.38.1/kapsis-ctl-darwin-x64"
        sha256 "5a17c5f69ab1f8366422dababc2358eefb541f54a9ad511e6b9e8e74f4cd98c9"
      end
      # KAPSIS_CTL_DARWIN_X64_MARKER_END
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

    # Install the kapsis-ctl binary from the per-platform release asset
    # selected by the on_macos + on_arm/on_intel resource blocks above.
    # Staged into libexec/bin/kapsis-ctl (NOT bin/) — it is an internal
    # helper for podman-health.sh's macOS-only auto-heal path, not a
    # supported public command. Intentionally no bin.install_symlink.
    # No Linux resource is declared (no consumer there), so this only
    # runs on macOS.
    if OS.mac?
      resource("kapsis-ctl").stage do
        ctl_bin_dir = libexec/"bin"
        ctl_bin_dir.mkpath
        staged = Dir["kapsis-ctl-*"].first
        odie "kapsis-ctl resource downloaded but no binary found" unless staged
        cp staged, ctl_bin_dir/"kapsis-ctl"
        chmod 0755, ctl_bin_dir/"kapsis-ctl"
      end
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

    # Verify kapsis-ctl was staged into libexec/bin (macOS only — no Linux
    # resource is declared, see the on_macos block above), is NOT exposed
    # as a public bin/ symlink, and its --version smoke check works.
    if OS.mac?
      assert_predicate libexec/"bin/kapsis-ctl", :exist?,
        "kapsis-ctl binary should be staged into libexec/bin"
      assert_predicate libexec/"bin/kapsis-ctl", :executable?,
        "kapsis-ctl binary should be executable"
      refute_predicate bin/"kapsis-ctl", :exist?,
        "kapsis-ctl must not be exposed as a public bin/ command"
      assert_match(/\d+\.\d+\.\d+|dev/,
        shell_output("#{libexec}/bin/kapsis-ctl --version", 0))
    end
  end
end
