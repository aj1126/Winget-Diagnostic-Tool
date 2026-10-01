# Remediation.ps1
# Remediation script for Microsoft Intune Proactive Remediation
# Resolves Windows Package Manager (winget) AppExecutionAlias failures (User Context)

[CmdletBinding()]
param()

# 1. Identity & Context Guard (Must run in User context)
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.IsSystem -or $env:USERNAME -ieq "SYSTEM") {
    Write-Output "Configuration Error: Intune Remediation script must be configured to run in User context ('Run this script using the logged-on credentials = Yes')."
    $exitCode = 1
    if ($env:IsTestRunner -eq "true" -or (Get-Variable -Name "IsTestRunner" -Scope "global" -ErrorAction SilentlyContinue).Value) {
        return $exitCode
    } else {
        exit $exitCode
    }
}

# 2. Module Discovery (Tier 1: Module-aware)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Get-Location
}

$localManifest = Join-Path $ScriptDir "..\WingetDiagnosticTool\WingetDiagnosticTool.psd1"
if (Test-Path $localManifest) {
    Import-Module $localManifest -Force -ErrorAction SilentlyContinue
} else {
    Import-Module WingetDiagnosticTool -ErrorAction SilentlyContinue
}

$remediationLog = [System.Collections.Generic.List[string]]::new()
$success = $true

