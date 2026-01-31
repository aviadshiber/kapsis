# Build Configuration Guide

This guide explains how to customize Kapsis container images by configuring which dependencies are included. This allows you to create optimized images for specific use cases, reducing image size and build time.

## Quick Start

### Using Predefined Profiles

The fastest way to customize your build is to use a predefined profile:

```bash
# Build a minimal image (~500MB) - base container only
./scripts/build-image.sh --profile minimal

# Build for Java development (~1.5GB) - Java, Maven, Gradle Enterprise
./scripts/build-image.sh --profile java-dev

# Build a full-stack image (~2.1GB) - Java, Node.js, Python
./scripts/build-image.sh --profile full-stack
```

### Preview Before Building

Use `--dry-run` to see what would be built without actually building:

```bash
./scripts/build-image.sh --profile java-dev --dry-run
```

## Available Profiles

| Profile | Est. Size | Languages | Build Tools | Best For |
|---------|-----------|-----------|-------------|----------|
| `minimal` | ~500MB | None | None | Shell scripts, basic tasks |
| `java-dev` | ~1.5GB | Java 17/8 | Maven, GE, protoc | Taboola Java development |
| `java8-legacy` | ~1.3GB | Java 8 only | Maven, GE, protoc | Legacy Java 8 projects |
| `full-stack` | ~2.1GB | Java, Node.js, Python | Maven, GE, protoc | Multi-language projects |
| `backend-go` | ~1.2GB | Go, Python | protoc | Go microservices |
| `backend-rust` | ~1.4GB | Rust, Python | protoc | Rust backend services |
| `ml-python` | ~1.8GB | Python, Node.js, Rust | None | ML/AI development |
| `frontend` | ~1.2GB | Node.js, Rust | None | Frontend/WebAssembly |

## Configuration File

### Default Configuration

The default configuration is stored in `configs/build-config.yaml`. Profile presets are in `configs/build-profiles/`.

### Configuration Schema

```yaml
version: "1.0"

languages:
  java:
    enabled: true
    versions:
      - "21.0.6-zulu"     # Zulu 21 LTS
      - "17.0.14-zulu"    # Zulu 17 LTS (default)
      - "8.0.422-zulu"    # Zulu 8 LTS
    default_version: "17.0.14-zulu"

  nodejs:
    enabled: true
    versions:
      - "18.18.0"
      - "20.10.0"
    default_version: "18.18.0"
    package_managers:
      pnpm: "9.15.3"
      yarn: "latest"

  python:
    enabled: true
    version: "system"     # Uses Ubuntu's Python 3.12
    venv: true
    pip: true

  rust:
    enabled: false
    channel: "stable"     # stable, beta, nightly
    components:
      - "rustfmt"
      - "clippy"
    cargo_binstall: true

  go:
    enabled: false
    version: "1.22.0"

build_tools:
  maven:
    enabled: true
    version: "3.9.9"

  gradle:
    enabled: false
    version: "8.5"

  gradle_enterprise:
    enabled: true
    extension_version: "1.20"
    ccud_version: "1.12.5"

  protoc:
    enabled: true
    version: "25.1"

system_packages:
  development:
    enabled: true
  shells:
    enabled: true
  utilities:
    enabled: true
  overlay:
    enabled: true
  custom: []
```

## CLI Tool: configure-deps.sh

The `configure-deps.sh` tool provides both interactive and non-interactive interfaces for configuring dependencies.

### Interactive Mode (for humans)

Run without arguments to enter interactive mode:

```bash
./scripts/configure-deps.sh
```

This displays a menu-driven interface:

```
╔═══════════════════════════════════════════════════════════════════╗
║           KAPSIS DEPENDENCY CONFIGURATION                         ║
╚═══════════════════════════════════════════════════════════════════╝

Current Profile: full-stack (~2.1GB)

  [1] Apply Profile Preset
  [2] Configure Languages
  [3] Configure Build Tools
  [4] Preview Changes
  [5] Save and Exit
  [Q] Quit without saving

Select option [1-5, Q]: _
```

### Non-Interactive Mode (for AI agents)

For automation and AI agent integration, use flags:

