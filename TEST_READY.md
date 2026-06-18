# Test Suite Status: READY

The E2E test suite for `Repair-WingetAlias.ps1` has been fully implemented and is ready for execution.

## Test Runner Information
- **Path**: `tests/Run-Tests.ps1`
- **Execution Command**: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Run-Tests.ps1`
- **Compatibility**: Supports both Windows PowerShell 5.1 and PowerShell Core 7+.
- **Process Isolation**: Every test case runs in a completely isolated sub-process with sandboxed environment variables, temporary folders, registry mocks, and file system states.

## Test Case Breakdown
A total of **60 E2E test cases** are defined, divided into four tiers:

### Tier 1: Feature Coverage (25 Tests)
- **Environment PATH (5 tests)**: Verifies adding missing path, removing duplicate path entries, leaving correct path unchanged, handling registry write errors, and creating backups.
- **App Execution Alias Settings (5 tests)**: Verifies re-enabling disabled execution alias keys, leaving enabled keys intact, handling missing registry keys, checking multiple disabled aliases, and DryRun behavior.
- **Corrupted Stub File Clean (5 tests)**: Verifies that healthy reparse point stubs are preserved, corrupted non-reparse point stubs are deleted, missing stubs are detected, and cmd fallback works.
- **AppX Package Repair (5 tests)**: Verifies package registration/reset cmdlets, handling missing package warnings, trigger download fallbacks, and handling registration/reset failures.
- **Scheduled Task / Startup Shortcut (5 tests)**: Verifies unattended background task registration under admin, user startup shortcut creation, shortcut creation failures, and omitting scheduling.

### Tier 2: Boundary & Corner Cases (25 Tests)
- **Environment PATH (5 tests)**: Verifies empty path initialization, leading/trailing semicolons cleanup, only semicolons clean, case-insensitive WindowsApps duplication prevention, and overwriting existing registry backups.
- **App Execution Alias Settings (5 tests)**: Verifies missing State value repair, correcting invalid State value types, lacking registry permissions handling, preserving non-zero states, and duplicate registry paths.
- **Corrupted Stub File Clean (5 tests)**: Verifies read-only stubs deletion, locked stubs fallback to cmd, missing parent directory restoration, subdirectories deletion, and non-reparse point stubs with large sizes.
- **AppX Package Repair (5 tests)**: Verifies older package version upgrade path, network errors on DownloadFallback, missing manifest files in install location, missing optional dependencies (VCLibs, UI.Xaml).
- **Scheduled Task / Startup Shortcut (5 tests)**: Verifies overwriting existing tasks/shortcuts, missing startup folders, running script as a background job (`-AsJob`), and job parameter forwarding.

### Tier 3: Cross-Feature Combinations (5 Tests)
- **Multi-system corruption (Test 51)**: Verifies repairing PATH, deleting corrupted stubs, and enabling registry settings simultaneously.
- **Dry run multi-corruption (Test 52)**: Verifies DryRun simulates all repairs without applying any changes.
- **Rollback registry backup (Test 53)**: Verifies restoring PATH from registry backup and cleaning up the backup key.
- **Rollback from file backup (Test 54)**: Verifies restoring PATH from `.reg` backup file when registry key is missing.
- **Rollback with no backups (Test 55)**: Verifies graceful handling of rollback when no backups exist.

### Tier 4: Real-World Application Scenarios (5 Tests)
- **Healthy system diagnostics (Test 56)**: Verifies diagnostics run and complete without triggering any repairs.
- **Full system repair (Test 57)**: Verifies recovering a completely broken system (missing path, folder, package, corrupt stubs) using DownloadFallback.
- **Open With loop remediation (Test 58)**: Verifies detecting and terminating active Open With loop.
- **Interactive menu selection (Test 59)**: Verifies interactive menu flows (e.g. running diagnostics then exiting) by mocking console inputs.
- **Verification fails post-repair (Test 60)**: Verifies handling of repair when verification fails (e.g., Open With loop persists).
