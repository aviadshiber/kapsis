# Audit System

Tamper-evident, hash-chained audit logging for all agent actions inside the Kapsis sandbox.

## Overview

The audit system provides comprehensive visibility into what AI agents do inside their sandboxed containers. Every tool invocation, shell command, file access, network call, and credential use is recorded as a JSONL event, cryptographically chained to the previous event via SHA-256 hashes.

**Why it exists:**

| Goal | How the Audit System Helps |
|------|---------------------------|
| **Visibility** | Complete record of every agent action during a session |
| **Tamper detection** | SHA-256 hash chain makes post-hoc modification detectable |
| **Alerting** | Real-time pattern detection flags suspicious behavior (credential exfiltration, mass deletion) |
| **Post-run analysis** | Structured reports summarize sessions, highlight security events, and track filesystem impact |

The audit system is **opt-in** for the initial release. It runs inline in the audit hook with minimal overhead and writes append-only JSONL files to `~/.kapsis/audit/`.

---

## Enabling Audit Logging

Audit logging is disabled by default. Enable it via environment variable or YAML config.

### Environment Variable

```bash
KAPSIS_AUDIT_ENABLED=true ./scripts/launch-agent.sh ~/project --task "implement feature"
```

### YAML Config

Add to your `agent-sandbox.yaml`:

```yaml
audit:
  enabled: true
```

### Verification

Once enabled, you will see a log message during launch:

```
[INFO] Audit initialized: ~/.kapsis/audit/<agent-id>-<session-id>.audit.jsonl
```

After the session completes, a text report is automatically generated at `~/.kapsis/audit/<agent-id>-report.txt`.

---

## Event Schema

