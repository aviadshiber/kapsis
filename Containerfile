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
    yq \
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

#===============================================================================
# JAVA INSTALLATION (SDKMAN for multiple versions)
#===============================================================================
ENV SDKMAN_DIR=/opt/sdkman
RUN curl -s "https://get.sdkman.io?rcupdate=false" | bash

# Install Java 17 (default) and Java 8
RUN bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
    sdk install java 17.0.9-tem && \
    sdk install java 8.0.392-tem && \
    sdk default java 17.0.9-tem"

# Set Java environment
ENV JAVA_HOME=/opt/sdkman/candidates/java/current
ENV PATH=$JAVA_HOME/bin:$PATH

#===============================================================================
# MAVEN INSTALLATION
#===============================================================================
ARG MAVEN_VERSION=3.9.11
ENV MAVEN_HOME=/opt/maven
ENV PATH=$MAVEN_HOME/bin:$PATH

RUN mkdir -p ${MAVEN_HOME} && \
    curl -fsSL https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
    | tar xzf - -C ${MAVEN_HOME} --strip-components=1

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
# AI AGENT CLI TOOLS (Optional - can be mounted from host)
#===============================================================================
# Claude Code - install if ANTHROPIC_API_KEY will be available
# RUN bash -c "source $NVM_DIR/nvm.sh && npm install -g @anthropic-ai/claude-code"

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

# Copy entrypoint and helper scripts
COPY scripts/entrypoint.sh /opt/kapsis/entrypoint.sh
COPY scripts/init-git-branch.sh /opt/kapsis/init-git-branch.sh
COPY scripts/post-exit-git.sh /opt/kapsis/post-exit-git.sh
COPY scripts/switch-java.sh /opt/kapsis/switch-java.sh

RUN chmod +x /opt/kapsis/*.sh

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
