[CmdletBinding()]
param(
    [string]$SetupRepo = "rubyddong82/private_bootstrap",
    [string]$SetupDir = "$HOME\private_bootstrap",
    [string]$SetupInstallScript = "install.ps1",
    [string]$WslDistribution = "Ubuntu",
    [string]$BootstrapUrl = "https://raw.githubusercontent.com/rubyddong82/public_bootstrap/main/bootstrap.ps1",
    [int]$MaxParallelPackageInstalls = 2,
    [string]$StateDir = "",
    [switch]$ForcePrivateSetup,
    [switch]$ResetCheckpoints,
    [switch]$NoRebootPrompt,
    [switch]$SkipWsl
)

$ErrorActionPreference = "Stop"
$script:RestartRecommended = $false
$script:StateFile = ""
$script:CompletedCheckpoints = New-Object "System.Collections.Generic.HashSet[string]"

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

function ConvertTo-ProcessArgumentList {
    param([string[]]$Arguments)

    $convertedArguments = foreach ($rawArgument in $Arguments) {
        $argument = [string]$rawArgument
        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        } else {
            $argument
        }
    }

    return ($convertedArguments -join " ")
}

function Get-ProcessExitCode {
    param([System.Diagnostics.Process]$Process)

    try {
        $Process.Refresh()
        return $Process.ExitCode
    } catch {
        return $null
    }
}

function Format-ExitCode {
    param($ExitCode)

    if ($null -eq $ExitCode) {
        return "unavailable"
    }

    return [string]$ExitCode
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
    $argumentList = ConvertTo-ProcessArgumentList $Arguments
    $process = Start-Process -FilePath $FilePath -ArgumentList $argumentList -NoNewWindow -PassThru
    $startedAt = Get-Date

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $HeartbeatSeconds
        if (-not $process.HasExited) {
            $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
            Write-Heartbeat "$Description still running after $elapsed seconds."
        }
    }

    $process.WaitForExit()
    $exitCode = Get-ProcessExitCode $process
    Write-Info "$Description finished with exit code $(Format-ExitCode $exitCode)."

    if (($null -eq $exitCode) -and (-not $AllowFailure)) {
        throw "$Description finished but did not expose an exit code."
    }

    if (($null -ne $exitCode) -and ($SuccessExitCodes -notcontains $exitCode) -and (-not $AllowFailure)) {
        throw "$Description failed with exit code $exitCode."
    }

    return $exitCode
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

function Resolve-StateDir {
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        return $StateDir
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA "public_bootstrap")
    }

    return (Join-Path $HOME ".public_bootstrap")
}

function Initialize-Checkpoints {
    $resolvedStateDir = Resolve-StateDir
    $script:StateFile = Join-Path $resolvedStateDir "checkpoints.txt"
    $script:CompletedCheckpoints.Clear()

    if (-not (Test-Path $resolvedStateDir)) {
        New-Item -ItemType Directory -Path $resolvedStateDir -Force | Out-Null
    }

    if ($ResetCheckpoints -and (Test-Path $script:StateFile)) {
        Remove-Item $script:StateFile -Force
        Write-Info "Existing checkpoints were reset."
    }

    if (Test-Path $script:StateFile) {
        Get-Content $script:StateFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [void]$script:CompletedCheckpoints.Add($_) }
    } else {
        New-Item -ItemType File -Path $script:StateFile -Force | Out-Null
    }

    Write-Info "Checkpoint file: $script:StateFile"
}

function Test-Checkpoint {
    param([string]$Name)
    return $script:CompletedCheckpoints.Contains($Name)
}

function Set-Checkpoint {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($script:StateFile)) {
        return
    }

    if ($script:CompletedCheckpoints.Add($Name)) {
        Add-Content -Path $script:StateFile -Value $Name -Encoding ASCII
        Write-Info "Checkpoint saved: $Name"
    }
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
    $stateDirArg = ConvertTo-QuotedPowerShellString (Resolve-StateDir)

    $commonArgs = "-SetupRepo $setupRepoArg -SetupDir $setupDirArg -SetupInstallScript $setupInstallScriptArg -WslDistribution $wslDistributionArg -MaxParallelPackageInstalls $MaxParallelPackageInstalls -StateDir $stateDirArg"

    if ($SkipWsl) {
        $commonArgs += " -SkipWsl"
    }

    if ($NoRebootPrompt) {
        $commonArgs += " -NoRebootPrompt"
    }

    if ($ForcePrivateSetup) {
        $commonArgs += " -ForcePrivateSetup"
    }

    if ($ResetCheckpoints) {
        $commonArgs += " -ResetCheckpoints"
    }

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

