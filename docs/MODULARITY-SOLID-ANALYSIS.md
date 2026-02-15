# Modularity & SOLID Analysis

Status tracking for the SOLID refactoring of Kapsis shell scripts.

## Extracted Libraries

| Library | Source | Functions | Status |
|---------|--------|-----------|--------|
| `scripts/lib/config-resolver.sh` | `launch-agent.sh`, `build-image.sh`, `build-agent-image.sh` | `resolve_agent_config()`, `resolve_build_config_file()` | Done |
| `scripts/lib/git-operations.sh` | `entrypoint.sh`, `post-container-git.sh`, `post-exit-git.sh` | `has_git_changes()`, `has_unpushed_commits()`, `git_push_refspec()`, `verify_git_push()` | Done |
| `scripts/lib/env-builder.sh` | `launch-agent.sh` | `generate_env_vars()` + 9 helpers | Done |
| `scripts/lib/volume-mounts.sh` | `launch-agent.sh` | `generate_volume_mounts()` + dispatch table, snapshots | Done |

## launch-agent.sh Refactoring

### Functions Split

| Original | Lines | Split Into | Status |
|----------|-------|-----------|--------|
| `resolve_config()` | ~60 | Delegates to `config-resolver.sh` | Done |
| `parse_config()` | ~154 | `_parse_core_config`, `_parse_git_config`, `_parse_env_and_fs_config`, `_parse_network_config`, `_parse_security_config` | Done |
| `generate_env_vars()` | ~200 | Extracted to `env-builder.sh` | Done |
| Volume mount functions | ~200 | Extracted to `volume-mounts.sh` | Done |
| `build_container_command()` | ~151 | `_build_tty_and_security_args`, `_build_network_args`, `_build_filtered_network_args`, `_build_dns_pinning_args`, `_build_mounts_env_and_image` | Done |
| `main()` | ~305 | `phase_init`, `phase_parse_and_validate`, `phase_prepare_container`, `phase_dry_run_exit`, `phase_run_container`, `phase_post_container`, `phase_finalize` | Done |

### Design Patterns Applied

- **Dispatch tables** for sandbox mode (`SANDBOX_HANDLERS`), volume mounts (`VOLUME_MOUNT_HANDLERS`), network modes
- **Phase-based orchestration**: `main()` is a thin orchestrator calling phase functions
- **Guard-against-multiple-sourcing**: All libraries use `_KAPSIS_*_LOADED` guard pattern
- **Nameref output parameters**: `config-resolver.sh` uses `local -n` for output variables

## Consumer Integration

| Script | Library Used | Integration | Status |
|--------|-------------|-------------|--------|
| `entrypoint.sh` | `git-operations.sh` | `post_exit_git()` split into `_post_exit_commit`, `_post_exit_push`, `_post_exit_show_pr`, `_post_exit_no_push` | Done |
| `post-container-git.sh` | `git-operations.sh` | `has_changes()` delegates to `has_git_changes()`, `verify_push()` delegates to `verify_git_push()`, `push_changes()` uses `git_push_refspec()` | Done |
| `post-exit-git.sh` | `git-operations.sh` | Change detection uses `has_git_changes()`, push uses `git_push_refspec()` | Done |
| `build-image.sh` | `config-resolver.sh` | `resolve_config_file()` delegates to `resolve_build_config_file()` | Done |
| `build-agent-image.sh` | `config-resolver.sh` | Build config resolution delegates to `resolve_build_config_file()` | Done |

## Test Coverage

| Test File | Library | Tests | Status |
|-----------|---------|-------|--------|
| `test-git-operations.sh` | `git-operations.sh` | 13 | Pass |
| `test-config-resolver.sh` | `config-resolver.sh` | 11 | Pass |
| `test-env-builder.sh` | `env-builder.sh` | 10 | Pass |
| `test-volume-mounts.sh` | `volume-mounts.sh` | 14 | Pass |

All tests added to `run-all-tests.sh` under `libs` category and `QUICK_TESTS`.

## Remaining Opportunities

- `entrypoint.sh` still large (~1280 lines) — could extract DNS filtering, status tracking, staged config overlay into separate libraries
- `post-container-git.sh` could have `validate_staged_files()` extracted to a validation library
- Security hardening in `launch-agent.sh` (`_build_tty_and_security_args`) could move to `security.sh`
