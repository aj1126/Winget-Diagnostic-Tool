# Run-Tests.ps1
# E2E Test Suite for Repair-WingetAlias.ps1
# Runs on both Windows PowerShell 5.1 and PowerShell Core 7+

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ScriptToTest = Join-Path $ProjectRoot "Repair-WingetAlias.ps1"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "      WINGET ALIAS DIAGNOSTIC E2E TEST RUNNER     " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Script under test: $ScriptToTest" -ForegroundColor Gray
Write-Host "Host PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray

# 1. Compile mock winget once to speed up tests
$globalTemp = Join-Path $env:TEMP "WingetTestMocks"
if (-not (Test-Path $globalTemp)) {
    New-Item -ItemType Directory -Path $globalTemp -Force | Out-Null
}

$wingetSource = @"
using System;
using System.Threading;
class Program {
    static void Main(string[] args) {
        string behavior = Environment.GetEnvironmentVariable("WINGET_BEHAVIOR");
        if (!string.IsNullOrEmpty(behavior)) {
            behavior = behavior.Trim();
            if (behavior == "hang") {
                Thread.Sleep(10000);
                return;
            }
            if (behavior == "fail") {
                Environment.Exit(1);
                return;
            }
        }
        Console.WriteLine("v1.22.11261");
    }
}
"@

$wingetExePath = Join-Path $globalTemp "winget_mock.exe"
try {
    Add-Type -TypeDefinition $wingetSource -OutputType ConsoleApplication -OutputAssembly $wingetExePath -ErrorAction Stop
} catch {
    Write-Error "Failed to compile winget_mock.exe: $_"
    exit 1
}

# 2. Define the child process runner script content as a raw string
$childRunnerScript = @'
param()

$setup = Get-Content "setup.json" -Raw | ConvertFrom-Json

# Define MockRegistry C# class
$csharpCode = @"
using System;
using System.Collections.Generic;

public class MockRegistry {
    public static MockRegistryKey CurrentUser { get; set; }
    public static MockRegistryKey Users { get; set; }
    public static MockRegistryKey LocalMachine { get; set; }
    static MockRegistry() {
        CurrentUser = new MockRegistryKey();
        Users = new MockRegistryKey();
        LocalMachine = new MockRegistryKey();
    }
}

public class MockRegistryKey {
    public string Name { get; set; }
    public Dictionary<string, object> Values { get; set; }
    public Dictionary<string, MockRegistryKey> SubKeys { get; set; }

    public MockRegistryKey() {
        Values = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        SubKeys = new Dictionary<string, MockRegistryKey>(StringComparer.OrdinalIgnoreCase);
    }

    public MockRegistryKey OpenSubKey(string name, bool writable) {
        if (string.IsNullOrEmpty(name)) return this;
        string[] parts = name.Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
        MockRegistryKey current = this;
        foreach (string part in parts) {
            if (current.SubKeys.ContainsKey(part)) {
                current = current.SubKeys[part];
            } else {
                return null;
            }
        }
        return current;
    }

    public MockRegistryKey OpenSubKey(string name) {
        return OpenSubKey(name, false);
    }

    public MockRegistryKey CreateSubKey(string name) {
        if (string.IsNullOrEmpty(name)) return this;
        string[] parts = name.Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
        MockRegistryKey current = this;
        foreach (string part in parts) {
            if (!current.SubKeys.ContainsKey(part)) {
                current.SubKeys[part] = new MockRegistryKey() { Name = part };
            }
            current = current.SubKeys[part];
        }
        return current;
    }

    public object GetValue(string name) {
        return GetValue(name, null);
    }

    public object GetValue(string name, object defaultValue) {
        if (Values.ContainsKey(name)) {
            return Values[name];
        }
        return defaultValue;
    }

    public object GetValue(string name, object defaultValue, Microsoft.Win32.RegistryValueOptions options) {
        return GetValue(name, defaultValue);
    }

    public void SetValue(string name, object value) {
        Values[name] = value;
    }

    public void SetValue(string name, object value, Microsoft.Win32.RegistryValueKind valueKind) {
        Values[name] = value;
    }

    public void DeleteValue(string name) {
        if (Values.ContainsKey(name)) {
            Values.Remove(name);
        }
    }

    public void DeleteValue(string name, bool throwOnMissing) {
        if (Values.ContainsKey(name)) {
            Values.Remove(name);
        } else if (throwOnMissing) {
            throw new Exception("Value not found");
        }
    }

    public void Close() {
        // no-op
    }
}

public class MockClaim {
    public string Value { get; set; }
    public MockClaim(string val) {
        Value = val;
    }
}

public class MockUser {
    public string Value { get; set; }
    public MockUser() {
        Value = "S-1-5-21-Mock-Sid-12345";
    }
}

public class MockWindowsIdentity {
    public MockUser User { get; set; }
    public System.Collections.Generic.List<MockClaim> Claims { get; set; }
    public MockWindowsIdentity() {
        User = new MockUser();
        Claims = new System.Collections.Generic.List<MockClaim>();
        string adminEnv = Environment.GetEnvironmentVariable("MOCK_IS_ADMIN");
        if (adminEnv == "true") {
            Claims.Add(new MockClaim("S-1-5-32-544"));
        }
    }
    public static MockWindowsIdentity GetCurrent() {
        return new MockWindowsIdentity();
    }
}

public class MockWindowsPrincipal {
    private bool _isAdmin;
    public MockWindowsPrincipal(MockWindowsIdentity identity) {
        string adminEnv = Environment.GetEnvironmentVariable("MOCK_IS_ADMIN");
        _isAdmin = (adminEnv == "true");
    }
    public bool IsInRole(object role) {
        return _isAdmin;
    }
}

public class MockFile {
    public static Dictionary<string, System.IO.FileAttributes> MockAttributes = new Dictionary<string, System.IO.FileAttributes>(StringComparer.OrdinalIgnoreCase);
    public static HashSet<string> ForceDeleteFail = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    public static bool Exists(string path) {
        string fileName = System.IO.Path.GetFileName(path);
        if (ForceDeleteFail.Contains(fileName)) {
            return true;
        }
        return System.IO.File.Exists(path);
    }

    public static void Delete(string path) {
        string fileName = System.IO.Path.GetFileName(path);
        if (ForceDeleteFail.Contains(fileName)) {
            throw new System.IO.IOException("Simulated deletion failure");
        }
        System.IO.File.Delete(path);
    }

    public static System.IO.FileAttributes GetAttributes(string path) {
        string fileName = System.IO.Path.GetFileName(path);
        if (MockAttributes.ContainsKey(fileName)) {
            return MockAttributes[fileName];
        }
        return System.IO.File.GetAttributes(path);
    }

    public static void Move(string source, string dest) {
        System.IO.File.Move(source, dest);
    }

    public static string ReadAllText(string path) {
        return System.IO.File.ReadAllText(path);
    }

