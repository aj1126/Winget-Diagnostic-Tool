function Invoke-WingetDiagnosticMenu {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSAvoidUsingWriteHost", "")]
    [CmdletBinding()]
    param()

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
        Write-Host "[5] Roll Back Previous Changes"
        Write-Host "[6] Exit"
        Write-Host ""

        $choice = Read-HostSafe "Select an option [1-6]"

        switch ($choice) {
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
                $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
                $aliases = Get-DeclaredExecutionAliases -pkg $pkg
                $aliasKeys = foreach ($alias in $aliases) {
                    "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\$alias"
                }
                foreach ($aliasKey in $aliasKeys) {
                    $subKey = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
                    if (Test-UserRegistryKey -SubKeyPath $subKey) {
                        if (Should-Process -Target "Registry Key HKCU:\$subKey" -Action "Set State = 1 (Enable alias)") {
                            Set-UserRegistryValue -SubKeyPath $subKey -ValueName "State" -Value 1 -ValueKind DWord
                            Write-Log -Message "Enabled alias setting $aliasKey." -Level "Success"
                        }
                    } else {
                        Write-Log -Message "Alias Setting [$aliasKey]: Key not present (Default Enabled)." -Level "Info"
                    }
                }
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "5" {
                Clear-Host
                Restore-EnvironmentBackup | Out-Null
                Read-HostSafe "`nPress Enter to return to menu"
            }
            "6" {
                Write-Host "Exiting wizard. Goodbye!" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "Invalid option. Please choose [1-6]" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}
