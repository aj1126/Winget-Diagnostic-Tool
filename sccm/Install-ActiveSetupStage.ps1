#requires -version 5.1
<#
.SYNOPSIS
    Stages WingetDiagnosticTool and registers Active Setup for OSD Task Sequences.
.DESCRIPTION
    Designed for execution during Microsoft SCCM / MECM or MDT Operating System Deployment (OSD)
    Task Sequences running under the NT AUTHORITY\SYSTEM context.

    Because Windows Package Manager (winget) execution aliases reside in individual user profiles
    (HKCU and %LOCALAPPDATA%), this script stages the repair utility locally into ProgramData
    and registers an Active Setup component in HKLM. When any user subsequently logs in,
    Windows automatically triggers the silent repair routine once within the user's interactive context.
.PARAMETER StagingPath
    Destination directory where module and repair scripts are staged.
    Defaults to "$env:ProgramData\WingetDiagnosticTool".
.PARAMETER Uninstall
    Unregisters the Active Setup component and removes staged files.
.PARAMETER Force
    Overwrites existing staged files without confirmation.
.EXAMPLE
    .\Install-ActiveSetupStage.ps1
    Stages files and registers Active Setup under HKLM.
.EXAMPLE
    .\Install-ActiveSetupStage.ps1 -Uninstall
    Unregisters Active Setup and removes staged files.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$StagingPath = "$env:ProgramData\WingetDiagnosticTool",

    [Parameter(Mandatory = $false)]
    [switch]$Uninstall,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$activeSetupKeyPath = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\WingetDiagnosticTool"

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Well-known SIDs, so the ACL does not depend on the OS display language.
$script:SidSystem = 'S-1-5-18'
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidUsers = 'S-1-5-32-545'
# The account running this script (SYSTEM in a task sequence). It owns what it creates.
$script:SidCurrent = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
# PowerShell 7 reaches the ACL APIs through FileSystemAclExtensions; Windows PowerShell 5.1 has them on the types.
$script:AclExtensions = 'System.IO.FileSystemAclExtensions' -as [type]

function Get-StagingSecurity {
    # A protected DACL: SYSTEM and Administrators Full, Users ReadAndExecute, nothing inherited from
    # ProgramData. -BuildSid also gets Full; it is used only while files are copied in.
    param([string]$BuildSid)

    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $grants = @(
        @($script:SidSystem, [System.Security.AccessControl.FileSystemRights]::FullControl),
        @($script:SidAdministrators, [System.Security.AccessControl.FileSystemRights]::FullControl),
        @($script:SidUsers, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    )
    if ($BuildSid) {
        $grants += , @($BuildSid, [System.Security.AccessControl.FileSystemRights]::FullControl)
    }
    foreach ($grant in $grants) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($grant[0])
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, $grant[1], $inherit, $propagation, $allow)
        $acl.AddAccessRule($rule)
    }
    return , $acl
}

function New-StagingDirectory {
    # Creates the folder with its DACL in the same call, so it is never writable by other users.
    # If the path already exists this does nothing; Assert-StagingSecure catches that case.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.DirectorySecurity]$Security
    )

    if (-not $PSCmdlet.ShouldProcess($Path, "Create locked staging directory")) { return }
    if ($script:AclExtensions) {
        [void]$script:AclExtensions::Create([System.IO.DirectoryInfo]::new($Path), $Security)
    } else {
        [void][System.IO.Directory]::CreateDirectory($Path, $Security)
    }
}

function Set-StagingAcl {
    # Replaces the staging folder's DACL with the final protected one (no build entry). The
    # inheritable entries propagate to every staged file and folder.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = Get-StagingSecurity
    if ($PSCmdlet.ShouldProcess($Path, "Set restricted staging ACL")) {
        $dir = [System.IO.DirectoryInfo]::new($Path)
        if ($script:AclExtensions) {
            $script:AclExtensions::SetAccessControl($dir, $acl)
        } else {
            $dir.SetAccessControl($acl)
        }
    }
}