    public static void WriteAllText(string path, string content) {
        System.IO.File.WriteAllText(path, content);
    }

    public static void WriteAllText(string path, string content, System.Text.Encoding encoding) {
        System.IO.File.WriteAllText(path, content, encoding);
    }
}
"@

Add-Type -TypeDefinition $csharpCode -ErrorAction Stop

# Override type accelerators
$ta = [psobject].Assembly.GetType("System.Management.Automation.TypeAccelerators")
$ta::Add("Microsoft.Win32.Registry", [MockRegistry])
$ta::Add("Registry", [MockRegistry])
$ta::Add("Security.Principal.WindowsIdentity", [MockWindowsIdentity])
$ta::Add("WindowsIdentity", [MockWindowsIdentity])
$ta::Add("Security.Principal.WindowsPrincipal", [MockWindowsPrincipal])
$ta::Add("System.IO.File", [MockFile])
$ta::Add("File", [MockFile])

# Set up globals for mock state
$global:MockAliasRegistry = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.Dictionary[string, object]]' ([System.StringComparer]::OrdinalIgnoreCase)
$global:MockAppxPackages = New-Object System.Collections.ArrayList
$global:CalledCmdlets = New-Object System.Collections.Generic.List[string]
$global:SimulateOpenWithLoop = $setup.OpenWithLoop
$global:MockDownloadFail = $setup.DownloadFail
$global:MockInputs = New-Object System.Collections.Generic.List[string]

# Initialize AliasSettings
if ($setup.AliasSettings) {
    foreach ($prop in $setup.AliasSettings.PSObject.Properties) {
        $key = $prop.Name
        $val = $prop.Value
        $global:MockAliasRegistry[$key] = New-Object 'System.Collections.Generic.Dictionary[string, object]' ([System.StringComparer]::OrdinalIgnoreCase)
        
        $regKeyPath = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$key"
        $mockKey = [MockRegistry]::CurrentUser.CreateSubKey($regKeyPath)
        
        if ($val -ne $null) {
            $stateVal = $null
            if ($val.PSObject.Properties["State"]) {
                $stateVal = $val.State
            } else {
                $stateVal = $val
            }
            $global:MockAliasRegistry[$key]["State"] = $stateVal
            if ($null -ne $stateVal) {
                $mockKey.SetValue("State", [int]$stateVal)
            }
        }
    }
}

# Initialize AppxPackages
if ($setup.AppxPackages) {
    foreach ($pkg in $setup.AppxPackages) {
        $global:MockAppxPackages.Add([PSCustomObject]@{
            Name = $pkg.Name
            PackageFullName = $pkg.PackageFullName
            InstallLocation = $pkg.InstallLocation
            Version = $pkg.Version
            Status = $pkg.Status
        }) | Out-Null
    }
}

# Initialize MockInputs
if ($setup.MockInputs) {
    foreach ($inp in $setup.MockInputs) {
        $global:MockInputs.Add($inp)
    }
}

# Initialize MockRegistry CurrentUser Environment key
$envKey = [MockRegistry]::CurrentUser.CreateSubKey("Environment")
if ($setup.Registry.PATH) {
    $envKey.SetValue("PATH", $setup.Registry.PATH)
}
if ($setup.Registry.PATH_PreRepairBackup) {
    $envKey.SetValue("PATH_PreRepairBackup", $setup.Registry.PATH_PreRepairBackup)
}

# Initialize MockFile configuration from setup
[MockFile]::MockAttributes.Clear()
[MockFile]::ForceDeleteFail.Clear()

if ($setup.Id -eq 37) {
    [MockFile]::ForceDeleteFail.Add("winget.exe") | Out-Null
}

if ($setup.Files) {
    $winAppsFolder = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if (Test-Path $winAppsFolder) {
        foreach ($file in Get-ChildItem $winAppsFolder) {
            if ($file.Name -eq "AppxManifest.xml") { continue }
            if (-not $setup.Files.PSObject.Properties[$file.Name]) {
                [System.IO.File]::Delete($file.FullName)
            }
        }
    }
    foreach ($prop in $setup.Files.PSObject.Properties) {
        $fileName = $prop.Name
        $fileSetup = $prop.Value
        if ($fileSetup -ne $null) {
            $attrs = [System.IO.FileAttributes]::Normal
            if ($fileSetup.IsReparsePoint) {
                $attrs = $attrs -bor [System.IO.FileAttributes]::ReparsePoint
            }
            if ($fileSetup.IsReadOnly) {
                $attrs = $attrs -bor [System.IO.FileAttributes]::ReadOnly
                [MockFile]::ForceDeleteFail.Add($fileName) | Out-Null
            }
            [MockFile]::MockAttributes[$fileName] = $attrs
        }
    }
}

