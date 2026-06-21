# Detection.ps1
# Diagnostics script for Microsoft Intune Proactive Remediation

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
    $res = Repair-WingetAlias -DryRun -ErrorAction SilentlyContinue
    if ($res -eq 2) {
        Write-Host "Diagnostics: Winget alias issues detected. Remediation required."
        exit 1
    } else {
        Write-Host "Diagnostics: Winget alias is healthy."
        exit 0
    }
} else {
    Write-Host "WingetDiagnosticTool module not found. Triggering remediation to install/repair."
    exit 1
}
