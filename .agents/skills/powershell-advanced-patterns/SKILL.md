---
name: powershell-advanced-patterns
description: Consolidated guidelines for advanced PowerShell scripting and testing, covering .NET type mocking via accelerators, scope isolation in modules, and robust admin privilege handling/NTFS file deletion.
---

# Advanced PowerShell Scripting & Testing Guidelines

Use this skill when developing, refactoring, or reviewing advanced PowerShell modules and test suites in this repository. It consolidates patterns for mocking, sandbox environment setup, scope/session isolation, and robust elevated administration actions.

---

## 1. Mocking & Sandbox Testing Patterns

### A. Type Accelerator Redirection Pattern

Fully qualified .NET class names (e.g., `[System.IO.File]` or `[Microsoft.Win32.Registry]`) bypass custom type accelerator overrides because PowerShell resolves them directly via CLR type lookups.

#### Recommended Implementation:

1. **In the Script Under Test**:
   - Register the short type accelerator dynamically at the top of the script if not already present:
     ```powershell
     $taInstance = [psobject].Assembly.GetType("System.Management.Automation.TypeAccelerators")
     if (-not $taInstance::Get.ContainsKey("File")) {
         $taInstance::Add("File", [System.IO.File])
     }
     ```
   - Replace all occurrences of `[System.IO.File]` with `[File]` throughout the script.
2. **In the Test Runner**:
   - Register the short name to point to your mock class:
     ```powershell
     $ta::Add("File", [MockFile])
     ```

### B. Fully Qualified Type Mocking via Class Reference Variables

When code under test calls fully qualified static methods directly, replacing all instances with a short name might be verbose.

#### Recommended Implementation:

1. **In the Script/Module Under Test**:
   Declare script-scoped class reference variables at the top of the file/module helper:
   ```powershell
   $script:WindowsIdentityClass = [System.Security.Principal.WindowsIdentity]
   $script:RegistryClass = [Microsoft.Win32.Registry]

   if ($env:IsTestRunner) {
       $script:WindowsIdentityClass = [MockWindowsIdentity]
       $script:RegistryClass = [MockRegistry]
   }
   ```
2. **Throughout the Script**:
   Invoke static methods/properties through the reference variable:
   ```powershell
   $identity = $script:WindowsIdentityClass::GetCurrent()
   $key = $script:RegistryClass::CurrentUser.OpenSubKey("Environment")
   ```

### C. Path Normalization in Mocks

Asserting against command execution strings with file paths often fails when run in sandboxes due to temporary host-specific absolute paths.
* **Pattern**: Normalize absolute temporary paths back to relative ones in test mock assertions:
  ```powershell
  $normalizedOutFile = $OutFile -replace '[A-Z]:\\.*\\Temp\\', 'Temp\'
  $global:CalledCmdlets.Add("Invoke-WebRequest: $Uri -> $normalizedOutFile")
  ```

---

## 2. Module Scope & Environment Isolation

### A. Dot-Sourcing Scope & `$WhatIfPreference` Leakage

Dot-sourcing a script under test running with `-DryRun` or `-WhatIf` sets `$WhatIfPreference = $true` in the caller's session scope, persisting after execution and silencing subsequent disk writes in `finally` blocks.
* **Pattern**: Explicitly reset `$WhatIfPreference = $false` at the start of the test runner's `finally` block:
  ```powershell
  try {
      . .\ScriptToTest.ps1 -DryRun
  } finally {
      $WhatIfPreference = $false
      $finalState | ConvertTo-Json | Out-File "final_state.json"
  }
  ```

### B. Test Harness Module Scope Isolation

PowerShell modules run in an isolated **Module Session State**. They bypass script-scoped mock functions in custom test runners.
* **Pattern 1: Mock Cmdlets globally**: Prefix all mock function definitions in the test runner with the `global:` scope modifier:
  ```powershell
  function global:Get-AppxPackage {
      param([string]$Name)
      $global:CalledCmdlets.Add("Get-AppxPackage: $Name")
  }
  ```
