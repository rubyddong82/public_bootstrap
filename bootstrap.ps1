[CmdletBinding()]
param(
    [string]$SetupRepo = "rubyddong82/private_bootstrap",
    [string]$SetupDir = "$HOME\private_bootstrap",
    [string]$SetupInstallScript = "install.ps1",
    [string]$WslDistribution = "Ubuntu",
    [string]$BootstrapUrl = "https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.ps1",
    [switch]$SkipWsl
)

$ErrorActionPreference = "Stop"
$script:RestartRecommended = $false

function Get-Timestamp {
    return (Get-Date).ToString("HH:mm:ss")
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    [$((Get-Timestamp))] $Message"
}

function Write-Heartbeat {
    param([string]$Message)
    Write-Host "    [$((Get-Timestamp))] ... $Message" -ForegroundColor DarkGray
}

function Invoke-ProcessWithHeartbeat {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Description,
        [int[]]$SuccessExitCodes = @(0),
        [int]$HeartbeatSeconds = 15,
        [switch]$AllowFailure
    )

    Write-Heartbeat "Starting $Description."
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru
    $startedAt = Get-Date

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $HeartbeatSeconds
        if (-not $process.HasExited) {
            $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
            Write-Heartbeat "$Description still running after $elapsed seconds."
        }
    }

    $process.WaitForExit()
    Write-Info "$Description finished with exit code $($process.ExitCode)."

    if (($SuccessExitCodes -notcontains $process.ExitCode) -and (-not $AllowFailure)) {
        throw "$Description failed with exit code $($process.ExitCode)."
    }

    return $process.ExitCode
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

