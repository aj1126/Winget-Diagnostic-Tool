---
name: powershell-robust-admin-patterns
description: Guidelines and patterns for robust PowerShell system administration, including reliable file deletion of system-locked files and session-aware profile resolution under elevation.
---

# PowerShell Robust System Administration Patterns

Use this skill when developing or reviewing PowerShell scripts that perform low-level system operations, such as interacting with user profiles during elevated execution or forcibly deleting system-locked files and reparse points.

## 1. Session-Aware Elevation Profile Resolution
When a PowerShell script runs elevated (Run as Administrator), environment variables like `$env:USERNAME` and `$env:USERPROFILE` may map to the Administrator account rather than the interactive user who launched the script. Querying `explorer.exe` process owner is a common workaround, but in multi-session environments (e.g., Remote Desktop, Fast User Switching), this can return the wrong user.

### Recommended Pattern: Filter by SessionId
Bind the `explorer.exe` query to the current process's `SessionId` to guarantee you resolve the user profile for the current active session.

```powershell
# Get the SessionId of the current PowerShell process
$currentSessionId = (Get-Process -Id $PID).SessionId
$filter = "Name = 'explorer.exe'"

# Add SessionId filter to ensure we only look at the current interactive session
if ($null -ne $currentSessionId) {
    $filter += " and SessionId = $currentSessionId"
}

# Safely query WMI/CIM for the explorer process in this session
$explorerProcs = Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue
if ($explorerProcs) {
    foreach ($ep in $explorerProcs) {
        $owner = Invoke-CimMethod -InputObject $ep -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($owner -and $owner.User) {
            # $owner.User is the original interactive user's username
            Write-Output "Interactive Username: $($owner.User)"
        }
    }
}
```

### Review Checklist:
- [ ] Ensure that elevated profile resolution logic filters processes by `$PID`'s `SessionId`.
- [ ] Avoid relying solely on `$env:USERNAME` when modifying `AppData` or `LocalAppdata` paths in scripts that may run elevated.

---

## 2. Robust File Deletion Hierarchy (System-Locked & Reparse Points)
Execution aliases and specific system files are often implemented as NTFS reparse points and are owned by `TrustedInstaller` or `SYSTEM`. Standard `Remove-Item` or `[System.IO.File]::Delete()` calls frequently fail with `UnauthorizedAccessException`.

### Recommended Pattern: Deletion Fallback Sequence
Implement a multi-stage fallback mechanism when dealing with stubborn files:
1. **Targeted native API (e.g., `fsutil`)**: If the file is a reparse point, attempt native deletion first.
2. **.NET API**: Standard `[System.IO.File]::Delete()`.
3. **ACL Remediation**: Use `takeown.exe` and `icacls.exe` to take ownership and grant `FullControl` (F) to the current user, then retry deletion.
4. **CMD Fallback**: As a last resort, use `cmd.exe /c del /f /q`.

```powershell
$Path = "C:\Path\To\StubbornFile.exe"
$shortPath = $Path # Consider resolving 8.3 short path if long paths are an issue

try {
    # 1. Standard .NET Deletion
    [System.IO.File]::Delete($Path)
} catch [System.UnauthorizedAccessException] {
    Write-Warning "Access Denied. Attempting ACL repair..."
    try {
        # 2. ACL Remediation
        Start-Process takeown.exe -ArgumentList "/f `"$shortPath`"" -NoNewWindow -Wait -ErrorAction Stop
        Start-Process icacls.exe -ArgumentList "`"$shortPath`" /grant `"\`"$($env:USERNAME)\`":(F)`"" -NoNewWindow -Wait -ErrorAction Stop
        
        # Retry .NET Deletion
        [System.IO.File]::Delete($Path)
    } catch {
        Write-Warning "ACL repair failed or insufficient. Attempting cmd fallback..."
        try {
            # 3. CMD Fallback
            Start-Process cmd.exe -ArgumentList "/c del /f /q `"$shortPath`"" -NoNewWindow -Wait -ErrorAction Stop
        } catch {
            Write-Error "Failed to remove file after all fallbacks: $_"
        }
    }
}
```

*Note: For reparse points, prefix this sequence with `fsutil reparsepoint delete "$shortPath"`.*

### Review Checklist:
- [ ] Validate that file deletion routines on potentially locked system files (like WindowsApps aliases) implement ACL remediation fallback (`takeown` / `icacls`).
- [ ] Ensure that native commands (`fsutil`, `takeown`, `icacls`) wait for completion (`-Wait`) and suppress their GUI window (`-NoNewWindow`).
