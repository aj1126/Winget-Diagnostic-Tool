using namespace Microsoft.Win32
function Repair-AppExecutionAlias {
    <#
    .SYNOPSIS
        Verifies and re-enables DesktopAppInstaller app execution aliases in the user registry.
    .DESCRIPTION
        Scans for declared execution aliases for Microsoft.DesktopAppInstaller (e.g. winget.exe, wingetdev.exe)
        and ensures their State value in HKCU:\Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings
        is set to 1 (Enabled).
    .OUTPUTS
        System.Boolean indicating whether all alias settings are enabled/repaired.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSShouldProcess", "")]
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseOutputTypeCorrectly", "")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Log -Message "Verifying and re-enabling execution aliases in registry..." -Level "Info"

    $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
    $aliases = Get-DeclaredExecutionAliases -pkg $pkg
    $regAliasSettings = foreach ($alias in $aliases) {
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\$alias"
    }

    $allSucceeded = $true
    foreach ($aliasKey in $regAliasSettings) {
        $subKey = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$aliasKey"
        if (Test-UserRegistryKey -SubKeyPath $subKey) {
            $state = Get-UserRegistryValue -SubKeyPath $subKey -ValueName "State" -DefaultValue $null
            $isStateEnabled = $false
            if ($null -ne $state) {
                $stateInt = 0
                if ([int]::TryParse($state, [ref]$stateInt)) {
                    if ($stateInt -ne 0) {
                        $isStateEnabled = $true
                    }
                }
            }
            if (-not $isStateEnabled) {
                if (Should-Process -Target "Registry Key HKCU:\$subKey" -Action "Set State = 1 (Enable alias)") {
                    $setResult = Set-UserRegistryValue -SubKeyPath $subKey -ValueName "State" -Value 1 -ValueKind DWord
                    if ($setResult) {
                        Write-Log -Message "Re-enabled alias settings for $aliasKey." -Level "Success"
                    } else {
                        Write-Log -Message "Failed to enable alias settings for $aliasKey." -Level "Error"
                        $allSucceeded = $false
                    }
                }
            } else {
                Write-Log -Message "Alias Setting [$aliasKey]: Already enabled." -Level "Info"
            }
        } else {
            Write-Log -Message "Alias Setting [$aliasKey]: Key not present (Default Enabled)." -Level "Info"
        }
    }

    return $allSucceeded
}

Set-Alias -Name Repair-AppExecutionAliases -Value Repair-AppExecutionAlias -Description "Plural alias for Repair-AppExecutionAlias"
