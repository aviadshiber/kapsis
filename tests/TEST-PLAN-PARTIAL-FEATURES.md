# Test Plan: Partially Tested Features

Behavior-based test plan for Agent Profiles, Gradle Cache Isolation, and Keychain Integration.

**Design Principles:**
- Test observable behaviors, not implementation details
- Tests should pass regardless of internal refactoring
- Focus on contracts: "given X input, expect Y outcome"
- No assertions on internal file paths, function names, or data structures

---

## 1. Agent Profiles

**Feature Summary:** YAML profiles define how AI agents are installed, configured, and launched.

### 1.1 Profile Loading & Resolution

| Test | Given | When | Then |
|------|-------|------|------|
| Valid profile loads | A valid agent profile exists | `--agent <name>` is used | Agent launches with profile settings |
| Missing profile errors | Profile doesn't exist | `--agent nonexistent` is used | Error message lists available agents |
| Profile name displayed | Valid profile with `name` field | Agent launches | Banner/logs show profile name |
| Profile metadata in status | Valid profile | Agent runs | Status JSON contains agent identifier |

**Test File:** `test-agent-profile-loading.sh`

```bash
# Behavior: Valid profile resolves and displays name
test_profile_name_displayed() {
    # Given: claude profile exists
    # When: launch with --agent claude --dry-run
    # Then: output contains agent name (case-insensitive match)
    output=$("$LAUNCH_SCRIPT" 1 "$PROJECT" --agent claude --dry-run 2>&1)
    assert_matches "$output" "[Cc]laude" "Agent name should appear in output"
}

# Behavior: Unknown profile lists alternatives
test_unknown_profile_shows_available() {
    # Given: 'foobar' profile doesn't exist
    # When: launch with --agent foobar
    # Then: error lists available agent names
    output=$("$LAUNCH_SCRIPT" 1 "$PROJECT" --agent foobar 2>&1) || true
    assert_contains "$output" "claude" "Should suggest available agents"
    assert_contains "$output" "aider" "Should suggest available agents"
}
```

### 1.2 Profile Authentication Requirements

| Test | Given | When | Then |
|------|-------|------|------|
| Required auth missing fails | Profile requires `ANTHROPIC_API_KEY` | Key not available | Launch fails with auth error |
| Required auth present succeeds | Profile requires key | Key available (env or keychain) | Launch proceeds |
| Optional auth missing succeeds | Profile has optional auth | Optional key missing | Launch proceeds (no error) |
| Auth error is actionable | Required auth missing | Launch attempted | Error message names the missing credential |

**Test File:** `test-agent-auth-requirements.sh`

```bash
# Behavior: Missing required credential blocks launch
test_missing_required_auth_fails() {
    # Given: profile requires ANTHROPIC_API_KEY
    # When: launch without the key available
    # Then: fails with message identifying the missing credential
    unset ANTHROPIC_API_KEY
    output=$("$LAUNCH_SCRIPT" 1 "$PROJECT" --agent claude --dry-run 2>&1) || exit_code=$?

    # Should fail OR warn about missing auth
    if [[ $exit_code -eq 0 ]]; then
        assert_contains "$output" "ANTHROPIC_API_KEY" "Should mention missing credential"
    fi
}

# Behavior: Available credential allows launch
test_present_auth_succeeds() {
    # Given: required credential is set
    export ANTHROPIC_API_KEY="test-key-12345"
    # When: launch with --dry-run
    # Then: proceeds without auth errors
    output=$("$LAUNCH_SCRIPT" 1 "$PROJECT" --agent claude --dry-run 2>&1)
    assert_not_contains "$output" "auth" "Should not show auth errors"
    assert_not_contains "$output" "credential" "Should not show credential errors"
}
```

### 1.3 Profile Config Mounts