```bash
# Apply a profile
./scripts/configure-deps.sh --profile java-dev

# Enable/disable specific dependencies
./scripts/configure-deps.sh --enable rust --disable nodejs

# Show changes without applying
./scripts/configure-deps.sh --profile minimal --dry-run

# Output as JSON (for AI agents)
./scripts/configure-deps.sh --profile java-dev --json

# Set specific values
./scripts/configure-deps.sh --set languages.java.default_version="21.0.6-zulu"

# Add a custom Java version
./scripts/configure-deps.sh --add-java-version "25.0.1-tem"

# Read config from JSON file
./scripts/configure-deps.sh --from-json custom-config.json
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Invalid arguments |
| 2 | Config file not found |
| 3 | Invalid configuration value |
| 4 | Write failure |
| 5 | TTY required (for interactive mode) |

### JSON Output Format

When using `--json`, the output follows this structure:

```json
{
  "success": true,
  "profile": "java-dev",
  "config_file": "configs/build-config.yaml",
  "changes": [
    {"key": "languages.rust.enabled", "old": "false", "new": "true"}
  ],
  "estimated_size": "1.5GB",
  "build_command": "./scripts/build-image.sh --profile java-dev"
}
```

## Java Version Management

### Supported Distributions

Kapsis uses SDKMAN for Java version management. Any SDKMAN-compatible version identifier works:

| Suffix | Vendor | Best For |
|--------|--------|----------|
| `-zulu` | Azul Zulu | General use, broad platform support (default) |
| `-tem` | Eclipse Temurin | Vendor-neutral, SDKMAN default |
| `-amzn` | Amazon Corretto | AWS deployments, long-term support |
| `-librca` | BellSoft Liberica | Spring Boot projects |
| `-graalce` | GraalVM CE | Native images, polyglot |
| `-ms` | Microsoft | Azure deployments |
| `-sem` | IBM Semeru | Low memory, fast startup |
| `-sapmchn` | SAP Machine | SAP environments |

### Selecting Java Versions

In the configuration file:

```yaml
languages:
  java:
    enabled: true
    versions:
      - "21.0.6-zulu"
      - "17.0.14-zulu"
      - "8.0.422-zulu"
    default_version: "17.0.14-zulu"
```

Via CLI:

```bash
# Set specific versions
./scripts/configure-deps.sh --set languages.java.versions='["8.0.422-zulu","17.0.14-zulu"]'

# Add a custom version
./scripts/configure-deps.sh --add-java-version "22.0.1-graalce"

# Change default
./scripts/configure-deps.sh --set languages.java.default_version="21.0.6-zulu"
```

## Build Script Integration

### Using build-image.sh

```bash
# Build with default configuration
./scripts/build-image.sh

# Build with a specific profile
./scripts/build-image.sh --profile java-dev

# Build with a custom config file
./scripts/build-image.sh --build-config my-custom-config.yaml

# Preview build without executing
./scripts/build-image.sh --profile minimal --dry-run

# Build with custom image name/tag
./scripts/build-image.sh --profile java-dev --name my-kapsis --tag v1.0
```

### Options

| Option | Description |
|--------|-------------|
| `--profile <name>` | Use a predefined profile |
| `--build-config <file>` | Use a custom configuration file |
| `--dry-run` | Show configuration without building |
| `--name <name>` | Custom image name (default: kapsis-sandbox) |
| `--tag <tag>` | Custom image tag (default: latest) |
| `--no-cache` | Build without Docker cache |
| `--push` | Push to registry after build |

## Creating Custom Profiles

1. Copy an existing profile as a starting point:
   ```bash
   cp configs/build-profiles/java-dev.yaml configs/build-profiles/my-custom.yaml
   ```

2. Edit the new profile:
   ```bash
   vim configs/build-profiles/my-custom.yaml
   ```

3. Use your custom profile:
   ```bash
   ./scripts/build-image.sh --profile my-custom
   ```

### Example: Python + Go Profile

```yaml
version: "1.0"

languages:
  java:
    enabled: false

  nodejs:
    enabled: false

  python:
    enabled: true
    version: "system"
    venv: true
    pip: true

  rust:
    enabled: false

  go:
    enabled: true
    version: "1.22.0"

build_tools:
  maven:
    enabled: false
  gradle:
    enabled: false
  gradle_enterprise:
    enabled: false
  protoc:
    enabled: true
    version: "25.1"

system_packages:
  development:
    enabled: true
  shells:
    enabled: true
  utilities:
    enabled: true
  overlay:
    enabled: true
  custom: []
```

## Image Size Optimization Tips

1. **Start with the smallest profile** that meets your needs
2. **Disable unused languages** - each language adds 200-600MB
3. **Use specific Java versions** - don't install all versions if you only need one
4. **Disable Gradle if using Maven only** - saves ~100MB
5. **Consider the minimal profile** for simple shell tasks

### Size Breakdown (approximate)

| Component | Size Impact |
|-----------|-------------|
| Base Ubuntu | ~300MB |
| Java (per version) | ~200MB |
| Node.js | ~200MB |
| Python | ~100MB |
| Rust | ~400MB |
| Go | ~300MB |
| Maven | ~50MB |
| Gradle | ~100MB |
| Development tools | ~150MB |

## Troubleshooting

### Config Parsing Errors

If you see YAML parsing errors:

```bash
# Validate your config file
yq eval '.' configs/build-config.yaml

# Check for syntax errors
./scripts/configure-deps.sh --dry-run
```

### Build Failures

1. **Missing yq**: Install with `brew install yq` (macOS) or `snap install yq` (Linux)
2. **Invalid profile**: Check available profiles with `./scripts/configure-deps.sh --list-profiles`
3. **Podman issues**: Ensure Podman machine is running on macOS

### Testing Configuration

Run the configuration tests:

```bash
./tests/test-build-config.sh
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KAPSIS_BUILD_CONFIG` | Override config file path | `configs/build-config.yaml` |
| `KAPSIS_DEBUG` | Enable debug output | `false` |

## See Also

- [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) - Complete configuration reference
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture overview
- [README.md](../README.md) - Getting started guide
