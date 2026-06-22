<#
.SYNOPSIS
    Automated local release script for aj1126/winget-diagnostic-tool.
.DESCRIPTION
    Performs safety checks (clean git working tree, passing test suite),
    pushes the main branch upstream, and creates/pushes an annotated release tag.
.PARAMETER Version
    The target release version (e.g. "1.0.0").
.EXAMPLE
    .\Invoke-Release.ps1 -Version "1.0.0"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The release version string (e.g., 1.0.0)")]
    [ValidateNotNullOrEmpty()]
    [string]$Version
)

# Format the tag name
$TagName = "v$Version"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "      WINGET DIAGNOSTIC RELEASE AUTOMATION        " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Target Version: $Version" -ForegroundColor Gray
Write-Host "Tag Name:       $TagName" -ForegroundColor Gray
Write-Host "--------------------------------------------------" -ForegroundColor Gray

# Step 1: Validate git working tree is completely clean
Write-Host "[1/4] Checking git working tree status..." -ForegroundColor Cyan
$gitStatus = git status --porcelain
if ($null -ne $gitStatus -and $gitStatus.Length -gt 0) {
    Write-Host "[ERROR] Git working tree is dirty! Commit or stash changes first." -ForegroundColor Red
    Write-Host $gitStatus -ForegroundColor Yellow
    exit 1
}
Write-Host "Git working tree is clean." -ForegroundColor Green

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Get-Location
}

# Update version string in manifest
$psd1Path = Join-Path $ScriptDir "WingetDiagnosticTool\WingetDiagnosticTool.psd1"
if (Test-Path $psd1Path -ErrorAction SilentlyContinue) {
    Write-Host "Updating module manifest version to $Version..." -ForegroundColor Cyan
    $manifestContent = Get-Content $psd1Path -Raw -ErrorAction Stop
    $manifestContent = $manifestContent -replace "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion = '$Version'"
    $manifestContent | Out-File $psd1Path -Encoding utf8 -Force -ErrorAction Stop
}

# Step 2: Execute E2E testing framework
Write-Host "[2/4] Executing local E2E test suite..." -ForegroundColor Cyan
$TestRunnerPath = Join-Path $ScriptDir "tests\Run-Tests.ps1"

if (-not (Test-Path $TestRunnerPath -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Test runner script not found at: $TestRunnerPath" -ForegroundColor Red
    exit 1
}

# Run tests under Windows PowerShell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TestRunnerPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Local testing framework failed. Aborting release." -ForegroundColor Red
    # Discard manifest changes to leave tree clean on failure
    git checkout -- $psd1Path
    exit 1
}
Write-Host "All test cases passed successfully." -ForegroundColor Green

# Run wiki documentation update automation
$ImageSource = "C:\Users\ajjuk\.gemini\antigravity\brain\5f3390e5-8c53-44ac-9a6b-2ba48e946b18\successful_test_run_1782060712208.png"
$WikiSyncPath = Join-Path $ScriptDir "Update-Wiki.ps1"
if (Test-Path $WikiSyncPath -ErrorAction SilentlyContinue) {
    Write-Host "Executing automated wiki documentation sync..." -ForegroundColor Cyan
    & $WikiSyncPath -ImageSource $ImageSource
}

# Commit manifest changes
if (Test-Path $psd1Path -ErrorAction SilentlyContinue) {
    Write-Host "Committing version bump changes..." -ForegroundColor Cyan
    git add $psd1Path
    git commit -m "chore(release): bump version to $Version"
}

# Step 3: Push current main branch to upstream remote
Write-Host "[3/4] Pushing main branch upstream..." -ForegroundColor Cyan
git push origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to push main branch to origin." -ForegroundColor Red
    exit 1
}
Write-Host "Successfully pushed main branch to origin." -ForegroundColor Green

# Step 4: Verify and push tag
Write-Host "[4/4] Verifying and creating release tag..." -ForegroundColor Cyan

# Check if tag already exists locally
$LocalTagCheck = git tag -l $TagName
# Check if tag already exists on remote origin
$RemoteTagCheck = git ls-remote --tags origin $TagName

if ($null -ne $LocalTagCheck -and $LocalTagCheck -eq $TagName) {
    Write-Host "[ERROR] Tag '$TagName' already exists locally." -ForegroundColor Red
    exit 1
}

if ($null -ne $RemoteTagCheck -and $RemoteTagCheck.Length -gt 0) {
    Write-Host "[ERROR] Tag '$TagName' already exists on remote origin." -ForegroundColor Red
    exit 1
}

Write-Host "Tag '$TagName' does not exist. Creating annotated tag..." -ForegroundColor Cyan
git tag -a $TagName -m "Release version $Version"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to create git tag '$TagName'." -ForegroundColor Red
    exit 1
}
Write-Host "Tag '$TagName' created locally." -ForegroundColor Green

Write-Host "Pushing tag '$TagName' upstream to trigger cloud CI/CD..." -ForegroundColor Cyan
git push origin $TagName
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to push tag '$TagName' to origin." -ForegroundColor Red
    exit 1
}
Write-Host "Successfully pushed tag '$TagName' upstream!" -ForegroundColor Green

Write-Host "--------------------------------------------------" -ForegroundColor Gray
Write-Host "Release $Version successfully initiated!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
exit 0