| Test | Given | When | Then |
|------|-------|------|------|
| Required mount missing fails | Profile requires `~/.claude.json` | File doesn't exist | Launch fails with path error |
| Optional mount missing succeeds | Profile has optional mount | File doesn't exist | Launch proceeds |
| Mount available in container | Mount source exists | Container runs | File accessible at target path |
| Mounts are read-only | Mount configured | Container modifies file | Modification doesn't affect host |

**Test File:** `test-agent-config-mounts.sh` (Container required)

```bash
# Behavior: Config file from host accessible in container
test_config_mount_accessible() {
    # Given: config file exists on host
    echo '{"test": true}' > "$HOME/.claude.json"

    # When: container runs with profile that mounts it
    # Then: file is readable inside container
    run_in_container "cat ~/.claude.json" | assert_contains '{"test": true}'
}

# Behavior: Config mount is read-only (host unchanged)
test_config_mount_readonly() {
    # Given: config file on host with known content
    echo 'original' > "$HOME/.test-config"
    host_checksum=$(md5sum "$HOME/.test-config")

    # When: container attempts to modify mounted config
    run_in_container "echo 'modified' > ~/.test-config" || true

    # Then: host file unchanged
    assert_equals "$host_checksum" "$(md5sum "$HOME/.test-config")" "Host config should be unchanged"
}
```

### 1.4 Image Building from Profile

| Test | Given | When | Then |
|------|-------|------|------|
| Build creates tagged image | Valid profile | `build-agent-image.sh <profile>` | Image exists with expected tag pattern |
| Built image is usable | Image built from profile | Launch with `--image` | Container starts successfully |
| Build fails gracefully | Invalid/missing profile | Build attempted | Error message identifies issue |
| Profile tools installed | Profile specifies npm/pip package | Image built and container runs | Tool is executable |

**Test File:** `test-agent-image-build.sh` (Container required)

```bash
# Behavior: Built image contains agent tool
test_built_image_has_agent() {
    # Given: image built from claude profile
    # When: check if claude tool exists
    # Then: tool is found and executable
    run_in_container "which claude || command -v claude"
    assert_exit_code 0 "Agent tool should be installed"
}

# Behavior: Build with unknown profile fails helpfully
test_build_unknown_profile_fails() {
    output=$("$SCRIPTS_DIR/build-agent-image.sh" nonexistent 2>&1) || exit_code=$?
    assert_not_equals 0 "$exit_code" "Should fail for unknown profile"
    assert_contains "$output" "not found\|unknown\|invalid" "Should explain failure"
}
```

---

## 2. Gradle Cache Isolation

**Feature Summary:** Each agent has isolated build cache; remote cache disabled to prevent cross-contamination.

### 2.1 Remote Cache Disabled

| Test | Given | When | Then |
|------|-------|------|------|
| Remote cache writes blocked | Agent runs Gradle build | Build completes | No artifacts uploaded to remote cache |
| Remote cache reads blocked | Remote cache has artifacts | Agent builds | Build doesn't download from remote |
| Build succeeds without remote | Remote cache disabled | Clean build | Build completes using local resources only |

**Test File:** `test-gradle-cache-isolation.sh` (Container required)

```bash
# Behavior: Gradle build succeeds without remote cache
test_gradle_build_without_remote() {
    # Given: Gradle project in container
    setup_gradle_project

    # When: run gradle build
    output=$(run_in_container "cd /workspace && ./gradlew build --info 2>&1")

    # Then: build succeeds
    assert_exit_code 0 "Gradle build should succeed"

    # And: no remote cache operations logged
    assert_not_contains "$output" "Downloading from build-cache" "Should not download from remote"
    assert_not_contains "$output" "Storing entry" "Should not upload to remote"
}

# Behavior: Build cache configuration is applied
test_gradle_cache_config_applied() {
    # Given: Gradle project
    # When: check effective cache configuration
    output=$(run_in_container "./gradlew properties --property buildCache 2>&1")

    # Then: remote cache is disabled
    # (Check behavior, not specific property names)
    assert_contains "$output" "remote.*false\|disabled" "Remote cache should be disabled"
}
```

