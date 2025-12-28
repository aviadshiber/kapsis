Name:           kapsis
Version:        0.8.4  # RELEASE_VERSION_MARKER - Do not remove, used by CI
Release:        1%{?dist}
Summary:        Hermetically isolated AI agent sandbox

License:        MIT
URL:            https://github.com/aviadshiber/kapsis
Source0:        https://github.com/aviadshiber/kapsis/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz

BuildArch:      noarch

Requires:       bash >= 3.2
Requires:       git >= 2.0
Requires:       jq
Requires:       podman >= 4.0
Recommends:     yq

%description
Kapsis is a hermetically isolated AI agent sandbox for running multiple
AI coding agents (Claude Code, Aider, Codex, Gemini) in parallel with
complete isolation via Podman containers and Copy-on-Write filesystems.

Features:
- Multi-agent support with parallel execution
- Podman-based container isolation with rootless execution
- Copy-on-Write filesystem isolation using overlays
- Git worktree integration for parallel branch development
- Maven isolation with snapshot blocking
- Centralized logging and status reporting

%prep
%autosetup -n %{name}-%{version}

%build
# Nothing to build - shell scripts

%install
# Create directories
install -d %{buildroot}%{_bindir}
install -d %{buildroot}%{_libexecdir}/%{name}/scripts
install -d %{buildroot}%{_libexecdir}/%{name}/lib
install -d %{buildroot}%{_datadir}/%{name}/configs/agents
install -d %{buildroot}%{_datadir}/%{name}/maven
install -d %{buildroot}%{_docdir}/%{name}

# Install executable scripts
install -m 755 scripts/launch-agent.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/build-image.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/build-agent-image.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/kapsis-cleanup.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/kapsis-status.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/entrypoint.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/worktree-manager.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/post-container-git.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/post-exit-git.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/preflight-check.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/init-git-branch.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/merge-changes.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 scripts/switch-java.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 setup.sh %{buildroot}%{_libexecdir}/%{name}/scripts/
install -m 755 quick-start.sh %{buildroot}%{_libexecdir}/%{name}/scripts/

# Install library files
install -m 644 scripts/lib/*.sh %{buildroot}%{_libexecdir}/%{name}/lib/

# Install configuration files
install -m 644 agent-sandbox.yaml.template %{buildroot}%{_datadir}/%{name}/
install -m 644 Containerfile %{buildroot}%{_datadir}/%{name}/
install -m 644 configs/*.yaml %{buildroot}%{_datadir}/%{name}/configs/ || true
install -m 644 configs/agents/*.yaml %{buildroot}%{_datadir}/%{name}/configs/agents/
install -m 644 maven/isolated-settings.xml %{buildroot}%{_datadir}/%{name}/maven/

# Install documentation
install -m 644 README.md %{buildroot}%{_docdir}/%{name}/
install -m 644 CHANGELOG.md %{buildroot}%{_docdir}/%{name}/
install -m 644 LICENSE %{buildroot}%{_docdir}/%{name}/

# Create wrapper scripts
cat > %{buildroot}%{_bindir}/kapsis << 'EOF'
#!/bin/bash
export KAPSIS_HOME="%{_datadir}/kapsis"
export KAPSIS_LIB="%{_libexecdir}/kapsis/lib"
export KAPSIS_SCRIPTS="%{_libexecdir}/kapsis/scripts"
exec %{_libexecdir}/kapsis/scripts/launch-agent.sh "$@"
EOF
chmod 755 %{buildroot}%{_bindir}/kapsis

cat > %{buildroot}%{_bindir}/kapsis-build << 'EOF'
#!/bin/bash
export KAPSIS_HOME="%{_datadir}/kapsis"
exec %{_libexecdir}/kapsis/scripts/build-image.sh "$@"
EOF
chmod 755 %{buildroot}%{_bindir}/kapsis-build

cat > %{buildroot}%{_bindir}/kapsis-cleanup << 'EOF'
#!/bin/bash
export KAPSIS_HOME="%{_datadir}/kapsis"
exec %{_libexecdir}/kapsis/scripts/kapsis-cleanup.sh "$@"
EOF
chmod 755 %{buildroot}%{_bindir}/kapsis-cleanup

cat > %{buildroot}%{_bindir}/kapsis-status << 'EOF'
#!/bin/bash
export KAPSIS_HOME="%{_datadir}/kapsis"
exec %{_libexecdir}/kapsis/scripts/kapsis-status.sh "$@"
EOF
chmod 755 %{buildroot}%{_bindir}/kapsis-status

cat > %{buildroot}%{_bindir}/kapsis-setup << 'EOF'
#!/bin/bash
export KAPSIS_HOME="%{_datadir}/kapsis"
exec %{_libexecdir}/kapsis/scripts/setup.sh "$@"
EOF
chmod 755 %{buildroot}%{_bindir}/kapsis-setup

cat > %{buildroot}%{_bindir}/kapsis-quick << 'EOF'
#!/bin/bash
export KAPSIS_HOME="%{_datadir}/kapsis"
exec %{_libexecdir}/kapsis/scripts/quick-start.sh "$@"
EOF
chmod 755 %{buildroot}%{_bindir}/kapsis-quick

%files
%license LICENSE
%doc README.md CHANGELOG.md
%{_bindir}/kapsis
%{_bindir}/kapsis-build
%{_bindir}/kapsis-cleanup
%{_bindir}/kapsis-status
%{_bindir}/kapsis-setup
%{_bindir}/kapsis-quick
%{_libexecdir}/%{name}/
%{_datadir}/%{name}/

%changelog
* Sun Dec 28 2025 Aviad Shiber <aviadshiber@gmail.com> - 0.7.6-1
- Update to v0.7.6
- Fix package versioning to match actual releases

* Wed Dec 24 2025 Aviad Shiber <aviadshiber@gmail.com> - 0.1.0-1
- Initial release
- Multi-agent support: Claude Code, Aider, Codex, Gemini
- Podman-based container isolation with rootless execution
- Copy-on-Write filesystem isolation using overlays
- Git worktree integration for parallel branch development
- Maven isolation with snapshot blocking
- Centralized logging system with multiple log levels
- Status reporting and monitoring CLI
- Cleanup and disk reclamation utilities
