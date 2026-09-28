@{
    ModuleVersion = '2.1.0'
    GUID = 'd2e2faef-410d-4a11-828b-e85d414a7906'
    Author = 'Albert Edward Jukes III'
    CompanyName = 'aj1126'
    Copyright = '(c) 2026. All rights reserved.'
    Description = 'A robust diagnostic and remediation engine designed to resolve winget execution loop issues.'
    PowerShellVersion = '5.1'
    RootModule = 'WingetDiagnosticTool.psm1'
    FunctionsToExport = @(
        'Repair-WingetAlias',
        'Invoke-WingetDiagnosticMenu',
        'Repair-AppExecutionAlias',
        'Repair-AliasStub',
        'Repair-EnvironmentPath',
        'Repair-AppXInstallerPackage',
        'Repair-ShadowingFiles',
        'Restore-EnvironmentBackup',
        'Run-Diagnostics'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @(
        'Repair-AppExecutionAliases',
        'Repair-AliasStubs'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('winget', 'diagnostic', 'alias', 'sysadmin', 'repair')
            ProjectUri = 'https://github.com/aj1126/Winget-Diagnostic-Tool'
        }
    }
}
