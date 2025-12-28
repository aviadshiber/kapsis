# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- CLAUDE.md guidelines for AI assistant onboarding
- GitHub Actions CI/CD pipeline with ShellCheck and tests
- Branch protection setup script for enforcing PR-only merges
- Security policy (SECURITY.md)
- Dependabot configuration for automated updates
- Container vulnerability scanning with Trivy
- Secret detection with TruffleHog
- Issue and PR templates
- Pre-commit hooks configuration
- CODEOWNERS file for automatic review requests
- Automatic CHANGELOG.md updates on release

### Fixed
- ShellCheck warnings in all shell scripts
- Podman machine checks now only run on macOS (Linux runs natively)
- Dry-run mode properly skips container and pre-flight checks
- yq raw output mode for proper YAML parsing

### Changed
- Container tests and security scans only run on merge to main (not on PRs)
- CI Success job properly gates all required checks

## [0.7.8] - 2025-12-28

### Fixed
- Use RELEASE_TOKEN for package updates to bypass branch protection (#57)

## [0.7.7] - 2025-12-28

### Fixed
- Update all packages to v0.7.6 with hardened CI automation (#56)

## [0.7.6] - 2025-12-28

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

[Unreleased]: https://github.com/aviadshiber/kapsis/compare/v0.7.8...HEAD
[0.7.8]: https://github.com/aviadshiber/kapsis/compare/v0.7.7...v0.7.8
[0.7.7]: https://github.com/aviadshiber/kapsis/compare/v0.7.6...v0.7.7
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
