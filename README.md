# Public Bootstrap

This repo is the public, no-secret seed for a brand new machine.

It exists because a fresh environment may not have Git, WSL, or the baseline
apps yet. The first step needs to work with only the tools that ship with the
operating system and a normal HTTPS download.

## Windows Flow

1. Start from a clean Windows install.
2. Open built-in PowerShell as Administrator.
3. Download this repo's `bootstrap.ps1` from `raw.githubusercontent.com`.
4. Run the script.
5. Let the script install baseline tools:
   - Git
   - PowerShell 7
   - Windows Terminal
   - Visual Studio Code
   - Obsidian
   - Google Chrome
   - WSL with Ubuntu
6. Restart Windows if WSL asks for it.
7. Rerun the same one-liner after reboot.
8. Let the script run the Linux bootstrap inside WSL for GitHub CLI, GitHub SSH and private setup.

## Windows Command

Minimal one-liner:

```powershell
irm https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.ps1 | iex
```

The first thing the script does is save a rerun helper to:

```text
%USERPROFILE%\Downloads\run-public-bootstrap.ps1
```

That helper contains only the one-liner above, so rerunning it downloads the
latest `bootstrap.ps1` from GitHub instead of using an old cached full script.

Verbose one-liner:

```powershell
$u="https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.ps1"; Write-Host "Downloading bootstrap..."; $s=irm -TimeoutSec 120 $u; Write-Host "Running bootstrap..."; iex $s
```

Run this from PowerShell as Administrator. WSL may require a reboot; if it does,
the script asks whether to restart now. Type `yes` to reboot through PowerShell,
then run the same one-liner again after Windows comes back.

If you forget to start PowerShell as Administrator, the script will open a UAC
prompt and continue in a new elevated PowerShell window.

The script prints timestamped progress messages around slow installs so it is
easier to tell when `winget` or WSL is still working.
Baseline Windows app installs run in parallel with a default limit of 2.
Increase it only if you are okay with more installer contention:

```powershell
$s=irm https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.ps1; & ([scriptblock]::Create($s)) -MaxParallelPackageInstalls 3
```

The Windows bootstrap records checkpoints in:

```text
%LOCALAPPDATA%\public_bootstrap\checkpoints.txt
```

Rerunning the one-liner resumes from the previous successful work. Installed
packages are still verified before they are skipped. Reset checkpoints with
`-ResetCheckpoints`.

Disable the interactive restart prompt with `-NoRebootPrompt`.
Skip the automatic Linux/WSL bootstrap handoff with `-SkipWslBootstrap`.

Safer version if you want to inspect the script first:

```powershell
iwr https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.ps1 -OutFile "$env:TEMP\bootstrap.ps1"
notepad "$env:TEMP\bootstrap.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\bootstrap.ps1"
```

By default, the Windows script installs baseline tools and WSL, then runs the
Linux bootstrap inside WSL. That Linux bootstrap installs GitHub CLI and handles
`rubyddong82/private_bootstrap`.

WSL installs Ubuntu by default. You can override the distro with
`-WslDistribution` or skip WSL with `-SkipWsl` when using the safer downloaded
script version.

On the first WSL run, Ubuntu may ask you to create a Linux user. The Linux
bootstrap may also ask for a sudo password or `gh auth login`.

When the Linux bootstrap runs inside WSL, it skips Linux desktop apps. VS Code,
Chrome, and Obsidian are installed on Windows instead.

Google Chrome is installed by default. If `winget` hits a temporary hash or
manifest problem, the script retries and then falls back to Google's direct MSI
installer. Chrome is treated as optional so it will not block WSL or the private
bootstrap path if every Chrome install path fails.

Obsidian is attempted by default through `winget` on Windows. It is optional, so
it will not block WSL if `winget` cannot install it.

## Linux Flow

1. Start from a fresh Linux install.
2. Open a terminal.
3. Download this repo's `bootstrap.sh` from `raw.githubusercontent.com`.
4. Run the script.
5. Let the script install baseline tools:
   - curl and certificates
   - Git
   - GitHub CLI
   - Visual Studio Code
   - Obsidian
   - Google Chrome
