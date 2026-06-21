# WingetDiagnosticTool.psm1
# Root module file that dynamically loads public and private functions.

$ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ModuleRoot)) {
    $ModuleRoot = $PSScriptRoot
}

# Define centralized script-level variables
$script:DiagnosticDataDir = Join-Path $env:LOCALAPPDATA "WingetDiagnosticTool"
if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
    $script:DiagnosticDataDir = Join-Path $env:TEMP "WingetDiagnosticTool"
}

# Load Private functions first (helpers and logging)
$PrivateScripts = Get-ChildItem -Path (Join-Path $ModuleRoot "Private") -Filter "*.ps1" -ErrorAction SilentlyContinue
foreach ($script in $PrivateScripts) {
    . $script.FullName
}

# Load Public functions next
$PublicScripts = Get-ChildItem -Path (Join-Path $ModuleRoot "Public") -Filter "*.ps1" -ErrorAction SilentlyContinue
foreach ($script in $PublicScripts) {
    . $script.FullName
}
