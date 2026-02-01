# Kapsis - Hermetically Isolated AI Agent Sandbox
#
# Multi-stage build with configurable dependencies.
#
# Build:
#   ./scripts/build-image.sh                          # Default (full-stack)
#   ./scripts/build-image.sh --profile java-dev       # Java development
#   ./scripts/build-image.sh --profile minimal        # Minimal image
#   ./scripts/build-image.sh --build-config custom.yaml
#
# Manual build with all defaults:
#   podman build -t kapsis-sandbox -f Containerfile .

#===============================================================================
# BUILD ARGUMENTS
#===============================================================================
# Security: Pin base image to specific digest for supply chain integrity
ARG BASE_IMAGE_DIGEST=sha256:955364933d0d91afa6e10fb045948c16d2b191114aa54bed3ab5430d8bbc58cc

# Language toggles (set by build-image.sh from build-config.yaml)
ARG ENABLE_JAVA=true
ARG ENABLE_NODEJS=true
ARG ENABLE_PYTHON=true
ARG ENABLE_RUST=false
ARG ENABLE_GO=false

# Java configuration
ARG JAVA_VERSIONS='["17.0.14-zulu","8.0.422-zulu"]'
ARG JAVA_DEFAULT="17.0.14-zulu"

# Node.js configuration
ARG NODE_VERSION=18.18.0

# Rust configuration
ARG RUST_CHANNEL=stable

# Go configuration
ARG GO_VERSION=1.22.0

# Build tool toggles
ARG ENABLE_MAVEN=true
ARG ENABLE_GRADLE=false
ARG ENABLE_GRADLE_ENTERPRISE=true
ARG ENABLE_PROTOC=true

# Build tool versions
ARG MAVEN_VERSION=3.9.9
ARG GRADLE_VERSION=8.5
ARG GE_EXT_VERSION=1.20
ARG GE_CCUD_VERSION=1.12.5
ARG PROTOC_VERSION=25.1

# System package toggles
ARG ENABLE_DEV_TOOLS=true
ARG ENABLE_SHELLS=true
ARG ENABLE_UTILITIES=true
ARG ENABLE_OVERLAY=true
ARG CUSTOM_PACKAGES=""

# yq configuration (required for Kapsis)
ARG YQ_VERSION=4.44.3
ARG YQ_SHA256=a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7

# User configuration
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=developer

# Agent installation (for agent-specific images)
ARG AGENT_NPM=""
ARG AGENT_PIP=""
ARG AGENT_SCRIPT=""

#===============================================================================
# STAGE: base - Essential packages only
#===============================================================================
FROM ubuntu@${BASE_IMAGE_DIGEST} AS base

LABEL maintainer="Kapsis Project"
LABEL description="Hermetically isolated sandbox for AI coding agents"
LABEL org.opencontainers.image.base.name="ubuntu:24.04"

ENV DEBIAN_FRONTEND=noninteractive

# Essential packages (always installed)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    jq \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

#===============================================================================
# STAGE: system-packages - Conditional system packages
#===============================================================================
FROM base AS system-packages

ARG ENABLE_DEV_TOOLS
ARG ENABLE_SHELLS
ARG ENABLE_UTILITIES
ARG ENABLE_OVERLAY
ARG ENABLE_PYTHON
ARG CUSTOM_PACKAGES