* **Pattern 2: Propagate configurations via Environment Variables**: Use process-wide environment variables instead of global/script variables to control mock execution inside imported modules:
  ```powershell
  $env:IsTestRunner = "true"
  ```

### C. Path Resolution Pitfall (`$PSScriptRoot` vs LocalAppData)

In a module, `$PSScriptRoot` points to the module's installation directory, which is often read-only.
* **Pattern**: Define a persistent, user-writable data directory leveraging `$env:LOCALAPPDATA` (or `$env:TEMP` as fallback) for all module logs, exports, and backup files:
  ```powershell
  $DiagnosticDataDir = Join-Path $env:LOCALAPPDATA "ModuleName"
  if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
      $DiagnosticDataDir = Join-Path $env:TEMP "ModuleName"
  }
  ```

---

## 3. Elevated Administration & File Operations

### A. Session-Aware Elevation Profile Resolution

When running elevated, environment variables like `$env:USERNAME` map to the Administrator account. Querying `explorer.exe` process owner can resolve the wrong user in multi-session environments.
* **Pattern**: Bind the process query to the current PID's `SessionId` to resolve the user profile for the current active interactive session:
  ```powershell
  $currentSessionId = (Get-Process -Id $PID).SessionId
  $filter = "Name = 'explorer.exe'"
  if ($null -ne $currentSessionId) {
      $filter += " and SessionId = $currentSessionId"
  }
  $explorerProcs = Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue
  ```

### B. Robust File Deletion Hierarchy (System-Locked & Reparse Points)

Execution aliases and system files implementing NTFS reparse points often fail standard deletion calls.
* **Pattern**: Implement a multi-stage fallback mechanism:
  1. **Native API (if reparse point)**: `fsutil reparsepoint delete "$shortPath"`
  2. **.NET API**: `[System.IO.File]::Delete($Path)`
  3. **ACL Remediation**: Use `takeown.exe` and `icacls.exe` to take ownership and grant `FullControl` (F) to current user, then retry.
  4. **CMD Fallback**: Use `cmd.exe /c del /f /q`.

---

## 4. Diagnostic Robustness & Optional Component Tolerances

When auditing environments or checking package aliases, distinguish between mandatory dependencies (e.g., `winget.exe`) and optional or dev-only additions (e.g., `wingetdev.exe`).

* **Rule 1: Optional File Tolerances**: If a file is optional, do not flag the system check as `FAIL` when the file does not exist. Instead, log its absence as `[Info]` or `[Warn]`.
* **Rule 2: Conditional Corrupted Validation**: If the optional component *does* exist, execute full verification (e.g., check if it is a valid NTFS reparse point). If it exists but is corrupted, flag it as `FAIL` and trigger repair.

#### Recommended Implementation Pattern:

```powershell
foreach ($alias in $aliases) {
    if (Test-Path $aliasPath) {
        # Perform strict checks (e.g. check if it is a reparse point)
    } else {
        if ($alias -eq "optional.exe") {
            Write-Log -Message "Alias [$alias] not present (optional)." -Level "Info"
        } else {
            $state = "FAIL"
            Write-Log -Message "Alias [$alias] is missing!" -Level "Error"
        }
    }
}
```

---

## 5. Verification Checklist

- [ ] Audit the codebase for fully qualified type names (`[System.*]`) used to invoke static methods, ensuring they are mapped to reference variables or type accelerators.
- [ ] Verify that all mock helper functions in the test runner/sandboxes are defined in the `global:` scope.
- [ ] Verify that test runner configuration settings and flags are passed to imported modules using process-wide environment variables.
- [ ] Verify that no logs, transcripts, or backups write to `$PSScriptRoot` inside modules.
- [ ] Ensure that elevated profile resolution logic filters processes by `$PID`'s `SessionId`.
- [ ] Validate that file deletion routines on potentially locked system files implement the ACL remediation fallback (`takeown` / `icacls`).
- [ ] Check that missing optional developer/pre-release assets do not mark the entire diagnostic suite status as `FAIL`.
- [ ] Ensure that existing but corrupted optional components are still properly identified and queued for cleanup/repair.
