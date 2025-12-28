# Kapsis Package Repository

This branch hosts APT and RPM package repositories for Kapsis.

## APT (Debian/Ubuntu)

```bash
# Add GPG key
curl -fsSL https://aviadshiber.github.io/kapsis/gpg/kapsis.asc | sudo gpg --dearmor -o /etc/apt/keyrings/kapsis.gpg

# Add repository
echo "deb [signed-by=/etc/apt/keyrings/kapsis.gpg] https://aviadshiber.github.io/kapsis/apt stable main" | sudo tee /etc/apt/sources.list.d/kapsis.list

# Install
sudo apt update
sudo apt install kapsis
```

## RPM (Fedora/RHEL/CentOS)

```bash
# Add repository
sudo tee /etc/yum.repos.d/kapsis.repo <<EOF
[kapsis]
name=Kapsis Repository
baseurl=https://aviadshiber.github.io/kapsis/rpm/packages
enabled=1
gpgcheck=1
gpgkey=https://aviadshiber.github.io/kapsis/gpg/kapsis.asc
EOF

# Install
sudo dnf install kapsis
```

## Homebrew (macOS/Linux)

```bash
brew tap aviadshiber/kapsis
brew install kapsis
```
