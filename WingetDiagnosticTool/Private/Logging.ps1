# Handles module-wide logging and transcript capabilities

function Rotate-LogFile {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs", "")]
    param(
        [string]$Path,
        [string]$BackupPath
    )
    if (Test-Path $Path) {
        $file = Get-Item $Path
        if ($file.Length -gt 1MB) {
            try {
                Copy-Item -Path $Path -Destination $BackupPath -Force -ErrorAction Stop
                Clear-Content -Path $Path -ErrorAction Stop
            } catch {
                $null = $_
            }
        }
    }
}

function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSAvoidUsingWriteHost", "")]
    param(
        [string]$Message,
        [string]$Level = "Info"
    )

    if (-not (Test-Path $script:DiagnosticDataDir)) {
        New-Item -ItemType Directory -Path $script:DiagnosticDataDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    $logPath = Join-Path $script:DiagnosticDataDir "Repair-WingetAlias.log"
    $backupPath = Join-Path $script:DiagnosticDataDir "Repair-WingetAlias.bak"
    Rotate-LogFile -Path $logPath -BackupPath $backupPath

    try {
        Add-Content -Path $logPath -Value $logLine -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    }

    if ($EventLog) {
        $eventType = "Information"
        $eventId = 1001
        switch ($Level) {
            "Error" { $eventType = "Error"; $eventId = 1003 }
            "Warning" { $eventType = "Warning"; $eventId = 1002 }
            "Success" { $eventType = "Information"; $eventId = 1000 }
        }
        try {
            Write-EventLog -LogName Application -Source "WingetDiagnosticTool" -EventId $eventId -EntryType $eventType -Message $Message -ErrorAction SilentlyContinue
        } catch {
            $null = $_
        }
    }

    # Write to terminal host
    $color = "Gray"
    switch ($Level) {
        "Error" { $color = "Red" }
        "Warning" { $color = "Yellow" }
        "Success" { $color = "Green" }
        "Info" { $color = "White" }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Start-ScriptTranscript {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseShouldProcessForStateChangingFunctions", "")]
    param()

    if (-not (Test-Path $script:DiagnosticDataDir)) {
        New-Item -ItemType Directory -Path $script:DiagnosticDataDir -Force | Out-Null
    }

    $transcriptPath = Join-Path $script:DiagnosticDataDir "Repair-WingetAlias_Transcript.log"
    $transcriptBak = Join-Path $script:DiagnosticDataDir "Repair-WingetAlias_Transcript.bak"
    Rotate-LogFile -Path $transcriptPath -BackupPath $transcriptBak

    Write-Log -Message "Starting transcript logging to: $transcriptPath" -Level "Info"
    try {
        Start-Transcript -Path $transcriptPath -Append -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Log -Message "Failed to start transcript logging: $_" -Level "Warning"
    }
}

function Stop-ScriptTranscript {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseShouldProcessForStateChangingFunctions", "")]
    param()

    try {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    } catch {
        $null = $_
    }
}
