# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- GitHub Actions CI/CD pipeline with ShellCheck and tests
- Branch protection setup script
- Security policy (SECURITY.md)
- Dependabot configuration for automated updates
- CodeQL security scanning
- Container vulnerability scanning with Trivy
- Issue and PR templates
- Pre-commit hooks configuration

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
