# Remediation.ps1
# Remediation script for Microsoft Intune Proactive Remediation

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Get-Location
}

$localManifest = Join-Path $ScriptDir "..\WingetDiagnosticTool\WingetDiagnosticTool.psd1"
if (Test-Path $localManifest) {
    Import-Module $localManifest -Force
} else {
    Import-Module WingetDiagnosticTool -ErrorAction SilentlyContinue
}

if (Get-Command Repair-WingetAlias -ErrorAction SilentlyContinue) {
    Write-Host "Running WingetDiagnosticTool Repair..."
    $exitCode = Repair-WingetAlias -Force -ErrorAction SilentlyContinue
    if ($exitCode -eq 0) {
        Write-Host "Remediation completed successfully."
        exit 0
    } else {
        Write-Error "Remediation failed with exit code $exitCode."
        exit 1
    }
} else {
    Write-Host "Module not loaded. Spawning bootstrap proxy..."
    $bootstrapPath = Join-Path $ScriptDir "..\Repair-WingetAlias.ps1"
    if (Test-Path $bootstrapPath) {
        & $bootstrapPath -Force
        exit $LastExitCode
    } else {
        Write-Error "WingetDiagnosticTool not found. Cannot remediate."
        exit 1
    }
}