function ConvertTo-QuotedPowerShellString {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-BootstrapCommand {
    $setupRepoArg = ConvertTo-QuotedPowerShellString $SetupRepo
    $setupDirArg = ConvertTo-QuotedPowerShellString $SetupDir
    $setupInstallScriptArg = ConvertTo-QuotedPowerShellString $SetupInstallScript
    $wslDistributionArg = ConvertTo-QuotedPowerShellString $WslDistribution

    $commonArgs = "-SetupRepo $setupRepoArg -SetupDir $setupDirArg -SetupInstallScript $setupInstallScriptArg -WslDistribution $wslDistributionArg"

    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath) -and (Test-Path $PSCommandPath)) {
        $scriptPathArg = ConvertTo-QuotedPowerShellString $PSCommandPath
        return @"
`$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host '==> Elevated bootstrap resumed' -ForegroundColor Cyan
& $scriptPathArg $commonArgs
"@
    }

    $bootstrapUrlArg = ConvertTo-QuotedPowerShellString $BootstrapUrl
    return @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
Write-Host ''
Write-Host '==> Elevated bootstrap resumed' -ForegroundColor Cyan
Write-Host '    Downloading latest bootstrap script...'
`$bootstrap = irm -TimeoutSec 120 $bootstrapUrlArg
& ([scriptblock]::Create(`$bootstrap)) $commonArgs
"@
}

function Start-ElevatedBootstrap {
    $command = New-BootstrapCommand
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))

    Write-Step "Administrator approval required"
    Write-Info "WSL installation needs elevation. Approve the UAC prompt in the new PowerShell window."

    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoExit",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-EncodedCommand",
            $encodedCommand
        ) | Out-Null
    } catch {
        throw "Could not start elevated PowerShell. Open PowerShell as Administrator and rerun the bootstrap one-liner."
    }
}

function Request-AdministratorForWsl {
    if ($SkipWsl) {
        return $false
    }

    $distros = @(Get-WslDistros)
    if ($distros.Count -gt 0) {
        return $false
    }

    if (Test-IsAdministrator) {
        return $false
    }

    Start-ElevatedBootstrap
    Write-Info "This non-elevated run will stop now. Continue in the elevated window."
    return $true
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
        [string]$Name,
        [string[]]$CommandNames = @(),
        [string[]]$TestPaths = @()
    )

    Write-Step "Checking $Name"

    foreach ($commandName in $CommandNames) {
        Write-Heartbeat "Looking for command $commandName."
        if (Test-Command $commandName) {
            Write-Info "$Name is already installed."
            return
        }
    }

    foreach ($testPath in $TestPaths) {
        if ([string]::IsNullOrWhiteSpace($testPath)) {
            continue
        }

        Write-Heartbeat "Looking for $testPath."
        if (Test-Path $testPath) {
            Write-Info "$Name is already installed."
            return
        }
    }

    Write-Info "Installing $Name..."
    Write-Heartbeat "winget may take a few minutes for $Name."
    Invoke-ProcessWithHeartbeat `
        -FilePath "winget" `
        -Arguments @("install", "--id", $Id, "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements") `
        -Description "winget install $Name" `
        -HeartbeatSeconds 20 | Out-Null
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
    Write-Heartbeat "Looking for existing WSL distributions."

    $distros = @(Get-WslDistros)
    if ($distros.Count -gt 0) {
        Write-Info "WSL is already installed: $($distros -join ', ')"
        return
    }

    if (-not (Test-Command "wsl.exe")) {
        throw "wsl.exe was not found. WSL install requires Windows 10 version 2004 or later, or Windows 11."
    }

    Write-Info "Installing WSL with $WslDistribution."
    Write-Heartbeat "This can take several minutes and may appear quiet."
    $installExitCode = Invoke-ProcessWithHeartbeat `
        -FilePath "wsl.exe" `
        -Arguments @("--install", "-d", $WslDistribution, "--no-launch") `
        -Description "WSL install for $WslDistribution" `
        -SuccessExitCodes @(0, 3010) `
        -HeartbeatSeconds 20 `
        -AllowFailure

    if ($installExitCode -notin @(0, 3010)) {
        Write-Info "Retrying WSL install with web download."
        Write-Heartbeat "Downloading WSL package directly from Microsoft."
        $installExitCode = Invoke-ProcessWithHeartbeat `
            -FilePath "wsl.exe" `
            -Arguments @("--install", "--web-download", "-d", $WslDistribution, "--no-launch") `
            -Description "WSL web-download install for $WslDistribution" `
            -SuccessExitCodes @(0, 3010) `
            -HeartbeatSeconds 20
    }

    if ($installExitCode -notin @(0, 3010)) {
        throw "WSL installation failed."
    }

    $script:RestartRecommended = $true
    Write-Info "WSL was installed. A Windows restart may be required before Linux setup can continue."
}

function Ensure-GhAuth {
    Write-Step "Checking GitHub CLI authentication"
    Write-Heartbeat "Running gh auth status."

    gh auth status *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "GitHub CLI is already authenticated."
        return
    }

    Write-Info "Starting GitHub login."
    Write-Heartbeat "Follow the prompts from GitHub CLI."
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
        Write-Heartbeat "Running git pull --ff-only."
        Push-Location $SetupDir
        try {
            Invoke-ProcessWithHeartbeat `
                -FilePath "git" `
                -Arguments @("pull", "--ff-only") `
                -Description "git pull for private bootstrap" `
                -HeartbeatSeconds 15 | Out-Null
        } finally {
            Pop-Location
        }
    } else {
        Write-Info "Cloning into $SetupDir."
        Write-Heartbeat "Running gh repo clone."
        Invoke-ProcessWithHeartbeat `
            -FilePath "gh" `
            -Arguments @("repo", "clone", $SetupRepo, $SetupDir) `
            -Description "gh repo clone $SetupRepo" `
            -HeartbeatSeconds 15 | Out-Null
    }

    $installPath = Join-Path $SetupDir $SetupInstallScript
    if (-not (Test-Path $installPath)) {
        Write-Host ""
        Write-Host "Setup repo cloned, but $SetupInstallScript was not found." -ForegroundColor Yellow
        Write-Host "Expected path: $installPath"
        return
    }

    Write-Step "Running private setup installer"
    Write-Heartbeat "Handing off to $installPath."
    Invoke-ProcessWithHeartbeat `
        -FilePath "powershell" `
        -Arguments @("-ExecutionPolicy", "Bypass", "-File", $installPath) `
        -Description "private setup installer" `
        -HeartbeatSeconds 15 | Out-Null
}

Assert-Windows
Write-Step "Starting public Windows bootstrap"
Write-Info "Target private repo: $SetupRepo"
Write-Info "Target clone path: $SetupDir"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Info "Could not force TLS 1.2; continuing with system defaults."
}

if (Request-AdministratorForWsl) {
    return
}

Write-Step "Checking Windows package manager"
Assert-Winget

Install-WingetPackage -Id "Git.Git" -Name "Git" -CommandNames @("git")
Install-WingetPackage -Id "GitHub.cli" -Name "GitHub CLI" -CommandNames @("gh")
Install-WingetPackage -Id "Microsoft.PowerShell" -Name "PowerShell 7" -CommandNames @("pwsh")
Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Name "Windows Terminal" -CommandNames @("wt")
Install-WingetPackage -Id "Microsoft.VisualStudioCode" -Name "Visual Studio Code" -CommandNames @("code")
Install-WingetPackage `
    -Id "Google.Chrome" `
    -Name "Google Chrome" `
    -CommandNames @("chrome", "chrome.exe") `
    -TestPaths @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")

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