### 2.2 Per-Agent Cache Isolation

| Test | Given | When | Then |
|------|-------|------|------|
| Agents have separate caches | Two agents on same project | Both build | Each has independent cache directory |
| Cache not shared | Agent 1 builds, Agent 2 builds | Same source code | Agent 2 doesn't get Agent 1's cache hits |
| Cache persists within agent | Same agent runs twice | Second build | Cache hits from first build |

**Test File:** `test-gradle-agent-isolation.sh` (Container required)

```bash
# Behavior: Same agent benefits from cache on rebuild
test_cache_persists_within_agent() {
    # Given: Agent 1 completed a build
    run_agent 1 "$PROJECT" "gradle build"

    # When: Agent 1 builds again
    output=$(run_agent 1 "$PROJECT" "gradle build --info 2>&1")

    # Then: cache hits observed (faster build, UP-TO-DATE tasks)
    assert_contains "$output" "UP-TO-DATE\|FROM-CACHE" "Should have cache hits"
}

# Behavior: Different agents don't share cache
test_agents_have_isolated_caches() {
    # Given: Agent 1 completed a build
    run_agent 1 "$PROJECT" "gradle build"

    # When: Agent 2 builds same project
    output=$(run_agent 2 "$PROJECT" "gradle build --info 2>&1")

    # Then: Agent 2 does full build (no cache hits from Agent 1)
    # Look for compilation happening, not cache restoration
    assert_contains "$output" "Compiling\|:compileJava" "Should compile from scratch"
}
```

### 2.3 Local Cache Behavior

| Test | Given | When | Then |
|------|-------|------|------|
| Local cache enabled | Default configuration | Build runs | Local cache directory created |
| Local cache improves rebuild | Incremental change | Second build | Only changed tasks execute |
| Cache cleanup works | Agent with cache | Cleanup with volumes | Cache directory removed |

```bash
# Behavior: Local cache is active
test_local_cache_enabled() {
    # Given: Gradle project
    # When: build completes
    run_in_container "gradle build"

    # Then: local cache exists (check behavior: cache populated)
    output=$(run_in_container "gradle build --info 2>&1")
    assert_contains "$output" "FROM-CACHE\|UP-TO-DATE" "Local cache should be working"
}
```

---

## 3. Keychain Integration

**Feature Summary:** Secrets retrieved from OS keychain; SSH keys verified and cached.

### 3.1 API Key Retrieval

| Test | Given | When | Then |
|------|-------|------|------|
| Key from keychain available | Secret stored in keychain | Container runs | Env var available inside container |
| Missing key handled gracefully | Secret not in keychain | Container runs | Warning logged, no crash |
| Keychain priority respected | Key in both env and keychain | Container runs | Environment value takes precedence |
| Secrets masked in output | Key retrieved | Dry-run output | Value shown as masked/redacted |

**Test File:** `test-keychain-retrieval.sh`

```bash
# Behavior: Secrets are masked in dry-run
test_secrets_masked_in_output() {
    # Given: API key is set
    export ANTHROPIC_API_KEY="sk-secret-value-12345"

    # When: dry-run executed
    output=$("$LAUNCH_SCRIPT" 1 "$PROJECT" --dry-run 2>&1)

    # Then: actual secret value NOT visible
    assert_not_contains "$output" "sk-secret-value-12345" "Secret should be masked"
    # And: masking indicator shown
    assert_contains "$output" "MASK\|\\*\\*\\*\|<redacted>" "Should show masking indicator"
}

# Behavior: Environment takes priority over keychain
test_env_priority_over_keychain() {
    # Given: key set via environment
    export ANTHROPIC_API_KEY="env-value"

    # When: launch (keychain may have different value)
    output=$("$LAUNCH_SCRIPT" 1 "$PROJECT" --dry-run 2>&1)

    # Then: environment source indicated (not keychain)
    # Check that passthrough is used, not keychain lookup
    assert_contains "$output" "passthrough\|environment" "Should use env value"
}
```

