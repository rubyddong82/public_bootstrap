#!/usr/bin/env bash
set -Eeuo pipefail

GITHUB_SSH_OK=0
INSTALL_DESKTOP_APPS="${INSTALL_DESKTOP_APPS:-auto}"

log_step() {
    printf '\n==> %s\n' "$1"
}

log_info() {
    printf '    %s\n' "$1"
}

die() {
    printf '\nERROR: %s\n' "$1" >&2
    exit 1
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

is_wsl() {
    if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ]; then
        return 0
    fi

    grep -qi microsoft /proc/version 2>/dev/null
}

should_install_desktop_apps() {
    case "$INSTALL_DESKTOP_APPS" in
        1|true|yes|on)
            return 0
            ;;
        0|false|no|off)
            return 1
            ;;
        auto)
            if is_wsl; then
                return 1
            fi
            return 0
            ;;
        *)
            die "INSTALL_DESKTOP_APPS must be auto, true, or false."
            ;;
    esac
}

as_root() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_sudo() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        return
    fi

    has_command sudo || die "sudo is required for package installation."
    sudo -v
}

install_with_apt() {
    ensure_sudo
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates git gpg

    if has_command gh; then
        return
    fi

    log_info "Installing GitHub CLI from the official apt repository."
    as_root mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
        as_root tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    as_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    as_root mkdir -p -m 755 /etc/apt/sources.list.d
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$(dpkg --print-architecture)" |
        as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y gh
}

install_with_dnf() {
    ensure_sudo
    as_root dnf install -y git curl gh
}

install_with_yum() {
    ensure_sudo
    as_root yum install -y git curl yum-utils

    if ! has_command gh; then
        as_root yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
        as_root yum install -y gh
    fi
}

install_with_pacman() {
    ensure_sudo
    as_root pacman -Sy --needed --noconfirm git curl github-cli
}

install_with_zypper() {
    ensure_sudo
    as_root zypper --non-interactive install git curl gh
}

install_with_brew() {
    brew install git gh
}

is_vscode_installed() {
    has_command code
}

is_chrome_installed() {
    has_command google-chrome || has_command google-chrome-stable
}

is_obsidian_installed() {
    has_command obsidian || [ -x /usr/bin/obsidian ] || [ -x /opt/Obsidian/obsidian ]
}

install_vscode_apt() {
    if is_vscode_installed; then
        log_info "Visual Studio Code is already installed."
        return
    fi

    log_info "Installing Visual Studio Code from the official Microsoft apt repository."
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y gpg
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
        gpg --dearmor |
        as_root tee /usr/share/keyrings/microsoft.gpg >/dev/null
    cat <<'EOF' | as_root tee /etc/apt/sources.list.d/vscode.sources >/dev/null
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y code
}

install_chrome_apt() {
    if is_chrome_installed; then
        log_info "Google Chrome is already installed."
        return
    fi

    local arch
    arch="$(dpkg --print-architecture)"
    if [ "$arch" != "amd64" ]; then
        log_info "Google Chrome automatic install is skipped on apt architecture $arch."
        return
    fi

    log_info "Installing Google Chrome from Google's Debian package."
    local deb_path
    deb_path="$(mktemp --suffix=.deb)"
    curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o "$deb_path"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_path"
    rm -f "$deb_path"
}

get_latest_obsidian_deb_url() {
    curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest |
        sed -n 's/.*"browser_download_url": "\(https:.*obsidian_[^"]*_amd64\.deb\)".*/\1/p' |
        head -n 1
}

install_obsidian_apt() {
    if is_obsidian_installed; then
        log_info "Obsidian is already installed."
        return
    fi

    local arch
    arch="$(dpkg --print-architecture)"
    if [ "$arch" != "amd64" ]; then
        log_info "Obsidian automatic install is skipped on apt architecture $arch."
        return
    fi

    log_info "Installing Obsidian from the official GitHub release .deb."
    local deb_url=""
    if ! deb_url="$(get_latest_obsidian_deb_url)"; then
        log_info "Could not query the latest Obsidian release. Skipping Obsidian."
        return
    fi

    if [ -z "$deb_url" ]; then
        log_info "Could not find an Obsidian .deb download URL. Skipping Obsidian."
        return
    fi

    local deb_path
    deb_path="$(mktemp --suffix=.deb)"
    if ! curl -fsSL "$deb_url" -o "$deb_path"; then
        log_info "Could not download the Obsidian .deb. Skipping Obsidian."
        rm -f "$deb_path"
        return
    fi

    if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_path"; then
        log_info "Could not install the Obsidian .deb. Skipping Obsidian."
        rm -f "$deb_path"
        return
    fi

    rm -f "$deb_path"
}