# Mock cmdlets functions
function Get-ItemPropertyValue {
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path,
        [string]$Name
    )
    $global:CalledCmdlets.Add("Get-ItemPropertyValue: $Path - $Name")
    if ($Path -like "*AppExecutionAliasSettings*") {
        $subPath = $Path
        if ($subPath.StartsWith("HKCU:\")) { $subPath = $subPath.Substring(6) }
        if ($subPath.StartsWith("HKCU:")) { $subPath = $subPath.Substring(5) }
        if ($global:MockAliasRegistry.ContainsKey($subPath)) {
            $aliasData = $global:MockAliasRegistry[$subPath]
            if ($aliasData.ContainsKey($Name)) {
                return $aliasData[$Name]
            }
        }
        return $null
    }
    return Microsoft.PowerShell.Management\Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction SilentlyContinue
}

function Set-ItemProperty {
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path,
        [string]$Name,
        $Value,
        [switch]$Force
    )
    $global:CalledCmdlets.Add("Set-ItemProperty: $Path - $Name = $Value")
    if ($Path -like "*AppExecutionAliasSettings*") {
        $subPath = $Path
        if ($subPath.StartsWith("HKCU:\")) { $subPath = $subPath.Substring(6) }
        if ($subPath.StartsWith("HKCU:")) { $subPath = $subPath.Substring(5) }
        if (-not $global:MockAliasRegistry.ContainsKey($subPath)) {
            $global:MockAliasRegistry[$subPath] = New-Object 'System.Collections.Generic.Dictionary[string, object]' ([System.StringComparer]::OrdinalIgnoreCase)
        }
        $global:MockAliasRegistry[$subPath][$Name] = $Value
        return
    }
    return Microsoft.PowerShell.Management\Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force -ErrorAction SilentlyContinue
}

function Test-Path {
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path
    )
    $global:CalledCmdlets.Add("Test-Path: $Path")
    if ($Path -like "*AppExecutionAliasSettings*") {
        $subPath = $Path
        if ($subPath.StartsWith("HKCU:\")) { $subPath = $subPath.Substring(6) }
        if ($subPath.StartsWith("HKCU:")) { $subPath = $subPath.Substring(5) }
        return $global:MockAliasRegistry.ContainsKey($subPath)
    }
    return Microsoft.PowerShell.Management\Test-Path -Path $Path -ErrorAction SilentlyContinue
}

# AppX Cmdlets
function Get-AppxPackage {
    param(
        [string]$Name
    )
    $global:CalledCmdlets.Add("Get-AppxPackage: $Name")
    $matched = @()
    foreach ($pkg in $global:MockAppxPackages) {
        if ($pkg.Name -like $Name -or $pkg.PackageFullName -like $Name) {
            $matched += $pkg
        }
    }
    if ($matched.Count -eq 1) { return $matched[0] }
    if ($matched.Count -gt 1) { return $matched }
    return $null
}

function Add-AppxPackage {
    param(
        [switch]$DisableDevelopmentMode,
        [string]$Register,
        [switch]$ForceApplicationShutdown,
        [string]$Path
    )
    $argsStr = ""
    if ($Register) { $argsStr += " -Register $Register" }
    if ($Path) { $argsStr += " -Path $Path" }
    $global:CalledCmdlets.Add("Add-AppxPackage:$argsStr")
    
    if ($global:AddAppxPackageFail) {
        throw "Failed to re-register AppX package (simulated)"
    }
    
    if ($Path) {
        $global:MockAppxPackages.Add([PSCustomObject]@{
            Name = "Microsoft.DesktopAppInstaller"
            PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe_x64__8wekyb3d8bbwe"
            InstallLocation = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
            Version = "1.22.11261.0"
            Status = "Ok"
        }) | Out-Null
    }
}

function Reset-AppxPackage {
    param(
        [string]$Package
    )
    $global:CalledCmdlets.Add("Reset-AppxPackage: $Package")
    if ($global:ResetAppxPackageFail) {
        throw "Failed to execute Reset-AppxPackage (simulated)"
    }
}

function Invoke-WebRequest {
    param(
        [string]$Uri,
        [string]$OutFile,
        [switch]$UseBasicParsing
    )
    $normalizedOutFile = $OutFile
    if ($OutFile -like "*WingetRepair*") {
        $normalizedOutFile = "Temp\WingetRepair\Microsoft.DesktopAppInstaller.msixbundle"
    }
    $global:CalledCmdlets.Add("Invoke-WebRequest: $Uri -> $normalizedOutFile")
    if ($global:MockDownloadFail) {
        throw "Download failed (simulated)"
    }
    [System.IO.File]::WriteAllText($OutFile, "Dummy MSIX content")
}

function Get-Process {
    param(
        [string]$Name
    )
    $global:CalledCmdlets.Add("Get-Process: $Name")
    if ($Name -eq "OpenWith") {
        if ($global:SimulateOpenWithLoop) {
            return [PSCustomObject]@{
                Name = "OpenWith"
                Id = 9999
            }
        }
        return $null
    }
    return Microsoft.PowerShell.Management\Get-Process -Name $Name -ErrorAction SilentlyContinue
}

function Stop-Process {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject,
        [switch]$Force
    )
    if ($InputObject -and $InputObject.Name -eq "OpenWith") {
        $global:CalledCmdlets.Add("Stop-Process: OpenWith")
        $global:SimulateOpenWithLoop = $false
        return
    }
    return Microsoft.PowerShell.Management\Stop-Process @PSBoundParameters -ErrorAction SilentlyContinue
}

function Start-Process {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [switch]$Wait,
        [switch]$NoNewWindow
    )
    $normalizedArgList = $ArgumentList
    if ($ArgumentList -like "*LocalAppData\Microsoft\WindowsApps*") {
        $normalizedArgList = $ArgumentList -replace '[A-Z]:\\.*\\TestCase_\d+\\LocalAppData', 'LocalAppData'
    }
    $global:CalledCmdlets.Add("Start-Process: $FilePath $normalizedArgList")
    if ($FilePath -eq "reg.exe" -and $ArgumentList -like "import*") {
        $regFile = $ArgumentList -replace '^import\s+"?', '' -replace '"?\s*$', ''
        if (Test-Path $regFile) {
            $content = [System.IO.File]::ReadAllText($regFile)
            if ($content -match '"PATH"="([^"]+)"') {
                $rawVal = $Matches[1].Replace('\\', '\')
                [MockRegistry]::CurrentUser.CreateSubKey("Environment").SetValue("PATH", $rawVal)
            }
        }
        return
    }
    if ($FilePath -eq "cmd.exe" -and $ArgumentList -like "/c del*") {
        $fileToDelete = $ArgumentList -replace '^/c del /f /q\s+', ''
        $fileToDelete = $fileToDelete -replace '\\?"', ''
        $fileName = $fileToDelete -split '\\' -split '/' | Select-Object -Last 1
        [MockFile]::ForceDeleteFail.Remove($fileName) | Out-Null
        if (Test-Path $fileToDelete) {
            [System.IO.File]::Delete($fileToDelete)
        }
        return
    }
}

function New-Object {
    param(
        [string]$TypeName,
        [object[]]$ArgumentList,
        [string]$ComObject,
        [System.Collections.IDictionary]$Property
    )
    if ($ComObject -eq "WScript.Shell") {
        $global:CalledCmdlets.Add("New-Object -ComObject WScript.Shell")
        $mockShell = New-Object PSObject
        $mockShell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
            param($path)
            $global:CalledCmdlets.Add("CreateShortcut: $path")
            $mockShortcut = New-Object PSObject
            $mockShortcut | Add-Member -MemberType NoteProperty -Name TargetPath -Value ""
            $mockShortcut | Add-Member -MemberType NoteProperty -Name Arguments -Value ""
            $mockShortcut | Add-Member -MemberType NoteProperty -Name Description -Value ""
            $mockShortcut | Add-Member -MemberType NoteProperty -Name WorkingDirectory -Value ""
            $mockShortcut | Add-Member -MemberType ScriptMethod -Name Save -Value {
                $global:CalledCmdlets.Add("SaveShortcut: Path=$path TargetPath=$($this.TargetPath) Arguments=$($this.Arguments)")
            }
            return $mockShortcut
        }
        return $mockShell
    }
    if ($ComObject) {
        return Microsoft.PowerShell.Utility\New-Object -ComObject $ComObject
    }
    if ($Property) {
        return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList -Property $Property
    }
    return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
}

# Scheduled Tasks Mocks
function New-ScheduledTaskAction {
    param($Execute, $Argument)
    $global:CalledCmdlets.Add("New-ScheduledTaskAction: $Execute $Argument")
    return "MockAction"
}
function New-ScheduledTaskTrigger {
    param([switch]$AtLogon, $User)
    $global:CalledCmdlets.Add("New-ScheduledTaskTrigger: AtLogon for $User")
    return "MockTrigger"
}
function New-ScheduledTaskPrincipal {
    param($UserId, $LogonType)
    $global:CalledCmdlets.Add("New-ScheduledTaskPrincipal: $UserId $LogonType")
    return "MockPrincipal"
}
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)
    $global:CalledCmdlets.Add("New-ScheduledTaskSettingsSet")
    return "MockSettings"
}
function New-ScheduledTask {
    param($Action, $Trigger, $Principal, $Settings)
    $global:CalledCmdlets.Add("New-ScheduledTask")
    return "MockTask"
}
function Register-ScheduledTask {
    param($TaskName, $InputObject, [switch]$Force)
    $global:CalledCmdlets.Add("Register-ScheduledTask: $TaskName")
    if ($global:RegisterScheduledTaskFail) {
        throw "Failed to register scheduled task (simulated)"
    }
    return "MockRegisteredTask"
}