if (Get-Command Repair-AppExecutionAliases -ErrorAction SilentlyContinue) {
    # Tier 1: Execute remediation using modular public cmdlets
    Write-Output "Initiating WingetDiagnosticTool module remediation..."

    # Step A: Environment PATH
    try {
        $pRes = Repair-EnvironmentPath
        if ($pRes) { $remediationLog.Add("Repaired User environment PATH") }
    } catch {
        $remediationLog.Add("PATH repair error: $_")
        $success = $false
    }

    # Step B: Registry Execution Alias
    try {
        $aRes = Repair-AppExecutionAliases
        if ($aRes) { $remediationLog.Add("Repaired AppExecutionAlias registry settings") }
    } catch {
        $remediationLog.Add("Alias registry repair error: $_")
        $success = $false
    }

    # Step C: Corrupted alias stubs
    try {
        $sRes = Repair-AliasStubs
        if ($sRes) {
            $remediationLog.Add("Cleaned corrupted alias stubs")
        } else {
            $remediationLog.Add("Stub cleanup error: a corrupted alias stub could not be removed")
            $success = $false
        }
    } catch {
        $remediationLog.Add("Stub cleanup error: $_")
        $success = $false
    }

    # Step D: Shadowing files
    try {
        $shRes = Repair-ShadowingFiles
        if ($shRes) { $remediationLog.Add("Cleaned shadowing files") }
    } catch {
        $remediationLog.Add("Shadowing file cleanup error: $_")
        $success = $false
    }

    # Step E: AppX Registration
    try {
        $pkgRes = Repair-AppXInstallerPackage
        if ($pkgRes) { $remediationLog.Add("Re-registered DesktopAppInstaller AppX package") }
    } catch {
        $remediationLog.Add("AppX registration error: $_")
        $success = $false
    }
} else {
    # Tier 2: Self-contained fallback remediation (zero external dependencies)
    # HKCU root; the test runner substitutes its in-memory MockRegistry so tests never touch the real registry
    $hkcu = if ('MockRegistry' -as [type]) { ('MockRegistry' -as [type])::CurrentUser } else { [Microsoft.Win32.Registry]::CurrentUser }
    Write-Output "Module not present. Initiating self-contained fallback remediation..."
    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path $env:USERPROFILE "AppData\Local"
    }
    $winAppsDir = if (-not [string]::IsNullOrWhiteSpace($localAppData)) { Join-Path $localAppData "Microsoft\WindowsApps" } else { "" }
    $wingetPath = if (-not [string]::IsNullOrWhiteSpace($winAppsDir)) { Join-Path $winAppsDir "winget.exe" } else { "" }
    $windowsAppsVar = "%LOCALAPPDATA%\Microsoft\WindowsApps"

    # Step A: Ensure WindowsApps folder exists
    if ([string]::IsNullOrWhiteSpace($winAppsDir) -or -not (Test-Path $winAppsDir)) {
        try {
            New-Item -ItemType Directory -Path $winAppsDir -Force | Out-Null
            $remediationLog.Add("Created missing WindowsApps directory")
        } catch {
            $remediationLog.Add("Failed to create WindowsApps folder: $_")
            $success = $false
        }
    }

    # Step B: Repair User PATH in HKCU:\Environment
    try {
        $envKey = $hkcu.OpenSubKey("Environment", $true)
        if ($envKey) {
            $userPath = $envKey.GetValue("PATH", "")
            $foundInUserPath = $false
            if (-not [string]::IsNullOrEmpty($userPath)) {
                foreach ($p in ($userPath -split ";")) {
                    if ($p.TrimEnd('\') -ieq $winAppsDir.TrimEnd('\') -or $p.TrimEnd('\') -ieq $windowsAppsVar.TrimEnd('\')) {
                        $foundInUserPath = $true
                        break
                    }
                }
            }
            if (-not $foundInUserPath) {
                $newPath = if ([string]::IsNullOrEmpty($userPath)) { $windowsAppsVar } else { "$userPath;$windowsAppsVar" }
                $envKey.SetValue("PATH", $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $remediationLog.Add("Appended WindowsApps to User PATH in registry")
            }
            $envKey.Close()
        }
    } catch {
        $remediationLog.Add("Failed to update User PATH: $_")
        $success = $false
    }

    # Step C: Re-enable AppExecutionAlias in Registry (State = 1)
    try {
        $subKeyPath = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"
        $aliasKey = $hkcu.OpenSubKey($subKeyPath, $true)
        if ($null -eq $aliasKey) {
            $aliasKey = $hkcu.CreateSubKey($subKeyPath)
        }
        if ($aliasKey) {
            $aliasKey.SetValue("State", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $aliasKey.Close()
            $remediationLog.Add("Re-enabled winget execution alias in registry (State = 1)")
        }
    } catch {
        $remediationLog.Add("Failed to set alias registry setting: $_")
        $success = $false
    }

    # Step D: Delete corrupted stub file if not a reparse point
    if (-not [string]::IsNullOrWhiteSpace($wingetPath) -and (Test-Path $wingetPath)) {
        try {
            $fileClass = if ('MockFile' -as [type]) { 'MockFile' -as [type] } else { [System.IO.File] }
            $attrs = $fileClass::GetAttributes($wingetPath)
            if (-not $attrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                $fileClass::Delete($wingetPath)
                $remediationLog.Add("Deleted corrupted non-reparse point stub at $wingetPath")
            }
        } catch {
            $remediationLog.Add("Failed to delete corrupted stub: $_")
            $success = $false
        }
    }

    # Step E: Re-register AppX package if corrupted
    try {
        $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
        if ($pkg -and $pkg.InstallLocation -and (Test-Path $pkg.InstallLocation)) {
            $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
            if (Test-Path $manifestPath) {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ErrorAction SilentlyContinue
                $remediationLog.Add("Re-registered Microsoft.DesktopAppInstaller from AppxManifest")
            }
        }
    } catch {
        $remediationLog.Add("AppX re-registration notice: $_")
    }
}

# 3. Post-Remediation Functional Verification Probe (3-second ceiling)
$targetLocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($targetLocalAppData)) {
    $targetLocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
}
if ([string]::IsNullOrWhiteSpace($targetLocalAppData)) {
    $targetLocalAppData = Join-Path $env:USERPROFILE "AppData\Local"
}
$probePath = if (-not [string]::IsNullOrWhiteSpace($targetLocalAppData)) {
    Join-Path $targetLocalAppData "Microsoft\WindowsApps\winget.exe"
} else {
    $null
}
$verified = $false
$versionStr = $null

if ($probePath -and (Test-Path $probePath)) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $probePath
    $psi.Arguments = "--version"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $exited = $proc.WaitForExit(3000)
        if ($exited -and $proc.ExitCode -eq 0) {
            $verified = $true
            $versionStr = $proc.StandardOutput.ReadToEnd().Trim()
        } else {
            if (-not $exited) {
                try { $proc.Kill() } catch { $null = $_ }
            }
        }
    } catch {
        $null = $_
    }
}

# 4. Final Output and Exit Determination
if ($verified) {
    $logSummary = if ($remediationLog.Count -gt 0) { " Actions: " + ($remediationLog -join "; ") + "." } else { "" }
    Write-Output "Success: Winget execution alias successfully remediated (Version: $versionStr).$logSummary"
    $exitCode = 0
} else {
    if ($success -and $remediationLog.Count -gt 0) {
        # Remediation actions completed; terminal/logon refresh may be needed to update process token
        Write-Output "Success: Remediation actions applied ($($remediationLog -join '; ')). Terminal refresh may be required."
        $exitCode = 0
    } else {
        Write-Output "Error: Remediation failed to restore healthy winget execution. Log: $($remediationLog -join '; ')"
        $exitCode = 1
    }
}

$isTestRunner = $env:IsTestRunner -eq "true" -or (Get-Variable -Name "IsTestRunner" -Scope "global" -ErrorAction SilentlyContinue).Value
if ($isTestRunner) {
    return $exitCode
} else {
    exit $exitCode
}
