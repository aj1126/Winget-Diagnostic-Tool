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

    The Active Setup key is written through the 64-bit registry view, so a 32-bit PowerShell host (the
    default for a task sequence's Run Command Line step) does not land it under WOW6432Node. Its Version
    follows the module version, so users who ran an older build run the repair again after an upgrade.
    If staging fails after it has started, an existing registration is removed, so it never runs an
    unverified folder.
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

# Active Setup component key, relative to HKLM, always in the 64-bit registry view.
$activeSetupSubKey = "SOFTWARE\Microsoft\Active Setup\Installed Components\WingetDiagnosticTool"
$activeSetupDisplayPath = "HKLM\$activeSetupSubKey (64-bit view)"

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

function Get-LocalMachineKey {
    # HKLM root in the 64-bit view; the test runner substitutes its in-memory MockRegistry so tests never
    # touch the real registry.
    $mockRegistry = 'MockRegistry' -as [type]
    if ($mockRegistry) {
        return $mockRegistry::LocalMachine
    }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

function Test-ActiveSetupRegistered {
    $key = (Get-LocalMachineKey).OpenSubKey($activeSetupSubKey)
    if ($key) {
        $key.Close()
        return $true
    }
    return $false
}

function Remove-ActiveSetupRegistration {
    # Deletes the Active Setup component key. Returns $true if a key was removed.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not (Test-ActiveSetupRegistered)) {
        return $false
    }
    if ($PSCmdlet.ShouldProcess($activeSetupDisplayPath, "Remove Active Setup registration")) {
        (Get-LocalMachineKey).DeleteSubKeyTree($activeSetupSubKey, $false)
        return $true
    }
    return $false
}

function Get-ActiveSetupVersion {
    # Active Setup runs StubPath again for a user whose recorded Version is lower than this one,
    # so the Version follows the module version (major,minor,build).
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $moduleVersion = [version](Import-PowerShellDataFile -LiteralPath $ManifestPath).ModuleVersion
    $build = [Math]::Max($moduleVersion.Build, 0)
    return "{0},{1},{2}" -f $moduleVersion.Major, $moduleVersion.Minor, $build
}

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
    # item; and the folder holds only files staged from the source. The folder itself is checked
    # before anything inside it is listed.
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

    $assertItem = {
        param([string]$Path, [System.IO.FileAttributes]$Attributes)
        if (($Attributes -band $reparse) -ne 0) {
            throw "Staged item is a link: $Path"
        }
        $acl = Get-Acl -LiteralPath $Path
        $owner = $acl.GetOwner($sidType).Value
        if ($trustedOwners -notcontains $owner) {
            throw "Staged item is owned by an untrusted principal ($owner): $Path"
        }
        foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if (($rule.FileSystemRights -band $writeMask) -eq 0) { continue }
            if ($writers -notcontains $rule.IdentityReference.Value) {
                throw "Principal $($rule.IdentityReference.Value) can write to staged item: $Path"
            }
        }
        return $acl
    }

    $rootInfo = [System.IO.DirectoryInfo]::new($StagingPath)
    if (($rootInfo.Attributes -band $reparse) -ne 0) {
        throw "Staging folder is a link, not a folder: $StagingPath"
    }
    $rootAcl = & $assertItem $rootInfo.FullName $rootInfo.Attributes
    if (-not $rootAcl.AreAccessRulesProtected) {
        throw "Staging folder ACL is not protected: $StagingPath"
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $StagingPath -Recurse -Force)) {
        $null = & $assertItem $item.FullName $item.Attributes
    }

    $rootFull = $rootInfo.FullName.TrimEnd('\')
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
$stagingStarted = $false

try {
    if (-not (Test-IsElevated)) {
        Write-Error "Access Denied: Install-ActiveSetupStage.ps1 must be executed with administrative privileges (SYSTEM or local admin)."
        $exitCode = 1
    } else {
        if ($Uninstall) {
            Write-Verbose "Unregistering Active Setup component..."
            if (Test-ActiveSetupRegistered) {
                if (Remove-ActiveSetupRegistration) {
                    Write-Output "Successfully removed Active Setup registry key: $activeSetupDisplayPath"
                }
            } else {
                Write-Output "Active Setup key not found: $activeSetupDisplayPath"
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

            # The module is staged with the script, and its manifest sets the Active Setup Version.
            $sourceManifest = Join-Path $sourceModuleDir "WingetDiagnosticTool.psd1"
            if (-not (Test-Path $sourceManifest)) {
                throw "Module manifest '$sourceManifest' could not be located; it is staged with the script and sets the Active Setup Version."
            }
            $activeSetupVersion = Get-ActiveSetupVersion -ManifestPath $sourceManifest

            # 2. Stage files into a fresh, locked-down target location.
            # Standard users can create folders under ProgramData and own what they create, so an
            # existing staging folder is never reused: it is deleted, then recreated with a locked
            # ACL in the same call, so no other user can write to it at any point. The new folder is
            # verified before anything is copied into it (a folder another user recreated in the
            # meantime fails that check), the build entry for this account is removed after the
            # copy, and the result is verified again. Any failure stops with exit 1 and removes an
            # existing Active Setup registration (see the catch block).
            $StagingPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StagingPath)
            if ($PSCmdlet.ShouldProcess($StagingPath, "Stage Files With Restricted ACL")) {
                $stagingStarted = $true
                if ([System.IO.Directory]::Exists($StagingPath)) {
                    [System.IO.Directory]::Delete($StagingPath, $true)
                    Write-Verbose "Removed existing staging directory: $StagingPath"
                }
                New-StagingDirectory -Path $StagingPath -Security (Get-StagingSecurity -BuildSid $script:SidCurrent)
                Assert-StagingSecure -StagingPath $StagingPath -ExpectedRelativePaths @() -BuildSid $script:SidCurrent
                Write-Verbose "Created locked staging directory: $StagingPath"

                $expectedFiles = @("Repair-WingetAlias.ps1")
                Copy-Item -Path $sourceRepairScript -Destination $StagingPath -Force:$Force
                Copy-Item -Path $sourceModuleDir -Destination $StagingPath -Recurse -Force:$Force
                $moduleParent = (Get-Item -LiteralPath $sourceModuleDir).Parent.FullName.TrimEnd('\')
                foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceModuleDir -Recurse -File -Force)) {
                    $expectedFiles += $sourceFile.FullName.Substring($moduleParent.Length + 1)
                }

                Set-StagingAcl -Path $StagingPath
                Assert-StagingSecure -StagingPath $StagingPath -ExpectedRelativePaths $expectedFiles
                Write-Output "Successfully staged WingetDiagnosticTool to: $StagingPath (ACL: SYSTEM/Administrators full, Users read-only)"
            }

            # 3. Register Active Setup in HKLM (64-bit view)
            $stagedScriptPath = Join-Path $StagingPath "Repair-WingetAlias.ps1"
            $powershellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $stubPath = "`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stagedScriptPath`" -Force"

            if ($PSCmdlet.ShouldProcess($activeSetupDisplayPath, "Register Active Setup Component")) {
                $hklm = Get-LocalMachineKey
                $componentKey = $hklm.CreateSubKey($activeSetupSubKey)
                try {
                    $componentKey.SetValue("", "Winget Diagnostic & Repair Stub")
                    $componentKey.SetValue("ComponentID", "WingetDiagnosticTool")
                    $componentKey.SetValue("StubPath", $stubPath)
                    $componentKey.SetValue("Version", $activeSetupVersion)
                    $componentKey.SetValue("Locale", "*")
                } finally {
                    $componentKey.Close()
                }

                Write-Output "Successfully registered Active Setup component at: $activeSetupDisplayPath"
                Write-Output "Stub command: $stubPath"
                Write-Output "Active Setup Version: $activeSetupVersion"
            }

            $exitCode = 0
        }
    }
} catch {
    Write-Error "Failed to configure Active Setup staging: $_"
    $exitCode = 1
    if ($stagingStarted) {
        # The old staging folder may be gone, partly deleted or unverified, so a registration that
        # would run it at the next logon must not stay.
        try {
            if (Remove-ActiveSetupRegistration -Confirm:$false) {
                Write-Warning "Removed the existing Active Setup registration because staging failed: $activeSetupDisplayPath"
            }
        } catch {
            Write-Error "Also failed to remove the existing Active Setup registration ($activeSetupDisplayPath): $_"
        }
    }
}

$isTestRunner = $env:IsTestRunner -eq "true" -or (Get-Variable -Name "IsTestRunner" -Scope "global" -ErrorAction SilentlyContinue).Value
if ($isTestRunner) {
    return $exitCode
} else {
    exit $exitCode
}
