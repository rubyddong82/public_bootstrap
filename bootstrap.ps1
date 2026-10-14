[CmdletBinding()]
param(
    [string]$SetupRepo = "rubyddong82/private_bootstrap",
    [string]$SetupDir = "$HOME\private_bootstrap",
    [string]$SetupInstallScript = "install.ps1",
    [string]$WslDistribution = "Ubuntu",
    [switch]$SkipWsl
)

$ErrorActionPreference = "Stop"
$script:RestartRecommended = $false

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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-AdministratorForWsl {
    if ($SkipWsl) {
        return
    }

    $distros = @(Get-WslDistros)
    if ($distros.Count -gt 0) {
        return
    }

    if (Test-IsAdministrator) {
        return
    }

    throw "WSL installation requires Administrator. Open PowerShell as Administrator and rerun the one-liner, or run this script with -SkipWsl."
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

function Get-WslDistros {
    if (-not (Test-Command "wsl.exe")) {
        return @()
    }

    $commandShell = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { "cmd.exe" } else { $env:ComSpec }
    $distros = @(& $commandShell /d /c "wsl.exe --list --quiet 2>NUL")
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @(
        $distros |
            ForEach-Object { ([string]$_).Trim().Trim([char]0xfeff).Trim([char]0) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Install-Wsl {
    if ($SkipWsl) {
        Write-Step "Skipping WSL"
        Write-Info "WSL installation was disabled with -SkipWsl."
        return
    }

    Write-Step "Checking WSL"

    $distros = @(Get-WslDistros)
    if ($distros.Count -gt 0) {
        Write-Info "WSL is already installed: $($distros -join ', ')"
        return
    }

    if (-not (Test-Command "wsl.exe")) {
        throw "wsl.exe was not found. WSL install requires Windows 10 version 2004 or later, or Windows 11."
    }

    Write-Info "Installing WSL with $WslDistribution."
    wsl.exe --install -d $WslDistribution --no-launch
    $installExitCode = $LASTEXITCODE

    if ($installExitCode -notin @(0, 3010)) {
        Write-Info "Retrying WSL install with web download."
        wsl.exe --install --web-download -d $WslDistribution --no-launch
        $installExitCode = $LASTEXITCODE
    }

    if ($installExitCode -notin @(0, 3010)) {
        throw "WSL installation failed."
    }

    $script:RestartRecommended = $true
    Write-Info "WSL was installed. A Windows restart may be required before Linux setup can continue."
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
Assert-AdministratorForWsl

Install-WingetPackage -Id "Git.Git" -Name "Git"
Install-WingetPackage -Id "GitHub.cli" -Name "GitHub CLI"
Install-WingetPackage -Id "Microsoft.PowerShell" -Name "PowerShell 7"
Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Name "Windows Terminal"
Install-WingetPackage -Id "Microsoft.VisualStudioCode" -Name "Visual Studio Code"
Install-WingetPackage -Id "Google.Chrome" -Name "Google Chrome"

Install-Wsl

if ($script:RestartRecommended) {
    Write-Step "Restart recommended"
    Write-Info "Restart Windows, then rerun the same bootstrap one-liner to continue with $SetupRepo."
    return
}

Refresh-Path
Clone-SetupRepo

Write-Step "Bootstrap complete"
Write-Info "Open a new terminal so PATH changes are fully available."