function Test-WslInstallNeedsAdministrator {
    if ($SkipWsl) {
        return $false
    }

    $distros = @(Get-WslDistros)
    if ($distros.Count -gt 0) {
        return $false
    }

    return $true
}

function Request-AdministratorForBootstrap {
    if (Test-IsAdministrator) {
        return $false
    }

    if (Test-WslInstallNeedsAdministrator) {
        Start-ElevatedBootstrap
        Write-Info "This non-elevated run will stop now. Continue in the elevated window."
        return $true
    }

    return $false
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

function Test-PackageInstalled {
    param(
        [hashtable]$Package
    )

    Write-Step "Checking $($Package.Name)"
    $checkpointName = "package:$($Package.Id)"
    $hasCheckpoint = Test-Checkpoint $checkpointName
    if ($hasCheckpoint) {
        Write-Info "Checkpoint found for $($Package.Name); verifying it is still installed."
    }

    foreach ($commandName in @($Package.CommandNames)) {
        Write-Heartbeat "Looking for command $commandName."
        if (Test-Command $commandName) {
            Write-Info "$($Package.Name) is already installed."
            Set-Checkpoint $checkpointName
            return $true
        }
    }

    foreach ($testPath in @($Package.TestPaths)) {
        if ([string]::IsNullOrWhiteSpace($testPath)) {
            continue
        }

        Write-Heartbeat "Looking for $testPath."
        if (Test-Path $testPath) {
            Write-Info "$($Package.Name) is already installed."
            Set-Checkpoint $checkpointName
            return $true
        }
    }

    if ($hasCheckpoint) {
        Write-Info "Checkpoint existed, but $($Package.Name) was not detected. It will be retried."
    }

    return $false
}

function Start-WingetPackageProcess {
    param(
        [hashtable]$Package,
        [string[]]$ExtraArguments = @()
    )

    Write-Info "Starting $($Package.Name) install."
    Write-Heartbeat "winget may take a few minutes for $($Package.Name)."

    $arguments = @("install", "--id", $Package.Id, "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements")
    $arguments += $ExtraArguments
    $argumentList = ConvertTo-ProcessArgumentList $arguments

    $process = Start-Process `
        -FilePath "winget" `
        -ArgumentList $argumentList `
        -NoNewWindow `
        -PassThru

    return [pscustomobject]@{
        Name = $Package.Name
        Id = $Package.Id
        Package = $Package
        Process = $process
        StartedAt = Get-Date
        LastHeartbeatAt = Get-Date
    }
}

function Invoke-WingetPackageInstall {
    param(
        [hashtable]$Package,
        [string[]]$ExtraArguments = @(),
        [string]$Reason = "install"
    )

    Write-Info "Starting $($Package.Name) $Reason."
    $exitCode = Invoke-ProcessWithHeartbeat `
        -FilePath "winget" `
        -Arguments (@("install", "--id", $Package.Id, "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements") + $ExtraArguments) `
        -Description "winget install $($Package.Name)" `
        -HeartbeatSeconds 20 `
        -AllowFailure

    return $exitCode
}

function Install-GoogleChromeDirect {
    param([hashtable]$Package)

    try {
        Write-Step "Installing Google Chrome directly"
        Write-Info "winget could not install Chrome cleanly. Downloading Google's standalone MSI instead."

        $downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) "public_bootstrap"
        if (-not (Test-Path $downloadDir)) {
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        }

        $installerPath = Join-Path $downloadDir "googlechromestandaloneenterprise64.msi"
        $installerUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"

        if (Test-Path $installerPath) {
            Remove-Item $installerPath -Force
        }

        if (Test-Command "curl.exe") {
            $downloadExitCode = Invoke-ProcessWithHeartbeat `
                -FilePath "curl.exe" `
                -Arguments @("-L", "--fail", "--retry", "3", "--connect-timeout", "20", "--output", $installerPath, $installerUrl) `
                -Description "Google Chrome direct download" `
                -HeartbeatSeconds 10 `
                -AllowFailure

            if ($null -eq $downloadExitCode) {
                Write-Info "Chrome download exit code was unavailable. Checking the downloaded file."
            } elseif ($downloadExitCode -ne 0) {
                Write-Info "Chrome download exited with $downloadExitCode. Checking whether the installer file is usable."
            }
        } else {
            Write-Heartbeat "curl.exe was not found; using PowerShell download."
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
        }

        $installerFile = Get-Item -Path $installerPath -ErrorAction SilentlyContinue
        if (($null -eq $installerFile) -or ($installerFile.Length -lt 1048576)) {
            Write-Info "Chrome direct installer was not downloaded completely."
            return $false
        }

        $installExitCode = Invoke-ProcessWithHeartbeat `
            -FilePath "msiexec.exe" `
            -Arguments @("/i", $installerPath, "/qn", "/norestart") `
            -Description "Google Chrome direct MSI install" `
            -SuccessExitCodes @(0, 3010) `
            -HeartbeatSeconds 20 `
            -AllowFailure

        if (($installExitCode -in @(0, 3010)) -or (Test-PackageInstalled -Package $Package)) {
            Set-Checkpoint "package:$($Package.Id)"
            Write-Info "Google Chrome direct install finished successfully."
            return $true
        }

        Write-Info "Google Chrome direct installer exited with $installExitCode."
        return $false
    } catch {
        Write-Info "Google Chrome direct install failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-WingetFallbacks {
    param([object[]]$FailedPackages)

    $remainingFailures = New-Object System.Collections.ArrayList

    foreach ($package in $FailedPackages) {
        if (Test-PackageInstalled -Package $package) {
            continue
        }

        if ($package.RetryIgnoreSecurityHash) {
            Write-Step "Retrying $($package.Name)"
            Write-Info "winget reported a failure. Retrying with --ignore-security-hash for this package only."
            $exitCode = Invoke-WingetPackageInstall `
                -Package $package `
                -ExtraArguments @("--ignore-security-hash") `
                -Reason "retry with hash mismatch bypass"

            if ($exitCode -eq 0 -or (Test-PackageInstalled -Package $package)) {
                Set-Checkpoint "package:$($package.Id)"
                Write-Info "$($package.Name) retry finished successfully."
                continue
            }

            if ($package.DirectChromeFallback -and (Install-GoogleChromeDirect -Package $package)) {
                continue
            }

            if ($package.Optional) {
                Write-Info "$($package.Name) is optional. Continuing after retry failure."
                continue
            }

            [void]$remainingFailures.Add("$($package.Name) ($($package.Id)) retry exited with $exitCode")
            continue
        }

        if ($package.DirectChromeFallback -and (Install-GoogleChromeDirect -Package $package)) {
            continue
        }

        if ($package.Optional) {
            Write-Info "$($package.Name) is optional. Continuing after install failure."
            continue
        }

        [void]$remainingFailures.Add("$($package.Name) ($($package.Id)) failed")
    }

    return $remainingFailures
}

function Install-WingetPackages {
    param([hashtable[]]$Packages)

    Write-Step "Checking baseline app packages"
    Write-Info "Package installs will run with max parallelism: $MaxParallelPackageInstalls"

    $pending = New-Object System.Collections.ArrayList
    foreach ($package in $Packages) {
        if (-not (Test-PackageInstalled -Package $package)) {
            [void]$pending.Add($package)
        }
    }

    if ($pending.Count -eq 0) {
        Write-Info "All baseline app packages are already installed."
        return
    }

    $maxParallel = [Math]::Max(1, $MaxParallelPackageInstalls)
    $active = New-Object System.Collections.ArrayList
    $failedPackages = New-Object System.Collections.ArrayList

    Write-Step "Installing baseline app packages"
    Write-Info "Pending packages: $($pending.Count)"

    while ($pending.Count -gt 0 -or $active.Count -gt 0) {
        while ($pending.Count -gt 0 -and $active.Count -lt $maxParallel) {
            $package = $pending[0]
            $pending.RemoveAt(0)
            $record = Start-WingetPackageProcess -Package $package
            [void]$active.Add($record)
        }

        Start-Sleep -Seconds 5

        for ($index = $active.Count - 1; $index -ge 0; $index--) {
            $record = $active[$index]
            $process = $record.Process

            if ($process.HasExited) {
                $process.WaitForExit()
                $exitCode = Get-ProcessExitCode $process
                Write-Info "$($record.Name) install finished with exit code $(Format-ExitCode $exitCode)."

                if (($null -eq $exitCode) -or ($exitCode -ne 0)) {
                    Write-Info "$($record.Name) will be checked for fallback handling."
                    [void]$failedPackages.Add($record.Package)
                } else {
                    Set-Checkpoint "package:$($record.Id)"
                }

                $active.RemoveAt($index)
                continue
            }

            $secondsSinceHeartbeat = [int]((Get-Date) - $record.LastHeartbeatAt).TotalSeconds
            if ($secondsSinceHeartbeat -ge 20) {
                $elapsed = [int]((Get-Date) - $record.StartedAt).TotalSeconds
                Write-Heartbeat "$($record.Name) install still running after $elapsed seconds."
                $record.LastHeartbeatAt = Get-Date
            }
        }
    }

    if ($failedPackages.Count -gt 0) {
        $remainingFailures = Invoke-WingetFallbacks -FailedPackages $failedPackages.ToArray()
        if ($remainingFailures.Count -gt 0) {
            throw "One or more winget installs failed: $($remainingFailures -join '; ')"
        }
    }

    Write-Info "Baseline app package installs finished."
    Set-Checkpoint "phase:packages"
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

function Complete-WslInstallRequest {
    param([string]$Message)

    $script:RestartRecommended = $true
    Set-Checkpoint "phase:wsl-install-requested"
    Write-Info $Message
}

function Invoke-RestartPrompt {
    Write-Step "Restart recommended"
    Write-Info "Restart Windows, then rerun the same bootstrap one-liner to continue with $SetupRepo."

    if ($NoRebootPrompt) {
        Write-Info "Reboot prompt is disabled with -NoRebootPrompt."
        return
    }

    Write-Host ""
    $answer = Read-Host "Type yes to restart Windows now, or press Enter to do it later"
    if ($answer.Trim().ToLowerInvariant() -notin @("yes", "y")) {
        Write-Info "Restart skipped. Rerun the same bootstrap one-liner after restarting manually."
        return
    }

    Refresh-Path

    $restartShell = "pwsh"
    if (-not (Test-Command "pwsh")) {
        $pwshCandidates = @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe"
        )

        foreach ($candidate in $pwshCandidates) {
            if ((-not [string]::IsNullOrWhiteSpace($candidate)) -and (Test-Path $candidate)) {
                $restartShell = $candidate
                break
            }
        }
    }

    if (($restartShell -eq "pwsh") -and (-not (Test-Command "pwsh"))) {
        Write-Info "pwsh was not found yet. Falling back to Windows PowerShell for the restart command."
        $restartShell = "powershell.exe"
    }

    Write-Info "Restarting Windows now with $restartShell."
    $restartExitCode = Invoke-ProcessWithHeartbeat `
        -FilePath $restartShell `
        -Arguments @("-NoProfile", "-Command", "Restart-Computer -Force") `
        -Description "PowerShell restart command" `
        -HeartbeatSeconds 5 `
        -AllowFailure

    if (($null -ne $restartExitCode) -and ($restartExitCode -ne 0)) {
        Write-Info "Restart-Computer exited with $restartExitCode. Trying shutdown.exe fallback."
        Invoke-ProcessWithHeartbeat `
            -FilePath "shutdown.exe" `
            -Arguments @("/r", "/t", "5") `
            -Description "shutdown.exe restart fallback" `
            -HeartbeatSeconds 5 `
            -AllowFailure | Out-Null
    }
}

function Install-Wsl {
    if ($SkipWsl) {
        Write-Step "Skipping WSL"
        Write-Info "WSL installation was disabled with -SkipWsl."
        Set-Checkpoint "phase:wsl-skipped"
        return
    }

    Write-Step "Checking WSL"
    Write-Heartbeat "Looking for existing WSL distributions."
    if (Test-Checkpoint "phase:wsl") {
        Write-Info "WSL checkpoint found; verifying current WSL state."
    }

    $distros = @(Get-WslDistros)
    if ($distros.Count -gt 0) {
        Write-Info "WSL is already installed: $($distros -join ', ')"
        Set-Checkpoint "phase:wsl"
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

    if ($null -eq $installExitCode) {
        Complete-WslInstallRequest "WSL install did not expose an exit code. Windows may have accepted the feature change and asked for a restart."
        return
    }

    if ($installExitCode -notin @(0, 3010)) {
        Write-Info "Retrying WSL install with web download."
        Write-Heartbeat "Downloading WSL package directly from Microsoft."
        $installExitCode = Invoke-ProcessWithHeartbeat `
            -FilePath "wsl.exe" `
            -Arguments @("--install", "--web-download", "-d", $WslDistribution, "--no-launch") `
            -Description "WSL web-download install for $WslDistribution" `
            -SuccessExitCodes @(0, 3010) `
            -HeartbeatSeconds 20 `
            -AllowFailure
    }

    if ($null -eq $installExitCode) {
        Complete-WslInstallRequest "WSL web-download install did not expose an exit code. Windows may have accepted the feature change and asked for a restart."
        return
    }

    if ($installExitCode -notin @(0, 3010)) {
        throw "WSL installation failed."
    }

    Complete-WslInstallRequest "WSL was installed. A Windows restart may be required before Linux setup can continue."
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

    if ((Test-Checkpoint "phase:private-setup") -and (-not $ForcePrivateSetup) -and (Test-Path $SetupDir)) {
        Write-Step "Private setup already completed"
        Write-Info "Checkpoint found for private setup. Use -ForcePrivateSetup to run it again."
        return
    }

    if ((Test-Checkpoint "phase:private-setup") -and (-not (Test-Path $SetupDir))) {
        Write-Info "Private setup checkpoint exists, but $SetupDir is missing. The repo will be cloned again."
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
    Set-Checkpoint "phase:private-setup"
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

if (Request-AdministratorForBootstrap) {
    return
}

Initialize-Checkpoints

Write-Step "Checking Windows package manager"
Assert-Winget

$baselinePackages = @(
    @{
        Id = "Git.Git"
        Name = "Git"
        CommandNames = @("git")
        TestPaths = @()
    },
    @{
        Id = "GitHub.cli"
        Name = "GitHub CLI"
        CommandNames = @("gh")
        TestPaths = @()
    },
    @{
        Id = "Microsoft.PowerShell"
        Name = "PowerShell 7"
        CommandNames = @("pwsh")
        TestPaths = @()
    },
    @{
        Id = "Microsoft.WindowsTerminal"
        Name = "Windows Terminal"
        CommandNames = @("wt")
        TestPaths = @()
    },
    @{
        Id = "Microsoft.VisualStudioCode"
        Name = "Visual Studio Code"
        CommandNames = @("code")
        TestPaths = @()
    },
    @{
        Id = "Obsidian.Obsidian"
        Name = "Obsidian"
        CommandNames = @("obsidian", "obsidian.exe")
        TestPaths = @("$env:LOCALAPPDATA\Obsidian\Obsidian.exe", "$env:LOCALAPPDATA\Programs\Obsidian\Obsidian.exe", "$env:ProgramFiles\Obsidian\Obsidian.exe")
        Optional = $true
    },
    @{
        Id = "Google.Chrome"
        Name = "Google Chrome"
        CommandNames = @("chrome", "chrome.exe")
        TestPaths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
        RetryIgnoreSecurityHash = $true
        DirectChromeFallback = $true
        Optional = $true
    }
)

Install-WingetPackages -Packages $baselinePackages

Install-Wsl

if ($script:RestartRecommended) {
    Invoke-RestartPrompt
    return
}

Refresh-Path
Clone-SetupRepo

Write-Step "Bootstrap complete"
Set-Checkpoint "phase:bootstrap"
Write-Info "Open a new terminal so PATH changes are fully available."

