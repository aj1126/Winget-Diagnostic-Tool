<#
.SYNOPSIS
    Winget Execution Alias Diagnostic and Remediation Tool.
.DESCRIPTION
    Checks for and repairs Winget execution loop and path configuration issues
    on Windows 11. Can be run interactively or automated.
.PARAMETER Rollback
    Restores the previous PATH variable from a backup key or file.
.PARAMETER Force
    Runs diagnostics and applies repairs automatically without interactive prompts.
.PARAMETER AsJob
    Runs the diagnostic and repair routines in a background PowerShell job.
.PARAMETER DownloadFallback
    Enables downloading and installing the latest DesktopAppInstaller package
    from the official Microsoft GitHub releases page if it is missing locally.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [switch]$Rollback,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$AsJob,

    [Parameter(Mandatory = $false)]
    [switch]$DownloadFallback,

    [Parameter(Mandatory = $false)]
    [switch]$ScheduleTask
)

# Initialize logging function
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("Info", "Success", "Warn", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    $logPath = Join-Path $PSScriptRoot "Repair-WingetAlias.log"
    try {
        Add-Content -Path $logPath -Value $logLine -ErrorAction SilentlyContinue
    } catch {}
    
    # Check if we are in a background job or running silently
    # Write-Host works in jobs but we can check if console is interactive
    $color = "White"
    switch ($Level) {
        "Success" { $color = "Green" }
        "Warn"    { $color = "Yellow" }
        "Error"   { $color = "Red" }
        "Info"    { $color = "Cyan" }
    }
    
    Write-Host $logLine -ForegroundColor $color
}

# Initialize transcript functions
function Start-ScriptTranscript {
    $transcriptPath = Join-Path $PSScriptRoot "Repair-WingetAlias_Transcript.log"
    Write-Log -Message "Starting transcript logging to: $transcriptPath" -Level "Info"
    try {
        Start-Transcript -Path $transcriptPath -Append -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Log -Message "Failed to start transcript logging: $_" -Level "Warn"
    }
}

function Stop-ScriptTranscript {
    try {
        Stop-Transcript | Out-Null
        Write-Log -Message "Transcript logging stopped." -Level "Info"
    } catch {}
}

