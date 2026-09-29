#requires -version 5.1
<#
.SYNOPSIS
    Stages WingetDiagnosticTool and registers Active Setup for OSD Task Sequences.
.DESCRIPTION
    Designed for execution during Microsoft SCCM / MECM or MDT Operating System Deployment (OSD)
    Task Sequences running under the NT AUTHORITY\SYSTEM context.

    Because Windows Package Manager (winget) execution aliases reside in individual user profiles
    (HKCU and %LOCALAPPDATA%), this script stages the repair utility locally into ProgramData
    and registers an Active Setup component in HKLM. When any user subsequently logs in,
    Windows automatically triggers the silent repair routine once within the user's interactive context.
.PARAMETER StagingPath
    Destination directory where module and repair scripts are staged.
    Defaults to "$env:ProgramData\WingetDiagnosticTool".
.PARAMETER Uninstall
    Unregisters the Active Setup component and removes staged files.
.PARAMETER Force
    Overwrites existing staged files without confirmation.
.EXAMPLE
    .\Install-ActiveSetupStage.ps1
    Stages files and registers Active Setup under HKLM.
.EXAMPLE
    .\Install-ActiveSetupStage.ps1 -Uninstall
    Unregisters Active Setup and removes staged files.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$StagingPath = "$env:ProgramData\WingetDiagnosticTool",

    [Parameter(Mandatory = $false)]
    [switch]$Uninstall,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$activeSetupKeyPath = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\WingetDiagnosticTool"

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$exitCode = 0

try {
    if (-not (Test-IsElevated)) {
        Write-Error "Access Denied: Install-ActiveSetupStage.ps1 must be executed with administrative privileges (SYSTEM or local admin)."
        $exitCode = 1
    } else {
        if ($Uninstall) {
            Write-Verbose "Unregistering Active Setup component..."
            if (Test-Path $activeSetupKeyPath) {
                if ($PSCmdlet.ShouldProcess($activeSetupKeyPath, "Remove-Item Registry Key")) {
                    Remove-Item -Path $activeSetupKeyPath -Force -Recurse -ErrorAction Stop
                    Write-Output "Successfully removed Active Setup registry key: $activeSetupKeyPath"
                }
            } else {
                Write-Output "Active Setup key not found: $activeSetupKeyPath"
            }

            if (Test-Path $StagingPath) {
                if ($PSCmdlet.ShouldProcess($StagingPath, "Remove Staged Files")) {
                    Remove-Item -Path $StagingPath -Force -Recurse -ErrorAction Stop
                    Write-Output "Successfully removed staging folder: $StagingPath"
                }
            }
            $exitCode = 0
        } else {
            # 1. Resolve source files
            $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
            if ([string]::IsNullOrWhiteSpace($scriptDir)) {
                $scriptDir = Get-Location
            }
            $projectRoot = Split-Path -Parent $scriptDir

            $sourceRepairScript = Join-Path $projectRoot "Repair-WingetAlias.ps1"
            $sourceModuleDir = Join-Path $projectRoot "WingetDiagnosticTool"

            # Check if running directly from project root
            if (-not (Test-Path $sourceRepairScript)) {
                $sourceRepairScript = Join-Path $scriptDir "Repair-WingetAlias.ps1"
                $sourceModuleDir = Join-Path $scriptDir "WingetDiagnosticTool"
            }

            if (-not (Test-Path $sourceRepairScript)) {
                throw "Source file 'Repair-WingetAlias.ps1' could not be located in '$projectRoot' or '$scriptDir'."
            }

            # 2. Stage files into target location
            if (-not (Test-Path $StagingPath)) {
                if ($PSCmdlet.ShouldProcess($StagingPath, "Create Staging Directory")) {
                    New-Item -ItemType Directory -Path $StagingPath -Force:$Force | Out-Null
                    Write-Verbose "Created staging directory: $StagingPath"
                }
            }

            if ($PSCmdlet.ShouldProcess($StagingPath, "Copy Staged Files")) {
                Copy-Item -Path $sourceRepairScript -Destination $StagingPath -Force:$Force
                if (Test-Path $sourceModuleDir) {
                    Copy-Item -Path $sourceModuleDir -Destination $StagingPath -Recurse -Force:$Force
                }
                Write-Output "Successfully staged WingetDiagnosticTool to: $StagingPath"
            }

            # 3. Register Active Setup in HKLM
            $stagedScriptPath = Join-Path $StagingPath "Repair-WingetAlias.ps1"
            $powershellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $stubPath = "`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stagedScriptPath`" -Force"

            if ($PSCmdlet.ShouldProcess($activeSetupKeyPath, "Register Active Setup Component")) {
                if (-not (Test-Path $activeSetupKeyPath)) {
                    New-Item -Path $activeSetupKeyPath -Force | Out-Null
                }

                Set-ItemProperty -Path $activeSetupKeyPath -Name "(Default)" -Value "Winget Diagnostic & Repair Stub" -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "ComponentID" -Value "WingetDiagnosticTool" -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "StubPath" -Value $stubPath -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "Version" -Value "1,0,0" -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "Locale" -Value "*" -Force

                Write-Output "Successfully registered Active Setup component at: $activeSetupKeyPath"
                Write-Output "Stub command: $stubPath"
            }

            $exitCode = 0
        }
    }
} catch {
    Write-Error "Failed to configure Active Setup staging: $_"
    $exitCode = 1
}

$isTestRunner = $env:IsTestRunner -eq "true" -or (Get-Variable -Name "IsTestRunner" -Scope "global" -ErrorAction SilentlyContinue).Value
if ($isTestRunner) {
    return $exitCode
} else {
    exit $exitCode
}
