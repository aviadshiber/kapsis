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

### Fixed
- ShellCheck warnings in all shell scripts
- Podman machine checks now only run on macOS (Linux runs natively)
- Dry-run mode properly skips container and pre-flight checks
- yq raw output mode for proper YAML parsing

### Changed
- Container tests and security scans only run on merge to main (not on PRs)
- CI Success job properly gates all required checks

## [1.0.0] - 2024-XX-XX

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

[Unreleased]: https://github.com/aviadshiber/kapsis/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/aviadshiber/kapsis/releases/tag/v1.0.0
