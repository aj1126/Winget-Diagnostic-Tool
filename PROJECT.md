# Project: Winget Diagnostic and Remediation Tool

## Architecture
The tool is a standalone PowerShell script (`Repair-WingetAlias.ps1`) designed to diagnose and repair the Winget execution alias loop. It must run on both Windows PowerShell 5.1 and PowerShell 7+.

### Code Layout
- `Repair-WingetAlias.ps1` - Main diagnostic and remediation script.
- `tests/` - Folder containing E2E and unit tests.
- `tests/Run-Tests.ps1` - Test runner.
- `tests/fixtures/` - Test fixtures for registry and file system simulation.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Setup & Planning | Initialize briefing, plan, progress, and project files. | None | DONE |
| 2 | E2E Testing Track | Create opaque-box E2E test suite (Tiers 1-4) & publish `TEST_READY.md`. | Milestone 1 | PLANNED |
| 3 | Implementation Exploration | Analyze existing `Repair-WingetAlias.ps1` for gaps against requirements. | Milestone 1 | PLANNED |
| 4 | Implementation Improvements | Fix gaps in `Repair-WingetAlias.ps1` (R1-R5, DryRun, logs). | Milestone 3 | PLANNED |
| 5 | Verify Implementation | Run E2E tests, execute reviewer & challenger loops. | Milestone 2, 4 | PLANNED |
| 6 | Forensic Audit | Run forensic auditor checks to verify integrity (no hardcoding, etc.). | Milestone 5 | PLANNED |
| 7 | Adversarial Hardening | Run challenger to find coverage/robustness gaps and fix them (Tier 5). | Milestone 6 | PLANNED |

## Interface Contracts
### `Repair-WingetAlias.ps1` CLI Contract
- `-DryRun`: Switch to simulate actions without applying changes.
- `-Force`: Switch to execute diagnostics and repairs automatically without interactive prompts.
- `-Rollback`: Switch to restore environment path from backup.
- `-AsJob`: Switch to run diagnostic/repair in background.
- `-DownloadFallback`: Switch to download DesktopAppInstaller if missing.
- Exit code: `0` on success, non-zero on error.
- Logging: Writes to `Repair-WingetAlias.log` (rotating at 1MB) and `Repair-WingetAlias_Transcript.log` under the user profile (or script root).

### Test Suite Contract
- Command: `powershell.exe -File tests/Run-Tests.ps1`
- Expected: exit code 0 when all tests pass.