install_vscode_rpm_repo() {
    if is_vscode_installed; then
        log_info "Visual Studio Code is already installed."
        return
    fi

    log_info "Installing Visual Studio Code from the official Microsoft RPM repository."
    as_root rpm --import https://packages.microsoft.com/keys/microsoft.asc
    cat <<'EOF' | as_root tee /etc/yum.repos.d/vscode.repo >/dev/null
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
}

install_chrome_rpm_package() {
    if is_chrome_installed; then
        log_info "Google Chrome is already installed."
        return
    fi

    local arch
    arch="$(uname -m)"
    if [ "$arch" != "x86_64" ]; then
        log_info "Google Chrome automatic install is skipped on RPM architecture $arch."
        return
    fi

    log_info "Installing Google Chrome from Google's RPM package."
    if has_command dnf; then
        as_root dnf install -y https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
    elif has_command yum; then
        as_root yum install -y https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
    elif has_command zypper; then
        as_root zypper --non-interactive install https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
    fi
}

install_desktop_apps() {
    log_step "Checking desktop apps"

    if ! should_install_desktop_apps; then
        log_info "Skipping Linux desktop apps. WSL uses the Windows installs for VS Code, Chrome, and Obsidian."
        return
    fi

    if has_command apt-get; then
        ensure_sudo
        install_vscode_apt
        install_chrome_apt
        install_obsidian_apt
    elif has_command dnf; then
        ensure_sudo
        if is_vscode_installed; then
            log_info "Visual Studio Code is already installed."
        else
            install_vscode_rpm_repo
            as_root dnf check-update || true
            as_root dnf install -y code
        fi
        install_chrome_rpm_package
        log_info "Obsidian automatic install is currently Ubuntu/Debian-only."
    elif has_command yum; then
        ensure_sudo
        if is_vscode_installed; then
            log_info "Visual Studio Code is already installed."
        else
            install_vscode_rpm_repo
            as_root yum check-update || true
            as_root yum install -y code
        fi
        install_chrome_rpm_package
        log_info "Obsidian automatic install is currently Ubuntu/Debian-only."
    elif has_command zypper; then
        ensure_sudo
        if is_vscode_installed; then
            log_info "Visual Studio Code is already installed."
        else
            install_vscode_rpm_repo
            as_root zypper --non-interactive install code
        fi
        install_chrome_rpm_package
        log_info "Obsidian automatic install is currently Ubuntu/Debian-only."
    else
        log_info "Automatic VS Code, Chrome, and Obsidian install is not supported for this package manager yet."
    fi
}

baseline_tools_installed() {
    has_command curl && has_command git && has_command gh || return 1

    # ca-certificates and gpg have no command to probe on apt systems, so ask dpkg.
    if has_command dpkg; then
        dpkg -s ca-certificates gpg >/dev/null 2>&1 || return 1
    fi
}

install_baseline_tools() {
    log_step "Checking baseline Linux tools"

    if baseline_tools_installed; then
        log_info "curl, Git, and GitHub CLI are already installed; skipping package installs."
        return
    fi

    log_info "Some baseline tools are missing; installing."
    if has_command apt-get; then
        install_with_apt
    elif has_command dnf; then
        install_with_dnf
    elif has_command yum; then
        install_with_yum
    elif has_command pacman; then
        install_with_pacman
    elif has_command zypper; then
        install_with_zypper
    elif has_command brew; then
        install_with_brew
    else
        die "Unsupported package manager. Install git and gh manually, then rerun."
    fi
}