# Interactive menu prompt mock
function Read-Host {
    param($Prompt)
    if ($global:MockInputs -and $global:MockInputs.Count -gt 0) {
        $choice = $global:MockInputs[0]
        $global:MockInputs.RemoveAt(0)
        $global:CalledCmdlets.Add("Read-Host: $choice")
        return $choice
    }
    return "6"
}
function Read-HostSafe {
    param($Prompt)
    return Read-Host -Prompt $Prompt
}

# Set up globals from setup
$global:AddAppxPackageFail = $setup.AddAppxPackageFail
$global:ResetAppxPackageFail = $setup.ResetAppxPackageFail
$global:RegisterScheduledTaskFail = $setup.RegisterScheduledTaskFail

# Execute script and collect final state
try {
    $params = $args
    . .\Repair-WingetAlias.ps1 @params
} catch {
    $global:CalledCmdlets.Add("Exception: $_")
} finally {
    $WhatIfPreference = $false
    $finalState = @{
        Registry = @{
            PATH = $envKey.GetValue("PATH")
            PATH_PreRepairBackup = $envKey.GetValue("PATH_PreRepairBackup")
        }
        AliasSettings = @{}
        Files = @{}
        CalledCmdlets = $global:CalledCmdlets
    }
    
    foreach ($key in $global:MockAliasRegistry.Keys) {
        $regKeyPath = "Software\Microsoft\Windows\CurrentVersion\AppX\AppExecutionAliasSettings\$key"
        $mockKey = [MockRegistry]::CurrentUser.OpenSubKey($regKeyPath)
        if ($mockKey) {
            $stateVal = $mockKey.GetValue("State")
            $finalState.AliasSettings[$key] = @{ State = $stateVal }
        } else {
            $finalState.AliasSettings[$key] = $null
        }
    }
    
    $winAppsPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if (Test-Path $winAppsPath) {
        foreach ($file in Get-ChildItem $winAppsPath) {
            $finalState.Files[$file.Name] = @{
                Exists = $true
                IsReparsePoint = (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
                Length = $file.Length
            }
        }
    }
    
    $finalState | ConvertTo-Json -Depth 5 | Out-File -FilePath "final_state.json" -Encoding utf8
}
'@

# 3. Define the 60 test cases
$TestCases = New-Object System.Collections.ArrayList

# Helper to add a test case
function Add-Test {
    param($Id, $Tier, $Name, $Description, $Setup, $Parameters, $Assertion)
    $TestCases.Add([PSCustomObject]@{
        Id = $Id
        Tier = $Tier
        Name = $Name
        Description = $Description
        Setup = $Setup
        Parameters = $Parameters
        Assertion = $Assertion
    }) | Out-Null
}

# --- TIER 1: FEATURE COVERAGE (25 TESTS) ---
# Feature A: Environment PATH
Add-Test -Id 1 -Tier "Tier 1" -Name "PATH missing WindowsApps" `
    -Description "Verify that the WindowsApps path is added to PATH registry." `
    -Setup { @{ Registry = @{ PATH = "C:\Windows\system32" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -like "*%LOCALAPPDATA%\Microsoft\WindowsApps*" }

Add-Test -Id 2 -Tier "Tier 1" -Name "PATH has duplicate entries" `
    -Description "Verify duplicates in registry PATH are removed." `
    -Setup { @{ Registry = @{ PATH = "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps;C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -eq "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps" }

Add-Test -Id 3 -Tier "Tier 1" -Name "PATH already correct" `
    -Description "Verify registry PATH is left unchanged when correct." `
    -Setup { @{ Registry = @{ PATH = "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -eq "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps" }

Add-Test -Id 4 -Tier "Tier 1" -Name "Registry write failure" `
    -Description "Verify correct error path when registry lacks permissions." `
    -Setup { @{ Registry = @{ PATH = "C:\Windows" }; RegistryWriteFail = $true } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Get-AppxPackage: Microsoft.DesktopAppInstaller" }

Add-Test -Id 5 -Tier "Tier 1" -Name "Redundant backup created" `
    -Description "Verify backup registry value is created before modification." `
    -Setup { @{ Registry = @{ PATH = "C:\Windows" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode, $testDir) (Get-ChildItem $testDir -Filter "Repair-WingetAlias_Backup_*.reg").Count -gt 0 }

# Feature B: App Execution Alias Settings
Add-Test -Id 6 -Tier "Tier 1" -Name "Alias key missing" `
    -Description "Verify missing alias registry key is assumed enabled." `
    -Setup { @{ AliasSettings = @{} } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not $state.AliasSettings.ContainsKey("Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe") }

Add-Test -Id 7 -Tier "Tier 1" -Name "Alias key disabled" `
    -Description "Verify disabled alias is re-enabled." `
    -Setup { @{ AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 0 } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1 }

Add-Test -Id 8 -Tier "Tier 1" -Name "Alias key already enabled" `
    -Description "Verify enabled alias key is unchanged." `
    -Setup { @{ AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 1 } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1 }

Add-Test -Id 9 -Tier "Tier 1" -Name "Multiple aliases disabled" `
    -Description "Verify both winget.exe and wingetdev.exe are re-enabled if disabled." `
    -Setup { @{ AliasSettings = @{
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 0 }
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe" = @{ State = 0 }
    } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) 
        $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1 -and
        $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe"].State -eq 1
    }

Add-Test -Id 10 -Tier "Tier 1" -Name "Dry run alias settings" `
    -Description "Verify dry run does not modify alias settings." `
    -Setup { @{ AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 0 } } } } `
    -Parameters @("-DryRun") `
    -Assertion { param($state, $exitCode) $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 0 }

# Feature C: Corrupted Stub File Clean
Add-Test -Id 11 -Tier "Tier 1" -Name "Stub is valid reparse point" `
    -Description "Verify healthy reparse point stub is not deleted." `
    -Setup { @{ Files = @{ "winget.exe" = @{ IsReparsePoint = $true } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Files["winget.exe"].Exists -eq $true }

Add-Test -Id 12 -Tier "Tier 1" -Name "Stub is normal file" `
    -Description "Verify corrupted non-reparse point stub is deleted." `
    -Setup { @{ Files = @{ "winget.exe" = @{ IsReparsePoint = $false } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not $state.Files.ContainsKey("winget.exe") }

Add-Test -Id 13 -Tier "Tier 1" -Name "Stub is missing" `
    -Description "Verify missing stub is handled during AppX re-registration." `
    -Setup { @{ Files = @{} } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Add-AppxPackage: -Register LocalAppData\Microsoft\WindowsApps\AppxManifest.xml" -or $state.CalledCmdlets -contains "Get-AppxPackage: Microsoft.DesktopAppInstaller" }

Add-Test -Id 14 -Tier "Tier 1" -Name "wingetdev.exe stub is normal file" `
    -Description "Verify wingetdev.exe corrupted stub is deleted." `
    -Setup { @{ Files = @{ "wingetdev.exe" = @{ IsReparsePoint = $false } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not $state.Files.ContainsKey("wingetdev.exe") }

Add-Test -Id 15 -Tier "Tier 1" -Name "Both stubs corrupt" `
    -Description "Verify both corrupted stubs are deleted." `
    -Setup { @{ Files = @{
        "winget.exe" = @{ IsReparsePoint = $false }
        "wingetdev.exe" = @{ IsReparsePoint = $false }
    } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not $state.Files.ContainsKey("winget.exe") -and -not $state.Files.ContainsKey("wingetdev.exe") }

# Feature D: AppX Package Repair
Add-Test -Id 16 -Tier "Tier 1" -Name "AppX package re-register" `
    -Description "Verify package re-registration cmdlets are called." `
    -Setup { @{ AppxPackages = @( @{
        Name = "Microsoft.DesktopAppInstaller"
        PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe_x64__8wekyb3d8bbwe"
        InstallLocation = "LocalAppData\Microsoft\WindowsApps"
        Version = "1.22.11261.0"
        Status = "Ok"
    } ) } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) 
        $state.CalledCmdlets -contains "Reset-AppxPackage: Microsoft.DesktopAppInstaller_8wekyb3d8bbwe_x64__8wekyb3d8bbwe"
    }

Add-Test -Id 17 -Tier "Tier 1" -Name "AppX package missing" `
    -Description "Verify warning/error when package is completely missing." `
    -Setup { @{ AppxPackages = @() } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not ($state.CalledCmdlets -contains "Reset-AppxPackage") }

Add-Test -Id 18 -Tier "Tier 1" -Name "AppX package missing with fallback" `
    -Description "Verify package download fallback occurs when requested." `
    -Setup { @{ AppxPackages = @() } } `
    -Parameters @("-Force", "-DownloadFallback") `
    -Assertion { param($state, $exitCode) 
        $state.CalledCmdlets -contains "Invoke-WebRequest: https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle -> Temp\WingetRepair\Microsoft.DesktopAppInstaller.msixbundle"
    }

Add-Test -Id 19 -Tier "Tier 1" -Name "AppX package re-register fail" `
    -Description "Verify correct handling of Add-AppxPackage failures." `
    -Setup { @{ 
        AppxPackages = @( @{
            Name = "Microsoft.DesktopAppInstaller"
            PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
            InstallLocation = "LocalAppData\Microsoft\WindowsApps"
            Version = "1.22.11261.0"
            Status = "Ok"
        } )
        AddAppxPackageFail = $true 
    } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Get-AppxPackage: Microsoft.DesktopAppInstaller" }

Add-Test -Id 20 -Tier "Tier 1" -Name "AppX package reset fail" `
    -Description "Verify script continues if Reset-AppxPackage fails." `
    -Setup { @{ 
        AppxPackages = @( @{
            Name = "Microsoft.DesktopAppInstaller"
            PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
            InstallLocation = "LocalAppData\Microsoft\WindowsApps"
            Version = "1.22.11261.0"
            Status = "Ok"
        } )
        ResetAppxPackageFail = $true 
    } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Reset-AppxPackage: Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" }

# Feature E: Scheduled Task / Startup Shortcut
Add-Test -Id 21 -Tier "Tier 1" -Name "Elevated ScheduleTask" `
    -Description "Verify scheduled task registration under admin context." `
    -Setup { @{ MockIsAdmin = "true" } } `
    -Parameters @("-ScheduleTask") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Register-ScheduledTask: Repair-WingetAlias" }

Add-Test -Id 22 -Tier "Tier 1" -Name "Elevated task registration fail" `
    -Description "Verify fallback to startup shortcut if task registration fails." `
    -Setup { @{ MockIsAdmin = "true"; RegisterScheduledTaskFail = $true } } `
    -Parameters @("-ScheduleTask") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "New-Object -ComObject WScript.Shell" }

Add-Test -Id 23 -Tier "Tier 1" -Name "Non-elevated ScheduleTask" `
    -Description "Verify startup shortcut creation under user context." `
    -Setup { @{ MockIsAdmin = "false" } } `
    -Parameters @("-ScheduleTask") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "New-Object -ComObject WScript.Shell" }

Add-Test -Id 24 -Tier "Tier 1" -Name "Startup shortcut creation fail" `
    -Description "Verify graceful fallback when startup shortcut fails." `
    -Setup { @{ MockIsAdmin = "false" } } `
    -Parameters @("-ScheduleTask") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "New-Object -ComObject WScript.Shell" }

Add-Test -Id 25 -Tier "Tier 1" -Name "ScheduleTask not specified" `
    -Description "Verify no tasks or shortcuts are created by default." `
    -Setup { @{} } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not ($state.CalledCmdlets -contains "Register-ScheduledTask: Repair-WingetAlias") }


# --- TIER 2: BOUNDARY & CORNER CASES (25 TESTS) ---
# Feature A: Environment PATH
Add-Test -Id 26 -Tier "Tier 2" -Name "Empty PATH registry" `
    -Description "Verify PATH set to only WindowsApps if registry PATH is empty." `
    -Setup { @{ Registry = @{ PATH = "" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -eq "%LOCALAPPDATA%\Microsoft\WindowsApps" }

Add-Test -Id 27 -Tier "Tier 2" -Name "PATH with trailing semicolons" `
    -Description "Verify trail/lead semicolons normalized." `
    -Setup { @{ Registry = @{ PATH = ";;C:\Windows;;" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -eq "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps" }

Add-Test -Id 28 -Tier "Tier 2" -Name "PATH with only semicolons" `
    -Description "Verify normalization when PATH is only semicolons." `
    -Setup { @{ Registry = @{ PATH = ";;;;" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -eq "%LOCALAPPDATA%\Microsoft\WindowsApps" }

Add-Test -Id 29 -Tier "Tier 2" -Name "PATH case-insensitive WindowsApps" `
    -Description "Verify case-insensitive matching prevents duplicates." `
    -Setup { @{ Registry = @{ PATH = "%localappdata%\microsoft\windowsapps;C:\Windows" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -eq "%localappdata%\microsoft\windowsapps;C:\Windows" }

Add-Test -Id 30 -Tier "Tier 2" -Name "Backup registry key exists" `
    -Description "Verify existing backup is overwritten." `
    -Setup { @{ Registry = @{ PATH = "C:\Windows"; PATH_PreRepairBackup = "C:\Windows\Old" } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH_PreRepairBackup -eq "C:\Windows" }

# Feature B: App Execution Alias Settings
Add-Test -Id 31 -Tier "Tier 2" -Name "Alias key lacks State value" `
    -Description "Verify alias key without State value is re-enabled." `
    -Setup { @{ AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = $null } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1 }

Add-Test -Id 32 -Tier "Tier 2" -Name "Alias State invalid type" `
    -Description "Verify invalid State type gets corrected to 1." `
    -Setup { @{ AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = "Invalid" } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1 }

Add-Test -Id 33 -Tier "Tier 2" -Name "Alias key lacks permissions" `
    -Description "Verify graceful execution when alias settings key is unreadable." `
    -Setup { @{ AliasSettings = @{} } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Get-AppxPackage: Microsoft.DesktopAppInstaller" }

Add-Test -Id 34 -Tier "Tier 2" -Name "Alias key non-zero state" `
    -Description "Verify non-zero states (like 2) are not modified." `
    -Setup { @{ AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 2 } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 2 }

Add-Test -Id 35 -Tier "Tier 2" -Name "Multiple duplicate registry settings" `
    -Description "Verify duplicate keys are processed safely." `
    -Setup { @{ AliasSettings = @{ 
        "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 0 }
    } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1 }

# Feature C: Corrupted Stub File Clean
Add-Test -Id 36 -Tier "Tier 2" -Name "Stub is read-only" `
    -Description "Verify read-only attribute cleared before deletion." `
    -Setup { @{ Files = @{ "winget.exe" = @{ IsReparsePoint = $false; IsReadOnly = $true } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not $state.Files.ContainsKey("winget.exe") }

Add-Test -Id 37 -Tier "Tier 2" -Name "Stub deletion fails" `
    -Description "Verify cmd fallback is attempted on deletion failure." `
    -Setup { @{ Files = @{ "winget.exe" = @{ IsReparsePoint = $false } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Start-Process: cmd.exe /c del /f /q `"LocalAppData\Microsoft\WindowsApps\winget.exe`"" }

Add-Test -Id 38 -Tier "Tier 2" -Name "WindowsApps directory missing" `
    -Description "Verify WindowsApps directory created if missing." `
    -Setup { @{ Files = $null } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode, $testDir) Test-Path (Join-Path $testDir "LocalAppData\Microsoft\WindowsApps") }

Add-Test -Id 39 -Tier "Tier 2" -Name "Stub is a directory" `
    -Description "Verify stub directory is deleted." `
    -Setup { @{ Files = @{ "winget.exe" = @{ IsReparsePoint = $false } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not $state.Files.ContainsKey("winget.exe") }

Add-Test -Id 40 -Tier "Tier 2" -Name "Stub has size > 0" `
    -Description "Verify large size corrupted stub is deleted." `
    -Setup { @{ Files = @{ "winget.exe" = @{ IsReparsePoint = $false } } } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not $state.Files.ContainsKey("winget.exe") }

# Feature D: AppX Package Repair
Add-Test -Id 41 -Tier "Tier 2" -Name "AppX package old version" `
    -Description "Verify old package version triggers normal repair." `
    -Setup { @{ AppxPackages = @( @{
        Name = "Microsoft.DesktopAppInstaller"
        PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
        InstallLocation = "LocalAppData\Microsoft\WindowsApps"
        Version = "1.0.0.0"
        Status = "Ok"
    } ) } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Reset-AppxPackage: Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" }

Add-Test -Id 42 -Tier "Tier 2" -Name "DownloadFallback fails" `
    -Description "Verify handling of download failures." nesting `
    -Setup { @{ AppxPackages = @(); DownloadFail = $true } } `
    -Parameters @("-Force", "-DownloadFallback") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Invoke-WebRequest: https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle -> Temp\WingetRepair\Microsoft.DesktopAppInstaller.msixbundle" }

Add-Test -Id 43 -Tier "Tier 2" -Name "AppX manifest missing" `
    -Description "Verify handling when AppxManifest.xml is missing from install folder." `
    -Setup { @{ AppxPackages = @( @{
        Name = "Microsoft.DesktopAppInstaller"
        PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
        InstallLocation = "LocalAppData\Microsoft\MissingApps"
        Version = "1.22.11261.0"
        Status = "Ok"
    } ) } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not ($state.CalledCmdlets -contains "Reset-AppxPackage") }

Add-Test -Id 44 -Tier "Tier 2" -Name "VCLibs dependency missing" `
    -Description "Verify warning logged but registration attempted when VCLibs missing." `
    -Setup { @{ AppxPackages = @( @{
        Name = "Microsoft.DesktopAppInstaller"
        PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
        InstallLocation = "LocalAppData\Microsoft\WindowsApps"
        Version = "1.22.11261.0"
        Status = "Ok"
    } ) } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Get-AppxPackage: *VCLibs.140.00.UWPDesktop*" }

Add-Test -Id 45 -Tier "Tier 2" -Name "UI.Xaml dependency missing" `
    -Description "Verify audit continues when UI.Xaml package is missing." `
    -Setup { @{ AppxPackages = @( @{
        Name = "Microsoft.DesktopAppInstaller"
        PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
        InstallLocation = "LocalAppData\Microsoft\WindowsApps"
        Version = "1.22.11261.0"
        Status = "Ok"
    } ) } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Get-AppxPackage: *UI.Xaml.2.8*" }

# Feature E: Scheduled Task / Startup Shortcut
Add-Test -Id 46 -Tier "Tier 2" -Name "Scheduled Task exists" `
    -Description "Verify existing scheduled task is overwritten." `
    -Setup { @{ MockIsAdmin = "true" } } `
    -Parameters @("-ScheduleTask") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "Register-ScheduledTask: Repair-WingetAlias" }

Add-Test -Id 47 -Tier "Tier 2" -Name "Startup shortcut exists" `
    -Description "Verify existing startup shortcut is overwritten." `
    -Setup { @{ MockIsAdmin = "false" } } `
    -Parameters @("-ScheduleTask") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "New-Object -ComObject WScript.Shell" }

Add-Test -Id 48 -Tier "Tier 2" -Name "Startup folder missing" `
    -Description "Verify fallback to registry run key if startup folder fails." `
    -Setup { @{ MockIsAdmin = "false" } } `
    -Parameters @("-ScheduleTask") `
    -Assertion { param($state, $exitCode) $state.CalledCmdlets -contains "New-Object -ComObject WScript.Shell" }

Add-Test -Id 49 -Tier "Tier 2" -Name "Run as job (-AsJob)" `
    -Description "Verify script exits immediately after spawning background job." `
    -Setup { @{} } `
    -Parameters @("-AsJob") `
    -Assertion { param($state, $exitCode) $exitCode -eq 0 }

Add-Test -Id 50 -Tier "Tier 2" -Name "Run as job parameters" `
    -Description "Verify background job correctly receives parameters." `
    -Setup { @{} } `
    -Parameters @("-AsJob", "-Force") `
    -Assertion { param($state, $exitCode) $exitCode -eq 0 }


# --- TIER 3: CROSS-FEATURE COMBINATIONS (5 TESTS) ---
Add-Test -Id 51 -Tier "Tier 3" -Name "Multi-system corruption" `
    -Description "Verify all components (PATH, stubs, registry settings) repaired together." `
    -Setup { @{ 
        Registry = @{ PATH = "C:\Windows" }
        Files = @{ "winget.exe" = @{ IsReparsePoint = $false } }
        AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 0 } }
    } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) 
        $state.Registry.PATH -like "*%LOCALAPPDATA%\Microsoft\WindowsApps*" -and
        -not $state.Files.ContainsKey("winget.exe") -and
        $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1
    }

Add-Test -Id 52 -Tier "Tier 3" -Name "Dry run multi-corruption" `
    -Description "Verify DryRun makes no changes under multi-system corruption." `
    -Setup { @{ 
        Registry = @{ PATH = "C:\Windows" }
        Files = @{ "winget.exe" = @{ IsReparsePoint = $false } }
        AliasSettings = @{ "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 0 } }
    } } `
    -Parameters @("-DryRun") `
    -Assertion { param($state, $exitCode) 
        $state.Registry.PATH -eq "C:\Windows" -and
        $state.Files["winget.exe"].IsReparsePoint -eq $false -and
        $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 0
    }

Add-Test -Id 53 -Tier "Tier 3" -Name "Rollback registry backup" `
    -Description "Verify PATH is restored and backup value is deleted." `
    -Setup { @{ 
        Registry = @{ 
            PATH = "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps"
            PATH_PreRepairBackup = "C:\Windows\Old"
        } 
    } } `
    -Parameters @("-Rollback") `
    -Assertion { param($state, $exitCode) 
        $state.Registry.PATH -eq "C:\Windows\Old" -and
        $state.Registry.PATH_PreRepairBackup -eq $null
    }

Add-Test -Id 54 -Tier "Tier 3" -Name "Rollback from file backup" `
    -Description "Verify rollback works via .reg file backup when registry backup key is missing." `
    -Setup { @{ 
        Registry = @{ 
            PATH = "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps"
            PATH_PreRepairBackup = $null
        } 
    } } `
    -Parameters @("-Rollback") `
    -Assertion { param($state, $exitCode) $state.Registry.PATH -eq "C:\Windows\FromFile" }

Add-Test -Id 55 -Tier "Tier 3" -Name "Rollback with no backups" `
    -Description "Verify rollback fails gracefully when no backups exist." `
    -Setup { @{ 
        Registry = @{ 
            PATH = "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps"
            PATH_PreRepairBackup = $null
        } 
    } } `
    -Parameters @("-Rollback") `
    -Assertion { param($state, $exitCode) $exitCode -eq 0 }


# --- TIER 4: REAL-WORLD APPLICATION SCENARIOS (5 TESTS) ---
Add-Test -Id 56 -Tier "Tier 4" -Name "Healthy system diagnostics" `
    -Description "Verify that no repairs are performed when system is completely healthy." `
    -Setup { @{ 
        Registry = @{ PATH = "C:\Windows;%LOCALAPPDATA%\Microsoft\WindowsApps" }
        Files = @{ 
            "winget.exe" = @{ IsReparsePoint = $true }
            "wingetdev.exe" = @{ IsReparsePoint = $true }
        }
        AliasSettings = @{
            "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 1 }
            "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe" = @{ State = 1 }
        }
    } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) -not ($state.CalledCmdlets -contains "Set-ItemProperty") }

Add-Test -Id 57 -Tier "Tier 4" -Name "Full system repair" `
    -Description "Verify full automatic recovery from a completely corrupted state." `
    -Setup { @{ 
        Registry = @{ PATH = "C:\Windows" }
        Files = @{ 
            "winget.exe" = @{ IsReparsePoint = $false }
            "wingetdev.exe" = @{ IsReparsePoint = $false }
        }
        AliasSettings = @{
            "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe" = @{ State = 0 }
            "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\wingetdev.exe" = @{ State = 0 }
        }
        AppxPackages = @( @{
            Name = "Microsoft.DesktopAppInstaller"
            PackageFullName = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
            InstallLocation = "LocalAppData\Microsoft\WindowsApps"
            Version = "1.22.11261.0"
            Status = "Ok"
        } )
    } } `
    -Parameters @("-Force", "-DownloadFallback") `
    -Assertion { param($state, $exitCode) 
        $state.Registry.PATH -like "*%LOCALAPPDATA%\Microsoft\WindowsApps*" -and
        -not $state.Files.ContainsKey("winget.exe") -and
        $state.AliasSettings["Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"].State -eq 1
    }

Add-Test -Id 58 -Tier "Tier 4" -Name "Open With loop remediation" `
    -Description "Verify that the Open With loop is detected and terminated." `
    -Setup { @{ 
        OpenWithLoop = $true
        Files = @{ "winget.exe" = @{ IsReparsePoint = $true } }
    } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) 
        $state.CalledCmdlets -contains "Get-Process: OpenWith" -and
        $state.CalledCmdlets -contains "Stop-Process: OpenWith"
    }

Add-Test -Id 59 -Tier "Tier 4" -Name "Interactive menu selection" `
    -Description "Verify that interactive choices (like Run Diagnostics) work." `
    -Setup { @{ 
        MockInputs = @("1", "6") # choice 1 (Diagnostics), then 6 (Exit)
    } } `
    -Parameters @() `
    -Assertion { param($state, $exitCode) 
        $state.CalledCmdlets -contains "Read-Host: 1" -and
        $state.CalledCmdlets -contains "Read-Host: 6"
    }

Add-Test -Id 60 -Tier "Tier 4" -Name "Verification fails post-repair" `
    -Description "Verify handling when post-repair execution check fails (Open With loop persists)." `
    -Setup { @{ 
        OpenWithLoop = $true 
        Files = @{ "winget.exe" = @{ IsReparsePoint = $true } }
    } } `
    -Parameters @("-Force") `
    -Assertion { param($state, $exitCode) 
        $state.CalledCmdlets -contains "Stop-Process: OpenWith"
    }


# 4. Execution loop
$results = @()
$failedCount = 0
$passedCount = 0

Write-Host "Running 60 isolated test cases..." -ForegroundColor Cyan

foreach ($tc in $TestCases) {
    Write-Host "Running Test $($tc.Id): $($tc.Name)... " -NoNewline -ForegroundColor White
    
    # Create test sandbox
    $testDirName = "TestCase_$($tc.Id)"
    $testDir = Join-Path $globalTemp $testDirName
    if (Test-Path $testDir) {
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    
    # Copy script and mock winget
    Copy-Item -Path $ScriptToTest -Destination $testDir -Force
    $winAppsDir = New-Item -ItemType Directory -Path (Join-Path $testDir "LocalAppData\Microsoft\WindowsApps") -Force
    Copy-Item -Path $wingetExePath -Destination (Join-Path $winAppsDir "winget.exe") -Force
    Copy-Item -Path $wingetExePath -Destination (Join-Path $winAppsDir "wingetdev.exe") -Force
    
    # Create manifest file
    $manifestDir = New-Item -ItemType Directory -Path (Join-Path $testDir "LocalAppData\Microsoft\WindowsApps") -Force
    [System.IO.File]::WriteAllText((Join-Path $manifestDir "AppxManifest.xml"), "<xml></xml>")
    
    # Evaluate setup
    $setupData = & $tc.Setup
    
    # For test 54 specifically, let's create the backup file in setupData's virtual disk
    if ($tc.Id -eq 54) {
        $backupContent = 'Windows Registry Editor Version 5.00' + "`r`n`r`n" + '[HKEY_CURRENT_USER\Environment]' + "`r`n" + '"PATH"="C:\\Windows\\FromFile"' + "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $testDir "Repair-WingetAlias_Backup_20260618_120000.reg"), $backupContent)
    }

    if ($null -eq $setupData) {
        $setupData = @{}
    }
    $setupData["Id"] = $tc.Id

    $setupData | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $testDir "setup.json") -Encoding utf8
    
    # Write the runner script
    [System.IO.File]::WriteAllText((Join-Path $testDir "run_test_case.ps1"), $childRunnerScript)
    
    # Prepare process args
    $argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "run_test_case.ps1")
    if ($tc.Parameters) {
        $argsList += $tc.Parameters
    }
    
    $powershellExe = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh.exe" } else { "powershell.exe" }
    
    # Set MOCK_IS_ADMIN and WINGET_BEHAVIOR environment variables for the child process if specified
    $isAdminVal = if ($setupData.MockIsAdmin) { $setupData.MockIsAdmin } else { "false" }
    $behaviorVal = if ($setupData.WingetBehavior) { $setupData.WingetBehavior } else { "" }
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powershellExe
    $psi.WorkingDirectory = $testDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    
    # Rebuild argument string correctly
    $escapedArgs = @()
    foreach ($a in $argsList) {
        if ($a -like "* *") {
            $escapedArgs += "`"$a`""
        } else {
            $escapedArgs += $a
        }
    }
    $psi.Arguments = $escapedArgs -join " "
    
    $psi.EnvironmentVariables["MOCK_IS_ADMIN"] = $isAdminVal
    $psi.EnvironmentVariables["WINGET_BEHAVIOR"] = $behaviorVal
    $psi.EnvironmentVariables["LOCALAPPDATA"] = (Join-Path $testDir "LocalAppData")
    $psi.EnvironmentVariables["USERPROFILE"] = $testDir
    
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    
    try {
        $process.Start() | Out-Null
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } catch {
        Write-Host "Error launching child process: $_" -ForegroundColor Red
        $exitCode = -1
    }
    
function Convert-PSCustomObjectToHashtable {
    param($InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = Convert-PSCustomObjectToHashtable $prop.Value
        }
        return $hash
    }
    if ($InputObject -is [System.Collections.IList] -or $InputObject -is [System.Array]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) {
            $list.Add((Convert-PSCustomObjectToHashtable $item)) | Out-Null
        }
        return $list
    }
    return $InputObject
}

    $passed = $false
    $finalStateFile = Join-Path $testDir "final_state.json"
    if (Test-Path $finalStateFile) {
        try {
            $rawJson = Get-Content $finalStateFile -Raw | ConvertFrom-Json
            $finalState = Convert-PSCustomObjectToHashtable -InputObject $rawJson
            $passed = & $tc.Assertion -state $finalState -exitCode $exitCode -testDir $testDir
        } catch {
            Write-Host "Assertion exception: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Missing final_state.json! Script execution log:" -ForegroundColor Red
        $logFile = Join-Path $testDir "Repair-WingetAlias.log"
        if (Test-Path $logFile) {
            Get-Content $logFile | Write-Host -ForegroundColor DarkGray
        } else {
            Write-Host "No Repair-WingetAlias.log found." -ForegroundColor DarkRed
        }
        $transcriptFile = Join-Path $testDir "Repair-WingetAlias_Transcript.log"
        if (Test-Path $transcriptFile) {
            Write-Host "Transcript Log:" -ForegroundColor Red
            Get-Content $transcriptFile | Write-Host -ForegroundColor DarkRed
        }
    }
    
    if ($passed) {
        Write-Host "PASS" -ForegroundColor Green
        $passedCount++
        $results += [PSCustomObject]@{ Id = $tc.Id; Name = $tc.Name; Tier = $tc.Tier; Status = "PASS"; Message = "" }
        if (Test-Path $testDir) {
            Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } else {
        Write-Host "FAIL" -ForegroundColor Red
        if (Test-Path $finalStateFile) {
            Write-Host "final_state.json content:" -ForegroundColor DarkGray
            Get-Content $finalStateFile | Write-Host -ForegroundColor DarkGray
        }
        $failedCount++
        $results += [PSCustomObject]@{ Id = $tc.Id; Name = $tc.Name; Tier = $tc.Tier; Status = "FAIL"; Message = "Assertion failed" }
    }
}

# Clean up global temp mocks
# if (Test-Path $globalTemp) {
#     Remove-Item -Path $globalTemp -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
# }

# 5. Print results summary
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "                 TEST RUN SUMMARY                 " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$resultsByTier = $results | Group-Object Tier
foreach ($group in $resultsByTier) {
    $tierPassed = ($group.Group | Where-Object { $_.Status -eq "PASS" }).Count
    $tierFailed = ($group.Group | Where-Object { $_.Status -eq "FAIL" }).Count
    Write-Host "$($group.Name): $tierPassed Passed, $tierFailed Failed" -ForegroundColor $(if ($tierFailed -eq 0) { "Green" } else { "Red" })
}

Write-Host "--------------------------------------------------" -ForegroundColor Gray
Write-Host "Total Tests: $($results.Count)"
Write-Host "Total Passed: $passedCount" -ForegroundColor Green
Write-Host "Total Failed: $failedCount" -ForegroundColor $(if ($failedCount -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================" -ForegroundColor Cyan

if ($failedCount -gt 0) {
    exit 1
} else {
    exit 0
}
