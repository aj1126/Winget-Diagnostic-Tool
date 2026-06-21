using namespace Microsoft.Win32
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
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidTrailingWhitespace", "")]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "")]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "")]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidOverwritingBuiltInCmdlets", "")]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSShouldProcess", "")]
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
    [switch]$ScheduleTask,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$EventLog
)

# Register type accelerators if not present
$taInstance = [psobject].Assembly.GetType("System.Management.Automation.TypeAccelerators")
if (-not $taInstance::Get.ContainsKey("WindowsIdentity")) {
    $taInstance::Add("WindowsIdentity", [System.Security.Principal.WindowsIdentity])
}
if (-not $taInstance::Get.ContainsKey("File")) {
    $taInstance::Add("File", [System.IO.File])
}

# Register EventLog Source if requested and elevated
if ($EventLog) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("WingetDiagnosticTool")) {
            New-EventLog -LogName Application -Source "WingetDiagnosticTool" -ErrorAction Stop
        }
    } catch {
        # Suppress error (likely not running as Admin)
    }
}

# Helper to rotate log files when they exceed 1MB
function Rotate-LogFile {
    param (
        [string]$Path,
        [string]$BackupPath
    )
    if ([File]::Exists($Path)) {
        try {
            $len = [System.IO.FileInfo]::new($Path).Length
            if ($len -gt 1MB) {
                if ([File]::Exists($BackupPath)) {
                    [File]::Delete($BackupPath)
                }
                [File]::Move($Path, $BackupPath)
            }
        } catch {
            $null = $_
        }
    }
}

# Initialize logging function
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("Info", "Success", "Warn", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    # Write to local log file
    $logPath = Join-Path $PSScriptRoot "Repair-WingetAlias.log"
    $backupPath = Join-Path $PSScriptRoot "Repair-WingetAlias.bak"
    Rotate-LogFile -Path $logPath -BackupPath $backupPath
    
    try {
        Add-Content -Path $logPath -Value $logLine -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    }
    
    # Write to Windows Event Log if requested
    if ($EventLog) {
        $eventType = "Information"
        $eventId = 1001
        switch ($Level) {
            "Success" { $eventType = "Information"; $eventId = 1000 }
            "Info"    { $eventType = "Information"; $eventId = 1001 }
            "Warn"    { $eventType = "Warning"; $eventId = 2000 }
            "Error"   { $eventType = "Error"; $eventId = 3000 }
        }
        try {
            Write-EventLog -LogName Application -Source "WingetDiagnosticTool" -EventId $eventId -EntryType $eventType -Message $Message -ErrorAction Stop
        } catch {
            $null = $_
        }
    }
    
    $color = "White"
    switch ($Level) {
        "Success" { $color = "Green" }
        "Warn"    { $color = "Yellow" }
        "Error"   { $color = "Red" }
        "Info"    { $color = "Cyan" }
    }
    
    Write-Host $logLine -ForegroundColor $color
}

# Safe wrapper around $PSCmdlet.ShouldProcess that handles non-advanced/null contexts gracefully
function Should-Process {
    param (
        [string]$Target,
        [string]$Action
    )
    if ($null -eq $PSCmdlet) {
        return $true
    }
    return $PSCmdlet.ShouldProcess($Target, $Action)
}

# Interactive detection
$IsInteractive = [Environment]::UserInteractive -and ($Host.Name -notmatch "Background|Job|NonInteractive") -and ($null -ne $Host.UI)

# Safe Read-Host that doesn't hang in non-interactive sessions
function Read-HostSafe {
    param (
        [string]$Prompt
    )
    if ($IsInteractive) {
        return Read-Host $Prompt
    } else {
        Write-Log -Message "Read-Host called in non-interactive session. Returning empty string." -Level "Warn"
        return ""
    }
}

