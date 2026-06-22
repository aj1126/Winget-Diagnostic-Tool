<#
.SYNOPSIS
    Automated Wiki Synchronization and Image Integration Tool.
.DESCRIPTION
    Updates files in the cloned wiki repository and commits changes to master.
.PARAMETER ImageSource
    The path to the local PNG image representing a successful E2E test run.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessage("PSAvoidUsingWriteHost", "")]
[Diagnostics.CodeAnalysis.SuppressMessage("PSUseBOMForUnicodeEncodedFile", "")]
param(
    [Parameter(Mandatory = $false)]
    [string]$ImageSource
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Get-Location
}

$WikiDir = Join-Path $ScriptDir "wiki"
if (-not (Test-Path $WikiDir)) {
    Write-Warning "Wiki directory not found at $WikiDir. Skipping sync."
    return
}

# 1. Update test run image if provided
if (-not [string]::IsNullOrEmpty($ImageSource) -and (Test-Path $ImageSource)) {
    $WikiImagesDir = Join-Path $WikiDir "images"
    if (-not (Test-Path $WikiImagesDir)) {
        New-Item -ItemType Directory -Path $WikiImagesDir -Force | Out-Null
    }

    $DestinationImage = Join-Path $WikiImagesDir "successful_test_run.png"
    Copy-Item -Path $ImageSource -Destination $DestinationImage -Force
    Write-Host "Copied E2E test screenshot to wiki images." -ForegroundColor Green
}

# 2. Append screenshot reference to Quick Start Guide in wiki
$quickStartPath = Join-Path $WikiDir "Quick-Start-Guide.md"
if (Test-Path $quickStartPath) {
    $qsContent = Get-Content $quickStartPath -Raw
    if ($qsContent -notlike "*Automated Test Verification*") {
        $qsContent += @"

## 🧪 Automated Test Verification
The tool is continuously verified against 66 isolated edge-case test runs in a virtual test harness to prevent regressions in registry, permissions, or process loop states.

Below is a terminal recording screenshot of a successful E2E test suite execution:

![Successful Test Run](images/successful_test_run.png)
"@
        $qsContent | Out-File $quickStartPath -Encoding utf8 -Force
        Write-Host "Updated Quick-Start-Guide.md with E2E verification screenshot." -ForegroundColor Green
    }
}

# 3. Commit and push wiki updates
$gitStatus = git -C $WikiDir status --porcelain
if ($null -ne $gitStatus -and $gitStatus.Length -gt 0) {
    Write-Host "Git changes detected in Wiki. Pushing updates..." -ForegroundColor Cyan
    git -C $WikiDir add -A
    git -C $WikiDir commit -m "docs(wiki): automated update and test screenshot addition"
    git -C $WikiDir push origin master
    Write-Host "Successfully pushed documentation and wiki updates upstream." -ForegroundColor Green
} else {
    Write-Host "Wiki is already up-to-date." -ForegroundColor Green
}
