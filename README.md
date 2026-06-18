# Winget Diagnostic & Remediation Tool

A production-grade, single-profile PowerShell utility designed to diagnose and repair Windows Package Manager (`winget`) execution loops, corrupted reparse points, and registry PATH inconsistencies on Windows 11.

---

## 1. PRODUCT OVERVIEW

On Windows 11, the `winget` command-line tool executes via an **AppExecutionAlias**—a specialized NTFS reparse point located in `%LOCALAPPDATA%\Microsoft\WindowsApps`. 

Corruption of this alias, missing user environment PATH entries, or disabled app execution settings in Windows can lead to:
1. **The "Open With" Loop**: Windows fails to resolve the execution alias target and continuously prompts the user to select an application to open `winget.exe`.
2. **Command Not Found Errors**: Shells fail to locate `winget` due to missing directory references in the User registry.

This tool provides a safe, non-destructive, and reversible diagnostics and remediation pipeline running entirely within the current user's profile context (no administrative privileges required for core repairs).

---

## 2. USER GUIDE

This section covers interactive use, deployment options, and emergency rollback procedures.

### Prerequisites & Policy Bypass
By default, Windows blocks script execution. To run this script in an active PowerShell session, bypass the execution policy for the current process:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

### Execution Modes

#### Interactive Wizard (Default)
Run the script without arguments to launch the text-based console menu:
```powershell
.\Repair-WingetAlias.ps1
```
The wizard will guide you through running diagnostics, performing repairs, setting up logon automation, or rolling back changes.

#### Automated Remediate-All (Unattended)
Perform full diagnostic checks and apply all necessary repairs automatically:
```powershell
.\Repair-WingetAlias.ps1 -Force
```

#### Safe Dry-Run (What-If / Dry-Run Mode)
Preview registry changes, file deletions, and package registrations without applying any modifications:
```powershell
.\Repair-WingetAlias.ps1 -DryRun
# Or use standard PowerShell WhatIf support:
.\Repair-WingetAlias.ps1 -WhatIf -Force
```

#### Scheduled Continuous Repair
Ensure `winget` remains functional after Windows Updates or profile changes. The script automatically chooses the safest installation method based on your access level:
```powershell
.\Repair-WingetAlias.ps1 -ScheduleTask
```
* **Elevated Session (Admin)**: Registers a native Windows Scheduled Task under your user account to run at logon.
* **Standard Session (User)**: Generates a silent startup shortcut in:
  `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Repair-WingetAlias.lnk`

---

## 3. DEVELOPER GUIDE

This section explains the internals, registry changes, and dependency requirements.

### Architecture Workflow

```mermaid
graph TD
    Start[Script Run] --> InitLog[Start Transcript & Log]
    InitLog --> PermCheck{Write Permissions?}
    PermCheck -->|No| ErrExit[Log Error & Exit 1]
    PermCheck -->|Yes| ModeSelect{Check Parameters}
    
    ModeSelect -->|AsJob| SpawnJob[Spawn Background PS Job]
    ModeSelect -->|Rollback| RollbackMode[Restore PATH from Backup]
    ModeSelect -->|ScheduleTask| SetupTask[Install Task / Startup Shortcut]
    ModeSelect -->|Force / Menu| RunDiag[Execute Diagnostic Checks]
    
    RunDiag --> CheckPath[1. Validate PATH Key HKCU]
    RunDiag --> CheckAppX[2. Verify Microsoft.DesktopAppInstaller Package]
    RunDiag --> CheckDeps[3. Audit UWP Dependencies]
    RunDiag --> CheckAlias[4. Validate Alias Reparse Points]
    RunDiag --> CheckToggle[5. Check Registry State Toggles]
    RunDiag --> CheckLoop[6. Active Loop execution check]
    
    CheckLoop --> DiagSummary{Needs Repair?}
    DiagSummary -->|No| SuccessExit[Log Pass & Exit 0]
    DiagSummary -->|Yes| RepairMode[Run Remediation Routine]
    
    RepairMode --> RepPath[Repair Registry PATH]
    RepPath --> RepToggle[Enable Alias Registry States]
    RepToggle --> CleanStubs[Delete Corrupt Alias File Stubs]
    CleanStubs --> RepAppX[Register & Reset AppX Package]
    RepAppX --> VerifyRun[Final Execution Test]
    VerifyRun --> SuccessExit
```

