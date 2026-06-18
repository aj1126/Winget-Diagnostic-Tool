# Winget Diagnostic Tool Test Infrastructure

This document outlines the test architecture, feature inventory, scenario coverage, and quality thresholds of the end-to-end (E2E) testing framework for `Repair-WingetAlias.ps1`.

---

## 1. Feature Inventory

The test suite evaluates five core functional domains of the diagnostic and repair tool:

### A. Environment PATH Management
- **Description**: Inspects and corrects the User's environment PATH variable to ensure the Winget WindowsApps folder (`%LOCALAPPDATA%\Microsoft\WindowsApps`) is present.
- **Coverage**:
  - Adds the path when missing.
  - Removes duplicate path entries (case-insensitive).
  - Performs no writes if the path is already correct.
  - Handles registry write permissions errors gracefully.
  - Saves backups before updating the PATH.

### B. App Execution Alias Registry Settings
- **Description**: Diagnoses registry keys governing execution aliases under `HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths` and `HKCU:\Software\Microsoft\Windows\CurrentVersion\Appx\AppExecutionAliasSettings`.
- **Coverage**:
  - Re-enables disabled execution aliases (`State = 0` updated to `State = 1`).
  - Preserves custom states (e.g., `State = 2`).
  - Gracefully handles missing alias keys.
  - Simulates DryRun mode where configurations are scanned but not altered.

### C. Corrupted Stub File Remediation
- **Description**: Detects and deletes invalid, zero-byte, or non-reparse point executable files (stubs) in `%LOCALAPPDATA%\Microsoft\WindowsApps` (e.g., `winget.exe` or `wingetdev.exe`).
- **Coverage**:
  - Preserves healthy reparse point files.
  - Deletes corrupted/flat files.
  - Automatically clears read-only attributes before deletion.
  - Uses `cmd.exe` delete fallback if standard .NET file APIs fail.

### D. AppX Package Repair
- **Description**: Repairs registration of the parent AppX package `Microsoft.DesktopAppInstaller`.
- **Coverage**:
  - Re-registers packages via `Add-AppxPackage -Register` and resets via `Reset-AppxPackage`.
  - Down-version package upgrade detection.
  - Handles missing manifest files and missing dependencies (VCLibs, UI.Xaml) gracefully.
  - Network-down simulation during MSIX bundle fallback downloads via `-DownloadFallback`.

### E. Automation & Integration (Scheduled Tasks & Jobs)
- **Description**: Verifies command-line parameters for background tasks, silent automation, and rollback.
- **Coverage**:
  - Registers scheduled tasks under admin elevation.
  - Fallback to startup folder shortcut creation under standard user contexts.
  - Asynchronous execution via `-AsJob` and parameter propagation.

---

## 2. Test Architecture

To verify scripts safely without corrupting the host machine's environment, registry, or packages, `tests/Run-Tests.ps1` runs tests in isolated sandboxes.

```
+-------------------------------------------------------------+
|                     tests/Run-Tests.ps1                     |
|                                                             |
|   1. Compiles mock winget binary                            |
|   2. Iterates through 60 defined test cases                 |
|   3. Prepares sandbox, setup.json, and run_test_case.ps1    |
|   4. Spawns isolated PowerShell sub-process                 |
|   5. Evaluates output state and asserts pass/fail status    |
+-------------------------------------------------------------+
                               |
                               v (Spawn process)
+-------------------------------------------------------------+
|                Isolated PowerShell Sandbox                  |
|                                                             |
|   - Loads setup.json configuration                          |
|   - Injects C# MockRegistry and overrides accelerators      |
|   - Mocks Cmdlets (Get-AppxPackage, Test-Path, etc.)        |
|   - Executes Repair-WingetAlias.ps1                         |
|   - Writes final_state.json on termination                  |
+-------------------------------------------------------------+
```

### Sandbox & Mocks
- **Process Isolation**: Every test case runs in a unique subdirectory under `Temp\WingetTestMocks`. It copies a localized version of the script and a mock version of `winget.exe` to prevent interaction with the actual machine.
- **Registry Redirector**: A custom C# `MockRegistry` helper overrides type accelerators (`[Microsoft.Win32.Registry]`, `[Security.Principal.WindowsIdentity]`, `[Security.Principal.WindowsPrincipal]`), intercepting all read/write actions.
- **Cmdlet Mocking**: Key cmdlets (e.g. `Set-ItemProperty`, `Get-AppxPackage`, `Add-AppxPackage`, `Invoke-WebRequest`, `Get-Process`) are overridden in the child scope. They track invoked arguments and return custom mock records.
- **State Serialization**: The child process runs inside a `try...finally` block that captures registry outputs, file attributes, and list of called cmdlets, serializing them to `final_state.json` before exiting.

---

## 3. Real-World Application Scenarios

The framework tests full-system diagnostic flows under Tier 4, simulating complex end-user environments:

1. **Healthy System Diagnostics (Test 56)**: Tests that a fully functioning system does not trigger any modifications or writes, avoiding unnecessary file or registry operations.
2. **Full System Repair (Test 57)**: Restores a system suffering from multiple corruptions simultaneously (e.g., missing registry keys, corrupted execution stubs, and unregistered packages) using `-DownloadFallback`.
3. **Open With Loop Remediation (Test 58)**: Simulates the infinite loop where the OS spawns the "Open With" dialog when attempting to run `winget.exe`. The tool detects, kills the `OpenWith.exe` process, and corrects the execution path.
4. **Interactive Menu Selection (Test 59)**: Simulates console prompt inputs (diagnostics scan followed by exiting) to verify menu navigation reliability.
5. **Verification Fails Post-Repair (Test 60)**: Assures that if the repair process executes but the system validation fails (e.g., execution loop persists), the script registers the error status and exits with a non-zero code.

---

## 4. Coverage Thresholds

| Tier | Focus | Test Count | Target Pass Rate |
|---|---|---|---|
| **Tier 1** | Feature Coverage | 25 | 100% |
| **Tier 2** | Boundary & Corner Cases | 25 | 100% |
| **Tier 3** | Cross-Feature Combinations | 5 | 100% |
| **Tier 4** | Real-World Scenarios | 5 | 100% |
| **Total** | **Full Suite** | **60** | **100%** |

- **Strict Enforcement**: The test runner enforces a 100% pass rate. If any single test fails its assertion or throws an exception, `Run-Tests.ps1` returns exit code `1`.
- **Pre-commit Verification**: All changes to `Repair-WingetAlias.ps1` must be verified using the test runner prior to integration.