### 3.2 Credential File Injection

| Test | Given | When | Then |
|------|-------|------|------|
| File created with secret | `inject_to_file` configured | Container runs | File exists with correct content |
| File has secure permissions | File injection configured | File created | Permissions are 0600 or stricter |
| Parent directories created | Target path has nested dirs | Injection runs | Directories created automatically |
| Env var removed after injection | `inject_to_file` used | Container runs | Original env var not set |

**Test File:** `test-credential-injection.sh` (Container required)

```bash
# Behavior: Injected file has secure permissions
test_injected_file_permissions() {
    # Given: credential injection configured
    # When: container runs with injection
    # Then: file permissions are secure (not world-readable)
    perms=$(run_in_container "stat -c %a ~/.credentials/token 2>/dev/null || stat -f %Lp ~/.credentials/token")

    # 600 or stricter (no group/other access)
    assert_matches "$perms" "^[0-6]00$" "File should have secure permissions"
}

# Behavior: Nested directories created automatically
test_injection_creates_parent_dirs() {
    # Given: injection target is deeply nested
    # When: container runs
    # Then: parent directories exist
    run_in_container "test -d ~/.config/app/secrets"
    assert_exit_code 0 "Parent directories should be created"
}
```

### 3.3 SSH Host Key Verification

| Test | Given | When | Then |
|------|-------|------|------|
| Known hosts verified | github.com configured | SSH verification runs | Key verified against official fingerprint |
| Verification failure blocks | Wrong fingerprint cached | Verification runs | Error with MITM warning |
| Cache improves performance | Host verified once | Second launch | Cached key used (faster) |
| Cache respects TTL | Cached key expired | Launch | Fresh key fetched |

**Test File:** `test-ssh-verification.sh`

```bash
# Behavior: Known host fingerprint verified
test_known_host_verified() {
    # Given: github.com in ssh.verify_hosts config
    # When: SSH verification runs
    output=$("$SCRIPTS_DIR/verify-ssh-hosts.sh" github.com 2>&1)

    # Then: verification succeeds
    assert_exit_code 0 "GitHub verification should succeed"
    assert_contains "$output" "verified\|success\|✓" "Should indicate verification passed"
}

# Behavior: Invalid fingerprint rejected
test_invalid_fingerprint_rejected() {
    # Given: wrong fingerprint in config
    echo "github.com SHA256:wrongfingerprintvalue" > "$HOME/.kapsis/ssh-hosts.conf"

    # When: verification runs
    output=$("$SCRIPTS_DIR/verify-ssh-hosts.sh" github.com 2>&1) || exit_code=$?

    # Then: rejected with security warning
    assert_not_equals 0 "$exit_code" "Should fail with wrong fingerprint"
    assert_contains "$output" "mismatch\|MITM\|failed" "Should warn about fingerprint issue"
}
```

### 3.4 SSH Cache Management

| Test | Given | When | Then |
|------|-------|------|------|
| Cache can be cleared | Cached SSH keys exist | `--ssh-cache` cleanup | Cache entries removed |
| Clear is idempotent | Cache already empty | `--ssh-cache` cleanup | No error |
| Platform-appropriate storage | Running on macOS/Linux | Key cached | Stored in platform keychain or file |

**Test File:** `test-ssh-cache-cleanup.sh`