### Registry Modifications Reference

| Target Subsystem | Registry Path | Expected State |
| :--- | :--- | :--- |
| **User environment block** | `HKCU:\Environment` | `PATH` must contain `%LOCALAPPDATA%\Microsoft\WindowsApps`. Value kind must be `REG_EXPAND_SZ` (`ExpandString`). |
| **Winget Alias Toggle** | `HKCU:\Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe` | `State` DWORD value must be `1` (Enabled). |
| **Winget Dev Alias Toggle** | `HKCU:\Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe` | `State` DWORD value must be `1` (Enabled). |
| **Backup Registry Key** | `HKCU:\Environment\PATH_PreRepairBackup` | Stores the original `PATH` string prior to any modifications. Deleted upon rollback. |

### Advanced Technical Implementations
1. **Safety Registry Operations**: The script directly queries raw Registry values using `.GetValue("PATH", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)` to avoid flattening environment variables during backups.
2. **Reparse Point Deletion**: Standard PowerShell `Remove-Item` fails on corrupted or orphaned reparse points. The script bypasses this by utilizing .NET's `[System.IO.File]::Delete($Path)`.
3. **Active Loop Detection**: The script monitors spawned test-executions in a separate background thread with a 3-second timeout. If the process hangs or spawns `OpenWith.exe`, it is flagged as an active execution loop, and the processes are immediately terminated.
4. **Elevated Targeting of Logged-In User Profile**: When executed in an elevated Administrator session, the script does not default to the Administrator's own profile. Instead, it dynamically resolves the currently active standard user profile by detecting the owner of the `explorer.exe` process or querying `Win32_ComputerSystem.UserName`. It translates their SID to target the correct user hive under `HKEY_USERS\<SID>` and performs file operations in their `%LOCALAPPDATA%`, providing comprehensive remediation coverage for the target user while running elevated.

---

## 4. AI / AGENTIC INTERFACE GUIDE

This section defines specifications for other AI agents to execute, parse, and automate operations using this script.

### Script Parameter Schema

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-Force` | Switch | `$false` | Bypasses interactive menus and applies repairs automatically. |
| `-Rollback` | Switch | `$false` | Restores previous PATH value and cleans up backup logs. |
| `-AsJob` | Switch | `$false` | Spawns the script asynchronously as a background PowerShell Job. |
| `-DownloadFallback` | Switch | `$false` | Downloads and installs the latest official `.msixbundle` from Microsoft's GitHub if the local package is missing. |
| `-ScheduleTask` | Switch | `$false` | Installs the logon Scheduled Task or Startup shortcut. |
| `-DryRun` | Switch | `$false` | Simulates all diagnostic and repair steps without modifying the registry or deleting files. |
| `-WhatIf` | Switch | `$false` | Standard dry-run parameter (inherits `SupportsShouldProcess`). |

### Execution Templates

#### Asynchronous Execution (Fire and Forget)
Agents can launch the script in the background and track the job status:
```powershell
$Job = Start-Job -FilePath ".\Repair-WingetAlias.ps1" -ArgumentList "-Force", "-DownloadFallback"
```

#### CLI Log Analysis
The script maintains a structured, time-stamped execution log in `Repair-WingetAlias.log` and a transcript in `Repair-WingetAlias_Transcript.log`.

**Structured Log Regex**:
```regex
^\[(?<Timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[(?<Level>Info|Success|Warn|Error)\] (?<Message>.*)$
```

### Exit Codes & Diagnostics
The script returns the following process exit codes:
- **`0`**: Success. All diagnostic checks passed, or repair operations completed and verified successfully.
- **`1`**: Critical Failure. Encountered access restrictions, registry write permission failures, or the active loop persisted after remediation.
- **`2`**: Package Missing. The `Microsoft.DesktopAppInstaller` AppX package is missing and `-DownloadFallback` was not specified.
- **`3`**: Execution Policy Blocked. Script execution is restricted on the system.
