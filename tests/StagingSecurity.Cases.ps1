# StagingSecurity.Cases.ps1
# Cases for the staging checks in sccm\Install-ActiveSetupStage.ps1, run by tests\Run-Tests.ps1 (tests 89-96) inside
# a test sandbox. It loads the script's functions and $script: settings without running the script, runs one case,
# and returns 0 when the check behaves as the case expects (1 otherwise). A rejection only counts when its message
# names the reason the case is about, so a different check failing first does not hide a missing one.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H')]
    [string]$Case
)

$installScript = Join-Path (Get-Location) "sccm\Install-ActiveSetupStage.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
foreach ($statement in $ast.EndBlock.Statements) {
    $isFunction = $statement -is [System.Management.Automation.Language.FunctionDefinitionAst]
    $isScriptSetting = ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($statement.Left.Extent.Text -like '$script:*')
    if ($isFunction -or $isScriptSetting) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

$caseRoot = Join-Path (Get-Location) "cases"
[void][System.IO.Directory]::CreateDirectory($caseRoot)
$stagedFiles = @('top.ps1', 'Mod\Private\deep.ps1')

function Initialize-CleanStagedFolder {
    # Stages two files the way Install-ActiveSetupStage.ps1 does: locked create, copy, final ACL.
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $caseRoot $Name
    New-StagingDirectory -Path $path -Security (Get-StagingSecurity -BuildSid $script:SidCurrent)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $path 'Mod\Private'))
    Set-Content -LiteralPath (Join-Path $path 'top.ps1') -Value 'x'
    Set-Content -LiteralPath (Join-Path $path 'Mod\Private\deep.ps1') -Value 'y'
    Set-StagingAcl -Path $path
    return $path
}

$expectedReason = @{
    A = 'can write to staged item'
    B = 'is a link'
    C = 'owned by an untrusted principal'
    D = 'not protected|can write to staged item'
    E = 'can write to staged item'
    G = 'Unexpected file'
}
$shouldReject = $expectedReason.ContainsKey($Case)
$rejected = $false
$message = ''

try {
    switch ($Case) {
        'A' {
            # An explicit write entry for an arbitrary user SID on a staged subfolder
            $path = Initialize-CleanStagedFolder -Name 'caseA'
            $subFolder = Join-Path $path 'Mod\Private'
            $acl = Get-Acl -LiteralPath $subFolder
            $sid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1001')
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
            $dir = [System.IO.DirectoryInfo]::new($subFolder)
            if ($script:AclExtensions) { $script:AclExtensions::SetAccessControl($dir, $acl) } else { $dir.SetAccessControl($acl) }
            Assert-StagingSecure -StagingPath $path -ExpectedRelativePaths $stagedFiles
        }
        'B' {
            # The staging path is a junction to a clean staged folder
            $target = Initialize-CleanStagedFolder -Name 'caseB-target'
            $link = Join-Path $caseRoot 'caseB-link'
            $null = cmd.exe /c mklink /J "$link" "$target"
            Assert-StagingSecure -StagingPath $link -ExpectedRelativePaths $stagedFiles
        }
        'C' {
            # A folder owned by another principal (System32\drivers\etc is owned by TrustedInstaller)
            $foreign = Join-Path $env:SystemRoot 'System32\drivers\etc'
            $owner = (Get-Acl -LiteralPath $foreign).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if (@($script:SidSystem, $script:SidAdministrators, $script:SidCurrent) -contains $owner) {
                Write-Output "Case C precondition failed: $foreign is owned by $owner, a trusted owner"
                return 1
            }
            Assert-StagingSecure -StagingPath $foreign -ExpectedRelativePaths @()
        }
        'D' {
            # The path was recreated by someone else before the locked create, so the create did nothing
            $path = Join-Path $caseRoot 'caseD'
            [void][System.IO.Directory]::CreateDirectory($path)
            New-StagingDirectory -Path $path -Security (Get-StagingSecurity -BuildSid $script:SidCurrent)
            Assert-StagingSecure -StagingPath $path -ExpectedRelativePaths @() -BuildSid $script:SidCurrent
        }
        'E' {
            # The build entry is still there at the final check
            $path = Join-Path $caseRoot 'caseE'
            New-StagingDirectory -Path $path -Security (Get-StagingSecurity -BuildSid $script:SidCurrent)
            Assert-StagingSecure -StagingPath $path -ExpectedRelativePaths @()
        }
        'F' {
            # A fresh locked folder passes the check made before the copy
            $path = Join-Path $caseRoot 'caseF'
            New-StagingDirectory -Path $path -Security (Get-StagingSecurity -BuildSid $script:SidCurrent)
            Assert-StagingSecure -StagingPath $path -ExpectedRelativePaths @() -BuildSid $script:SidCurrent
        }
        'G' {
            # A file that was not staged from the source
            $path = Join-Path $caseRoot 'caseG'
            New-StagingDirectory -Path $path -Security (Get-StagingSecurity -BuildSid $script:SidCurrent)
            Set-Content -LiteralPath (Join-Path $path 'evil.ps1') -Value 'x'
            Assert-StagingSecure -StagingPath $path -ExpectedRelativePaths @() -BuildSid $script:SidCurrent
        }
        'H' {
            # A cleanly staged folder passes the final check
            $path = Initialize-CleanStagedFolder -Name 'caseH'
            Assert-StagingSecure -StagingPath $path -ExpectedRelativePaths $stagedFiles
        }
    }
} catch {
    $rejected = $true
    $message = $_.Exception.Message
}

if ($shouldReject) {
    $asExpected = $rejected -and ($message -match $expectedReason[$Case])
} else {
    $asExpected = -not $rejected
}
Write-Output ("Case {0}: rejected={1}; message={2}; {3}" -f $Case, $rejected, $message, $(if ($asExpected) { 'as expected' } else { 'NOT as expected' }))
if ($asExpected) { return 0 } else { return 1 }