# Resolve interactive standard logged-in user profile, even under elevation
function Get-TargetUserAndSid {
    if ($script:TargetUserAndSidCache) {
        return $script:TargetUserAndSidCache
    }

    $currentIdentity = [WindowsIdentity]::GetCurrent()
    $targetUsername = $env:USERNAME
    $targetSid = $currentIdentity.User.Value
    
    $isAdmin = $currentIdentity.Claims | Where-Object { $_.Value -eq "S-1-5-32-544" }
    
    if ($isAdmin) {
        try {
            $currentSessionId = (Get-Process -Id $PID).SessionId
            $filter = "Name = 'explorer.exe'"
            if ($null -ne $currentSessionId) {
                $filter += " and SessionId = $currentSessionId"
            }
            $explorerProcs = Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue
            if ($explorerProcs) {
                foreach ($ep in $explorerProcs) {
                    $owner = Invoke-CimMethod -InputObject $ep -MethodName GetOwner -ErrorAction SilentlyContinue
                    if ($owner -and $owner.User) {
                        $ntAccount = New-Object System.Security.Principal.NTAccount($owner.User)
                        $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
                        if ($sid) {
                            $targetUsername = $owner.User
                            $targetSid = $sid.Value
                            break
                        }
                    }
                }
            }
        } catch {
            Write-Log -Message "Failed to resolve explorer.exe owner: $_" -Level "Warn"
        }
        
        if ($targetUsername -eq $env:USERNAME -and $currentIdentity.Name -match "Administrator") {
            try {
                $compSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
                if ($compSystem -and $compSystem.UserName) {
                    $u = $compSystem.UserName -split "\\" | Select-Object -Last 1
                    $ntAccount = New-Object System.Security.Principal.NTAccount($u)
                    $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
                    if ($sid) {
                        $targetUsername = $u
                        $targetSid = $sid.Value
                    }
                }
            } catch {
                Write-Log -Message "Failed to resolve logged-in user from Win32_ComputerSystem: $_" -Level "Warn"
            }
        }
    }
    
    $script:TargetUserAndSidCache = [pscustomobject]@{
        Username = $targetUsername
        Sid      = $targetSid
        IsAdmin  = [bool]$isAdmin
    }
    
    return $script:TargetUserAndSidCache
}