function Assert-StagingSecure {
    # Fails closed unless: the staging folder is a real folder (not a link) with a protected ACL;
    # every staged item is owned by SYSTEM, Administrators or the account running this script;
    # only SYSTEM and Administrators (plus -BuildSid, while files are copied) can write to any
    # item; and the folder holds only files staged from the source.
    param(
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExpectedRelativePaths,
        [string]$BuildSid
    )

    $sidType = [System.Security.Principal.SecurityIdentifier]
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $trustedOwners = @($script:SidSystem, $script:SidAdministrators, $script:SidCurrent)
    $writers = @($script:SidSystem, $script:SidAdministrators)
    if ($BuildSid) { $writers += $BuildSid }
    $writeMask = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'

    if (([System.IO.DirectoryInfo]::new($StagingPath).Attributes -band $reparse) -ne 0) {
        throw "Staging folder is a link, not a folder: $StagingPath"
    }
    $items = @(Get-Item -LiteralPath $StagingPath -Force) + @(Get-ChildItem -LiteralPath $StagingPath -Recurse -Force)
    foreach ($item in $items) {
        if (($item.Attributes -band $reparse) -ne 0) {
            throw "Staged item is a link: $($item.FullName)"
        }
        $acl = Get-Acl -LiteralPath $item.FullName
        $owner = $acl.GetOwner($sidType).Value
        if ($trustedOwners -notcontains $owner) {
            throw "Staged item is owned by an untrusted principal ($owner): $($item.FullName)"
        }
        foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if (($rule.FileSystemRights -band $writeMask) -eq 0) { continue }
            if ($writers -notcontains $rule.IdentityReference.Value) {
                throw "Principal $($rule.IdentityReference.Value) can write to staged item: $($item.FullName)"
            }
        }
    }
    if (-not (Get-Acl -LiteralPath $StagingPath).AreAccessRulesProtected) {
        throw "Staging folder ACL is not protected: $StagingPath"
    }

    $rootFull = (Get-Item -LiteralPath $StagingPath -Force).FullName.TrimEnd('\')
    $expected = @{}
    foreach ($rel in $ExpectedRelativePaths) { $expected[$rel.ToLowerInvariant()] = $true }
    foreach ($file in @(Get-ChildItem -LiteralPath $StagingPath -Recurse -File -Force)) {
        $rel = $file.FullName.Substring($rootFull.Length + 1)
        if (-not $expected.ContainsKey($rel.ToLowerInvariant())) {
            throw "Unexpected file in staging folder: $rel"
        }
    }
}

$exitCode = 0

