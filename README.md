# Winget Diagnostic and Remediation Tool

A professional, PowerShell-based diagnostic and remediation script to fix the Winget "Open With" execution alias loop on Windows 11.

## Key Features

- **Execution Alias Repair**: Restores or re-registers the `Microsoft.DesktopAppInstaller` AppX package and resets individual execution aliases.
- **Environment Path Restorer**: Checks, normalizes, and appends `%LOCALAPPDATA%\Microsoft\WindowsApps` to the user's `PATH` registry environment (`HKCU:\Environment`).
- **Interactive CLI Wizard**: A user-friendly console menu to run diagnostics, apply specific repairs, or perform rollbacks.
- **Safety & Dry Run (`-WhatIf`)**: Standard support to preview modifications without applying changes.
- **Double-Redundant Rollback**: Generates a timestamped `.reg` file backup of user environment variables and stores the pre-repair `PATH` in the registry.
- **Background Execution (`-AsJob`)**: Runs silently in the background using PowerShell Jobs.

## How to Run

Because this script modifies the registry, it runs in the current user context and **does not require admin elevation** for primary user-scoped repairs.

### Prerequisites

You may need to bypass the local execution policy to run scripts. In an active PowerShell window:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

### Usage Examples

1. **Interactive Menu (Default)**:
   ```powershell
   .\Repair-WingetAlias.ps1
   ```

2. **Dry Run (Preview changes)**:
   ```powershell
   .\Repair-WingetAlias.ps1 -WhatIf
   ```

3. **Background Job**:
   ```powershell
   .\Repair-WingetAlias.ps1 -AsJob
   ```

4. **Rollback Changes**:
   ```powershell
   .\Repair-WingetAlias.ps1 -Rollback
   ```

5. **Silent Mode (Script Automation)**:
   ```powershell
   .\Repair-WingetAlias.ps1 -Force
   ```
