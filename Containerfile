# Kapsis - Hermetically Isolated AI Agent Sandbox
# Build: podman build -t kapsis-sandbox -f Containerfile .

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

LABEL maintainer="Kapsis Project"
LABEL description="Hermetically isolated sandbox for AI coding agents"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essential tools
    curl \
    wget \
    git \
    jq \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    # Development tools
    build-essential \
    # Search tools
    ripgrep \
    fd-find \
    # Python (for build scripts)
    python3 \
    python3-pip \
    python3-venv \
    # Shell
    bash \
    zsh \
    # Networking tools
    netcat-openbsd \
    dnsutils \
    # Process tools
    procps \
    htop \
    # Text processing
    less \
    vim-tiny \
    # Filesystem overlay (for macOS CoW support)
    fuse-overlayfs \
    fuse3 \
    && rm -rf /var/lib/apt/lists/*

# Create symlinks for common tool names
RUN ln -sf /usr/bin/fdfind /usr/bin/fd

# Install yq (Mike Farah's yq) - not available in Ubuntu 24.04 apt repos
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

#===============================================================================
# JAVA INSTALLATION (SDKMAN for multiple versions)
#===============================================================================
ENV SDKMAN_DIR=/opt/sdkman
RUN curl -s "https://get.sdkman.io?rcupdate=false" | bash

# Install Java 17 (default), Java 8, and Maven via SDKMAN
# Using SDKMAN for Maven provides reliable downloads (archive.apache.org is often slow/unreliable)
# Note: Use current SDKMAN versions - check with 'sdk list java' or 'sdk list maven' if build fails
ARG MAVEN_VERSION=3.9.9
RUN bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
    sdk install java 17.0.17-tem && \
    sdk install java 8.0.472-tem && \
    sdk default java 17.0.17-tem && \
    sdk install maven ${MAVEN_VERSION}"

# Set Java and Maven environment
ENV JAVA_HOME=/opt/sdkman/candidates/java/current
ENV MAVEN_HOME=/opt/sdkman/candidates/maven/current
ENV PATH=$JAVA_HOME/bin:$MAVEN_HOME/bin:$PATH

#===============================================================================
# NODE.JS INSTALLATION (for Claude Code and frontend builds)
#===============================================================================
ARG NODE_VERSION=18.18.0
ENV NVM_DIR=/opt/nvm
ENV PATH=$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH

RUN mkdir -p $NVM_DIR && \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
        nvm install ${NODE_VERSION} && \
        nvm alias default ${NODE_VERSION} && \
        nvm use default && \
        npm install -g pnpm@9.15.3"

#===============================================================================
# AI AGENT CLI TOOLS (Build-time installation)
#===============================================================================
# Agents can be installed at build time via build args.
# This creates agent-specific images (e.g., kapsis-claude:latest)
#
# Usage:
#   podman build --build-arg AGENT_NPM="@anthropic-ai/claude-code" -t kapsis-claude .
#   podman build --build-arg AGENT_PIP="anthropic aider-chat" -t kapsis-aider .

ARG AGENT_NPM=""
ARG AGENT_PIP=""

# Install npm-based agents (Claude Code, etc.)
RUN if [ -n "$AGENT_NPM" ]; then \
        bash -c "source $NVM_DIR/nvm.sh && npm install -g $AGENT_NPM"; \
    fi

# Install pip-based agents (Anthropic SDK, Aider, etc.)
RUN if [ -n "$AGENT_PIP" ]; then \
        pip3 install --no-cache-dir $AGENT_PIP; \
    fi

#===============================================================================
# PRE-CACHE GRADLE ENTERPRISE EXTENSION
#===============================================================================
# GE extension resolves BEFORE settings.xml, so it can't use our mirror/auth.
# Pre-download to local repo during build so it's available at runtime.
# These artifacts are on Maven Central (public).
ARG GE_EXT_VERSION=1.20
ARG GE_CCUD_VERSION=1.12.5

RUN mkdir -p /tmp/ge-cache && cd /tmp/ge-cache && \
    # Create minimal pom to resolve the extensions
    echo '<?xml version="1.0" encoding="UTF-8"?>' > pom.xml && \
    echo '<project><modelVersion>4.0.0</modelVersion>' >> pom.xml && \
    echo '<groupId>kapsis</groupId><artifactId>ge-cache</artifactId><version>1.0</version>' >> pom.xml && \
    echo '<dependencies>' >> pom.xml && \
    echo "  <dependency><groupId>com.gradle</groupId><artifactId>gradle-enterprise-maven-extension</artifactId><version>${GE_EXT_VERSION}</version></dependency>" >> pom.xml && \
    echo "  <dependency><groupId>com.gradle</groupId><artifactId>common-custom-user-data-maven-extension</artifactId><version>${GE_CCUD_VERSION}</version></dependency>" >> pom.xml && \
    echo '</dependencies></project>' >> pom.xml && \
    # Download to global location that will be copied to user's .m2 later
    mvn -B dependency:resolve dependency:resolve-plugins -Dmaven.repo.local=/opt/kapsis/m2-cache && \
    # Remove _remote.repositories tracking files to prevent repository ID validation errors
    # These files cause "cached from a remote repository ID that is unavailable" errors
    find /opt/kapsis/m2-cache -name "_remote.repositories" -delete && \
    rm -rf /tmp/ge-cache

#===============================================================================
# NON-ROOT USER SETUP
#===============================================================================
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=developer

# Remove existing ubuntu user/group (Ubuntu 24.04 has UID/GID 1000 taken)
# Then create our developer user with the requested UID/GID
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true && \
    groupadd -g ${GROUP_ID} ${USERNAME} && \
    useradd -m -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash ${USERNAME}

# Create directories for Maven and Gradle with correct ownership
# Note: .m2/repository is mounted as a named volume at runtime, so we don't pre-populate here.
# The entrypoint.sh copies pre-cached GE extensions from /opt/kapsis/m2-cache at startup.
RUN mkdir -p /home/${USERNAME}/.m2/repository \
             /home/${USERNAME}/.gradle \
             /home/${USERNAME}/.m2/.gradle-enterprise \
             /workspace && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /workspace

#===============================================================================
# ISOLATION CONFIGURATION FILES
#===============================================================================
# Copy isolated Maven settings (blocks SNAPSHOTs and deploy)
COPY maven/isolated-settings.xml /opt/kapsis/maven/settings.xml

# Create lib directory and copy libraries
RUN mkdir -p /opt/kapsis/lib
COPY scripts/lib/logging.sh /opt/kapsis/lib/logging.sh
COPY scripts/lib/status.sh /opt/kapsis/lib/status.sh

# Copy entrypoint and helper scripts
COPY scripts/entrypoint.sh /opt/kapsis/entrypoint.sh
COPY scripts/init-git-branch.sh /opt/kapsis/init-git-branch.sh
COPY scripts/post-exit-git.sh /opt/kapsis/post-exit-git.sh
COPY scripts/switch-java.sh /opt/kapsis/switch-java.sh

# Create agents directory for custom agent wrapper scripts
RUN mkdir -p /opt/kapsis/agents && chown ${USER_ID}:${GROUP_ID} /opt/kapsis/agents

# Make all scripts executable and readable
RUN chmod 755 /opt/kapsis/*.sh /opt/kapsis/lib/*.sh && \
    chmod 644 /opt/kapsis/maven/settings.xml

#===============================================================================
# ENVIRONMENT CONFIGURATION
#===============================================================================
ENV KAPSIS_HOME=/opt/kapsis
ENV MAVEN_SETTINGS=/opt/kapsis/maven/settings.xml
ENV WORKSPACE=/workspace

# Source SDKMAN and NVM in bash profile
RUN echo 'source $SDKMAN_DIR/bin/sdkman-init.sh' >> /home/${USERNAME}/.bashrc && \
    echo 'source $NVM_DIR/nvm.sh' >> /home/${USERNAME}/.bashrc && \
    echo 'export PATH=$JAVA_HOME/bin:$MAVEN_HOME/bin:$PATH' >> /home/${USERNAME}/.bashrc

#===============================================================================
# RUNTIME CONFIGURATION
#===============================================================================
USER ${USERNAME}
WORKDIR /workspace

# Use custom entrypoint for initialization
ENTRYPOINT ["/opt/kapsis/entrypoint.sh"]

# Default command (can be overridden)
CMD ["bash"]