ensure_gh_auth() {
    log_step "Checking GitHub CLI authentication"

    if gh auth status >/dev/null 2>&1; then
        log_info "GitHub CLI is already authenticated."
        return
    fi

    log_info "Starting GitHub login."
    gh auth login --web --hostname github.com --git-protocol ssh --scopes admin:public_key --skip-ssh-key
}

ensure_github_ssh() {
    log_step "Setting up GitHub SSH access (WSL/Linux key only)"

    # Only the Linux-side key counts. Never use a Windows key, ssh.exe, or an agent
    # forwarded from Windows when deciding whether SSH is already set up.
    local ssh_bin=/usr/bin/ssh keygen_bin=/usr/bin/ssh-keygen
    if [ ! -x "$ssh_bin" ] || [ ! -x "$keygen_bin" ]; then
        log_info "Linux OpenSSH client not found; installing openssh-client."
        if has_command apt-get; then
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client
        fi
        if [ ! -x "$ssh_bin" ] || [ ! -x "$keygen_bin" ]; then
            log_info "Could not find /usr/bin/ssh; skipping SSH setup."
            return 0
        fi
    fi

    local ssh_dir="$HOME/.ssh" key="$HOME/.ssh/id_ed25519" ssh_out
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    case "$(readlink -f "$ssh_dir")" in
        /mnt/*)
            log_info "$ssh_dir points into the Windows filesystem ($(readlink -f "$ssh_dir"))."
            log_info "Replace it with a real Linux directory and rerun; skipping SSH setup."
            return 0
            ;;
    esac

    if [ ! -f "$key" ]; then
        log_info "No WSL/Linux SSH key found. Generating $key (enter a passphrase, or empty for none)."
        "$keygen_bin" -t ed25519 -C "$USER@$(hostname)" -f "$key" || { log_info "ssh-keygen failed; skipping SSH setup."; return 0; }
    else
        log_info "Linux SSH key already exists: $key"
    fi

    github_ssh_test() {
        "$ssh_bin" -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none \
            -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true
    }

    ssh_out="$(github_ssh_test)"
    if printf '%s' "$ssh_out" | grep -q "successfully authenticated"; then
        log_info "GitHub already accepts the WSL key; nothing to do."
        GITHUB_SSH_OK=1
        return 0
    fi
    log_info "GitHub does not accept the WSL key yet; registering it."

    if ! gh auth status -h github.com >/dev/null 2>&1; then
        gh auth login --web --hostname github.com --git-protocol ssh --scopes admin:public_key --skip-ssh-key || { log_info "gh auth login failed; skipping SSH setup."; return 0; }
    elif ! gh auth status -h github.com 2>&1 | grep -q "admin:public_key"; then
        log_info "Refreshing GitHub CLI scope for key upload."
        gh auth refresh -h github.com -s admin:public_key || { log_info "gh auth refresh failed; skipping SSH setup."; return 0; }
    fi

    local local_key
    local_key="$(awk '{print $2}' "$key.pub")"
    if gh ssh-key list 2>/dev/null | grep -qF "$local_key"; then
        log_info "This WSL key is already registered on GitHub."
    else
        gh ssh-key add "$key.pub" --title "$(hostname)-wsl" && log_info "WSL key added to GitHub as '$(hostname)-wsl'." \
            || { log_info "gh ssh-key add failed; add it manually."; return 0; }
    fi

    ssh_out="$(github_ssh_test)"
    if printf '%s' "$ssh_out" | grep -q "successfully authenticated"; then
        log_info "GitHub SSH test passed with the WSL key."
        GITHUB_SSH_OK=1
    else
        log_info "GitHub SSH test did not confirm authentication: $ssh_out"
        log_info "If the key has a passphrase, load it with ssh-add and run: ssh -T git@github.com"
    fi
}

setup_github() {
    ensure_gh_auth
    ensure_github_ssh

    if [ "$GITHUB_SSH_OK" = 1 ]; then
        gh config set git_protocol ssh -h github.com >/dev/null 2>&1 || true
    else
        # No working SSH key: let git use the gh token instead of prompting for a password.
        gh auth setup-git >/dev/null 2>&1 || true
    fi
}

install_baseline_tools
install_desktop_apps
setup_github

log_step "Bootstrap complete"