6. Log in to GitHub with `gh auth login`.
7. Set up GitHub SSH (see below).
8. Clone `rubyddong82/private_bootstrap`.
9. Run the private repo's Linux installer.

### GitHub SSH (Linux / WSL)

The key lives in the Linux `~/.ssh` (inside WSL when run from the Windows
bootstrap), not in the Windows profile. The script:

1. Generates `~/.ssh/id_ed25519` if it does not exist (optional passphrase).
2. Logs in with `gh auth login` including the `admin:public_key` scope, or
   refreshes the scope if already logged in.
3. Uploads the public key with `gh ssh-key add`, titled with the hostname.
4. Verifies with `ssh -T git@github.com`.

Safe to rerun: if `ssh -T git@github.com` already succeeds the step is skipped,
and login and key upload are skipped individually when already done. Failures
here are non-fatal.

## Linux Command

Minimal one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.sh | bash
```

Safer version if you want to inspect the script first:

```bash
curl -fsSL https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.sh -o /tmp/bootstrap.sh
less /tmp/bootstrap.sh
bash /tmp/bootstrap.sh
```

The Linux script is Ubuntu/Debian-first, with basic support for other common
package managers. Override the private repo or clone path with environment
variables:

```bash
SETUP_REPO=rubyddong82/private_bootstrap SETUP_DIR="$HOME/private_bootstrap" bash /tmp/bootstrap.sh
```

On a normal Linux install, desktop apps are installed by default. On WSL they are
skipped by default. Override with `INSTALL_DESKTOP_APPS=true` or
`INSTALL_DESKTOP_APPS=false`.

On Ubuntu/Debian, Obsidian is installed from the official GitHub release `.deb`
when desktop apps are enabled. Other Linux package managers currently skip
Obsidian and continue.

## Repo Split

Use two repos:

```text
public:  public_bootstrap
private: private_bootstrap
```

The public bootstrap repo should contain only generic setup logic. It should be
safe for anyone to read.

The private setup repo can contain personal dotfiles, package lists, app config,
and scripts that place files on disk.

## Things the Private Setup Repo Can Manage

- Git config
- SSH config templates
- PowerShell profile and modules
- Windows Terminal settings
- VS Code settings, keybindings, snippets, and extensions
- Fonts
- Linux-side setup after WSL is installed
- Windows features and registry settings
- Common applications through `winget`, `scoop`, or `choco`
- Project folders under the user profile
- Non-secret files copied into `Documents`, `%APPDATA%`, or `%USERPROFILE%`

## Things Not to Commit

Do not commit secrets, tokens, or private credentials:

- SSH private keys
- API keys
- OAuth tokens
- Password manager exports
- Browser cookies or profiles
- `.env` files with real secret values
- GPG private keys

Use templates such as `.env.example` and let the setup script prompt for secrets
or connect to a password manager later.

## Bootstrap Script Contract

`bootstrap.ps1` should stay small and boring:

- Use built-in Windows PowerShell compatibility.
- Prefer `winget` for baseline installs.
- Be safe to run more than once.
- Avoid machine-specific secrets.
- Print clear next steps when something needs manual attention.
- Delegate real customization to the private setup repo.

## Private Repo Shape

The private setup repo can look like this:

```text
private_bootstrap/
├─ install.ps1
├─ install.sh
├─ packages/
│  ├─ winget.json
│  ├─ apt.txt
│  ├─ scoop.ps1
│  └─ npm-global.txt
├─ windows/
│  ├─ settings.ps1
│  ├─ registry.ps1
│  └─ optional-features.ps1
├─ dotfiles/
│  ├─ Git/
│  ├─ PowerShell/
│  ├─ VSCode/
│  └─ WindowsTerminal/
├─ wsl/
│  ├─ install.ps1
│  └─ ubuntu-setup.sh
└─ files/
   ├─ Documents/
   ├─ AppData/
   └─ UserProfile/
```