Each line in the audit JSONL file is a self-contained JSON object with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `seq` | int | Monotonically increasing sequence number (resets on rotation) |
| `timestamp` | string | ISO 8601 UTC timestamp (`2025-01-15T10:30:45Z`) |
| `session_id` | string | Unique session identifier (`YYYYMMDD-HHMMSS-PID`) |
| `agent_id` | string | Agent identifier (e.g., `abc123`) |
| `agent_type` | string | Agent type (e.g., `claude-cli`, `aider`, `codex-cli`) |
| `project` | string | Project name |
| `event_type` | string | Classified event type (see [Event Types](#event-types)) |
| `tool_name` | string | Tool that generated the event (e.g., `Bash`, `Read`, `Write`, `Edit`) |
| `detail` | object | Event-specific payload (command, file_path, etc.) |
| `prev_hash` | string | SHA-256 hash of the previous event (64 hex chars) |
| `hash` | string | SHA-256 hash of this event (64 hex chars) |

### Example JSONL Line

```json
{"seq":3,"timestamp":"2025-01-15T10:30:47Z","session_id":"20250115-103045-1234","agent_id":"abc123","agent_type":"claude-cli","project":"my-project","event_type":"shell_command","tool_name":"Bash","detail":{"command":"git status"},"prev_hash":"a1b2c3...","hash":"d4e5f6..."}
```

All string fields containing secrets are sanitized before writing via the logging library's secret sanitization.

---

## Event Types

Events are classified into the following types, either explicitly or via auto-classification:

| Event Type | Description | Examples |
|------------|-------------|---------|
| `session_start` | Genesis event when audit initializes | Logged automatically by `audit_init()` |
| `session_end` | Final event when audit finalizes | Logged automatically by `audit_finalize()` |
| `credential_access` | Access to secrets, keychains, or sensitive credential files | `security find-generic-password`, access to `.ssh/`, `.gnupg/`, `.aws/` |
| `filesystem_op` | File read, write, edit, or directory operations | `Read`, `Write`, `Edit`, `Glob`, `Grep` tools; `cp`, `mv`, `rm`, `mkdir` commands |
| `network_activity` | Network requests, package installs, git remote operations | `curl`, `wget`, `npm install`, `git clone/fetch/push` |
| `git_op` | Git state-changing operations | `git commit`, `git push`, `git merge`, `git rebase`, `git checkout` |
| `shell_command` | Shell commands not classified into other categories | Any `Bash` tool invocation |
| `tool_use` | Generic tool invocation (catch-all) | Any tool not matching the above categories |
| `chain_continuation` | Genesis event after file rotation | Links the new file to the previous file's chain |

### Auto-Classification

When `event_type` is set to `"auto"`, the audit library classifies the event based on the tool name, command string, and file path using pattern matching in `_audit_classify_event()`.

---

## Hash Chain

Every audit event is cryptographically linked to the previous event via SHA-256, creating a tamper-evident chain.

### How It Works

1. **Genesis event** (`seq: 0`): The `prev_hash` is all zeros (64 `0` characters)
2. **Hash input**: Concatenation of `prev_hash + seq + timestamp + event_type + tool_name + detail`
3. **Hash computation**: `printf '%s' "$hash_input" | sha256_hash` (using `scripts/lib/compat.sh` cross-platform SHA-256)
4. **Chain linkage**: Each event stores its own `hash` and the `prev_hash` from the preceding event

```
Event 0 (genesis):
  prev_hash = 0000...0000 (64 zeros)
  hash = SHA-256(prev_hash + seq + timestamp + event_type + tool_name + detail)

Event 1:
  prev_hash = hash of Event 0
  hash = SHA-256(prev_hash + seq + timestamp + event_type + tool_name + detail)

Event N:
  prev_hash = hash of Event N-1
  hash = SHA-256(...)
```

### Chain Continuation on Rotation

When an audit file is rotated (due to size limit), the new file starts with a `chain_continuation` event whose `detail` includes:

```json
{
  "action": "chain_continuation",
  "previous_file": "<path>.1",
  "continued_from_hash": "<last hash from previous file>"
}
```

This allows verifying the full chain across rotated files.

### Tampering Detection

If any event is modified, deleted, or inserted:

- The stored `hash` will not match the recomputed hash
- The `prev_hash` of the next event will not match the modified event's hash
- `audit_verify_chain()` will report the exact sequence number and line where the chain breaks

---

## Verification

### Command-Line Verification

```bash
# Verify the latest audit file
./scripts/audit-report.sh --latest --verify

# Verify a specific file
./scripts/audit-report.sh ~/.kapsis/audit/abc123-20250115-103045-1234.audit.jsonl --verify

# Verify by agent ID
./scripts/audit-report.sh --agent-id abc123 --verify
```

The `--verify` flag adds a "Hash Chain Verification" section to the report output showing `VALID` or `BROKEN` with details about where the chain broke.

### Programmatic Verification

```bash
source scripts/lib/compat.sh
source scripts/lib/json-utils.sh
source scripts/lib/logging.sh
source scripts/lib/constants.sh
source scripts/lib/audit.sh

audit_verify_chain "/path/to/file.audit.jsonl"
# Returns 0 if valid, 1 if broken
```

The `audit_verify_chain()` function re-reads every event, recomputes the hash from its fields, and verifies both:

1. The `prev_hash` matches the previous event's `hash`
2. The stored `hash` matches the recomputed hash

---

## Real-Time Pattern Detection

The audit system includes a lightweight in-process pattern detection engine (`scripts/lib/audit-patterns.sh`) that runs inline after each event is logged. It uses a ring buffer of the last 20 events to detect suspicious behavioral patterns.

### Detected Patterns

| Pattern | Severity | Description | Trigger Condition |
|---------|----------|-------------|-------------------|
| `credential_exfiltration` | HIGH | Credential access followed by network activity | `credential_access` + `network_activity` within 30 seconds (excludes standard package managers) |
| `mass_deletion` | MEDIUM | Bulk destructive file operations | 5+ `rm -rf`, `rm -r`, `find -delete`, or `shred` commands in the 20-event window |
| `sensitive_path_access` | HIGH | Access to sensitive directories or files | Any access to `.ssh/`, `.gnupg/`, `.aws/`, `.kube/`, `/etc/passwd`, `/etc/shadow` |
| `unusual_commands` | CRITICAL | Suspicious command patterns | `base64 -d`, `curl | sh`, `nc -l`, `python -c socket`, `eval base64` |

### Package Manager Allowlist

Network activity from standard package managers (`npm`, `pip`, `maven`, `gradle`, `cargo`, `go`, `yarn`, `pnpm`, `gem`, `composer`, `nuget`) is excluded from `credential_exfiltration` detection since these legitimately access the network.

### Alert File Format

Alerts are written to `~/.kapsis/audit/<agent-id>-alerts.jsonl` as JSONL:

```json
{"timestamp":"2025-01-15T10:31:00Z","agent_id":"abc123","session_id":"20250115-103045-1234","pattern":"sensitive_path_access","severity":"HIGH","description":"Access to sensitive path: /home/developer/.ssh/id_rsa","trigger_events":[19]}
```

Alerts are also logged as warnings via the logging system:

```
[WARN] AUDIT ALERT [HIGH] sensitive_path_access: Access to sensitive path: /home/developer/.ssh/id_rsa
```

---

## Post-Run Reports

After a session completes, Kapsis automatically generates a text report at `~/.kapsis/audit/<agent-id>-report.txt`. You can also generate reports manually.

### Usage

```bash
# Generate report for latest audit file
./scripts/audit-report.sh --latest

# Generate report for specific agent
./scripts/audit-report.sh --agent-id abc123

# Generate report for specific file
./scripts/audit-report.sh ~/.kapsis/audit/abc123-20250115-103045-1234.audit.jsonl

# JSON output for scripting
./scripts/audit-report.sh --latest --format json

# Brief summary only
./scripts/audit-report.sh --latest --summary

# Show only security alerts
./scripts/audit-report.sh --latest --alerts-only

# Include hash chain verification
./scripts/audit-report.sh --latest --verify
```

### Report Sections (Text Format)

1. **Session Summary** -- Agent metadata, duration, total events, events by type
2. **Hash Chain Verification** -- Chain integrity result (only with `--verify`)
3. **Security Alerts** -- All triggered alerts with severity, pattern, and description
4. **Event Statistics** -- Top 10 commands, most accessed files, tool/event type distribution
5. **Credential Access Log** -- Every `credential_access` event with timestamp and tool
6. **Filesystem Impact** -- Total filesystem operations, unique files modified

### JSON Report Structure

With `--format json`, the report is a single JSON object:

```json
{
  "summary": { "agent_id": "...", "duration": "...", "total_events": 42, ... },
  "alerts": [ ... ],
  "statistics": { "top_commands": [...], "top_files": [...], "tool_usage": {...}, ... },
  "credential_access": [ ... ],
  "filesystem_impact": { "total_operations": 15, "unique_files": 8, "paths": [...] },
  "chain_verification": { "result": "valid", "message": "..." }
}
```

---

## File Layout

All audit files are stored under `~/.kapsis/audit/` (configurable via `KAPSIS_AUDIT_DIR`):

```
~/.kapsis/audit/
├── abc123-20250115-103045-1234.audit.jsonl      # Primary audit trail
├── abc123-20250115-103045-1234.audit.jsonl.1    # Rotated (previous)
├── abc123-20250115-103045-1234.audit.jsonl.2    # Rotated (older)
├── abc123-20250115-103045-1234.audit.jsonl.3    # Rotated (oldest)
├── abc123-alerts.jsonl                          # Security alerts
├── abc123-report.txt                            # Auto-generated text report
├── def456-20250116-090000-5678.audit.jsonl      # Another agent's audit trail
├── def456-alerts.jsonl                          # Another agent's alerts
└── def456-report.txt                            # Another agent's report
```

### Naming Convention

- **Audit files**: `<agent-id>-<YYYYMMDD-HHMMSS>-<PID>.audit.jsonl`
- **Rotated files**: Append `.1`, `.2`, `.3` (max 3 rotated files per session)
- **Alert files**: `<agent-id>-alerts.jsonl`
- **Report files**: `<agent-id>-report.txt`

### File Permissions

- Audit directory: `700` (owner-only access)
- Audit files: `600` (owner read/write only)

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_AUDIT_ENABLED` | `false` | Enable audit logging (`true` or `false`) |
| `KAPSIS_AUDIT_DIR` | `~/.kapsis/audit` | Directory for audit files |
| `KAPSIS_AUDIT_MAX_FILE_SIZE_MB` | `50` | Per-session file size cap (MB) before rotation |
| `KAPSIS_AUDIT_TTL_DAYS` | `30` | Auto-delete audit files older than this (days) |
| `KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB` | `500` | Total audit directory size cap (MB), oldest files pruned first |

### YAML Config

```yaml
audit:
  enabled: true                # Enable audit logging
  max_file_size_mb: 50         # Rotate at 50 MB per file
  ttl_days: 30                 # Delete files older than 30 days
  max_total_size_mb: 500       # Cap total audit storage at 500 MB
```

### Constants

All defaults are defined in `scripts/lib/constants.sh`:

```bash
KAPSIS_DEFAULT_AUDIT_ENABLED="false"
KAPSIS_AUDIT_MAX_FILE_SIZE_MB=50
KAPSIS_AUDIT_TTL_DAYS=30
KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB=500
CONTAINER_AUDIT_PATH="/kapsis-audit"
```

---

## Cleanup

Audit cleanup runs automatically in the background at the start of each new session (non-blocking). It applies two strategies:

### TTL-Based Cleanup

Files older than `KAPSIS_AUDIT_TTL_DAYS` (default: 30 days) are deleted. This covers audit logs, rotated files, alert files, and report files.

### Size-Based Cleanup

If the total audit directory size exceeds `KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB` (default: 500 MB), the oldest files are deleted first until the total is under the cap. The current session's active audit file is never deleted.

### Integration with kapsis-cleanup.sh

The `kapsis-cleanup.sh` script can be used for manual cleanup of all Kapsis resources including audit files:

```bash
./scripts/kapsis-cleanup.sh
```

---

## K8s Backend

When using the Kubernetes backend (`--backend k8s`), audit logging integrates as follows:

### Environment Variable Injection

When `KAPSIS_AUDIT_ENABLED=true`, the K8s config translator (`scripts/lib/k8s-config.sh`) injects audit environment variables into the AgentRequest CR:

```yaml
spec:
  environment:
    vars:
      - name: KAPSIS_AUDIT_ENABLED
        value: "true"
      - name: KAPSIS_AUDIT_DIR
        value: "/kapsis-audit"
```

### Operator-Provisioned Volumes

The operator's job builder automatically creates an `emptyDir` volume named `kapsis-audit` and mounts it at `/kapsis-audit` in the agent container whenever a Job is created. No explicit CRD field is required.

### Audit Log Retrieval

Audit events written to `/kapsis-audit/` are streamed to stdout by the **status-sidecar** container. Log aggregators (ELK, Splunk, Loki) capture them automatically from the pod's stdout. No `kubectl cp` is needed.

```bash
# Retrieve audit logs from a running or completed pod
kubectl logs -c status-sidecar <pod-name> -n <namespace>
```

### Differences from Podman Backend

| Aspect | Podman | K8s |
|--------|--------|-----|
| Volume type | Bind mount (host directory) | emptyDir (pod-local) |
| Real-time access | Yes (host can read during session) | Via log aggregator or `kubectl logs` |
| Persistence | Files persist on host | Retained in log aggregation system |
| Retrieval | Automatic (shared volume) | `kubectl logs -c status-sidecar` |

---

## Cross-Platform Notes

- **SHA-256 hashing**: Uses `scripts/lib/compat.sh` which provides `sha256_hash` -- selects `shasum -a 256` on macOS or `sha256sum` on Linux
- **File timestamps**: Uses `get_file_mtime()` from `compat.sh` for portable modification time retrieval (macOS `stat -f %m` vs Linux `stat -c %Y`)
- **File sizes**: Uses `get_file_size()` from `compat.sh` for portable size retrieval
- **Date formatting**: ISO 8601 UTC timestamps are generated with `date -u` which works consistently across platforms

---

## Examples

### Enable Audit for a Single Run

```bash
KAPSIS_AUDIT_ENABLED=true ./scripts/launch-agent.sh ~/project \
    --agent claude --task "implement login feature"
```

### Read Raw Audit Events

```bash
# View all events (pretty-print with jq if available)
cat ~/.kapsis/audit/abc123-*.audit.jsonl | jq .

# Filter for credential access events
cat ~/.kapsis/audit/abc123-*.audit.jsonl | jq 'select(.event_type == "credential_access")'

# Count events by type
cat ~/.kapsis/audit/abc123-*.audit.jsonl | jq -r '.event_type' | sort | uniq -c | sort -rn
```

### Verify Hash Chain Integrity

```bash
./scripts/audit-report.sh --latest --verify
```

Expected output for a valid chain:

```
=== Hash Chain Verification ===

  Result: VALID
  Audit chain verified: 42 events in abc123-20250115-103045-1234.audit.jsonl
```

### Generate a JSON Report

```bash
./scripts/audit-report.sh --latest --format json | jq .summary
```

### Check for Security Alerts

```bash
# Quick check: any alerts?
./scripts/audit-report.sh --latest --alerts-only

# Machine-readable alerts
./scripts/audit-report.sh --latest --alerts-only --format json
```

### Enable Audit in YAML Config

```yaml
# agent-sandbox.yaml
audit:
  enabled: true
  max_file_size_mb: 100
  ttl_days: 60
  max_total_size_mb: 1000
```

### K8s Backend with Audit

```bash
KAPSIS_AUDIT_ENABLED=true ./scripts/launch-agent.sh ~/project \
    --backend k8s --agent claude --task "implement feature"
```

Or via CRD:

```yaml
apiVersion: kapsis.aviadshiber.github.io/v1alpha1
kind: AgentRequest
metadata:
  name: kapsis-audit-example
spec:
  image: kapsis-claude-cli:latest
  agent:
    type: claude-cli
    command: ["bash", "-c", "claude --task 'implement feature'"]
    workdir: /workspace
  audit:
    enabled: true
  resources:
    memory: "8Gi"
    cpu: "4"
```

---

## Key Files

| File | Purpose |
|------|---------|
| `scripts/lib/audit.sh` | Core audit library -- initialization, event logging, hash chain, rotation, cleanup |
| `scripts/lib/audit-patterns.sh` | Real-time pattern detection -- ring buffer, 4 detection patterns, alert output |
| `scripts/audit-report.sh` | Post-run report generator -- text and JSON formats, chain verification |
| `scripts/lib/constants.sh` | Default configuration values for audit system |
| `scripts/lib/compat.sh` | Cross-platform SHA-256 hash function (`sha256_hash`) |
| `scripts/backends/k8s.sh` | K8s backend: surfaces audit via `kubectl logs -c status-sidecar` |
| `scripts/lib/k8s-config.sh` | K8s CR generation with audit env vars |
| `operator/internal/controller/job_builder.go` | Operator: emptyDir volume (`kapsis-audit`) + env var injection |
