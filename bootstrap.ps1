[CmdletBinding()]
param(
    [string]$SetupRepo = "rubyddong82/laptop-setup",
    [string]$SetupDir = "$HOME\laptop-setup",
    [string]$SetupInstallScript = "install.ps1"
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message"
}

function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Assert-Windows {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core") {
        throw "This bootstrap script is intended for Windows."
    }
}

function Assert-Winget {
    if (Test-Command "winget") {
        return
    }

    Write-Host ""
    Write-Host "winget was not found." -ForegroundColor Yellow
    Write-Host "Install or update 'App Installer' from Microsoft Store, then rerun this script."
    Write-Host "Store page: ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1"

    try {
        Start-Process "ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1"
    } catch {
        Write-Host "Could not open Microsoft Store automatically."
    }

    throw "winget is required before this bootstrap can continue."
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Name
    )

    Write-Step "Checking $Name"

    $listOutput = winget list --id $Id --exact --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0 -and ($listOutput -match [regex]::Escape($Id))) {
        Write-Info "$Name is already installed."
        return
    }

    Write-Info "Installing $Name..."
    winget install --id $Id --exact --source winget --accept-package-agreements --accept-source-agreements
}

function Ensure-GhAuth {
    Write-Step "Checking GitHub CLI authentication"

    gh auth status *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "GitHub CLI is already authenticated."
        return
    }

    Write-Info "Starting GitHub login."
    gh auth login
}

function Clone-SetupRepo {
    if ([string]::IsNullOrWhiteSpace($SetupRepo)) {
        Write-Step "No private setup repo requested"
        Write-Info "Baseline tools are installed. Rerun with -SetupRepo owner/repo when ready."
        return
    }

    Ensure-GhAuth

    Write-Step "Preparing setup repo $SetupRepo"

    if (Test-Path $SetupDir) {
        Write-Info "$SetupDir already exists. Pulling latest changes."
        Push-Location $SetupDir
        try {
            git pull --ff-only
        } finally {
            Pop-Location
        }
    } else {
        Write-Info "Cloning into $SetupDir."
        gh repo clone $SetupRepo $SetupDir
    }

    $installPath = Join-Path $SetupDir $SetupInstallScript
    if (-not (Test-Path $installPath)) {
        Write-Host ""
        Write-Host "Setup repo cloned, but $SetupInstallScript was not found." -ForegroundColor Yellow
        Write-Host "Expected path: $installPath"
        return
    }

    Write-Step "Running private setup installer"
    powershell -ExecutionPolicy Bypass -File $installPath
}

Assert-Windows

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Info "Could not force TLS 1.2; continuing with system defaults."
}

Write-Step "Checking Windows package manager"
Assert-Winget

Install-WingetPackage -Id "Git.Git" -Name "Git"
Install-WingetPackage -Id "GitHub.cli" -Name "GitHub CLI"
Install-WingetPackage -Id "Microsoft.PowerShell" -Name "PowerShell 7"
Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Name "Windows Terminal"

Refresh-Path
Clone-SetupRepo

Write-Step "Bootstrap complete"
Write-Info "Open a new terminal so PATH changes are fully available."