# Development tools (build-essential, ripgrep, fd-find)
RUN if [ "$ENABLE_DEV_TOOLS" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            build-essential \
            ripgrep \
            fd-find && \
        ln -sf /usr/bin/fdfind /usr/bin/fd && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Shell environments
RUN if [ "$ENABLE_SHELLS" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            bash \
            zsh && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# System utilities
RUN if [ "$ENABLE_UTILITIES" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            procps \
            htop \
            less \
            vim-tiny \
            netcat-openbsd \
            dnsutils \
            dnsmasq && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Filesystem overlay (required for macOS CoW support)
RUN if [ "$ENABLE_OVERLAY" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            fuse-overlayfs \
            fuse3 && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Python (used for build scripts and some agents)
RUN if [ "$ENABLE_PYTHON" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            python3 \
            python3-pip \
            python3-venv && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Custom packages
RUN if [ -n "$CUSTOM_PACKAGES" ]; then \
        apt-get update && apt-get install -y --no-install-recommends $CUSTOM_PACKAGES && \
        rm -rf /var/lib/apt/lists/*; \
    fi

#===============================================================================
# STAGE: yq-installer - Install yq (required for Kapsis)
#===============================================================================
FROM base AS yq-installer

ARG YQ_VERSION
ARG YQ_SHA256
ARG TARGETARCH

RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
    wget -qO /tmp/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" && \
    if [ -n "$YQ_SHA256" ] && [ "$ARCH" = "amd64" ]; then \
        echo "${YQ_SHA256}  /tmp/yq" | sha256sum -c - || \
        { echo "WARNING: yq checksum mismatch - script may have been updated."; }; \
    fi && \
    mv /tmp/yq /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

#===============================================================================
# STAGE: java-installer - Install Java via SDKMAN (conditional)
#===============================================================================
FROM base AS java-installer

ARG ENABLE_JAVA
ARG JAVA_VERSIONS
ARG JAVA_DEFAULT
ARG ENABLE_MAVEN
ARG MAVEN_VERSION

ENV SDKMAN_DIR=/opt/sdkman

# Install SDKMAN and Java versions
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
        curl -sL "https://get.sdkman.io?rcupdate=false" -o /tmp/sdkman-install.sh && \
        bash /tmp/sdkman-install.sh && \
        rm -f /tmp/sdkman-install.sh && \
        # Parse JSON array and install each version
        bash -c 'source $SDKMAN_DIR/bin/sdkman-init.sh && \
            for version in $(echo '"'"''"$JAVA_VERSIONS"''"'"' | jq -r ".[]" 2>/dev/null || echo "17.0.14-zulu 8.0.422-zulu"); do \
                echo "Installing Java $version..." && \
                sdk install java $version || true; \
            done && \
            sdk default java '"$JAVA_DEFAULT"''; \
    else \
        mkdir -p /opt/sdkman; \
    fi

# Install Maven (requires Java)
RUN if [ "$ENABLE_JAVA" = "true" ] && [ "$ENABLE_MAVEN" = "true" ]; then \
        bash -c 'source $SDKMAN_DIR/bin/sdkman-init.sh && \
            sdk install maven '"$MAVEN_VERSION"''; \
    fi

#===============================================================================
# STAGE: nodejs-installer - Install Node.js via NVM (conditional)
#===============================================================================
FROM base AS nodejs-installer

ARG ENABLE_NODEJS
ARG NODE_VERSION

ENV NVM_DIR=/opt/nvm

RUN if [ "$ENABLE_NODEJS" = "true" ]; then \
        mkdir -p $NVM_DIR && \
        curl -sL "https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh" -o /tmp/nvm-install.sh && \
        bash /tmp/nvm-install.sh && \
        rm -f /tmp/nvm-install.sh && \
        bash -c 'source $NVM_DIR/nvm.sh && \
            nvm install '"$NODE_VERSION"' && \
            nvm alias default '"$NODE_VERSION"' && \
            nvm use default && \
            npm install -g pnpm@9.15.3'; \
    else \
        mkdir -p /opt/nvm; \
    fi

#===============================================================================
# STAGE: rust-installer - Install Rust via rustup (conditional)
#===============================================================================
FROM base AS rust-installer

ARG ENABLE_RUST
ARG RUST_CHANNEL

ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo

RUN if [ "$ENABLE_RUST" = "true" ]; then \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
            sh -s -- -y --default-toolchain "$RUST_CHANNEL" --profile minimal && \
        . /opt/cargo/env && \
        rustup component add rustfmt clippy; \
    else \
        mkdir -p /opt/rustup /opt/cargo; \
    fi

#===============================================================================
# STAGE: go-installer - Install Go (conditional)
#===============================================================================
FROM base AS go-installer

ARG ENABLE_GO
ARG GO_VERSION
ARG TARGETARCH

RUN if [ "$ENABLE_GO" = "true" ]; then \
        ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
        curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /opt -xz; \
    else \
        mkdir -p /opt/go; \
    fi

#===============================================================================
# STAGE: ge-cache - Pre-cache Gradle Enterprise extensions (conditional)
#===============================================================================
FROM java-installer AS ge-cache

ARG ENABLE_JAVA
ARG ENABLE_GRADLE_ENTERPRISE
ARG GE_EXT_VERSION
ARG GE_CCUD_VERSION

ENV SDKMAN_DIR=/opt/sdkman

RUN mkdir -p /opt/kapsis/m2-cache && \
    if [ "$ENABLE_JAVA" = "true" ] && [ "$ENABLE_GRADLE_ENTERPRISE" = "true" ]; then \
        mkdir -p /tmp/ge-cache && cd /tmp/ge-cache && \
        echo '<?xml version="1.0" encoding="UTF-8"?>' > pom.xml && \
        echo '<project><modelVersion>4.0.0</modelVersion>' >> pom.xml && \
        echo '<groupId>kapsis</groupId><artifactId>ge-cache</artifactId><version>1.0</version>' >> pom.xml && \
        echo '<dependencies>' >> pom.xml && \
        echo "  <dependency><groupId>com.gradle</groupId><artifactId>gradle-enterprise-maven-extension</artifactId><version>${GE_EXT_VERSION}</version></dependency>" >> pom.xml && \
        echo "  <dependency><groupId>com.gradle</groupId><artifactId>common-custom-user-data-maven-extension</artifactId><version>${GE_CCUD_VERSION}</version></dependency>" >> pom.xml && \
        echo '</dependencies></project>' >> pom.xml && \
        bash -c 'source $SDKMAN_DIR/bin/sdkman-init.sh && \
            mvn -B dependency:resolve dependency:resolve-plugins -Dmaven.repo.local=/opt/kapsis/m2-cache' && \
        find /opt/kapsis/m2-cache -name "_remote.repositories" -delete && \
        rm -rf /tmp/ge-cache; \
    fi

#===============================================================================
# STAGE: protoc-cache - Pre-cache protoc binaries (conditional)
#===============================================================================
FROM java-installer AS protoc-cache

ARG ENABLE_JAVA
ARG ENABLE_PROTOC
ARG PROTOC_VERSION

ENV SDKMAN_DIR=/opt/sdkman

RUN mkdir -p /opt/kapsis/m2-protoc && \
    if [ "$ENABLE_JAVA" = "true" ] && [ "$ENABLE_PROTOC" = "true" ]; then \
        mkdir -p /tmp/protoc-cache && cd /tmp/protoc-cache && \
        echo '<?xml version="1.0" encoding="UTF-8"?>' > pom.xml && \
        echo '<project><modelVersion>4.0.0</modelVersion>' >> pom.xml && \
        echo '<groupId>kapsis</groupId><artifactId>protoc-cache</artifactId><version>1.0</version>' >> pom.xml && \
        echo '<dependencies>' >> pom.xml && \
        echo "  <dependency><groupId>com.google.protobuf</groupId><artifactId>protoc</artifactId><version>${PROTOC_VERSION}</version><classifier>linux-x86_64</classifier><type>exe</type></dependency>" >> pom.xml && \
        echo "  <dependency><groupId>com.google.protobuf</groupId><artifactId>protoc</artifactId><version>${PROTOC_VERSION}</version><classifier>linux-aarch_64</classifier><type>exe</type></dependency>" >> pom.xml && \
        echo '</dependencies></project>' >> pom.xml && \
        bash -c 'source $SDKMAN_DIR/bin/sdkman-init.sh && \
            mvn -B dependency:resolve -Dmaven.repo.local=/opt/kapsis/m2-protoc -DincludeScope=runtime' 2>/dev/null || true && \
        find /opt/kapsis/m2-protoc -name "protoc-*" -type f -exec chmod +x {} \; && \
        find /opt/kapsis/m2-protoc -name "_remote.repositories" -delete && \
        rm -rf /tmp/protoc-cache; \
    fi

#===============================================================================
# STAGE: final - Combine all components
#===============================================================================
FROM system-packages AS final

ARG ENABLE_JAVA
ARG ENABLE_NODEJS
ARG ENABLE_RUST
ARG ENABLE_GO
ARG NODE_VERSION
ARG USER_ID
ARG GROUP_ID
ARG USERNAME
ARG AGENT_NPM
ARG AGENT_PIP
ARG AGENT_SCRIPT

# Copy yq (always required)
COPY --from=yq-installer /usr/local/bin/yq /usr/local/bin/yq

# Copy Java/SDKMAN (conditional - directories exist even if empty)
COPY --from=java-installer /opt/sdkman /opt/sdkman

# Copy Node.js/NVM (conditional)
COPY --from=nodejs-installer /opt/nvm /opt/nvm

# Copy Rust (conditional)
COPY --from=rust-installer /opt/rustup /opt/rustup
COPY --from=rust-installer /opt/cargo /opt/cargo

# Copy Go (conditional)
COPY --from=go-installer /opt/go /opt/go

# Copy GE cache
COPY --from=ge-cache /opt/kapsis/m2-cache /opt/kapsis/m2-cache

# Copy protoc cache (merge with GE cache)
COPY --from=protoc-cache /opt/kapsis/m2-protoc /opt/kapsis/m2-cache

# Set up environment variables
ENV SDKMAN_DIR=/opt/sdkman
ENV NVM_DIR=/opt/nvm
ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
ENV GOROOT=/opt/go
ENV GOPATH=/home/${USERNAME}/go

# Configure Java environment (conditional)
RUN if [ "$ENABLE_JAVA" = "true" ] && [ -f "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then \
        echo 'export JAVA_HOME=/opt/sdkman/candidates/java/current' >> /etc/profile.d/kapsis-java.sh && \
        echo 'export MAVEN_HOME=/opt/sdkman/candidates/maven/current' >> /etc/profile.d/kapsis-java.sh && \
        echo 'export PATH=$JAVA_HOME/bin:$MAVEN_HOME/bin:$PATH' >> /etc/profile.d/kapsis-java.sh && \
        chmod +x /etc/profile.d/kapsis-java.sh; \
    fi

# Configure Node.js environment (conditional)
RUN if [ "$ENABLE_NODEJS" = "true" ] && [ -d "$NVM_DIR/versions/node" ]; then \
        echo "export PATH=$NVM_DIR/versions/node/v${NODE_VERSION}/bin:\$PATH" >> /etc/profile.d/kapsis-nodejs.sh && \
        chmod +x /etc/profile.d/kapsis-nodejs.sh; \
    fi

# Configure Rust environment (conditional)
RUN if [ "$ENABLE_RUST" = "true" ] && [ -f "$CARGO_HOME/env" ]; then \
        echo 'source $CARGO_HOME/env' >> /etc/profile.d/kapsis-rust.sh && \
        chmod +x /etc/profile.d/kapsis-rust.sh; \
    fi

# Configure Go environment (conditional)
RUN if [ "$ENABLE_GO" = "true" ] && [ -d "/opt/go/bin" ]; then \
        echo 'export PATH=/opt/go/bin:$GOPATH/bin:$PATH' >> /etc/profile.d/kapsis-go.sh && \
        chmod +x /etc/profile.d/kapsis-go.sh; \
    fi

# Install npm-based agents (Claude Code, etc.) - conditional
RUN if [ -n "$AGENT_NPM" ] && [ "$ENABLE_NODEJS" = "true" ]; then \
        bash -c 'source $NVM_DIR/nvm.sh && npm install -g $AGENT_NPM'; \
    fi

# Install pip-based agents (Anthropic SDK, Aider, etc.) - conditional
RUN if [ -n "$AGENT_PIP" ]; then \
        pip3 install --no-cache-dir $AGENT_PIP || true; \
    fi

# Install script-based agents (Claude native installer, etc.) - conditional
# The script runs as root, binary is copied to /usr/local/bin for system-wide access
# Note: Must use 'cp -L' to follow symlinks - Claude installer creates symlink at ~/.local/bin/claude
#       pointing to actual binary in ~/.local/share/claude/versions/X.X.X
RUN if [ -n "$AGENT_SCRIPT" ]; then \
        echo "Running agent install script: $AGENT_SCRIPT" && \
        bash -c "$AGENT_SCRIPT" && \
        if [ -f "$HOME/.local/bin/claude" ] || [ -L "$HOME/.local/bin/claude" ]; then \
            echo "Copying claude to /usr/local/bin/ (following symlink)" && \
            cp -L "$HOME/.local/bin/claude" /usr/local/bin/claude && \
            chmod +x /usr/local/bin/claude && \
            rm -rf "$HOME/.local/bin/claude" "$HOME/.local/share/claude" && \
            echo "Claude installed at /usr/local/bin/claude"; \
        else \
            echo "WARNING: claude binary not found at $HOME/.local/bin/claude"; \
        fi; \
    fi

#===============================================================================
# NON-ROOT USER SETUP
#===============================================================================
# Remove existing ubuntu user/group (Ubuntu 24.04 has UID/GID 1000 taken)
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true && \
    groupadd -g ${GROUP_ID} ${USERNAME} && \
    useradd -m -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash ${USERNAME}

# Create directories with correct ownership
RUN mkdir -p /home/${USERNAME}/.m2/repository \
             /home/${USERNAME}/.gradle \
             /home/${USERNAME}/.m2/.gradle-enterprise \
             /home/${USERNAME}/go \
             /workspace && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /workspace

#===============================================================================
# KAPSIS SCRIPTS AND CONFIGURATION
#===============================================================================
# Copy isolated Maven settings
COPY maven/isolated-settings.xml /opt/kapsis/maven/settings.xml

# Create lib directory and copy libraries
RUN mkdir -p /opt/kapsis/lib
COPY scripts/lib/constants.sh /opt/kapsis/lib/constants.sh
COPY scripts/lib/logging.sh /opt/kapsis/lib/logging.sh
COPY scripts/lib/status.sh /opt/kapsis/lib/status.sh
COPY scripts/lib/agent-types.sh /opt/kapsis/lib/agent-types.sh
COPY scripts/lib/progress-monitor.sh /opt/kapsis/lib/progress-monitor.sh
COPY scripts/lib/progress-instructions.md /opt/kapsis/lib/progress-instructions.md
COPY scripts/lib/status.py /opt/kapsis/lib/status.py
COPY scripts/lib/inject-status-hooks.sh /opt/kapsis/lib/inject-status-hooks.sh
COPY scripts/lib/dns-filter.sh /opt/kapsis/lib/dns-filter.sh

# Create hooks directory and copy status tracking hooks
RUN mkdir -p /opt/kapsis/hooks/agent-adapters
COPY scripts/hooks/kapsis-status-hook.sh /opt/kapsis/hooks/kapsis-status-hook.sh
COPY scripts/hooks/kapsis-stop-hook.sh /opt/kapsis/hooks/kapsis-stop-hook.sh
COPY scripts/hooks/tool-phase-mapping.sh /opt/kapsis/hooks/tool-phase-mapping.sh
COPY scripts/hooks/agent-adapters/claude-adapter.sh /opt/kapsis/hooks/agent-adapters/claude-adapter.sh
COPY scripts/hooks/agent-adapters/codex-adapter.sh /opt/kapsis/hooks/agent-adapters/codex-adapter.sh
COPY scripts/hooks/agent-adapters/gemini-adapter.sh /opt/kapsis/hooks/agent-adapters/gemini-adapter.sh

# Copy entrypoint and helper scripts
COPY scripts/entrypoint.sh /opt/kapsis/entrypoint.sh
COPY scripts/init-git-branch.sh /opt/kapsis/init-git-branch.sh
COPY scripts/post-exit-git.sh /opt/kapsis/post-exit-git.sh
COPY scripts/switch-java.sh /opt/kapsis/switch-java.sh

# Create agents directory for custom agent wrapper scripts
RUN mkdir -p /opt/kapsis/agents && chown ${USER_ID}:${GROUP_ID} /opt/kapsis/agents

# Make all scripts executable and readable
RUN chmod 755 /opt/kapsis/*.sh /opt/kapsis/lib/*.sh /opt/kapsis/lib/status.py && \
    chmod 755 /opt/kapsis/hooks/*.sh /opt/kapsis/hooks/agent-adapters/*.sh && \
    chmod 644 /opt/kapsis/maven/settings.xml /opt/kapsis/lib/progress-instructions.md

#===============================================================================
# ENVIRONMENT CONFIGURATION
#===============================================================================
ENV KAPSIS_HOME=/opt/kapsis
ENV MAVEN_SETTINGS=/opt/kapsis/maven/settings.xml
ENV WORKSPACE=/workspace

# Source environment scripts in user's bashrc
# Note: SDKMAN and NVM scripts reference variables like ZSH_VERSION that may be unset.
# We wrap with 'set +u' to handle strict mode inherited from parent shells.
RUN echo '[ -f /etc/profile.d/kapsis-java.sh ] && source /etc/profile.d/kapsis-java.sh' >> /home/${USERNAME}/.bashrc && \
    echo '[ -f /etc/profile.d/kapsis-nodejs.sh ] && source /etc/profile.d/kapsis-nodejs.sh' >> /home/${USERNAME}/.bashrc && \
    echo '[ -f /etc/profile.d/kapsis-rust.sh ] && source /etc/profile.d/kapsis-rust.sh' >> /home/${USERNAME}/.bashrc && \
    echo '[ -f /etc/profile.d/kapsis-go.sh ] && source /etc/profile.d/kapsis-go.sh' >> /home/${USERNAME}/.bashrc && \
    echo '[ -f $SDKMAN_DIR/bin/sdkman-init.sh ] && { set +u 2>/dev/null; source $SDKMAN_DIR/bin/sdkman-init.sh; } || true' >> /home/${USERNAME}/.bashrc && \
    echo '[ -f $NVM_DIR/nvm.sh ] && { set +u 2>/dev/null; source $NVM_DIR/nvm.sh; } || true' >> /home/${USERNAME}/.bashrc

#===============================================================================
# RUNTIME CONFIGURATION
#===============================================================================
USER ${USERNAME}
WORKDIR /workspace

# Use custom entrypoint for initialization
ENTRYPOINT ["/opt/kapsis/entrypoint.sh"]

# Default command (can be overridden)
CMD ["bash"]
