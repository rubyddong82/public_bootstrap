# New Laptop Bootstrap

This repo is the public, no-secret seed for a brand new Windows laptop.

It exists because a fresh Windows environment may not have Git, WSL, PowerShell 7,
or GitHub CLI yet. The first step needs to work with built-in Windows PowerShell
and a normal HTTPS download.

## Intended Flow

1. Start from a clean Windows install.
2. Open built-in PowerShell as Administrator.
3. Download this repo's `bootstrap.ps1` from `raw.githubusercontent.com`.
4. Run the script.
5. Let the script install baseline tools:
   - Git
   - GitHub CLI
   - PowerShell 7
   - Windows Terminal
   - WSL with Ubuntu
6. Restart Windows if WSL asks for it.
7. Rerun the same one-liner after reboot.
8. Log in to GitHub with `gh auth login`.
9. Clone the private machine setup repo.
10. Run the private repo's installer.

## Fresh Machine Command

Minimal one-liner:

```powershell
irm https://raw.githubusercontent.com/rubyddong82/laptop-bootstrap/main/bootstrap.ps1 | iex
```

Run this from PowerShell as Administrator. WSL may require a reboot; if the
script asks for one, restart Windows and run the same one-liner again.

Safer version if you want to inspect the script first:

```powershell
iwr https://raw.githubusercontent.com/rubyddong82/laptop-bootstrap/main/bootstrap.ps1 -OutFile "$env:TEMP\bootstrap.ps1"
notepad "$env:TEMP\bootstrap.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\bootstrap.ps1"
```

By default, the script installs baseline tools and then clones
`rubyddong82/laptop-setup`. You can override that target with `-SetupRepo` if
needed.

WSL installs Ubuntu by default. You can override the distro with
`-WslDistribution` or skip WSL with `-SkipWsl` when using the safer downloaded
script version.

## Repo Split

Use two repos:

```text
public:  laptop-bootstrap
private: laptop-setup
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

## Later Private Repo Shape

The private setup repo can look like this:

```text
laptop-setup/
├─ install.ps1
├─ packages/
│  ├─ winget.json
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

