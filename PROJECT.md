# Project: Winget Diagnostic and Remediation Tool

## Architecture
The tool is a standalone PowerShell script (`Repair-WingetAlias.ps1`) designed to diagnose and repair the Winget execution alias loop. It must run on both Windows PowerShell 5.1 and PowerShell 7+.

### Code Layout
- `Repair-WingetAlias.ps1` - Main diagnostic and remediation script.
- `tests/` - Folder containing the E2E test suite.
- `tests/Run-Tests.ps1` - Test runner (60 test cases across 4 tiers).
- `TEST_INFRA.md` - Test architecture and coverage documentation.
- `TEST_READY.md` - Test suite readiness status.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Setup & Planning | Initialize briefing, plan, progress, and project files. | None | DONE |
| 2 | E2E Testing Track | Create opaque-box E2E test suite (Tiers 1-4) & publish `TEST_READY.md`. | Milestone 1 | DONE |
| 3 | Implementation Exploration | Analyze existing `Repair-WingetAlias.ps1` for gaps against requirements. | Milestone 1 | DONE |
| 4 | Implementation Improvements | Fix gaps in `Repair-WingetAlias.ps1` (R1-R5, DryRun, logs). | Milestone 3 | DONE |
| 5 | Verify Implementation | Run E2E tests (60/60 passing), verify PS 5.1/7+ compatibility. | Milestone 2, 4 | DONE |
| 6 | Forensic Audit | Forensic auditor verified integrity (no hardcoding, facade logic). CLEAN verdict. | Milestone 5 | DONE |
| 7 | Victory Audit | Independent 3-phase audit (timeline, integrity, test execution). VICTORY CONFIRMED. | Milestone 6 | DONE |
| 8 | Governance Rulesets | Establish branch protection rules, mandatory PR approvals, conversation resolution gates, and blocking CI pipelines. | Milestone 7 | DONE |
| 9 | Milestone v1.1.0 | Deliver session isolation, ghost pointer loop diagnostics, native NTFS repairs, and 62/62 E2E test compliance. | Milestone 8 | DONE |
| 10 | Milestone v2.0.0 | Convert monolithic script to a PowerShell module, decouple UI menu, CI/CD PSGallery automated publishing, Intune integration, MDT/SCCM exit codes, and 66/66 E2E tests. | Milestone 9 | DONE |



## Interface Contracts
### `Repair-WingetAlias.ps1` CLI Contract
- `-DryRun`: Switch to simulate actions without applying changes.
- `-Force`: Switch to execute diagnostics and repairs automatically without interactive prompts.
- `-Rollback`: Switch to restore environment path from backup.
- `-AsJob`: Switch to run diagnostic/repair in background.
- `-DownloadFallback`: Switch to download DesktopAppInstaller if missing.
- `-ScheduleTask`: Switch to install logon Scheduled Task or Startup shortcut.
- Exit codes:
  - `0`: Success (System healthy or repaired successfully).
  - `1`: Failure (Error during execution or verification failure).
  - `2`: Dry-run mode completed successfully with simulated changes.
  - `3`: Rollback completed successfully.
- Logging: Writes to `Repair-WingetAlias.log` (rotating at 1MB) and `Repair-WingetAlias_Transcript.log` under the redirected LocalAppData `%LOCALAPPDATA%\WingetDiagnosticTool`.

### Test Suite Contract
- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Run-Tests.ps1`
- Expected: exit code `0` when all 66 tests pass.
- Coverage: Tier 1 (Feature, 25 tests), Tier 2 (Boundary, 25 tests), Tier 3 (Cross-Feature, 5 tests), Tier 4 (Real-World, 11 tests).
