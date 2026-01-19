# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [1.6.0] - 2026-01-19

### Added
- Add commit verification, SSH fallback, and worktree resume (#121)

### Changed
- Bump the github-actions group with 2 updates (#120)

## [Unreleased]

## [0.8.3] - 2025-12-28

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

[Unreleased]: https://github.com/aviadshiber/kapsis/compare/v1.6.0...HEAD
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
