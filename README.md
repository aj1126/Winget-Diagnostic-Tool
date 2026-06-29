# Winget Diagnostic & Remediation Tool

[Quick Start](#-quick-start-copy--paste) | [Safety Standards](#️-non-destructive-architecture--safety-standards) | [Extended Docs](README_EXTENDED.md) | [Testing Suite](TEST_INFRA.md) | [Use Cases & Causes](docs/USE_CASES_AND_CAUSES.md)

[![Lint State](https://github.com/aj1126/winget-diagnostic-tool/actions/workflows/lint.yml/badge.svg)](https://github.com/aj1126/winget-diagnostic-tool/actions)
[![Production Release Pipeline](https://github.com/aj1126/winget-diagnostic-tool/actions/workflows/release.yml/badge.svg)](https://github.com/aj1126/winget-diagnostic-tool/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A safe, single-profile utility engineered to diagnose and repair corrupted Windows Package Manager (`winget`) execution aliases, broken NTFS reparse points, and asymmetrical profile registry inconsistencies on Windows 11.

## ⚡ What It Fixes (The 5-Second Rule)

* **The "Open With" Loop:** Permanently breaks out of the loop where running `winget` repeatedly prompts the user to select a GUI handler app.
* **Mangled Reparse Points:** Forcefully purges corrupted execution alias files in `%USERPROFILE%\AppData\Local\Microsoft\WindowsApps` that standard shell commands fail to delete.
* **Elevation Profile Mismatches:** Corrects registry `PATH` variables within the active user's environment block, even when executed from an elevated administrative context.

---

## 🚀 Quick Start (Copy & Paste)

To evaluate your system state and interactively apply fixes, execute the following command block from a native **Windows PowerShell** or **PowerShell Core** console:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing '[https://raw.githubusercontent.com/aj1126/winget-diagnostic-tool/main/Repair-WingetAlias.ps1').Content](https://raw.githubusercontent.com/aj1126/winget-diagnostic-tool/main/Repair-WingetAlias.ps1').Content)))

```

### Unattended Enterprise Automation (RMM/Intune/MDT)

For headless deployment image scrubbing or silent profile repairs, append the `-Force` switch:

```powershell
.\Repair-WingetAlias.ps1 -Force
```

#### Standardized Exit Codes (MDT/SCCM/Intune)

The script and module return deterministic exit codes to simplify enterprise orchestration:
* `0`: Success (System healthy or repaired successfully).
* `1`: Failure (Error during execution or verification failure).
* `2`: Dry-run mode completed successfully with simulated changes.
* `3`: Rollback completed successfully.

---

## 🛡️ Non-Destructive Architecture & Safety Standards

System utility execution demands strict isolation and deterministic boundaries. This engine operates under a non-destructive legal sandbox paradigm:

* **Transactional Backups:** Prior to altering any registry keys under the user's environment block, the tool exports structured `.reg` files locally so changes can be reverted with a double-click.
* **Low-Level .NET Deletions:** To bypass NTFS reparse point file locks where high-level cmdlets fail (`Remove-Item`), the script accesses the underlying file system primitives directly via `[System.IO.File]::Delete()`.
* **Asymmetrical Elevation Protection:** The script maps the actual interactive user token via `explorer.exe` process ownership rather than targeting the administrator profile's registry hive, preventing configuration bleed.
* **Deterministic Verification Framework:** Zero guesswork. The remediation tree evaluates state changes post-fix and monitors thread stability using an explicit 3-second diagnostic execution timeout.

---

## 📖 Deep Dive & Technical Reference

If you are looking for the original technical deep dives, architectural breakdowns, historical edge cases, or deep platform context regarding this project:
* 📄 **Read the full guide:** [Extended Documentation Reference](README_EXTENDED.md)
* 🔍 **Root Causes & Scenarios:** [Use-Cases & Root Cause Analysis](docs/USE_CASES_AND_CAUSES.md)

---

## 🧪 Vetting Status

* **PSScriptAnalyzer Lint Compliance:** 100% Pass (0 Errors, 0 Warnings)
* **Integration Tests:** 68 / 68 E2E Edge Cases Passed across Windows PowerShell 5.1 and PS 7+