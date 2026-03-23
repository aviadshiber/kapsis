# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [2.16.2] - 2026-03-23

### Fixed
- Tighten command inference patterns and review cleanup
- Support explicit agent.type in config YAML for LSP injection (#213)

## [Unreleased]

## [2.1.1] - 2026-02-02

### Fixed
- Correct porcelain parsing and improve review findings
- Prevent post-container commit from silently losing staged files (#211)


### Added
- Built-in agent liveness monitoring and auto-kill (#209)

### Fixed
- Address review findings in liveness monitor
- Remove unused LAUNCH_SCRIPT variable


### Fixed
- Guard VERSION write and add install layout comments
- Handle "unknown" version in compare and write VERSION on install
- Redirect display output to stderr to prevent stdout pollution


### Changed
- Bump google.golang.org/grpc


### Added
- Support LSP server configuration via kapsis config YAML


### Fixed
- Skip progress injection instead of /tmp fallback
- Fall back to /tmp when workspace is read-only


### Fixed
- Prevent test-ssh-cache-cleanup.sh from hanging
- Parse top-level audit.enabled YAML config for volume mount

### Documentation
- Add audit trail to landing page + fix config-based audit mount


### Added
- Integrate audit system into hooks and container launch
- Add post-run audit report script
- Add K8s backend integration for audit system
- Add real-time pattern detection library
- Add core audit trail library with hash-chained JSONL logging

### Changed
- Add coverage for JSON report, alerts-only, cleanup, and false positives
- Suppress shellcheck false positives in k8s test helpers
- Add comprehensive test suite and cleanup integration

### Fixed
- Correct alert field name and severity case in report
- Replace fake API token in test to avoid GitGuardian false positive
- Address code review findings for audit library

### Documentation
- Add comprehensive audit system documentation


### Changed
- Bump the github-actions group with 3 updates


### Fixed
- Address code review findings for #183
- Add stale worktree and branch cleanup for large repos (#183)


### Fixed
- Address review feedback for #168
- Ensure overlay mode status transitions to 'complete' (#168)


### Fixed
- Resolve grep -c race in check_orphan_volumes on CI
- Auto-cleanup volumes and images to prevent disk exhaustion (#191)


### Fixed
- Resolve gnome-keyring-daemon race condition in secret injection (#189)


### Fixed
- Correct protoc version and upgrade Node.js to v22 LTS


### Fixed
- Capture error output instead of swallowing it in cache-tree rebuild
- Rebuild index cache-tree after sanitized git sync (#186)


### Changed
- Bump the github-actions group with 2 updates


### Added
- Enforce NetworkPolicy per agent pod based on network mode (#182)
- Wire task, git, and security fields to pod spec (#182)
- Add podAnnotations passthrough for Vault/OpenBao integration (#182)
- Implement operator reconciliation with pod builder and status bridge (#182)
- Scaffold Go operator with kubebuilder (#182)
- Add K8s backend detection to entrypoint.sh (#182)
- K8s backend dry-run outputs AgentRequest CR YAML (#182)
- Add K8s config translator library (#182)
- Add AgentRequest CRD definition and example (#182)
- Add backend-aware guards for sandbox and post-git (#182)
- Add K8s backend stub with CR lifecycle (#182)
- Add --backend flag to launch-agent.sh (#182)
- Add backend constants and test scaffold for K8s backend (#182)

### Changed
- Upgrade Go dependencies to latest stable versions
- Add NetworkPolicy unit and integration tests (#182)
- Add pod_builder unit tests for task, git, and security wiring (#182)
- Add negative and edge case tests for config translation (#182)
- Add k8s config translation tests to category (#182)
- Add k8s test category to run-all-tests.sh (#182)
- Extract Podman backend from launch-agent.sh (#182)
- Add .worktrees/ to .gitignore

### Fixed
- Change API group from kapsis.io to kapsis.aviadshiber.github.io (#182)
- Upgrade OTel SDK to v1.40.0 (CVE-2026-24051) (#182)
- Update k8s config tests for YAML-escaped branch values (#182)
- Filter by agent container name and retry status updates on conflict (#182)
- Harden YAML escaping, wire generate_env_yaml, add kubectl failure counter (#182)
- Use omitempty for K8s API compat and only update GistUpdatedAt on change (#182)
- Set Guaranteed QoS and drop capabilities per security profile (#182)
- Prevent YAML injection in CR generator and fix bash 3.2 compat (#182)
- Add polling timeout, consolidate kubectl calls, move source to file scope (#182)

### Documentation
- Add K8s backend to landing page (#182)
- Update network isolation from Planned to Implemented (#182)
- Add feature maturity table and document network mode as planned (#182)
- Remove redundant auto-injected env vars from example CR (#182)
- Add K8s backend documentation (#182)


### Fixed
- Add compat.sh to container image (transitive dependency)
- Add missing container libs for entrypoint.sh (fixes #180)


### Fixed
- Use allowlist validation for keyring_collection and keyring_profile fields


### Added
- Add keyring_profile field for container-side D-Bus key (#176)

### Changed
- Bump the github-actions group across 1 directory with 3 updates


### Fixed
- Prepend IgnoreUnknown to SSH config for macOS-to-Linux portability (#172)


### Added
- Add keyring_collection for 99designs/keyring compatibility (#170)


### Added
- 169-auto-worktree-cleanup

### Fixed
- Security hardening for gc_stale_worktrees
- Address PR review issues for worktree auto-cleanup


### Documentation
- Update landing page and README with latest features and agent profiles


### Fixed
- Address code review feedback on staging race condition
- Prevent torn reads in bind-mount staging with host-side snapshots


### Added
- Add secret store injection for container keychain secrets (#162)

### Fixed
- Address code review feedback on secret store injection


### Fixed
- Add trap EXIT to test framework to clean up test project dirs (#157)


### Changed
- Bump github/codeql-action in the github-actions group


### Documentation
- Fix inaccuracies across user-facing documentation


### Documentation
- Update CLAUDE.md with comprehensive codebase documentation


### Added
- Support different local and remote branch names via --remote-branch

### Documentation
- Add test coverage analysis with prioritized recommendations


### Fixed
- Address PR review feedback for config whitelist filtering


### Added
- Support hook and MCP server whitelisting in container config


### Fixed
- Use set -e safe arithmetic to prevent silent container crashes


### Fixed
- Add platform detection to build-agent-image.sh for CI compatibility


### Changed
- Address PR review feedback for DNS filtering fix

### Fixed
- Check KAPSIS_RESOLV_CONF_MOUNTED before resolv.conf writability test


### Added
- Fix-shellcheck-sc2064
- Fix-homoglyph-count
- Fix-sanitize-review
- File-sanitization-spec

### Fixed
- Use staged_before in re-staging assertion


### Changed
- Bump the github-actions group with 2 updates


### Added
- Test-sdkman-offline-mode
- Sdkman-offline-mode

### Fixed
- Update secret masking test for --env-file behavior
- Add test agent config for env-file tests in CI
- Use correct SDKMAN config key sdkman_selfupdate_feature
- Resolve SC2034 shellcheck warning in test-containerfile.sh


### Added
- Add animated progress display to terminal demo
- Show log file location on failure
- Add in-place terminal progress visualization

### Changed
- Auto-prune dangling images after successful builds

### Fixed
- Update test patterns to accept quoted variable references
- Preserve exit code in EXIT trap and fix short-circuit bugs
- Show 100% progress before completion message
- Remove -i flag for non-interactive runs to prevent hang
- Address PR review issues for progress display
- Resolve CLI network mode override and output buffering
- Add set +u protection to switch-java.sh
- Show real-time container output and log it
- Handle set -u when sourcing SDKMAN/NVM in bashrc
- Show actual container errors instead of generic message
- Ensure completion message is always shown
- Use ERROR log level for cleaner progress display
- Suppress verbose logs when progress display is active

### Documentation
- Add security warning about bash -x debug mode exposing secrets
- Document progress display environment variables


### Changed
- Bump the github-actions group with 2 updates


### BREAKING CHANGES
- Refactor --no-push to positive --push flag

### Added
- Refactor --no-push to positive --push flag


### Fixed
- Add NET_BIND_SERVICE to default capabilities


### Fixed
- Use fallback chain for Java version switching


### Added
- Support Claude CLI native installer for minimal images
- Add fail-fast dependency validation for agent builds
- Add configurable container dependencies system

### Changed
- Add tests for KAPSIS_NETWORK_MODE env var passing

### Fixed
- Pass KAPSIS_NETWORK_MODE env var for all network modes


### Added
- Pre-cache protoc binaries and add Java version config

### Fixed
- Replace heredoc with echo commands in protoc cache section
- Resolve ShellCheck warnings SC2178 and SC2128
- Prevent SCRIPT_DIR namespace pollution in sourced scripts


### Fixed
- Extend secret sanitization to all log levels


### Fixed
- Sanitize secrets in debug logs


### Fixed
- Skip entrypoint in base-branch env var test
- Disable commit signing in all test repos + fix shellcheck
- Disable commit signing in test repos
- Add --base-branch parameter for proper branch creation (#116)


### Added
- Add commit verification, SSH fallback, and worktree resume (#121)

### Changed
- Bump the github-actions group with 2 updates (#120)


### Fixed
- Map schedule event to manual for differential-shellcheck (#119)


### Fixed
- Expand environment variables in config paths (#112)


### Fixed
- Scope validation agent-agnostic and mode-aware (#118)


### Fixed
- Add artifactory-build to DNS allowlist (#117)


### Changed
- Release v1.5.4


### Fixed
- Verify critical scripts during installation (#106) (#111)


### Changed
- Bump actions/checkout from 4.3.1 to 6.0.1 in the github-actions group (#108)


### Added
- Add agent gist for live activity updates

### Fixed
- Prevent CWD corruption in scope validation tests
- Improve gist feature with constant and instruction injection

### Security
- Harden gist feature with path validation and config control


### Added
- Add --dev flag for developer setup with pre-commit hooks
- Integrate security.sh library into launch-agent.sh
- Improve content architecture and reduce redundancy
- Update for GA release, remove beta branding
- Add security hardening library and profiles (WIP)

### Changed
- Update pre-commit hooks and fix deprecation warnings

### Fixed
- Help text shows correct command name for package manager installs
- Kapsis --help returns exit code 0 (Unix convention) (#102)

### Security
- Pin pre-commit hooks to immutable commit SHAs

### Documentation
- Add SEO meta tags, profile guidance, and footer clarity
- Improve security profiles terminology and interactivity
- Make security profiles interactive with hover/click
- Add security profiles spectrum visualization


### Fixed
- Help text shows correct command name for package manager installs


### Fixed
- Kapsis --help returns exit code 0 (Unix convention) (#102)


### Added
- Improve content architecture and reduce redundancy
- Update for GA release, remove beta branding


### Added
- Add pre-commit and pre-push hook system

### Fixed
- Generate descriptive CHANGELOG entries from commits
- Use output variable in spellcheck tests


### Changed
- Release v1.1.0


### Changed
- Release v1.0.0


### Changed
- Release v0.20.4


### Changed
- Release v0.20.3


### Changed
- Release v0.20.2


### Changed
- Release v0.20.1


### Changed
- Release v0.20.0


### Changed
- Release v0.19.0


### Changed
- Release v0.18.1


### Changed
- Release v0.18.0


### Changed
- Release v0.17.0


### Changed
- Release v0.16.1


### Changed
- Release v0.16.0


### Changed
- Release v0.15.0


### Changed
- Release v0.14.0


### Changed
- Release v0.13.1


### Changed
- Release v0.13.0


### Changed
- Release v0.12.1


### Changed
- Release v0.8.6


### Changed
- Release v0.8.5


### Changed
- Release v0.8.4


### Fixed
- Package manager installations now work without GitHub authentication
- Homebrew formula updated to v0.7.6 with correct SHA256
- RPM spec updated to v0.7.6
- Debian changelog updated to v0.7.6

### Added
- CI automation to update all package definitions (Homebrew, RPM, Debian) on release
- Input validation and retry logic for package updates
- Livecheck block in Homebrew formula for version tracking

## [0.7.5] - 2025-12-27

### Security
- Add checksum verification and version pinning to install script (#54)

## [0.7.4] - 2025-12-27

### Fixed
- Add copy button and fix code overflow on mobile landing page (#53)

## [0.7.3] - 2025-12-27

### Documentation
- Clarify automatic dependency installation in setup.sh (#52)

## [0.7.2] - 2025-12-27

### Documentation
- Prioritize package manager installation over script execution (#51)

## [0.7.1] - 2025-12-27

### Changed
- Implement behavior-based tests for partial coverage features (#50)

## [0.7.0] - 2025-12-27

### Added
- Package manager installation support (Homebrew, RPM, Debian) (#49)

## [0.6.0] - 2025-12-26

### Added
- `--ssh-cache` option for cleanup script to clear SSH host key cache (#48)

## [0.5.3] - 2025-12-26

### Documentation
- Add Security section to landing page with SSH and network features (#47)

## [0.5.2] - 2025-12-26

### Security
- Fix high severity vulnerabilities (Phase 2) (#45)

## [0.5.1] - 2025-12-26

### Fixed
- Correct trivy-action SHA typo in CI (#46)

## [0.5.0] - 2025-12-26

### Added
- SSH host key verification system for secure git operations (#44)

## [0.4.1] - 2025-12-25

### Changed
- Optimize CI with parallel jobs, smart filtering, and image caching (#43)

## [0.4.0] - 2025-12-25

### Added
- GitHub Pages landing page (#42)
- CI optimizations for faster builds

## [0.3.0] - 2025-12-25

### Added
- Verify push before signaling success in git workflow (#41)

## [0.2.6] - 2025-12-25

### Fixed
- Push even when agent commits itself (#39)

## [0.2.5] - 2025-12-25

### Fixed
- Support --config flag for image name resolution in preflight checks (#38)

## [0.2.4] - 2025-12-24

### Fixed
- Mount sanitized git at workspace root for native git support (#37)

## [0.2.3] - 2025-12-24

### Fixed
- Worktree permissions for rootless podman in CI (#36)

## [0.2.2] - 2025-12-24

### Fixed
- Improve test coverage and add container tests to PRs (#35)

## [0.2.1] - 2025-12-24

### Fixed
- Use SDKMAN for Maven to avoid archive.apache.org timeouts (#34)

## [0.2.0] - 2025-12-24

### Added
- Auto-generate changelog from conventional commits (#33)

## [0.1.2] - 2025-12-24

### Fixed
- Use PAT to trigger Release workflow on tag push (#32)

### Documentation
- Add concise CLAUDE.md referencing existing documentation (#31)

## [0.1.0] - 2025-12-24

### Added
- Initial release of Kapsis sandbox orchestration platform
- Multi-agent support: Claude Code, Aider, Codex, Gemini
- Podman-based container isolation with rootless execution
- Copy-on-Write filesystem isolation using overlays
- Git worktree integration for parallel branch development
- Maven isolation with snapshot blocking
- Centralized logging system with multiple log levels
- Status reporting and monitoring CLI
- Cleanup and disk reclamation utilities
- Pre-flight validation checks
- Comprehensive test suite (153 tests)

### Security
- Non-root container execution
- UID/GID namespace mapping
- Filesystem isolation from host
- Credential isolation via OS keychain integration
- No privileged container access

### Documentation
- Architecture documentation
- Configuration reference
- Git workflow guide
- Setup and installation guide
- Contributing guidelines

[Unreleased]: https://github.com/aviadshiber/kapsis/compare/v2.16.2...HEAD
[2.16.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.16.2
[2.16.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.16.1
[2.16.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.16.0
[2.15.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.15.2
[2.15.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.15.1
[2.15.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.15.0
[2.14.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.14.2
[2.14.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.14.1
[2.14.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.14.0
[2.13.6]: https://github.com/aviadshiber/kapsis/releases/tag/v2.13.6
[2.13.5]: https://github.com/aviadshiber/kapsis/releases/tag/v2.13.5
[2.13.4]: https://github.com/aviadshiber/kapsis/releases/tag/v2.13.4
[2.13.3]: https://github.com/aviadshiber/kapsis/releases/tag/v2.13.3
[2.13.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.13.2
[2.13.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.13.1
[2.12.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.12.2
[2.12.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.12.1
[2.12.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.12.0
[2.11.3]: https://github.com/aviadshiber/kapsis/releases/tag/v2.11.3
[2.11.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.11.2
[2.11.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.11.0
[2.10.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.10.1
[2.10.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.10.0
[2.9.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.9.0
[2.8.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.8.2
[2.8.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.8.1
[2.8.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.8.0
[2.7.5]: https://github.com/aviadshiber/kapsis/releases/tag/v2.7.5
[2.7.3]: https://github.com/aviadshiber/kapsis/releases/tag/v2.7.3
[2.7.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.7.2
[2.7.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.7.1
[2.7.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.7.0
[2.6.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.6.1
[2.6.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.6.0
[2.5.2]: https://github.com/aviadshiber/kapsis/releases/tag/v2.5.2
[2.5.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.5.1
[2.4.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.4.1
[2.4.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.4.0
[2.3.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.3.1
[2.2.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.2.0
[2.1.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.1.1
[2.1.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.1.0
[2.0.1]: https://github.com/aviadshiber/kapsis/releases/tag/v2.0.1
[2.0.0]: https://github.com/aviadshiber/kapsis/releases/tag/v2.0.0
[1.8.2]: https://github.com/aviadshiber/kapsis/releases/tag/v1.8.2
[1.8.1]: https://github.com/aviadshiber/kapsis/releases/tag/v1.8.1
[1.8.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.8.0
[1.7.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.7.0
[1.6.3]: https://github.com/aviadshiber/kapsis/releases/tag/v1.6.3
[1.6.2]: https://github.com/aviadshiber/kapsis/releases/tag/v1.6.2
[1.6.1]: https://github.com/aviadshiber/kapsis/releases/tag/v1.6.1
[1.6.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.6.0
[1.5.8]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.8
[1.5.7]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.7
[1.5.6]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.6
[1.5.5]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.5
[1.5.4]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.4
[1.5.3]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.3
[1.5.1]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.1
[1.5.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.5.0
[1.4.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.4.0
[1.3.2]: https://github.com/aviadshiber/kapsis/releases/tag/v1.3.2
[1.3.1]: https://github.com/aviadshiber/kapsis/releases/tag/v1.3.1
[1.3.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.3.0
[1.2.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.2.0
[1.1.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.1.0
[1.0.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.0.0
[0.20.4]: https://github.com/aviadshiber/kapsis/releases/tag/v0.20.4
[0.20.3]: https://github.com/aviadshiber/kapsis/releases/tag/v0.20.3
[0.20.2]: https://github.com/aviadshiber/kapsis/releases/tag/v0.20.2
[0.20.1]: https://github.com/aviadshiber/kapsis/releases/tag/v0.20.1
[0.20.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.20.0
[0.19.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.19.0
[0.18.1]: https://github.com/aviadshiber/kapsis/releases/tag/v0.18.1
[0.18.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.18.0
[0.17.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.17.0
[0.16.1]: https://github.com/aviadshiber/kapsis/releases/tag/v0.16.1
[0.16.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.16.0
[0.15.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.15.0
[0.14.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.14.0
[0.13.1]: https://github.com/aviadshiber/kapsis/releases/tag/v0.13.1
[0.13.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.13.0
[0.12.1]: https://github.com/aviadshiber/kapsis/releases/tag/v0.12.1
[0.8.6]: https://github.com/aviadshiber/kapsis/releases/tag/v0.8.6
[0.8.5]: https://github.com/aviadshiber/kapsis/releases/tag/v0.8.5
[0.8.4]: https://github.com/aviadshiber/kapsis/releases/tag/v0.8.4
[0.8.3]: https://github.com/aviadshiber/kapsis/compare/v0.7.6...v0.8.3
[0.7.6]: https://github.com/aviadshiber/kapsis/compare/v0.7.5...v0.7.6
[0.7.5]: https://github.com/aviadshiber/kapsis/compare/v0.7.4...v0.7.5
[0.7.4]: https://github.com/aviadshiber/kapsis/compare/v0.7.3...v0.7.4
[0.7.3]: https://github.com/aviadshiber/kapsis/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/aviadshiber/kapsis/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/aviadshiber/kapsis/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/aviadshiber/kapsis/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/aviadshiber/kapsis/compare/v0.5.3...v0.6.0
[0.5.3]: https://github.com/aviadshiber/kapsis/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/aviadshiber/kapsis/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/aviadshiber/kapsis/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/aviadshiber/kapsis/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/aviadshiber/kapsis/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/aviadshiber/kapsis/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/aviadshiber/kapsis/compare/v0.2.6...v0.3.0
[0.2.6]: https://github.com/aviadshiber/kapsis/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/aviadshiber/kapsis/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/aviadshiber/kapsis/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/aviadshiber/kapsis/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/aviadshiber/kapsis/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/aviadshiber/kapsis/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/aviadshiber/kapsis/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/aviadshiber/kapsis/compare/v0.1.0...v0.1.2
[0.1.0]: https://github.com/aviadshiber/kapsis/releases/tag/v0.1.0