```bash
# Behavior: SSH cache cleanup removes entries
test_ssh_cache_cleanup() {
    # Given: SSH key is cached
    "$SCRIPTS_DIR/verify-ssh-hosts.sh" github.com

    # When: cleanup with --ssh-cache
    "$SCRIPTS_DIR/kapsis-cleanup.sh" --ssh-cache

    # Then: cache is cleared (next lookup will re-fetch)
    # Verify by checking that cache lookup indicates miss
    output=$("$SCRIPTS_DIR/verify-ssh-hosts.sh" github.com --verbose 2>&1)
    assert_contains "$output" "fetching\|scanning\|not cached" "Should fetch fresh after cleanup"
}

# Behavior: Cleanup is safe to run multiple times
test_cleanup_idempotent() {
    # Given: empty cache
    "$SCRIPTS_DIR/kapsis-cleanup.sh" --ssh-cache

    # When: cleanup again
    "$SCRIPTS_DIR/kapsis-cleanup.sh" --ssh-cache

    # Then: no error
    assert_exit_code 0 "Repeated cleanup should succeed"
}
```

### 3.5 Cross-Platform Keychain

| Test | Given | When | Then |
|------|-------|------|------|
| macOS uses Keychain | Running on macOS | Secret retrieved | Uses `security` command |
| Linux uses secret-tool | Running on Linux with secret-tool | Secret retrieved | Uses `secret-tool` command |
| Linux fallback to file | Linux without secret-tool | SSH cache used | Falls back to file storage |

**Test File:** `test-keychain-platform.sh`

```bash
# Behavior: Platform detection works
test_platform_detected() {
    # Given: running on known platform
    # When: keychain operation attempted
    output=$("$SCRIPTS_DIR/lib/ssh-keychain.sh" --test-platform 2>&1)

    # Then: appropriate backend selected
    case "$(uname -s)" in
        Darwin) assert_contains "$output" "keychain\|security" "macOS should use Keychain" ;;
        Linux)  assert_contains "$output" "secret-tool\|file" "Linux should use secret-tool or file" ;;
    esac
}

# Behavior: Missing secret-tool falls back gracefully
test_linux_fallback() {
    # Given: Linux without secret-tool
    # When: cache operation runs
    # Then: falls back to file-based cache without error

    # (This test validates graceful degradation)
    output=$(PATH=/usr/bin:/bin "$SCRIPTS_DIR/lib/ssh-keychain.sh" cache github.com "key" 2>&1) || true
    assert_not_contains "$output" "command not found" "Should not error on missing secret-tool"
}
```

---

## Test Implementation Checklist

### New Test Files to Create

| File | Category | Container Required | Priority |
|------|----------|-------------------|----------|
| `test-agent-profile-loading.sh` | agent | No | High |
| `test-agent-auth-requirements.sh` | agent | No | High |
| `test-agent-config-mounts.sh` | agent | Yes | Medium |
| `test-agent-image-build.sh` | agent | Yes | Medium |
| `test-gradle-cache-isolation.sh` | maven | Yes | High |
| `test-gradle-agent-isolation.sh` | maven | Yes | High |
| `test-keychain-retrieval.sh` | security | No | High |
| `test-credential-injection.sh` | security | Yes | Medium |
| `test-ssh-verification.sh` | security | No | High |
| `test-ssh-cache-cleanup.sh` | cleanup | No | Medium |
| `test-keychain-platform.sh` | security | No | Low |

### Estimated Test Counts

| Feature | New Tests | Existing | Total |
|---------|-----------|----------|-------|
| Agent Profiles | ~20 | 16 | ~36 |
| Gradle Cache | ~12 | 1 | ~13 |
| Keychain Integration | ~18 | 34 | ~52 |
| **Total** | **~50** | **51** | **~101** |

---

## Notes for Implementation

1. **Mocking Strategy**: For keychain tests without real secrets, use test-specific service names that can be safely created/deleted.

2. **Network Tests**: SSH verification tests should handle network unavailability gracefully (skip or mock).

3. **Container Tests**: Tests requiring containers should use `skip_if_no_container` helper.

4. **Cleanup**: All tests must clean up created resources (volumes, cache entries, temp files).

5. **Parallel Safety**: Tests should use unique identifiers to avoid conflicts when run in parallel.
