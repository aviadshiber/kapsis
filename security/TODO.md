# Security Hardening - Remaining Work

This document tracks the remaining work to fully integrate security hardening into Kapsis.

## Completed ✅

- [x] `scripts/lib/security.sh` - Security library with:
  - Security profile definitions (minimal, standard, strict, paranoid)
  - Capability management functions
  - Seccomp profile generation
  - LSM (AppArmor/SELinux) detection
  - Filesystem hardening options
- [x] `security/seccomp/kapsis-agent-base.json` - Base seccomp profile
- [x] `security/seccomp/kapsis-interactive.json` - Debug seccomp profile
- [x] `security/seccomp/kapsis-audit.json` - Audit seccomp profile
- [x] `security/apparmor/kapsis-agent` - Full AppArmor profile
- [x] `security/README.md` - Documentation

## Remaining Work 🔧

### 1. Integration into `launch-agent.sh`

Source the security library and call its functions:

```bash
# In launch-agent.sh, after sourcing other libraries:
source "$SCRIPT_DIR/lib/security.sh"

# Before container launch, add security arguments:
SECURITY_ARGS=$(build_security_args)
podman run ... $SECURITY_ARGS ...
```

**Required changes:**
- [ ] Add `source "$SCRIPT_DIR/lib/security.sh"` after other library sources
- [ ] Call `init_security()` during initialization
- [ ] Call `build_security_args()` before podman run
- [ ] Integrate security args into the podman command construction

### 2. CLI Flag `--security-profile`

Add command-line option to select security profile:

```bash
--security-profile <minimal|standard|strict|paranoid>
```

**Required changes:**
- [ ] Add `--security-profile` to `parse_args()` case statement
- [ ] Add `SECURITY_PROFILE` variable
- [ ] Update `usage()` with new option documentation
- [ ] Pass profile to security library initialization

### 3. Config File Support

Parse security section from agent-sandbox.yaml:

```yaml
security:
  profile: strict
  seccomp:
    enabled: true
  capabilities:
    drop_all: true
```

**Required changes:**
- [ ] Add security config parsing in `load_config()` or create dedicated function
- [ ] Map YAML keys to environment variables
- [ ] Validate config values

### 4. Tests for `security.sh`

Create test file `tests/test-security.sh`:

- [ ] Test `generate_capability_args()` output
- [ ] Test `build_seccomp_args()` for each profile
- [ ] Test LSM detection functions
- [ ] Test security profile validation
- [ ] Test environment variable overrides
- [ ] Integration test with actual podman container (profile application)

### 5. SELinux Policies

The `security/selinux/` directory is empty. If SELinux support is needed:

- [ ] Create SELinux policy module for Kapsis
- [ ] Add SELinux installation instructions to README
- [ ] Test on RHEL/Fedora systems

### 6. Documentation Updates

- [ ] Update main README.md with security profile options
- [ ] Add security section to CONFIG-REFERENCE.md
- [ ] Document security profiles in ARCHITECTURE.md

## Implementation Priority

1. **High**: Integration into launch-agent.sh (core functionality)
2. **High**: CLI flag (user-facing feature)
3. **Medium**: Config file support (convenience)
4. **Medium**: Tests (quality assurance)
5. **Low**: SELinux (niche use case)
6. **Low**: Documentation (polish)

## Notes

- The security.sh library is fully functional and self-contained
- Seccomp profiles are production-ready for Java/Node.js development
- AppArmor profile requires system installation (see security/README.md)
- SELinux can remain disabled (current behavior) until policies are created
