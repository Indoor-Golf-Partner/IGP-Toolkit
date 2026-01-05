<#
.SYNOPSIS
  Configure or disable an automatic shutdown scheduled task.

.DESCRIPTION
  Uses a Windows Scheduled Task named "IGP Shut Down".

  Options:
  1) Set/replace shutdown time:
     - Creates or replaces the task to run daily at a chosen time (HH:mm)
     - Task runs as SYSTEM with highest privileges
     - Executes: shutdown.exe /s /f /t 0

  2) Disable Auto Shut Down:
     - If task exists, disables it (does not delete)

.NOTES
  - Requires Administrator privileges (launcher handles elevation).
  - Time format: 24h, e.g. 22:30
#>

function Get-ConfirmText {
@"
This module manages an automatic shutdown task ("IGP Shut Down").

- Setting a time will create or replace a daily scheduled task that shuts down the PC.
- Disabling will disable the task if it exists.

Do you want to continue?
"@
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$ts [$Level] $Message"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TaskName { "IGP Shut Down" }

function Get-ExistingTask {
    $name = Get-TaskName
    try {
        return Get-ScheduledTask -TaskName $name -ErrorAction Stop
    } catch {
        return $null
    }
}

function Show-TaskStatus {
    $task = Get-ExistingTask
    if (-not $task) {
        Write-Host "Task: $(Get-TaskName)  -> NOT FOUND" -ForegroundColor Yellow
        return
    }

    Write-Host "Task: $(Get-TaskName)" -ForegroundColor Cyan
    Write-Host "  Enabled: $($task.Settings.Enabled)"
    Write-Host "  State:   $($task.State)"

    if ($task.Triggers.Count -gt 0) {
        Write-Host "  Trigger(s):"
        foreach ($t in $task.Triggers) {
            if ($t.StartBoundary) {
                Write-Host "    - $($t.StartBoundary)"
            }
        }
    } else {
        Write-Host "  Trigger(s): (none found)"
    }
}

function Read-TimeHHmm {
    while ($true) {
        $input = Read-Host "Enter shutdown time (HH:mm), e.g. 22:30"
        if ([string]::IsNullOrWhiteSpace($input)) {
            Write-Host "No time entered. Cancelled." -ForegroundColor Yellow
            return $null
        }

        if ($input -match '^(?:[01]\d|2[0-3]):[0-5]\d$') {
            return $input
        }

        Write-Host "Invalid time. Use 24h HH:mm (e.g. 07:15 or 22:30)." -ForegroundColor Yellow
    }
}

function Create-OrReplaceShutdownTask {
    param(
        [Parameter(Mandatory)] [string]$TimeHHmm
    )

    $name = Get-TaskName

    $existing = Get-ExistingTask
    if ($existing) {
        Write-Log "Existing task found. Removing to replace..." "WARN"
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    }

    $shutdownExe = Join-Path $env:SystemRoot "System32\shutdown.exe"
    if (-not (Test-Path -LiteralPath $shutdownExe)) {
        throw "shutdown.exe not found: $shutdownExe"
    }

    $at = [DateTime]::ParseExact($TimeHHmm, "HH:mm", $null)
    $trigger = New-ScheduledTaskTrigger -Daily -At $at.TimeOfDay

    $action  = New-ScheduledTaskAction -Execute $shutdownExe -Argument "/s /f /t 0"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet \
        -AllowStartIfOnBatteries \
        -DontStopIfGoingOnBatteries \
        -StartWhenAvailable \
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

    Write-Log "Registering task '$name' to shut down daily at $TimeHHmm..."
    Register-ScheduledTask -TaskName $name -InputObject $task -Force -ErrorAction Stop | Out-Null

    Write-Log "Task created successfully."
}

function Disable-ShutdownTaskIfExists {
    $name = Get-TaskName
    $task = Get-ExistingTask
    if (-not $task) {
        Write-Log "Task '$name' does not exist. Nothing to disable." "WARN"
        return
    }

    Disable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
    Write-Log "Task '$name' disabled."
}

function Show-Menu {
    Write-Host ""
    Write-Host "Auto Shut Down"
    Write-Host "--------------"
    Write-Host "  1) Set/Replace shutdown time (creates daily task)"
    Write-Host "  2) Disable Auto Shut Down (disables task if it exists)"
    Write-Host "  3) Show current status"
    Write-Host "  Q) Back"
    Write-Host ""
    return (Read-Host "Select an option")
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw "Administrator privileges are required. Run the toolkit elevated."
    }

    while ($true) {
        Clear-Host
        Show-TaskStatus
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        switch ($choice) {
            '1' {
                $t = Read-TimeHHmm
                if ($null -ne $t) {
                    Create-OrReplaceShutdownTask -TimeHHmm $t
                }
                Read-Host "Press Enter to continue..." | Out-Null
            }
            '2' {
                Disable-ShutdownTaskIfExists
                Read-Host "Press Enter to continue..." | Out-Null
            }
            '3' {
                Show-TaskStatus
                Read-Host "Press Enter to continue..." | Out-Null
            }
            default {
                Write-Host "Invalid selection." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}
