function Repair-AliasStub {
    <#
    .SYNOPSIS
        Removes corrupted, non-reparse point execution alias stub files from the WindowsApps directory.
    .DESCRIPTION
        Inspects declared alias files (e.g. winget.exe, wingetdev.exe) in %LOCALAPPDATA%\Microsoft\WindowsApps.
        If a file exists but is NOT a valid NTFS ReparsePoint (corrupted zero-byte plain file or non-junction),
        it deletes the stub using low-level .NET primitives so AppX can re-create a clean junction.
    .OUTPUTS
        System.Boolean indicating whether all corrupted stubs were successfully removed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSShouldProcess", "")]
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseOutputTypeCorrectly", "")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Log -Message "Checking and removing corrupted execution alias stubs..." -Level "Info"

    $targetLocalAppData = Get-TargetUserLocalFolder "AppData\Local"
    $dirPath = "$targetLocalAppData\Microsoft\WindowsApps"
    if (-not (Test-Path $dirPath)) {
        return $true
    }

    $pkg = Get-TargetAppxPackage -Name "Microsoft.DesktopAppInstaller"
    $aliases = Get-DeclaredExecutionAliases -pkg $pkg

    foreach ($alias in $aliases) {
        $aliasPath = Join-Path $dirPath $alias
        $exists = [System.IO.File]::Exists($aliasPath)
        if ($exists) {
            $isReparse = $false
            try {
                $attrs = [System.IO.File]::GetAttributes($aliasPath)
                $isReparse = $attrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            } catch {
                Write-Log -Message "Failed to retrieve attributes for ${aliasPath}: $_" -Level "Warn"
            }

            if (-not $isReparse) {
                Write-Log -Message "Corrupted stub file found at $aliasPath (Not a reparse point). Removing..." -Level "Warn"
                Remove-ReparsePoint -Path $aliasPath
            }
        }
    }

    return $true
}

Set-Alias -Name Repair-AliasStubs -Value Repair-AliasStub -Description "Plural alias for Repair-AliasStub"