# Helper to expand environment variables correctly for target user profile
function Expand-TargetUserPath {
    param (
        [string]$Path
    )
    if ([string]::IsNullOrEmpty($Path)) { return "" }
    
    $target = Get-TargetUserAndSid
    $profilePath = ""
    if ($target.IsAdmin) {
        try {
            $profileKey = [Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($target.Sid)")
            if ($profileKey) {
                $profilePath = $profileKey.GetValue("ProfileImagePath", $null)
                $profileKey.Close()
            }
        } catch {
            Write-Log -Message "Failed to resolve profile image path from Registry: $_" -Level "Warn"
        }
    }
    if ([string]::IsNullOrEmpty($profilePath)) {
        $profilePath = $env:USERPROFILE
    }
    
    $expanded = $Path -ireplace '%USERPROFILE%', $profilePath
    $expanded = $expanded -ireplace '%LOCALAPPDATA%', "$profilePath\AppData\Local"
    $expanded = $expanded -ireplace '%APPDATA%', "$profilePath\AppData\Roaming"
    $expanded = [System.Environment]::ExpandEnvironmentVariables($expanded)
    
    return $expanded
}

# Resolve target user's local/roaming folder path
function Get-TargetUserLocalFolder {
    param (
        [string]$SubFolder = "AppData\Local"
    )
    $target = Get-TargetUserAndSid
    
    if ($target.IsAdmin) {
        try {
            $profileKey = [Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($target.Sid)")
            if ($profileKey) {
                $profilePath = $profileKey.GetValue("ProfileImagePath", $null)
                $profileKey.Close()
                if ($profilePath) {
                    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($profilePath)
                    $fullPath = Join-Path $expandedPath $SubFolder
                    if ([System.IO.Directory]::Exists($fullPath)) {
                        return $fullPath
                    }
                }
            }
        } catch {
            Write-Log -Message "Failed to resolve ProfileImagePath from ProfileList: $_" -Level "Warn"
        }
    }
    
    if ($SubFolder -eq "AppData\Local") {
        return $env:LOCALAPPDATA
    }
    return [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
}

$TargetLocalAppData = Get-TargetUserLocalFolder "AppData\Local"

# Get target user's registry key helper
function Get-UserRegistryKey {
    param (
        [string]$SubKeyPath,
        [bool]$Writable = $false
    )
    
    $target = Get-TargetUserAndSid
    if ($target.IsAdmin) {
        try {
            $key = [Registry]::Users.OpenSubKey("$($target.Sid)\$SubKeyPath", $Writable)
            if ($key) { return $key }
        } catch {
            Write-Log -Message "Failed to open target user registry key '$SubKeyPath': $_" -Level "Warn"
        }
    }
    
    try {
        return [Registry]::CurrentUser.OpenSubKey($SubKeyPath, $Writable)
    } catch {
        return $null
    }
}

# Get or create target user's registry key helper
function Get-OrCreateUserRegistryKey {
    param (
        [string]$SubKeyPath,
        [bool]$Writable = $true
    )
    
    $target = Get-TargetUserAndSid
    if ($target.IsAdmin) {
        try {
            $key = [Registry]::Users.OpenSubKey("$($target.Sid)\$SubKeyPath", $Writable)
            if (-not $key) {
                $key = [Registry]::Users.CreateSubKey("$($target.Sid)\$SubKeyPath")
            }
            if ($key) { return $key }
        } catch {
            Write-Log -Message "Failed to open or create target user registry key '$SubKeyPath': $_" -Level "Warn"
        }
    }
    
    try {
        $key = [Registry]::CurrentUser.OpenSubKey($SubKeyPath, $Writable)
        if (-not $key) {
            $key = [Registry]::CurrentUser.CreateSubKey($SubKeyPath)
        }
        return $key
    } catch {
        return $null
    }
}

# Read target user registry value
function Get-UserRegistryValue {
    param (
        [string]$SubKeyPath,
        [string]$ValueName,
        [object]$DefaultValue = $null
    )
    $key = Get-UserRegistryKey -SubKeyPath $SubKeyPath -Writable $false
    if ($key) {
        $val = $key.GetValue($ValueName, $DefaultValue)
        $key.Close()
        return $val
    }
    return $DefaultValue
}

# Write target user registry value
function Set-UserRegistryValue {
    param (
        [string]$SubKeyPath,
        [string]$ValueName,
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$ValueKind = [Microsoft.Win32.RegistryValueKind]::String
    )
    $key = Get-OrCreateUserRegistryKey -SubKeyPath $SubKeyPath -Writable $true
    if ($key) {
        try {
            $key.SetValue($ValueName, $Value, $ValueKind)
            return $true
        } finally {
            $key.Close()
        }
    }
    return $false
}

# Check target user registry key existence
function Test-UserRegistryKey {
    param (
        [string]$SubKeyPath
    )
    $key = Get-UserRegistryKey -SubKeyPath $SubKeyPath -Writable $false
    if ($key) {
        $key.Close()
        return $true
    }
    return $false
}

# Safe user/machine merged PATH session refresher
function Update-SessionPath {
    try {
        $machineKey = [Registry]::LocalMachine.OpenSubKey("System\CurrentControlSet\Control\Session Manager\Environment")
        $machinePath = ""
        if ($machineKey) {
            $machinePath = $machineKey.GetValue("PATH", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $machineKey.Close()
        }
        
        $userPath = Get-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH" -DefaultValue ""
        
        $expandedMachine = [System.Environment]::ExpandEnvironmentVariables($machinePath)
        $expandedUser = Expand-TargetUserPath -Path $userPath
        
        $parts = @()
        if (-not [string]::IsNullOrEmpty($expandedMachine)) {
            $parts += $expandedMachine -split ";"
        }
        if (-not [string]::IsNullOrEmpty($expandedUser)) {
            $parts += $expandedUser -split ";"
        }
        
        $filteredParts = @()
        foreach ($part in $parts) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $filteredParts += $part.Trim()
            }
        }
        
        $env:Path = $filteredParts -join ";"
        Write-Log -Message "Refreshed current session PATH from registry (merged Machine and User paths)." -Level "Success"
    } catch {
        Write-Log -Message "Failed to refresh session PATH: $_" -Level "Warn"
    }
}

# Target user aware AppX Package retriever
function Get-TargetAppxPackage {
    param (
        [string]$Name
    )
    $target = Get-TargetUserAndSid
    $pkg = $null
    if ($target.IsAdmin) {
        $pkg = Get-AppxPackage -Name $Name -User $target.Sid -ErrorAction SilentlyContinue | Select-Object -First 1
    } else {
        $pkg = Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    return $pkg
}

# Initialize transcript functions
function Start-ScriptTranscript {
    $transcriptPath = Join-Path $PSScriptRoot "Repair-WingetAlias_Transcript.log"
    $transcriptBak = Join-Path $PSScriptRoot "Repair-WingetAlias_Transcript.bak"
    Rotate-LogFile -Path $transcriptPath -BackupPath $transcriptBak
    
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
    } catch {
        $null = $_
    }
}

# Clean/Normalize path entries
function Get-NormalizedPath {
    param (
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return (Expand-TargetUserPath -Path $Path).Trim().TrimEnd('\')
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
        $ErrorActionPreference = "Stop"
        
        $currentRawPath = Get-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH" -DefaultValue ""
        if ([string]::IsNullOrEmpty($currentRawPath)) {
            Write-Log -Message "Current User PATH is empty. No backup created." -Level "Info"
            return $true
        }
        
        # 1. Registry backup key
        if (Should-Process -Target "Registry Key HKCU:\Environment" -Action "Create backup registry value 'PATH_PreRepairBackup'") {
            $backupSuccess = Set-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH_PreRepairBackup" -Value $currentRawPath -ValueKind ExpandString
            if ($backupSuccess) {
                Write-Log -Message "Saved path backup to registry key 'PATH_PreRepairBackup'." -Level "Success"
            } else {
                Write-Log -Message "Failed to save path backup to registry key 'PATH_PreRepairBackup'." -Level "Error"
                return $false
            }
        }
        
        # 2. Disk redundant backup file (.reg)
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $regFileName = "Repair-WingetAlias_Backup_$timestamp.reg"
        $regFilePath = Join-Path $PSScriptRoot $regFileName
        
        if (Should-Process -Target "File $regFilePath" -Action "Export environment backup as .reg file") {
            # Registry paths require backslash escaping
            $escapedPath = $currentRawPath.Replace('\', '\\').Replace('"', '\"')
            $target = Get-TargetUserAndSid
            $regKeyPath = if ($target.IsAdmin) { "HKEY_USERS\$($target.Sid)\Environment" } else { "HKEY_CURRENT_USER\Environment" }
            $regContent = @"
Windows Registry Editor Version 5.00

[$regKeyPath]
"PATH"="$escapedPath"
"@
            [File]::WriteAllText($regFilePath, $regContent, [System.Text.Encoding]::Unicode)
            Write-Log -Message "Exported redundant registry backup file to: $regFilePath" -Level "Success"
        }
        return $true
    } catch {
        Write-Log -Message "Error saving environment path backup: $_" -Level "Error"
        return $false
    }
}

# Parse .reg file contents to extract PATH value
function Get-PathFromRegFile {
    param (
        [string]$FilePath
    )
    try {
        $content = [File]::ReadAllText($FilePath)
        # Find PATH line and extract the value
        if ($content -match '(?m)^"PATH"="(.+)"\s*$') {
            $value = $Matches[1]
            # Unescape backslashes and quotes
            $value = $value.Replace('\\', '\').Replace('\"', '"')
            return $value
        }
    } catch {
        Write-Log -Message "Error parsing .reg file ${FilePath}: $_" -Level "Error"
    }
    return $null
}

# Rollback environment variables from backups
function Restore-EnvironmentBackup {
    try {
        $ErrorActionPreference = "Stop"
        
        $backupPath = Get-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH_PreRepairBackup" -DefaultValue ""
        
        if ([string]::IsNullOrEmpty($backupPath)) {
            Write-Log -Message "No path backup key found in registry. Searching for backup .reg files..." -Level "Warn"
            $backupFiles = Get-ChildItem -Path $PSScriptRoot -Filter "Repair-WingetAlias_Backup_*.reg" | Sort-Object LastWriteTime -Descending
            if ($backupFiles) {
                $latestFile = $backupFiles[0]
                Write-Log -Message "Found backup file: $($latestFile.Name) (Last Modified: $($latestFile.LastWriteTime))" -Level "Info"
                
                if (Should-Process -Target "Registry Import" -Action "Restore registry from backup file $($latestFile.FullName)") {
                    $restoredPath = Get-PathFromRegFile -FilePath $latestFile.FullName
                    if (-not [string]::IsNullOrEmpty($restoredPath)) {
                        Set-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH" -Value $restoredPath -ValueKind ExpandString
                        Write-Log -Message "Successfully restored registry from backup file (preserved REG_EXPAND_SZ)." -Level "Success"
                        Update-SessionPath
                        Broadcast-EnvironmentUpdate
                        return $true
                    } else {
                        Write-Log -Message "Failed to parse PATH from backup file $($latestFile.Name)." -Level "Error"
                        return $false
                    }
                }
            } else {
                Write-Log -Message "No registry or file backups found. Rollback cannot be completed." -Level "Error"
                return $false
            }
        } else {
            Write-Log -Message "Found registry backup value: $backupPath" -Level "Info"
            if (Should-Process -Target "Registry Key HKCU:\Environment" -Action "Restore PATH from 'PATH_PreRepairBackup'") {
                Set-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH" -Value $backupPath -ValueKind ExpandString
                
                # Delete backup value using .NET registry key
                $environmentKey = Get-UserRegistryKey -SubKeyPath "Environment" -Writable $true
                if ($environmentKey) {
                    try {
                        $environmentKey.DeleteValue("PATH_PreRepairBackup", $false)
                    } catch {
                        Write-Log -Message "Failed to delete PATH_PreRepairBackup: $_" -Level "Warn"
                    }
                    $environmentKey.Close()
                }
                
                Write-Log -Message "Successfully restored registry PATH value." -Level "Success"
                Update-SessionPath
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
        $ErrorActionPreference = "Stop"
        
        # Security check: verify registry write permissions
        try {
            $testSuccess = Set-UserRegistryValue -SubKeyPath "Environment" -ValueName "RepairWingetWriteTest" -Value "Test" -ValueKind String
            if (-not $testSuccess) { throw "Set-UserRegistryValue returned false" }
            $environmentKey = Get-UserRegistryKey -SubKeyPath "Environment" -Writable $true
            if ($environmentKey) {
                $environmentKey.DeleteValue("RepairWingetWriteTest", $false)
                $environmentKey.Close()
            }
            Write-Log -Message "Security Check: Verified User Environment registry write permissions." -Level "Success"
        } catch {
            Write-Log -Message "Security Check: Target user lacks write permissions to User Environment registry! Profile registry may be corrupted." -Level "Error"
            return $false
        }
        
        $currentRawPath = Get-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH" -DefaultValue ""
        $windowsAppsVar = "%LOCALAPPDATA%\Microsoft\WindowsApps"
        
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
        if (Should-Process -Target "Registry Key HKCU:\Environment" -Action "Update PATH value to: $newRawPath") {
            Set-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH" -Value $newRawPath -ValueKind ExpandString
            Update-SessionPath
            Broadcast-EnvironmentUpdate
            Write-Log -Message "Successfully updated PATH environment variables." -Level "Success"
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
    $wingetPath = "$TargetLocalAppData\Microsoft\WindowsApps\winget.exe"
    if (-not [File]::Exists($wingetPath)) {
        Write-Log -Message "winget.exe alias does not exist at $wingetPath. GHOST POINTER detected!" -Level "Error"
        return "GHOST_POINTER"
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
        } catch {
            Write-Log -Message "Failed to terminate hung winget.exe process: $_" -Level "Warn"
        }
    }
    
    return $loopDetected
}

# Repair AppX Installer Package Registration
function Repair-AppXInstallerPackage {
    $ErrorActionPreference = "Stop"
    Write-Log -Message "Running AppX package re-registration for Microsoft.DesktopAppInstaller..." -Level "Info"
    
    # Import AppX module explicitly (required on PowerShell Core 7+)
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module -Name Appx -ErrorAction SilentlyContinue
    }
    
    $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
    if (-not $pkg) {
        Write-Log -Message "Microsoft.DesktopAppInstaller is not registered for the target user!" -Level "Error"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($pkg.InstallLocation)) {
        Write-Log -Message "Microsoft.DesktopAppInstaller installation directory path is null or empty! Package registration might be severely corrupted." -Level "Error"
        return $false
    }
    
    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
    if (-not [File]::Exists($manifestPath)) {
        Write-Log -Message "Package manifest not found at: $manifestPath" -Level "Error"
        return $false
    }
    
    # Re-register package
    if (Should-Process -Target "AppX Package $($pkg.PackageFullName)" -Action "Re-register AppX package") {
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
        if (Should-Process -Target "AppX Package $($pkg.PackageFullName)" -Action "Reset AppX package data") {
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
    if ([File]::Exists($Path)) {
        if (Should-Process -Target "File $Path" -Action "Delete execution alias file stub") {
            $shortPath = $Path
            try {
                $fso = New-Object -ComObject Scripting.FileSystemObject
                $fsoFile = $fso.GetFile($Path)
                if ($fsoFile -and $fsoFile.ShortPath) {
                    $shortPath = $fsoFile.ShortPath
                }
            } catch {
                $null = $_
            }

            $isReparse = $false
            try {
                $attrs = [File]::GetAttributes($Path)
                $isReparse = $attrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            } catch {
                $null = $_
            }

            if ($isReparse) {
                try {
                    Write-Log -Message "Attempting native NTFS reparse point deletion via fsutil for $shortPath..." -Level "Info"
                    $proc = Start-Process fsutil.exe -ArgumentList "reparsepoint delete `"$shortPath`"" -NoNewWindow -Wait -PassThru -ErrorAction Stop
                    if ($proc.ExitCode -eq 0 -and -not [File]::Exists($Path)) {
                        Write-Log -Message "Deleted reparse point at $Path via fsutil." -Level "Success"
                        return
                    } else {
                        Write-Log -Message "fsutil failed to delete reparse point (ExitCode: $($proc.ExitCode))." -Level "Warn"
                    }
                } catch {
                    Write-Log -Message "Error running fsutil: $_" -Level "Warn"
                }
            }

            try {
                [File]::Delete($Path)
                Write-Log -Message "Deleted file stub at $Path." -Level "Success"
            } catch [System.UnauthorizedAccessException] {
                Write-Log -Message "Access Denied trying to delete $Path. Attempting to take ownership and grant permissions..." -Level "Warn"
                try {
                    Start-Process takeown.exe -ArgumentList "/f `"$shortPath`"" -NoNewWindow -Wait -ErrorAction Stop
                    Start-Process icacls.exe -ArgumentList "`"$shortPath`" /grant `"\`"$($env:USERNAME)\`":(F)`"" -NoNewWindow -Wait -ErrorAction Stop
                    [File]::Delete($Path)
                    Write-Log -Message "Deleted file stub at $Path after ACL repair." -Level "Success"
                } catch {
                    Write-Log -Message "Failed to delete after ACL repair: $_. Attempting cmd fallback..." -Level "Warn"
                    try {
                        Start-Process cmd.exe -ArgumentList "/c del /f /q `"$shortPath`"" -NoNewWindow -Wait -ErrorAction Stop
                        if ([File]::Exists($Path)) {
                            Write-Log -Message "Failed to delete $Path using cmd fallback after ACL repair." -Level "Error"
                        } else {
                            Write-Log -Message "Deleted file stub at $Path via cmd fallback after ACL repair." -Level "Success"
                        }
                    } catch {
                        Write-Log -Message "Failed to remove execution alias file after ACL repair: $_" -Level "Error"
                    }
                }
            } catch {
                Write-Log -Message "Failed to delete $Path using .NET API. Attempting cmd fallback..." -Level "Warn"
                try {
                    Start-Process cmd.exe -ArgumentList "/c del /f /q `"$shortPath`"" -NoNewWindow -Wait -ErrorAction Stop
                    if ([File]::Exists($Path)) {
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
    $ErrorActionPreference = "Stop"
    Write-Log -Message "Initializing offline package downloader..." -Level "Info"
    $downloadUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $tempDir = Join-Path $env:TEMP "WingetRepair"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    $destFile = Join-Path $tempDir "Microsoft.DesktopAppInstaller.msixbundle"
    
    if (Should-Process -Target "Internet Download" -Action "Download from $downloadUrl to $destFile") {
        try {
            # Force secure TLS Protocols (resolve Tls13 dynamically to support older .NET runtimes)
            $securityProtocols = [System.Net.SecurityProtocolType]::Tls12
            $tls13Val = 0
            try {
                $tls13Val = [System.Enum]::Parse([System.Net.SecurityProtocolType], 'Tls13')
            } catch {
                Write-Log -Message "TLS 1.3 enum unavailable on this runtime; using fallback value." -Level "Warn"
                $tls13Val = 12288
            }
            try {
                $securityProtocols = $securityProtocols -bor [System.Net.SecurityProtocolType]$tls13Val
            } catch {
                $null = $_
            }
            [System.Net.ServicePointManager]::SecurityProtocol = $securityProtocols
            
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
    $target = Get-TargetUserAndSid
    
    # We check if we are elevated
    $isAdmin = $target.IsAdmin
    
    if ($isAdmin) {
        Write-Log -Message "Elevated session detected. Attempting to register Windows Scheduled Task..." -Level "Info"
        if (Should-Process -Target "Task Scheduler" -Action "Register Scheduled Task '$taskName' to run at user logon") {
            try {
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Force"
                $trigger = New-ScheduledTaskTrigger -AtLogon -User $target.Username
                $principal = New-ScheduledTaskPrincipal -UserId $target.Username -LogonType Interactive
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
                
                Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
                Write-Log -Message "Successfully registered Windows Scheduled Task '$taskName' for user '$($target.Username)'." -Level "Success"
            } catch {
                Write-Log -Message "Failed to register scheduled task: $_. Falling back to User Startup folder/registry Run key..." -Level "Warn"
                $isAdmin = $false
            }
        }
    }
    
    if (-not $isAdmin) {
        Write-Log -Message "Creating startup execution path for non-elevated deployment..." -Level "Info"
        $startupFolder = Get-UserRegistryValue -SubKeyPath "Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ValueName "Startup" -DefaultValue ""
        if (-not [string]::IsNullOrEmpty($startupFolder)) {
            $startupFolder = Expand-TargetUserPath -Path $startupFolder
        } else {
            $startupFolder = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
        }
        if ([string]::IsNullOrEmpty($startupFolder)) {
            $startupFolder = Join-Path $env:USERPROFILE "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
        }
        $shortcutPath = Join-Path $startupFolder "$taskName.lnk"
        
        $shortcutCreated = $false
        if (Should-Process -Target "Startup Shortcut $shortcutPath" -Action "Create shortcut to execute script on logon") {
            try {
                $wshShell = New-Object -ComObject WScript.Shell
                $shortcut = $wshShell.CreateShortcut($shortcutPath)
                $shortcut.TargetPath = "powershell.exe"
                $shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Force"
                $shortcut.Description = "Automated Winget Execution Alias Repair"
                $shortcut.WorkingDirectory = $PSScriptRoot
                $shortcut.Save()
                Write-Log -Message "Successfully created startup shortcut at: $shortcutPath" -Level "Success"
                $shortcutCreated = $true
            } catch {
                Write-Log -Message "Failed to create startup shortcut: $_. Falling back to Registry Run key..." -Level "Warn"
            }
            
            if (-not $shortcutCreated) {
                # Fallback to Registry Run key (100% CLM compliant)
                try {
                    $runKeyPath = "Software\Microsoft\Windows\CurrentVersion\Run"
                    $runCommand = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Force"
                    Set-UserRegistryValue -SubKeyPath $runKeyPath -ValueName $taskName -Value $runCommand -ValueKind String
                    Write-Log -Message "Successfully created startup entry in registry Run key." -Level "Success"
                } catch {
                    Write-Log -Message "Failed to create startup entry in registry: $_" -Level "Error"
                }
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
    $currentRawPath = Get-UserRegistryValue -SubKeyPath "Environment" -ValueName "PATH" -DefaultValue ""
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
    $dirPath = "$TargetLocalAppData\Microsoft\WindowsApps"
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
    $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
    if ($pkg) {
        $pkgState = "PASS"
        Write-Log -Message "AppX Package Check: Microsoft.DesktopAppInstaller is installed." -Level "Success"
        Write-Log -Message "  - Version: $($pkg.Version)" -Level "Info"
        Write-Log -Message "  - Status: $($pkg.Status)" -Level "Info"
        
        # Verify physical install folder exists
        if (-not [string]::IsNullOrEmpty($pkg.InstallLocation) -and (Test-Path $pkg.InstallLocation)) {
            Write-Log -Message "AppX Installation Directory Check: Folder exists at $($pkg.InstallLocation)." -Level "Success"
        } else {
            $pkgState = "FAIL"
            Write-Log -Message "AppX Installation Directory Check: Folder is MISSING or invalid from $($pkg.InstallLocation)! App registration is corrupted." -Level "Error"
        }
    } else {
        Write-Log -Message "AppX Package Check: Microsoft.DesktopAppInstaller is MISSING!" -Level "Error"
    }

    # Dependency Auditing
    Write-Log -Message "Auditing AppX Package core dependencies..." -Level "Info"
    $vclibs = Get-TargetAppxPackage -Name "*VCLibs.140.00.UWPDesktop*"
    if ($vclibs) {
        Write-Log -Message "Dependency Check: VCLibs UWPDesktop is installed ($($vclibs.Version))." -Level "Success"
    } else {
        Write-Log -Message "Dependency Check: VCLibs UWPDesktop is MISSING! Re-registration might fail." -Level "Warn"
    }
    $uixaml = Get-TargetAppxPackage -Name "*UI.Xaml.2.8*"
    if ($uixaml) {
        Write-Log -Message "Dependency Check: Microsoft.UI.Xaml.2.8 is installed ($($uixaml.Version))." -Level "Success"
    } else {
        $anyxaml = Get-TargetAppxPackage -Name "*UI.Xaml*"
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
        $exists = [File]::Exists($aliasPath)
        if ($exists) {
            $isReparse = $false
            $size = 0
            try {
                $attrs = [File]::GetAttributes($aliasPath)
                $isReparse = $attrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)
                $size = [System.IO.FileInfo]::new($aliasPath).Length
            } catch {
                Write-Log -Message "Failed to retrieve attributes for ${aliasPath}: $_" -Level "Warn"
            }
            
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
        $subKey = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
        if (Test-UserRegistryKey -SubKeyPath $subKey) {
            $state = Get-UserRegistryValue -SubKeyPath $subKey -ValueName "State" -DefaultValue $null
            $isStateEnabled = $false
            if ($null -ne $state) {
                $stateInt = 0
                if ([int]::TryParse($state, [ref]$stateInt)) {
                    if ($stateInt -ne 0) {
                        $isStateEnabled = $true
                    }
                }
            }
            if (-not $isStateEnabled) {
                $settingsState = "FAIL"
                Write-Log -Message "Alias Setting [$aliasKey]: DISABLED or invalid in registry (State = $state)!" -Level "Error"
            } else {
                Write-Log -Message "Alias Setting [$aliasKey]: Enabled/Default (State = $state)." -Level "Success"
            }
        } else {
            Write-Log -Message "Alias Setting [$aliasKey]: Key not present (Default Enabled)." -Level "Success"
        }
    }
    
    # 6. OpenWith loop check
    $loopResult = Test-OpenWithLoop
    $loopDetected = ($loopResult -eq $true -or $loopResult -eq "GHOST_POINTER")
    
    Write-Log -Message "==================================================" -Level "Info"
    Write-Log -Message "                  SUMMARY STATUS                  " -Level "Info"
    Write-Log -Message "  - Environment PATH:  $pathState" -Level "Info"
    Write-Log -Message "  - AppX Package:      $pkgState" -Level "Info"
    Write-Log -Message "  - Execution Aliases: $aliasState" -Level "Info"
    Write-Log -Message "  - Alias Settings:    $settingsState" -Level "Info"
    Write-Log -Message "  - Loop Detected:     $(if ($loopResult -eq $true) { 'YES (FAIL)' } elseif ($loopResult -eq 'GHOST_POINTER') { 'GHOST POINTER (FAIL)' } else { 'NO (PASS)' })" -Level "Info"
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
    $dirPath = "$TargetLocalAppData\Microsoft\WindowsApps"
    if (-not (Test-Path $dirPath)) {
        if (Should-Process -Target "Directory $dirPath" -Action "Create missing WindowsApps folder") {
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
        $subKey = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
        if (Test-UserRegistryKey -SubKeyPath $subKey) {
            $state = Get-UserRegistryValue -SubKeyPath $subKey -ValueName "State" -DefaultValue $null
            $isStateEnabled = $false
            if ($null -ne $state) {
                $stateInt = 0
                if ([int]::TryParse($state, [ref]$stateInt)) {
                    if ($stateInt -ne 0) {
                        $isStateEnabled = $true
                    }
                }
            }
            if (-not $isStateEnabled) {
                if (Should-Process -Target "Registry Key HKCU:\$subKey" -Action "Set State = 1 (Enable alias)") {
                    Set-UserRegistryValue -SubKeyPath $subKey -ValueName "State" -Value 1 -ValueKind DWord
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
        $exists = [File]::Exists($aliasPath)
        if ($exists) {
            $isReparse = $false
            try {
                $attrs = [File]::GetAttributes($aliasPath)
                $isReparse = $attrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            } catch {
                Write-Log -Message "Failed to retrieve attributes for ${aliasPath}: $_" -Level "Warn"
            }
            
            if (-not $isReparse) {
                Write-Log -Message "Corrupted stub file found at $aliasPath (Not a reparse point). Removing..." -Level "Warn"
                Remove-ReparsePoint -Path $aliasPath
            }
        }
    }
    
    # 4. Package repair / Re-registration
    Write-Log -Message "[Step 4/4] Repairing AppX Package Registration..." -Level "Info"
    $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
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
            $version = & "$TargetLocalAppData\Microsoft\WindowsApps\winget.exe" --version 2>&1
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
        
        $choice = Read-HostSafe "Select an option [1-6]"
        
        switch ($choice) {
            "1" {
                Clear-Host
                Run-Diagnostics | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "2" {
                Clear-Host
                Repair-EnvironmentPath | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "3" {
                Clear-Host
                $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
                if ($pkg) {
                    Repair-AppXInstallerPackage | Out-Null
                } else {
                    Write-Log -Message "Package is missing. Downloading..." -Level "Info"
                    Install-WingetFallback
                }
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "4" {
                Clear-Host
                $aliasKeys = @(
                    "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe",
                    "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe"
                )
                foreach ($aliasKey in $aliasKeys) {
                    $subKey = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
                    if (Test-UserRegistryKey -SubKeyPath $subKey) {
                        if (Should-Process -Target "Registry Key HKCU:\$subKey" -Action "Set State = 1 (Enable alias)") {
                            Set-UserRegistryValue -SubKeyPath $subKey -ValueName "State" -Value 1 -ValueKind DWord
                            Write-Log -Message "Enabled alias setting $aliasKey." -Level "Success"
                        }
                    } else {
                        Write-Log -Message "Alias Setting [$aliasKey]: Key not present (Default Enabled)." -Level "Info"
                    }
                }
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "5" {
                Clear-Host
                Restore-EnvironmentBackup | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
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
    if ($DryRun) {
        $WhatIfPreference = $true
    }
    Start-ScriptTranscript

    # Detect non-interactive mode and default to Force mode if no switches are chosen
    if (-not $IsInteractive -and -not $Force -and -not $Rollback -and -not $ScheduleTask -and -not $DryRun) {
        Write-Log -Message "Non-interactive session detected without explicit switches. Defaulting to automatic diagnostic and repair (Force mode)." -Level "Info"
        $Force = $true
    }

    # Handle unattended background logon task switch
    if ($ScheduleTask) {
        Install-UnattendedTask
        exit
    }

    # Handle background execution switch
    if ($AsJob) {
        Write-Output "Spawning repair script as a background PowerShell Job..."
        
        $jobParams = @{}
        if ($Force) { $jobParams['Force'] = $true }
        if ($Rollback) { $jobParams['Rollback'] = $true }
        if ($DownloadFallback) { $jobParams['DownloadFallback'] = $true }
        if ($ScheduleTask) { $jobParams['ScheduleTask'] = $true }
        if ($DryRun) { $jobParams['DryRun'] = $true }
        if ($EventLog) { $jobParams['EventLog'] = $true }
        if ($WhatIfPreference) { $jobParams['WhatIf'] = $true }
        
        $job = Start-Job -ScriptBlock {
            & $using:PSCommandPath @using:jobParams
        }
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

    # Check for automatic Force or DryRun execution
    if ($Force -or $DryRun) {
        if ($DryRun) {
            Write-Log -Message "Dry-run switch detected. Commencing automatic diagnostics and simulated repairs..." -Level "Info"
        } else {
            Write-Log -Message "Force switch detected. Commencing automatic diagnostics and repairs..." -Level "Info"
        }
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

