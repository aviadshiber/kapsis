# Testing Guide

This guide describes the three-tier test convention used in Kapsis and explains
when to write which kind of test.

## Three-Tier Test Convention

Kapsis tests are organised into three tiers based on what they exercise and how
fast they run:

| Tier | Filename prefix | Container required | Speed | Catches |
|------|-----------------|--------------------|-------|---------|
| **Unit** | `test-<subsystem>.sh` | No | ~1 s | Logic bugs in a single script or function |
| **Host** | `test-host-<subsystem>.sh` | No | ~2-10 s | Multi-component interactions sourced from the host source tree |
| **Container** | `test-container-<subsystem>.sh` | Yes (auto-skip) | ~10-60 s | Packaging regressions — missing COPY lines, wrong permissions, wrong paths |

### When to write each tier

**Unit tests** (`test-<subsystem>.sh`)
- Single script or library function in isolation
- No external state (container, network, git repo)
- Examples: `test-logging.sh`, `test-compat.sh`, `test-json-utils.sh`

**Host tests** (`test-host-<subsystem>.sh`)
- Multiple inject scripts running in sequence on the host
- Fast feedback during development — no Podman needed
- Source scripts directly from `$KAPSIS_ROOT/scripts/lib/`
- Examples: `test-host-inject-gist-hook.sh`, `test-host-inject-all-hooks.sh`
- Do NOT cover: whether the script was COPY'd into the image correctly

**Container tests** (`test-container-<subsystem>.sh`)
- Run inject scripts **from inside** `$KAPSIS_TEST_IMAGE` (the real built image)
- Assert on runtime state (file presence at `/opt/kapsis/lib/`, settings.json
  contents produced by the packaged binary, not the host copy)
- Auto-skip via `skip_if_no_overlay_rw` when Podman is unavailable
- Examples: `test-container-libs.sh`, `test-container-plugin-hooks.sh`,
  `test-container-status-hooks.sh`, `test-container-gist-hook.sh`,
  `test-container-all-hooks.sh`
- Catch: a new `scripts/lib/*.sh` sourced by `entrypoint.sh` but missing a
  `COPY` line in `Containerfile` — the silent-skip bug class that went undetected
  for 6 days (PR #380)

## Coverage map

| Functionality | Host (fast) | Container (packaging) |
|---------------|-------------|-----------------------|
| Status hook injection | `test-host-inject-gist-hook.sh` | `test-container-status-hooks.sh` |
| Gist hook dispatch | `test-host-inject-gist-hook.sh` | `test-container-gist-hook.sh` |
| LSP + plugin combined | `test-host-inject-all-hooks.sh` | `test-container-all-hooks.sh` |
| Plugin hook injection | `test-plugin-hook-injection.sh` | `test-container-plugin-hooks.sh` |
| Core libs (logging, status) | — | `test-container-libs.sh` |
| Claude CLI dispatch (mock API) | `test-host-claude-mock-api.sh` | — (requires Claude CLI in image) |
| Claude CLI dispatch (live API) | `test-host-claude-live-api.sh` | — (requires real credentials) |

## Running tests

```bash
# Quick tests (no container) — runs in ~10 s
./tests/run-all-tests.sh --quick

# All container tests (requires Podman + built image)
./tests/run-all-tests.sh --category security

# Status tests only (host-tier)
./tests/run-all-tests.sh --category status

# Single test file
./tests/test-container-all-hooks.sh
```

## Writing a new container test

Use `tests/test-container-plugin-hooks.sh` as the canonical template.

Boilerplate every container test must have:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# --- test functions ---

test_my_lib_exists() {
    setup_container_test "my-lib-exists"
    local output
    output=$(run_in_container "test -f /opt/kapsis/lib/my-lib.sh && echo EXISTS || echo MISSING")
    cleanup_container_test
    assert_contains "$output" "EXISTS" "my-lib.sh must exist at /opt/kapsis/lib/"
}

main() {
    print_test_header "Container My Lib (real-image e2e)"

    # Required: skip gracefully when Podman or image is unavailable
    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests — prerequisites not met"
        exit 0
    fi

    setup_test_project
    run_test test_my_lib_exists
    cleanup_test_project
    print_summary
}

main "$@"
```

**Registration**: add the new file to the `security` category in `tests/run-all-tests.sh` AND to `QUICK_TESTS` (container tests self-skip without Podman, so they are safe in `--quick` mode).

**Fixture bind-mount pattern**: when a test needs a pre-populated `~/.claude` directory, create a `mktemp -d` fixture on the host, populate it, `chmod -R a+rwX` it, and bind-mount it into the container with `-v fixture/.claude:/home/developer/.claude:rw`. Read the resulting `settings.json` via container stdout (print between markers) rather than trying to read the bind-mount from the host after the container exits — uid-mapping makes the latter unreliable in CI.

## Background: the COPY regression bug class

Issue #381 tracks this. The pattern that was missed for 6 days:

1. A new `scripts/lib/my-feature.sh` is added to the source tree  
2. `scripts/entrypoint.sh` starts sourcing it  
3. The matching `COPY scripts/lib/my-feature.sh /opt/kapsis/lib/` line in `Containerfile` is forgotten  
4. Inside the container, the `source` call fails silently (bash `source` on a missing file in a function wrapped with `|| true` / `log_debug` returns 0)  
5. The feature silently no-ops at runtime for every agent run

A container test that asserts `test -f /opt/kapsis/lib/my-feature.sh` catches this at CI time. A host test that sources `$KAPSIS_ROOT/scripts/lib/my-feature.sh` does not — it always finds the file because it's reading from the host source tree.