# Clean/Normalize path entries
function Get-NormalizedPath {
    param (
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [System.Environment]::ExpandEnvironmentVariables($Path).Trim().TrimEnd('\')
}

# Broadcast WM_SETTINGCHANGE to environment
function Broadcast-EnvironmentUpdate {
    Write-Log -Message "Broadcasting WM_SETTINGCHANGE to refresh system environment variables..." -Level "Info"
    $signature = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd,
    uint Msg,
    IntPtr wParam,
    string lParam,
    uint fuFlags,
    uint uTimeout,
    out IntPtr lpdwResult
);
'@
    try {
        $type = Add-Type -MemberDefinition $signature -Name "NativeMethods" -Namespace "Win32" -PassThru -ErrorAction SilentlyContinue
        if (-not $type) {
            $type = [Win32.NativeMethods]
        }
        $result = [IntPtr]::Zero
        # WM_SETTINGCHANGE = 0x001A, SMTO_ABORTIFHUNG = 2
        $type::SendMessageTimeout([IntPtr]0xffff, 0x001a, [IntPtr]::Zero, "Environment", 2, 3000, [ref]$result) | Out-Null
        Write-Log -Message "System environment variable refresh broadcast completed." -Level "Success"
    } catch {
        Write-Log -Message "Failed to broadcast environment variable update: $_" -Level "Warn"
    }
}

# Save double-redundant backups of PATH variable
function Save-EnvironmentBackup {
    try {
        $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
        if (-not $regKey) {
            Write-Log -Message "Failed to open HKCU:\Environment registry key." -Level "Error"
            return $false
        }
        
        $currentRawPath = $regKey.GetValue("PATH", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrEmpty($currentRawPath)) {
            Write-Log -Message "Current User PATH is empty. No backup created." -Level "Info"
            return $true
        }
        
        # 1. Registry backup key
        if ($PSCmdlet.ShouldProcess("Registry Key HKCU:\Environment", "Create backup registry value 'PATH_PreRepairBackup'")) {
            $regKey.SetValue("PATH_PreRepairBackup", $currentRawPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Log -Message "Saved path backup to registry key 'PATH_PreRepairBackup'." -Level "Success"
        }
        
        # 2. Disk redundant backup file (.reg)
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $regFileName = "Repair-WingetAlias_Backup_$timestamp.reg"
        $regFilePath = Join-Path $PSScriptRoot $regFileName
        
        if ($PSCmdlet.ShouldProcess("File $regFilePath", "Export environment backup as .reg file")) {
            # Registry paths require backslash escaping
            $escapedPath = $currentRawPath.Replace('\', '\\').Replace('"', '\"')
            $regContent = @"
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Environment]
"PATH"="$escapedPath"
"@
            [System.IO.File]::WriteAllText($regFilePath, $regContent, [System.Text.Encoding]::Unicode)
            Write-Log -Message "Exported redundant registry backup file to: $regFilePath" -Level "Success"
        }
        return $true
    } catch {
        Write-Log -Message "Error saving environment path backup: $_" -Level "Error"
        return $false
    }
}

# Rollback environment variables from backups
function Restore-EnvironmentBackup {
    try {
        $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
        if (-not $regKey) {
            Write-Log -Message "Failed to open HKCU:\Environment registry key." -Level "Error"
            return $false
        }
        
        $backupPath = $regKey.GetValue("PATH_PreRepairBackup", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        
        if ([string]::IsNullOrEmpty($backupPath)) {
            Write-Log -Message "No path backup key found in registry. Searching for backup .reg files..." -Level "Warn"
            $backupFiles = Get-ChildItem -Path $PSScriptRoot -Filter "Repair-WingetAlias_Backup_*.reg" | Sort-Object LastWriteTime -Descending
            if ($backupFiles) {
                $latestFile = $backupFiles[0]
                Write-Log -Message "Found backup file: $($latestFile.Name) (Last Modified: $($latestFile.LastWriteTime))" -Level "Info"
                
                if ($PSCmdlet.ShouldProcess("Registry Import", "Restore registry from backup file $($latestFile.FullName)")) {
                    Start-Process reg.exe -ArgumentList "import `"$($latestFile.FullName)`"" -Wait -NoNewWindow
                    Write-Log -Message "Successfully restored registry from backup file." -Level "Success"
                    Broadcast-EnvironmentUpdate
                    return $true
                }
            } else {
                Write-Log -Message "No registry or file backups found. Rollback cannot be completed." -Level "Error"
                return $false
            }
        } else {
            Write-Log -Message "Found registry backup value: $backupPath" -Level "Info"
            if ($PSCmdlet.ShouldProcess("Registry Key HKCU:\Environment", "Restore PATH from 'PATH_PreRepairBackup'")) {
                $regKey.SetValue("PATH", $backupPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $regKey.DeleteValue("PATH_PreRepairBackup", $false)
                Write-Log -Message "Successfully restored registry PATH value." -Level "Success"
                
                # Update current session path
                $env:Path = [System.Environment]::ExpandEnvironmentVariables($backupPath)
                Broadcast-EnvironmentUpdate
                return $true
            }
        }
        return $false
    } catch {
        Write-Log -Message "Error restoring environment path backup: $_" -Level "Error"
        return $false
    }
}

# Repair environment PATH registry variable
function Repair-EnvironmentPath {
    try {
        $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
        if (-not $regKey) {
            Write-Log -Message "HKCU:\Environment key does not exist. Creating key..." -Level "Warn"
            if ($PSCmdlet.ShouldProcess("Registry Key HKCU:\Environment", "Create missing Registry Key")) {
                $regKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Environment")
            } else {
                return $false
            }
        }
        
        $currentRawPath = $regKey.GetValue("PATH", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $windowsAppsVar = "%LOCALAPPDATA%\Microsoft\WindowsApps"
        $windowsAppsAbs = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
        
        $paths = @()
        if (-not [string]::IsNullOrEmpty($currentRawPath)) {
            $paths = $currentRawPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
        
        $appsPathFound = $false
        $cleanedPaths = [System.Collections.Generic.List[string]]::new()
        
        foreach ($p in $paths) {
            $normalizedP = Get-NormalizedPath -Path $p
            $normalizedApps = Get-NormalizedPath -Path $windowsAppsVar
            
            if ($normalizedP -ieq $normalizedApps) {
                $appsPathFound = $true
            }
            
            # Remove case-insensitive duplicate path entries
            $isDuplicate = $false
            foreach ($cp in $cleanedPaths) {
                if ($normalizedP -ieq (Get-NormalizedPath -Path $cp)) {
                    $isDuplicate = $true
                    break
                }
            }
            
            if (-not $isDuplicate) {
                $cleanedPaths.Add($p)
            } else {
                Write-Log -Message "Cleaned up duplicate path entry in registry: $p" -Level "Warn"
            }
        }
        
        if ($appsPathFound) {
            Write-Log -Message "WindowsApps path is already present in User PATH registry." -Level "Success"
            if ($cleanedPaths.Count -eq $paths.Length) {
                return $true
            }
        } else {
            Write-Log -Message "WindowsApps path ($windowsAppsVar) is MISSING from User PATH registry." -Level "Warn"
            $cleanedPaths.Add($windowsAppsVar)
        }
        
        # Build new PATH variable and normalize trailing/leading semicolons
        $newRawPath = ($cleanedPaths -join ";").Trim(';')
        Write-Log -Message "Proposed User PATH: $newRawPath" -Level "Info"
        
        # Save backup before writing changes
        if (-not (Save-EnvironmentBackup)) {
            Write-Log -Message "Failed to backup path registry key. Aborting repair for safety." -Level "Error"
            return $false
        }
        
        # Apply repair
        if ($PSCmdlet.ShouldProcess("Registry Key HKCU:\Environment", "Update PATH value to: $newRawPath")) {
            $regKey.SetValue("PATH", $newRawPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            $env:Path = [System.Environment]::ExpandEnvironmentVariables($newRawPath)
            Write-Log -Message "Successfully updated PATH environment variables." -Level "Success"
            Broadcast-EnvironmentUpdate
        }
        return $true
    } catch {
        Write-Log -Message "Error repairing environment PATH: $_" -Level "Error"
        return $false
    }
}

# Test for the presence of an active "Open With" execution loop
function Test-OpenWithLoop {
    Write-Log -Message "Testing for active Winget Open With loop..." -Level "Info"
    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (-not (Test-Path $wingetPath)) {
        Write-Log -Message "winget.exe alias does not exist at $wingetPath. Cannot perform execution check." -Level "Warn"
        return $false
    }
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wingetPath
    $psi.Arguments = "--version"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    
    try {
        $started = $proc.Start()
        if (-not $started) {
            Write-Log -Message "Failed to initialize winget.exe process." -Level "Error"
            return $true
        }
    } catch {
        Write-Log -Message "Error spawning winget.exe process: $_" -Level "Error"
        return $true
    }
    
    $timeoutMs = 3000
    $intervalMs = 250
    $elapsed = 0
    $loopDetected = $false
    
    while ($elapsed -lt $timeoutMs) {
        if ($proc.HasExited) {
            break
        }
        
        # Check if Windows spawned the "Open With" dialog
        $openWithProcs = Get-Process -Name "OpenWith" -ErrorAction SilentlyContinue
        if ($openWithProcs) {
            Write-Log -Message "Open With GUI dialog process detected! Execution loop confirmed." -Level "Error"
            $loopDetected = $true
            # Immediately close the dialog process
            $openWithProcs | Stop-Process -Force -ErrorAction SilentlyContinue
            break
        }
        
        Start-Sleep -Milliseconds $intervalMs
        $elapsed += $intervalMs
    }
    
    if (-not $proc.HasExited) {
        Write-Log -Message "winget.exe execution hung (timed out after 3 seconds)." -Level "Error"
        $loopDetected = $true
        try {
            $proc.Kill()
        } catch {}
    }
    
    return $loopDetected
}

# Repair AppX Installer Package Registration
function Repair-AppXInstallerPackage {
    Write-Log -Message "Running AppX package re-registration for Microsoft.DesktopAppInstaller..." -Level "Info"
    
    # Import AppX module explicitly (required on PowerShell Core 7+)
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module -Name Appx -ErrorAction SilentlyContinue
    }
    
    $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
    if (-not $pkg) {
        Write-Log -Message "Microsoft.DesktopAppInstaller is not registered for the current user!" -Level "Error"
        return $false
    }
    
    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
    if (-not (Test-Path $manifestPath)) {
        Write-Log -Message "Package manifest not found at: $manifestPath" -Level "Error"
        return $false
    }
    
    # Re-register package
    if ($PSCmdlet.ShouldProcess("AppX Package $($pkg.PackageFullName)", "Re-register AppX package")) {
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ForceApplicationShutdown -ErrorAction Stop
            Write-Log -Message "Successfully re-registered AppX package." -Level "Success"
        } catch {
            Write-Log -Message "Failed to re-register AppX package: $_" -Level "Error"
            return $false
        }
    }
    
    # Reset package (clears corrupt user state data, Win 10/11)
    if (Get-Command "Reset-AppxPackage" -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess("AppX Package $($pkg.PackageFullName)", "Reset AppX package data")) {
            try {
                Reset-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                Write-Log -Message "Successfully completed package app reset." -Level "Success"
            } catch {
                Write-Log -Message "Warning: Failed to execute Reset-AppxPackage: $_" -Level "Warn"
            }
        }
    }
    
    return $true
}

# Delete corrupted execution alias stubs
function Remove-ReparsePoint {
    param (
        [string]$Path
    )
    if (Test-Path $Path) {
        if ($PSCmdlet.ShouldProcess("File $Path", "Delete execution alias file stub")) {
            try {
                # Use .NET API to safely delete reparse point file stubs
                [System.IO.File]::Delete($Path)
                Write-Log -Message "Deleted file stub at $Path." -Level "Success"
            } catch {
                Write-Log -Message "Failed to delete $Path using .NET API. Attempting cmd fallback..." -Level "Warn"
                try {
                    Start-Process cmd.exe -ArgumentList "/c del /f /q `"$Path`"" -NoNewWindow -Wait
                    if (Test-Path $Path) {
                        Write-Log -Message "Failed to delete $Path using cmd fallback." -Level "Error"
                    } else {
                        Write-Log -Message "Deleted file stub at $Path via cmd fallback." -Level "Success"
                    }
                } catch {
                    Write-Log -Message "Failed to remove execution alias file: $_" -Level "Error"
                }
            }
        }
    }
}

# Download latest Winget MSIX from GitHub releases page
function Install-WingetFallback {
    Write-Log -Message "Initializing offline package downloader..." -Level "Info"
    $downloadUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $tempDir = Join-Path $env:TEMP "WingetRepair"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    $destFile = Join-Path $tempDir "Microsoft.DesktopAppInstaller.msixbundle"
    
    if ($PSCmdlet.ShouldProcess("Internet Download", "Download from $downloadUrl to $destFile")) {
        try {
            # Force secure TLS Protocols
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
            Write-Log -Message "Downloading latest release package from GitHub..." -Level "Info"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $destFile -UseBasicParsing -ErrorAction Stop
            Write-Log -Message "Download completed. Installing package..." -Level "Info"
            Add-AppxPackage -Path $destFile -ErrorAction Stop
            Write-Log -Message "Successfully installed Winget package via downloader." -Level "Success"
        } catch {
            Write-Log -Message "Failed to download or install package: $_" -Level "Error"
        } finally {
            if (Test-Path $destFile) {
                Remove-Item -Path $destFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Install unattended background logon task
function Install-UnattendedTask {
    $taskName = "Repair-WingetAlias"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if ($isAdmin) {
        Write-Log -Message "Elevated session detected. Attempting to register Windows Scheduled Task..." -Level "Info"
        if ($PSCmdlet.ShouldProcess("Task Scheduler", "Register Scheduled Task '$taskName' to run at user logon")) {
            try {
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Force"
                $trigger = New-ScheduledTaskTrigger -AtLogon -User $env:USERNAME
                $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
                
                Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
                Write-Log -Message "Successfully registered Windows Scheduled Task '$taskName'." -Level "Success"
            } catch {
                Write-Log -Message "Failed to register scheduled task: $_. Falling back to User Startup folder shortcut..." -Level "Warn"
                $isAdmin = $false
            }
        }
    }
    
    if (-not $isAdmin) {
        Write-Log -Message "Creating User Startup folder shortcut for non-elevated deployment..." -Level "Info"
        $startupFolder = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
        $shortcutPath = Join-Path $startupFolder "$taskName.lnk"
        
        if ($PSCmdlet.ShouldProcess("Startup Shortcut $shortcutPath", "Create shortcut to execute script on logon")) {
            try {
                $wshShell = New-Object -ComObject WScript.Shell
                $shortcut = $wshShell.CreateShortcut($shortcutPath)
                $shortcut.TargetPath = "powershell.exe"
                $shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Force"
                $shortcut.Description = "Automated Winget Execution Alias Repair"
                $shortcut.WorkingDirectory = $PSScriptRoot
                $shortcut.Save()
                Write-Log -Message "Successfully created startup shortcut at: $shortcutPath" -Level "Success"
            } catch {
                Write-Log -Message "Failed to create startup shortcut: $_" -Level "Error"
            }
        }
    }
}

# Run full diagnostic suite
function Run-Diagnostics {
    Write-Log -Message "==================================================" -Level "Info"
    Write-Log -Message "          WINGET ALIAS DIAGNOSTICS REPORT         " -Level "Info"
    Write-Log -Message "==================================================" -Level "Info"
    
    # 1. Path checks
    $pathState = "FAIL"
    $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment")
    $currentRawPath = ""
    if ($regKey) {
        $currentRawPath = $regKey.GetValue("PATH", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    $windowsAppsVar = "%LOCALAPPDATA%\Microsoft\WindowsApps"
    $foundInRegistry = $false
    
    if (-not [string]::IsNullOrEmpty($currentRawPath)) {
        $paths = $currentRawPath -split ";"
        foreach ($p in $paths) {
            $normalizedP = Get-NormalizedPath -Path $p
            $normalizedTarget = Get-NormalizedPath -Path $windowsAppsVar
            if ($normalizedP -ieq $normalizedTarget) {
                $foundInRegistry = $true
                break
            }
        }
    }
    
    if ($foundInRegistry) {
        $pathState = "PASS"
        Write-Log -Message "PATH Check: $windowsAppsVar is present in registry." -Level "Success"
    } else {
        Write-Log -Message "PATH Check: $windowsAppsVar is MISSING from registry!" -Level "Error"
    }
    
    $foundInProcess = $false
    $procPaths = $env:Path -split ";"
    foreach ($p in $procPaths) {
        if ((Get-NormalizedPath -Path $p) -ieq (Get-NormalizedPath -Path $windowsAppsVar)) {
            $foundInProcess = $true
            break
        }
    }
    
    if ($foundInProcess) {
        Write-Log -Message "Process PATH Check: WindowsApps directory is present in current environment." -Level "Success"
    } else {
        Write-Log -Message "Process PATH Check: WindowsApps directory is MISSING from current environment!" -Level "Warn"
    }
    
    # 2. Directory check
    $dirPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if (Test-Path $dirPath) {
        Write-Log -Message "Directory Check: WindowsApps folder exists at $dirPath." -Level "Success"
    } else {
        Write-Log -Message "Directory Check: WindowsApps folder DOES NOT EXIST!" -Level "Error"
    }
    
    # 3. AppX Package check
    $pkgState = "FAIL"
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module -Name Appx -ErrorAction SilentlyContinue
    }
    $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
    if ($pkg) {
        $pkgState = "PASS"
        Write-Log -Message "AppX Package Check: Microsoft.DesktopAppInstaller is installed." -Level "Success"
        Write-Log -Message "  - Version: $($pkg.Version)" -Level "Info"
        Write-Log -Message "  - Status: $($pkg.Status)" -Level "Info"
    } else {
        Write-Log -Message "AppX Package Check: Microsoft.DesktopAppInstaller is MISSING!" -Level "Error"
    }

    # Dependency Auditing
    Write-Log -Message "Auditing AppX Package core dependencies..." -Level "Info"
    $vclibs = Get-AppxPackage -Name "*VCLibs.140.00.UWPDesktop*" -ErrorAction SilentlyContinue
    if ($vclibs) {
        Write-Log -Message "Dependency Check: VCLibs UWPDesktop is installed ($($vclibs[0].Version))." -Level "Success"
    } else {
        Write-Log -Message "Dependency Check: VCLibs UWPDesktop is MISSING! Re-registration might fail." -Level "Warn"
    }
    $uixaml = Get-AppxPackage -Name "*UI.Xaml.2.8*" -ErrorAction SilentlyContinue
    if ($uixaml) {
        Write-Log -Message "Dependency Check: Microsoft.UI.Xaml.2.8 is installed ($($uixaml[0].Version))." -Level "Success"
    } else {
        $anyxaml = Get-AppxPackage -Name "*UI.Xaml*" -ErrorAction SilentlyContinue
        if ($anyxaml) {
            Write-Log -Message "Dependency Check: Microsoft.UI.Xaml 2.8 is missing, but other UI.Xaml packages are installed." -Level "Warn"
        } else {
            Write-Log -Message "Dependency Check: Microsoft.UI.Xaml is completely MISSING! DesktopAppInstaller will fail to launch." -Level "Error"
        }
    }
    
    # 4. Alias files check
    $aliasState = "PASS"
    $aliases = @("winget.exe", "wingetdev.exe")
    foreach ($alias in $aliases) {
        $aliasPath = Join-Path $dirPath $alias
        if (Test-Path $aliasPath) {
            $fileInfo = Get-Item $aliasPath
            $isReparse = $fileInfo.Attributes -match "ReparsePoint"
            $size = $fileInfo.Length
            
            if ($isReparse) {
                Write-Log -Message "Alias File Check [$alias]: File exists and is a valid Reparse Point." -Level "Success"
            } else {
                $aliasState = "FAIL"
                Write-Log -Message "Alias File Check [$alias]: File exists but is NOT a reparse point (size: $size bytes). Stubs are corrupted!" -Level "Error"
            }
        } else {
            $aliasState = "FAIL"
            Write-Log -Message "Alias File Check [$alias]: File does not exist!" -Level "Error"
        }
    }
    
    # 5. Registry toggles check
    $settingsState = "PASS"
    $regAliasSettings = @(
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe",
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe"
    )
    foreach ($aliasKey in $regAliasSettings) {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
        if (Test-Path $regPath) {
            $state = Get-ItemPropertyValue -Path $regPath -Name "State" -ErrorAction SilentlyContinue
            if ($state -eq 0) {
                $settingsState = "FAIL"
                Write-Log -Message "Alias Setting [$aliasKey]: DISABLED in registry (State = 0)!" -Level "Error"
            } else {
                Write-Log -Message "Alias Setting [$aliasKey]: Enabled/Default (State = $state)." -Level "Success"
            }
        } else {
            Write-Log -Message "Alias Setting [$aliasKey]: Key not present (Default Enabled)." -Level "Success"
        }
    }
    
    # 6. OpenWith loop check
    $loopDetected = Test-OpenWithLoop
    
    Write-Log -Message "==================================================" -Level "Info"
    Write-Log -Message "                  SUMMARY STATUS                  " -Level "Info"
    Write-Log -Message "  - Environment PATH:  $pathState" -Level "Info"
    Write-Log -Message "  - AppX Package:      $pkgState" -Level "Info"
    Write-Log -Message "  - Execution Aliases: $aliasState" -Level "Info"
    Write-Log -Message "  - Alias Settings:    $settingsState" -Level "Info"
    Write-Log -Message "  - Loop Detected:     $(if ($loopDetected) { 'YES (FAIL)' } else { 'NO (PASS)' })" -Level "Info"
    Write-Log -Message "==================================================" -Level "Info"
    
    $needsRepair = ($pathState -eq "FAIL" -or $pkgState -eq "FAIL" -or $aliasState -eq "FAIL" -or $settingsState -eq "FAIL" -or $loopDetected)
    return $needsRepair
}

# Run full automatic repair routine
function Repair-All {
    Write-Log -Message "Starting automated repair routine..." -Level "Info"
    
    # 1. Path Repair
    Write-Log -Message "[Step 1/4] Repairing User environment PATH..." -Level "Info"
    $pathSuccess = Repair-EnvironmentPath
    if ($pathSuccess) {
        Write-Log -Message "PATH repair completed." -Level "Success"
    } else {
        Write-Log -Message "PATH repair failed." -Level "Error"
    }
    
    # Ensure WindowsApps folder exists
    $dirPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if (-not (Test-Path $dirPath)) {
        if ($PSCmdlet.ShouldProcess("Directory $dirPath", "Create missing WindowsApps folder")) {
            New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
            Write-Log -Message "Created folder at $dirPath." -Level "Success"
        }
    }
    
    # 2. Alias Setting Repair
    Write-Log -Message "[Step 2/4] Verifying and re-enabling execution aliases in registry..." -Level "Info"
    $regAliasSettings = @(
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe",
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe"
    )
    foreach ($aliasKey in $regAliasSettings) {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
        if (Test-Path $regPath) {
            $state = Get-ItemPropertyValue -Path $regPath -Name "State" -ErrorAction SilentlyContinue
            if ($state -eq 0) {
                if ($PSCmdlet.ShouldProcess("Registry Key $regPath", "Set State = 1 (Enable alias)")) {
                    Set-ItemProperty -Path $regPath -Name "State" -Value 1 -Force
                    Write-Log -Message "Re-enabled alias settings for $aliasKey." -Level "Success"
                }
            }
        }
    }
    
    # 3. Clean corrupted alias stubs
    Write-Log -Message "[Step 3/4] Checking and removing corrupted execution alias stubs..." -Level "Info"
    $aliases = @("winget.exe", "wingetdev.exe")
    foreach ($alias in $aliases) {
        $aliasPath = Join-Path $dirPath $alias
        if (Test-Path $aliasPath) {
            $fileInfo = Get-Item $aliasPath
            $isReparse = $fileInfo.Attributes -match "ReparsePoint"
            if (-not $isReparse) {
                Write-Log -Message "Corrupted stub file found at $aliasPath (Not a reparse point). Removing..." -Level "Warn"
                Remove-ReparsePoint -Path $aliasPath
            }
        }
    }
    
    # 4. Package repair / Re-registration
    Write-Log -Message "[Step 4/4] Repairing AppX Package Registration..." -Level "Info"
    $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
    if (-not $pkg) {
        Write-Log -Message "Microsoft.DesktopAppInstaller package is missing!" -Level "Error"
        if ($DownloadFallback) {
            Install-WingetFallback
        } else {
            Write-Log -Message "Please run script with -DownloadFallback switch to install Winget automatically." -Level "Info"
        }
    } else {
        $packageSuccess = Repair-AppXInstallerPackage
        if ($packageSuccess) {
            Write-Log -Message "AppX package registration repaired." -Level "Success"
        } else {
            Write-Log -Message "AppX package registration repair failed." -Level "Error"
        }
    }
    
    Write-Log -Message "Remediation actions finished. Testing Winget execution..." -Level "Info"
    
    # Verify execution
    $loopDetected = Test-OpenWithLoop
    if ($loopDetected) {
        Write-Log -Message "Verification Failed: Winget 'Open With' execution loop is still active." -Level "Error"
    } else {
        try {
            $version = & "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" --version 2>&1
            Write-Log -Message "Verification Success: Winget is working properly (Version: $($version.ToString().Trim()))." -Level "Success"
        } catch {
            Write-Log -Message "Verification Warn: Winget file verified, but execution returned: $_. Restarting your terminal may be required." -Level "Warn"
        }
    }
}

# Interactive wizard menu loop
function Show-InteractiveMenu {
    $title = @"
==================================================
      WINGET EXECUTION LOOP REPAIR WIZARD
==================================================
"@
    
    while ($true) {
        Clear-Host
        Write-Host $title -ForegroundColor Cyan
        Write-Host "Active Mode: " -NoNewline
        if ($WhatIfPreference) {
            Write-Host "DRY RUN (What-If)" -ForegroundColor Yellow
        } else {
            Write-Host "LIVE / REMEDIATION" -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "[1] Run Full Diagnostics"
        Write-Host "[2] Apply Path Repair (Add WindowsApps to PATH)"
        Write-Host "[3] Reset / Re-register DesktopAppInstaller Package"
        Write-Host "[4] Enable App Execution Aliases (Registry Settings)"
        Write-Host "[5] Roll Back Previous Changes"
        Write-Host "[6] Exit"
        Write-Host ""
        
        $choice = Read-Host "Select an option [1-6]"
        
        switch ($choice) {
            "1" {
                Clear-Host
                Run-Diagnostics | Out-Null
                Read-Host "`nPress Enter to return to menu"
            }
            "2" {
                Clear-Host
                Repair-EnvironmentPath | Out-Null
                Read-Host "`nPress Enter to return to menu"
            }
            "3" {
                Clear-Host
                $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
                if ($pkg) {
                    Repair-AppXInstallerPackage | Out-Null
                } else {
                    Write-Log -Message "Package is missing. Downloading..." -Level "Info"
                    Install-WingetFallback
                }
                Read-Host "`nPress Enter to return to menu"
            }
            "4" {
                Clear-Host
                $aliasKeys = @(
                    "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe",
                    "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe"
                )
                foreach ($aliasKey in $aliasKeys) {
                    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
                    if (Test-Path $regPath) {
                        if ($PSCmdlet.ShouldProcess("Registry Key $regPath", "Set State = 1 (Enable alias)")) {
                            Set-ItemProperty -Path $regPath -Name "State" -Value 1 -Force
                            Write-Log -Message "Enabled alias setting $aliasKey." -Level "Success"
                        }
                    } else {
                        Write-Log -Message "Alias Setting [$aliasKey]: Key not present (Default Enabled)." -Level "Info"
                    }
                }
                Read-Host "`nPress Enter to return to menu"
            }
            "5" {
                Clear-Host
                Restore-EnvironmentBackup | Out-Null
                Read-Host "`nPress Enter to return to menu"
            }
            "6" {
                Write-Host "Exiting wizard. Goodbye!" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "Invalid option. Please choose [1-6]" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

# --- SCRIPT MAIN EXECUTION ---

try {
    Start-ScriptTranscript

    # Handle unattended background logon task switch
    if ($ScheduleTask) {
        Install-UnattendedTask
        exit
    }

    # Handle background execution switch
    if ($AsJob) {
        Write-Output "Spawning repair script as a background PowerShell Job..."
        
        $argsArray = @()
        if ($Force) { $argsArray += "-Force" }
        if ($Rollback) { $argsArray += "-Rollback" }
        if ($DownloadFallback) { $argsArray += "-DownloadFallback" }
        if ($WhatIfPreference) { $argsArray += "-WhatIf" }
        
        $job = Start-Job -FilePath $PSCommandPath -ArgumentList $argsArray
        Write-Output "Job started successfully. ID: $($job.Id), Name: $($job.Name)"
        Write-Output "You can check job status using: Get-Job -Id $($job.Id)"
        Write-Output "Retrieve job logs in real time from: $(Join-Path $PSScriptRoot 'Repair-WingetAlias.log')"
        exit
    }

    # Check for Rollback request
    if ($Rollback) {
        Write-Log -Message "Rollback switch detected. Commencing restoration..." -Level "Info"
        Restore-EnvironmentBackup | Out-Null
        exit
    }

    # Check for automatic Force execution
    if ($Force) {
        Write-Log -Message "Force switch detected. Commencing automatic diagnostics and repairs..." -Level "Info"
        $needsRepair = Run-Diagnostics
        if ($needsRepair) {
            Repair-All
        } else {
            Write-Log -Message "All checks passed. No repair necessary." -Level "Success"
        }
        exit
    }

    # Otherwise, run interactive menu wizard
    Show-InteractiveMenu
} finally {
    Stop-ScriptTranscript
}
