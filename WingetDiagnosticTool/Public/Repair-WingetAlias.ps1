function Repair-WingetAlias {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSShouldProcess", "")]
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseOutputTypeCorrectly", "")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$Rollback,

        [Parameter(Mandatory = $false)]
        [switch]$DownloadFallback,

        [Parameter(Mandatory = $false)]
        [switch]$ScheduleTask,

        [Parameter(Mandatory = $false)]
        [switch]$AsJob,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [switch]$EventLog,

        [Parameter(Mandatory = $false)]
        [string]$TargetUser
    )

    $script:EventLog = $EventLog
    $script:DownloadFallback = $DownloadFallback

    try {
        if ($DryRun) {
            $WhatIfPreference = $true
        }
        Start-ScriptTranscript

        if ($ScheduleTask) {
            Install-UnattendedTask
            return 0
        }

        if ($AsJob) {
            Write-Output "Spawning repair script as a background PowerShell Job..."

            $jobParams = @{}
            if ($Force) { $jobParams['Force'] = $true }
            if ($Rollback) { $jobParams['Rollback'] = $true }
            if ($DownloadFallback) { $jobParams['DownloadFallback'] = $true }
            if ($ScheduleTask) { $jobParams['ScheduleTask'] = $true }
            if ($DryRun) { $jobParams['DryRun'] = $true }
            if ($EventLog) { $jobParams['EventLog'] = $true }
            if ($WhatIfPreference) { $jobParams['WhatIf'] = $true }
            if ($TargetUser) { $jobParams['TargetUser'] = $TargetUser }

            $job = Start-Job -ScriptBlock {
                Import-Module WingetDiagnosticTool -Force
                Repair-WingetAlias @using:jobParams
            }
            Write-Output "Job started successfully. ID: $($job.Id), Name: $($job.Name)"
            Write-Output "You can check job status using: Get-Job -Id $($job.Id)"
            Write-Output "Retrieve job logs in real time from: $(Join-Path $script:DiagnosticDataDir 'Repair-WingetAlias.log')"
            return 0
        }

        if ($Rollback) {
            Write-Log -Message "Rollback switch detected. Commencing restoration..." -Level "Info"
            $rollbackSuccess = Restore-EnvironmentBackup
            if ($rollbackSuccess) {
                return 3
            } else {
                return 1
            }
        }

        Write-Log -Message "Commencing automatic diagnostics and repairs..." -Level "Info"
        $needsRepair = Run-Diagnostics
        if ($needsRepair) {
            $repairSuccess = Repair-All
            if ($DryRun) {
                return 2
            }
            if ($repairSuccess) {
                return 0
            } else {
                return 1
            }
        } else {
            Write-Log -Message "All checks passed. No repair necessary." -Level "Success"
            if ($DryRun) {
                return 2
            }
            return 0
        }
    } finally {
        Stop-ScriptTranscript
    }
}
