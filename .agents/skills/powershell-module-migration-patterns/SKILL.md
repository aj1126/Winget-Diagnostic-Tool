---
name: powershell-module-migration-patterns
description: Guidelines for converting monolithic PowerShell scripts to modules, covering path resolution ($PSScriptRoot), backwards-compatible bootstraps, and global mock scope injection in E2E tests.
---

# PowerShell Module Migration & Testing Patterns

Use this skill when converting monolithic PowerShell scripts (`.ps1`) into structured modules (`.psm1`/`.psd1`), adapting test harnesses for scope isolation, or designing backwards-compatible runner scripts.

---

## 1. Path Resolution Pitfall (`$PSScriptRoot`)

### Context
Monolithic scripts often use `$PSScriptRoot` to write logs, transcripts, or backup files in their own folder. In a module, `$PSScriptRoot` points to the module's installation directory (often protected, e.g., in `C:\Program Files\WindowsPowerShell\Modules`). Running the module as a standard user will throw `UnauthorizedAccessException`.

### Recommended Pattern
Define a persistent, user-writable data directory leveraging `$env:LOCALAPPDATA` (or `$env:TEMP` as fallback):
```powershell
$DiagnosticDataDir = Join-Path $env:LOCALAPPDATA "ModuleName"
if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
    $DiagnosticDataDir = Join-Path $env:TEMP "ModuleName"
}

if (-not (Test-Path $DiagnosticDataDir)) {
    New-Item -ItemType Directory -Path $DiagnosticDataDir -Force | Out-Null
}
```
All file write operations (logs, exports, registry backups) must target `$DiagnosticDataDir` instead of `$PSScriptRoot`.

---

## 2. Test Harness Scope Isolation & Mock Bypass

### Context
1. **Mock Bypass**: In custom E2E test runners (not using Pester), helper functions are defined to mock cmdlets before executing the target script. PowerShell modules run in their own isolated **Module Session State**. When module functions call a cmdlet, they resolve undefined commands in their own scope, then fall back to the **Global Scope**. They bypass script-scoped functions in the test runner. Mocks will be bypassed, executing live system cmdlets.
2. **Variable Isolation**: Variables set in the caller's script or global scope (e.g., `$global:IsTestRunner = $true`) inside a test runner are not visible inside the imported module's private functions because `Import-Module` runs in a separate, isolated session state.

### Recommended Pattern
1. **Mock Cmdlets globally**: Prefix all mock function definitions in the test runner with the `global:` scope modifier:
   ```powershell
   # In the test runner / child process script:
   function global:Get-AppxPackage {
       param([string]$Name)
       $global:CalledCmdlets.Add("Get-AppxPackage: $Name")
       # ... mock return value
   }
   ```
   This forces the mocks into the global runspace, allowing the module's functions to resolve them.
2. **Propagate configurations via Environment Variables**: Use process-wide environment variables instead of global/script PowerShell variables to control mock execution or bypasses in modules:
   ```powershell
   # In the test runner:
   $env:IsTestRunner = "true"

   # In the module script:
   if ($env:IsTestRunner -eq "true") {
       # Use mocked behaviors
   }
   ```

---

## 3. Backwards-Compatible Bootstrap Proxy

### Context
System administrators frequently execute tools using raw GitHub links:
```powershell
irm https://raw.githubusercontent.com/user/repo/main/Script.ps1 | iex
```
Replacing the script with a module breaks these links.

### Recommended Pattern
Keep a lightweight proxy script at the root of the repository. It resolves the module (checking local directories first to support offline developers, then installing from PSGallery if missing), imports it, and forwards all arguments:
```powershell
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$TargetUser
    # ... mirror all cmdlet parameters
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Get-Location }

# 1. Local Dev Import
$localManifest = Join-Path $ScriptDir "ModuleName\ModuleName.psd1"
if (Test-Path $localManifest) {
    Import-Module $localManifest -Force
} else {
    # 2. PSGallery Installation
    if (-not (Get-Module -ListAvailable -Name ModuleName)) {
        Write-Host "Installing ModuleName from PowerShell Gallery..." -ForegroundColor Cyan
        Install-Module -Name ModuleName -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module ModuleName -Force
}

# 3. Call the cmdlet
$params = $PSBoundParameters
Cmdlet-Name @params
```

---

## 4. Verification Checklist

- [ ] Verify that no logs, transcripts, or backups write to `$PSScriptRoot` inside the module.
- [ ] Verify that all mock helper functions in the test runner/sandboxes are defined in the `global:` scope.
- [ ] Verify that test runner configuration settings and flags are passed to imported modules using process-wide environment variables instead of global/script PowerShell variables.
- [ ] Verify that the root bootstrap proxy script mirrors all cmdlet parameters and forwards them correctly.
