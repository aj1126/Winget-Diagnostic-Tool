# Detection.ps1
# Diagnostics and compliance detection script for Microsoft Intune Proactive Remediation
# Evaluates Windows Package Manager (winget) AppExecutionAlias health (User Context)

[CmdletBinding()]
param()

# 1. Identity & Context Guard (Must run in User context)
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.IsSystem -or $env:USERNAME -ieq "SYSTEM") {
    Write-Output "Configuration Error: Intune Detection script must be configured to run in User context ('Run this script using the logged-on credentials = Yes')."
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

# 3. Health Evaluation
$issues = [System.Collections.Generic.List[string]]::new()
$wingetVersion = $null

if (Get-Command Run-Diagnostics -ErrorAction SilentlyContinue) {
    # Execute full diagnostic sweep via module engine
    $needsRepair = Run-Diagnostics
    if ($needsRepair) {
        $issues.Add("Diagnostic sweep identified broken or degraded alias components")
    } else {
        # Quick verification of execution
        try {
            $localAppData = $env:LOCALAPPDATA
            if ([string]::IsNullOrWhiteSpace($localAppData)) {
                $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            }
            if ([string]::IsNullOrWhiteSpace($localAppData)) {
                $localAppData = Join-Path $env:USERPROFILE "AppData\Local"
            }
            $targetWinget = if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
                Join-Path $localAppData "Microsoft\WindowsApps\winget.exe"
            } else { $null }
            if ($targetWinget -and (Test-Path $targetWinget)) {
                $wingetVersion = & $targetWinget --version 2>&1
            } else {
                $wingetVersion = & winget.exe --version 2>&1
            }
        } catch {
            $issues.Add("winget.exe execution threw error: $_")
        }
    }
} else {
    # Tier 2: Self-contained fallback evaluation (zero external dependencies)
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

    # A. Directory check
    if ([string]::IsNullOrWhiteSpace($winAppsDir) -or -not (Test-Path $winAppsDir)) {
        $issues.Add("WindowsApps directory does not exist at $winAppsDir")
    }

    # B. User PATH check
    $userEnvKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment")
    $userPath = if ($userEnvKey) { $userEnvKey.GetValue("PATH", "") } else { "" }
    if ($userEnvKey) { $userEnvKey.Close() }

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
        $issues.Add("WindowsApps directory is missing from User PATH in registry")
    }

    # C. Execution alias file and ReparsePoint check
    if (-not [string]::IsNullOrWhiteSpace($wingetPath) -and (Test-Path $wingetPath)) {
        try {
            $fileClass = if ('MockFile' -as [type]) { 'MockFile' -as [type] } else { [System.IO.File] }
            $attrs = $fileClass::GetAttributes($wingetPath)
            if (-not $attrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                $issues.Add("winget.exe exists but is NOT a valid reparse point (corrupted stub)")
            }
        } catch {
            $issues.Add("Unable to read attributes for ${wingetPath}: $_")
        }
    } else {
        $issues.Add("winget.exe does not exist in $winAppsDir")
    }

    # D. Registry alias toggle check
    $aliasKeyPath = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"
    $aliasKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($aliasKeyPath)
    if ($aliasKey) {
        $stateVal = $aliasKey.GetValue("State", $null)
        $aliasKey.Close()
        if ($null -ne $stateVal) {
            $stateInt = 0
            if ([int]::TryParse($stateVal.ToString(), [ref]$stateInt)) {
                if ($stateInt -eq 0) {
                    $issues.Add("Winget execution alias is explicitly DISABLED in registry (State = 0)")
                }
            }
        }
    }

    # E. AppX package registration check
    $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
    if (-not $pkg) {
        $issues.Add("Microsoft.DesktopAppInstaller AppX package is not registered for CurrentUser")
    }

    # F. Non-blocking functional execution probe (3-second ceiling)
    if ($issues.Count -eq 0) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $wingetPath
        $psi.Arguments = "--version"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
            $exited = $proc.WaitForExit(3000)
            if ($exited) {
                if ($proc.ExitCode -eq 0) {
                    $wingetVersion = $proc.StandardOutput.ReadToEnd().Trim()
                } else {
                    $issues.Add("winget.exe returned non-zero exit code $($proc.ExitCode)")
                }
            } else {
                try { $proc.Kill() } catch { $null = $_ }
                $issues.Add("winget.exe execution timed out (possible OpenWith dialog hang)")
            }
        } catch {
            $issues.Add("Failed to execute winget.exe: $_")
        }
    }
}

# 4. Final Verdict and Output
if ($issues.Count -gt 0) {
    Write-Output "Non-compliant: Winget alias issues detected: $($issues -join '; '). Remediation required."
    $exitCode = 1
} else {
    $verStr = if ($wingetVersion) { " (Version: $wingetVersion)" } else { "" }
    Write-Output "Compliant: Winget execution alias and environment are healthy$verStr."
    $exitCode = 0
}

# Test runner vs production exit discipline
$isTestRunner = $env:IsTestRunner -eq "true" -or (Get-Variable -Name "IsTestRunner" -Scope "global" -ErrorAction SilentlyContinue).Value
if ($isTestRunner) {
    return $exitCode
} else {
    exit $exitCode
}
