# Winget Diagnostic Tool Architecture Map

## Overview
This tool diagnoses and automatically repairs execution alias loops associated with `winget.exe` on Windows. It works cross-version on Windows PowerShell 5.1 and PowerShell Core 7+.

---

## 1. Scaffolding & Components
- **Repair-WingetAlias.ps1**: Main bootstrap proxy script. Dynamically resolves, loads, and executes the core module, fallback downloading if missing from local directories.
- **WingetDiagnosticTool/**: Module bundle layout:
  - `WingetDiagnosticTool.psd1`: Module manifest defining identity, constraints, and exported cmdlets.
  - `WingetDiagnosticTool.psm1`: Script loader importing private module helper scripts and public cmdlets.
  - `Public/Repair-WingetAlias.ps1`: Core function definition of `Repair-WingetAlias` containing diagnostic steps and remediation logic.
  - `Public/Invoke-WingetDiagnosticMenu.ps1`: Renders console configuration selection menus.
  - `Private/Helpers.ps1`: Houses specific diagnostic methods, path repairs, NTFS link handling, and app package installations.
  - `Private/Logging.ps1`: Technical logs generation and Event Log logging.
- **tests/**: Opaque-box E2E test framework (`Run-Tests.ps1`) covering 60+ test scenarios.

---

## 2. Diagnostics & Remediation Patterns
- **Execution Environment Preflights**:
  - Automatically checks process privileges (User vs Admin tokens) and targets appropriate environment paths accordingly.
  - Checks interactive state via `[Environment]::UserInteractive` to configure silent non-interactive executions safely under automated task schedulers (MDT/SCCM/CI).
- **Remediation Techniques**:
  - Resolves orphaned link pointer loops by purging corrupted APPX package registration states.
  - Re-evaluates AppInstaller application packages using PowerShell Appx Cmdlet boundaries.
- **Transactional Safety & Logging**:
  - Incorporates dry-run execution (`-DryRun`) to analyze systems without altering paths or package registries.
  - Generates detailed tech logs (`Repair-WingetAlias.log`) with rotating thresholds to preserve disk capacity.
