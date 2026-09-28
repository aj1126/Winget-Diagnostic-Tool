function Invoke-WingetDiagnosticMenu {
    <#
    .SYNOPSIS
        Launches the interactive repair wizard for winget diagnostics and remediation.
    .DESCRIPTION
        Presents an interactive menu to allow administrators to run diagnostics, apply path repairs,
        re-register AppX packages, enable execution aliases, clean shadowing binaries, or restore backups.
        Includes non-interactive safety guards to prevent automated execution hangs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSAvoidUsingWriteHost", "")]
    [CmdletBinding()]
    param()

    # Non-interactive console guard (Rule 14 & Rule 201)
    $canPrompt = $IsInteractive
    if ($null -eq $canPrompt) {
        $canPrompt = [Environment]::UserInteractive -and ($Host.Name -notmatch "Background|Job|NonInteractive") -and ($null -ne $Host.UI) -and -not $env:NON_INTERACTIVE
    }
    if (-not $canPrompt -and -not $env:IsTestRunner) {
        Write-Log -Message "Invoke-WingetDiagnosticMenu cannot run in a non-interactive session. Use Repair-WingetAlias -Force or discrete repair functions." -Level "Warn"
        return
    }

    $title = @"
==================================================
      WINGET EXECUTION LOOP REPAIR WIZARD
==================================================
"@

    while ($true) {
        Clear-Host
        Write-Host $title -ForegroundColor Cyan
        Write-Host "Active Mode: " -NoNewline
        if ($WhatIfPreference) {
            Write-Host "DRY RUN (What-If)" -ForegroundColor Yellow
        } else {
            Write-Host "LIVE / REMEDIATION" -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "[1] Run Full Diagnostics"
        Write-Host "[2] Apply Path Repair (Add WindowsApps to PATH)"
        Write-Host "[3] Reset / Re-register DesktopAppInstaller Package"
        Write-Host "[4] Enable App Execution Aliases (Registry Settings)"
        Write-Host "[5] Clean Shadowing / Blocking Winget Files (e.g. in System32)"
        Write-Host "[6] Roll Back Previous Changes"
        Write-Host "[7] Exit"
        Write-Host ""

        $choice = Read-HostSafe "Select an option [1-7]"

        if ([string]::IsNullOrWhiteSpace($choice)) {
            if (-not $canPrompt -or $env:NON_INTERACTIVE) {
                Write-Log -Message "Invoke-WingetDiagnosticMenu exiting: empty input received in non-interactive environment." -Level "Warn"
                return
            }
            continue
        }

        if ($choice.Trim().ToUpper() -in @('Q', 'QUIT', 'EXIT')) {
            Write-Host "Exiting wizard. Goodbye!" -ForegroundColor Cyan
            return
        }

        switch ($choice.Trim()) {
            "1" {
                Clear-Host
                Run-Diagnostics | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "2" {
                Clear-Host
                Repair-EnvironmentPath | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "3" {
                Clear-Host
                $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
                if ($pkg) {
                    Repair-AppXInstallerPackage | Out-Null
                } else {
                    Write-Log -Message "Package is missing. Downloading..." -Level "Info"
                    Install-WingetFallback
                }
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "4" {
                Clear-Host
                Repair-AppExecutionAliases | Out-Null
                Repair-AliasStubs | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "5" {
                Clear-Host
                Repair-ShadowingFiles | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "6" {
                Clear-Host
                Restore-EnvironmentBackup | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "7" {
                Write-Host "Exiting wizard. Goodbye!" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "Invalid option. Please choose [1-7]" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}
