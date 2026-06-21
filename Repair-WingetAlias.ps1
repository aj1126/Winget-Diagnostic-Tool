using namespace Microsoft.Win32
<#
.SYNOPSIS
    Bootstrap proxy for WingetDiagnosticTool module.
.DESCRIPTION
    Automatically resolves, imports, and executes the WingetDiagnosticTool module.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Rollback,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$AsJob,

    [Parameter(Mandatory = $false)]
    [switch]$DownloadFallback,

    [Parameter(Mandatory = $false)]
    [switch]$ScheduleTask,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$EventLog,

    [Parameter(Mandatory = $false)]
    [string]$TargetUser
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Get-Location
}

$localManifest = Join-Path $ScriptDir "WingetDiagnosticTool\WingetDiagnosticTool.psd1"
if (Test-Path $localManifest) {
    Import-Module $localManifest -Force
} else {
    if (-not (Get-Module -ListAvailable -Name WingetDiagnosticTool)) {
        Write-Output "Installing WingetDiagnosticTool module from PowerShell Gallery..."
        Install-Module -Name WingetDiagnosticTool -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module WingetDiagnosticTool -Force
}

$params = $PSBoundParameters

# Interactivity check for bootstrapping
$IsInteractive = [Environment]::UserInteractive -and ($Host.Name -notmatch "Background|Job|NonInteractive") -and ($null -ne $Host.UI) -and -not $env:NON_INTERACTIVE
if (-not $IsInteractive -and -not $Force -and -not $Rollback -and -not $ScheduleTask -and -not $DryRun) {
    $params['Force'] = $true
}

$exitCode = 0
try {
    if ($params['Force'] -or $params['DryRun'] -or $params['Rollback'] -or $params['ScheduleTask'] -or $params['AsJob']) {
        $exitCode = Repair-WingetAlias @params
        if ($null -eq $exitCode) {
            $exitCode = 0
        }
    } else {
        Invoke-WingetDiagnosticMenu
        $exitCode = 0
    }
} catch {
    Write-Error $_
    $exitCode = 1
}

$isTestRunner = $env:IsTestRunner -eq "true" -or (Get-Variable -Name "IsTestRunner" -Scope "global" -ErrorAction SilentlyContinue).Value
if ($isTestRunner) {
    return $exitCode
} else {
    exit $exitCode
}