try {
    if (-not (Test-IsElevated)) {
        Write-Error "Access Denied: Install-ActiveSetupStage.ps1 must be executed with administrative privileges (SYSTEM or local admin)."
        $exitCode = 1
    } else {
        if ($Uninstall) {
            Write-Verbose "Unregistering Active Setup component..."
            if (Test-Path $activeSetupKeyPath) {
                if ($PSCmdlet.ShouldProcess($activeSetupKeyPath, "Remove-Item Registry Key")) {
                    Remove-Item -Path $activeSetupKeyPath -Force -Recurse -ErrorAction Stop
                    Write-Output "Successfully removed Active Setup registry key: $activeSetupKeyPath"
                }
            } else {
                Write-Output "Active Setup key not found: $activeSetupKeyPath"
            }

            if (Test-Path $StagingPath) {
                if ($PSCmdlet.ShouldProcess($StagingPath, "Remove Staged Files")) {
                    Remove-Item -Path $StagingPath -Force -Recurse -ErrorAction Stop
                    Write-Output "Successfully removed staging folder: $StagingPath"
                }
            }
            $exitCode = 0
        } else {
            # 1. Resolve source files
            $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
            if ([string]::IsNullOrWhiteSpace($scriptDir)) {
                $scriptDir = Get-Location
            }
            $projectRoot = Split-Path -Parent $scriptDir

            $sourceRepairScript = Join-Path $projectRoot "Repair-WingetAlias.ps1"
            $sourceModuleDir = Join-Path $projectRoot "WingetDiagnosticTool"

            # Check if running directly from project root
            if (-not (Test-Path $sourceRepairScript)) {
                $sourceRepairScript = Join-Path $scriptDir "Repair-WingetAlias.ps1"
                $sourceModuleDir = Join-Path $scriptDir "WingetDiagnosticTool"
            }

            if (-not (Test-Path $sourceRepairScript)) {
                throw "Source file 'Repair-WingetAlias.ps1' could not be located in '$projectRoot' or '$scriptDir'."
            }

            # 2. Stage files into a fresh, locked-down target location.
            # Standard users can create folders under ProgramData and own what they create, so an
            # existing staging folder is never reused: it is deleted, then recreated with a locked
            # ACL in the same call, so no other user can write to it at any point. The new folder is
            # verified before anything is copied into it (a folder another user recreated in the
            # meantime fails that check), the build entry for this account is removed after the
            # copy, and the result is verified again. Any failure stops with exit 1.
            $StagingPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StagingPath)
            if ($PSCmdlet.ShouldProcess($StagingPath, "Stage Files With Restricted ACL")) {
                if ([System.IO.Directory]::Exists($StagingPath)) {
                    [System.IO.Directory]::Delete($StagingPath, $true)
                    Write-Verbose "Removed existing staging directory: $StagingPath"
                }
                New-StagingDirectory -Path $StagingPath -Security (Get-StagingSecurity -BuildSid $script:SidCurrent)
                Assert-StagingSecure -StagingPath $StagingPath -ExpectedRelativePaths @() -BuildSid $script:SidCurrent
                Write-Verbose "Created locked staging directory: $StagingPath"

                $expectedFiles = @("Repair-WingetAlias.ps1")
                Copy-Item -Path $sourceRepairScript -Destination $StagingPath -Force:$Force
                if (Test-Path $sourceModuleDir) {
                    Copy-Item -Path $sourceModuleDir -Destination $StagingPath -Recurse -Force:$Force
                    $moduleParent = (Get-Item -LiteralPath $sourceModuleDir).Parent.FullName.TrimEnd('\')
                    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceModuleDir -Recurse -File -Force)) {
                        $expectedFiles += $sourceFile.FullName.Substring($moduleParent.Length + 1)
                    }
                }

                Set-StagingAcl -Path $StagingPath
                Assert-StagingSecure -StagingPath $StagingPath -ExpectedRelativePaths $expectedFiles
                Write-Output "Successfully staged WingetDiagnosticTool to: $StagingPath (ACL: SYSTEM/Administrators full, Users read-only)"
            }

            # 3. Register Active Setup in HKLM
            $stagedScriptPath = Join-Path $StagingPath "Repair-WingetAlias.ps1"
            $powershellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $stubPath = "`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stagedScriptPath`" -Force"

            if ($PSCmdlet.ShouldProcess($activeSetupKeyPath, "Register Active Setup Component")) {
                if (-not (Test-Path $activeSetupKeyPath)) {
                    New-Item -Path $activeSetupKeyPath -Force | Out-Null
                }

                Set-ItemProperty -Path $activeSetupKeyPath -Name "(Default)" -Value "Winget Diagnostic & Repair Stub" -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "ComponentID" -Value "WingetDiagnosticTool" -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "StubPath" -Value $stubPath -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "Version" -Value "1,0,0" -Force
                Set-ItemProperty -Path $activeSetupKeyPath -Name "Locale" -Value "*" -Force

                Write-Output "Successfully registered Active Setup component at: $activeSetupKeyPath"
                Write-Output "Stub command: $stubPath"
            }

            $exitCode = 0
        }
    }
} catch {
    Write-Error "Failed to configure Active Setup staging: $_"
    $exitCode = 1
}

$isTestRunner = $env:IsTestRunner -eq "true" -or (Get-Variable -Name "IsTestRunner" -Scope "global" -ErrorAction SilentlyContinue).Value
if ($isTestRunner) {
    return $exitCode
} else {
    exit $exitCode
}
