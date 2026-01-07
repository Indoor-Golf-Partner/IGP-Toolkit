

<#
.SYNOPSIS
  Clear TrackMan Performance Studio cache/temp folders and optionally enable/disable clearing at startup.

.DESCRIPTION
  Clears (deletes contents of) the following folders if they exist:
    - C:\ProgramData\Trackman\Trackman Performance Studio\Cache
    - C:\ProgramData\Trackman\Trackman Performance Studio\Temp
    - C:\ProgramData\Trackman\VideoManagement

  Provides a submenu:
    1) Clear TrackMan Cache
    2) Enable/Disable clearing cache at startup (Scheduled Task)

  Startup task name:
    - IGP Clear Trackman Cache

  Startup task action:
    - Runs PowerShell and executes this script with -Mode Startup

.NOTES
  - Requires Administrator privileges.
  - For the scheduled task, Windows Task Scheduler runs a program/script; to run a specific function,
    you typically run PowerShell with a command that dot-sources the script then calls the function,
    or (cleaner) pass a parameter and let the script decide what to run.

  IMPORTANT:
  - This file should be saved with a .ps1 extension in the deployed path.
#>

param(
    [ValidateSet('Interactive','Startup')]
    [string]$Mode = 'Interactive'
)

function Get-ConfirmText {
@"
This will delete TrackMan Performance Studio cache/temp data.

Folders affected:
- C:\ProgramData\Trackman\Trackman Performance Studio\Cache
- C:\ProgramData\Trackman\Trackman Performance Studio\Temp
- C:\ProgramData\Trackman\VideoManagement

Do you want to continue?
"@
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "$ts [$Level] $Message"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TaskName { 'IGP Clear Trackman Cache' }

function Get-ExistingTask {
    $name = Get-TaskName
    try {
        return Get-ScheduledTask -TaskName $name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Clear-FolderContents {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Not found (skip): $Path" 'WARN'
        return
    }

    try {
        $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $items -or $items.Count -eq 0) {
            Write-Log "Already empty: $Path"
            return
        }

        Write-Log "Clearing contents: $Path"
        # Remove everything inside the folder (files and subfolders), but keep the folder.
        $items | Remove-Item -Recurse -Force -ErrorAction Stop
        Write-Log "Cleared: $Path"
    }
    catch {
        Write-Log "Failed to clear '$Path': $($_.Exception.Message)" 'ERROR'
    }
}

function Clear-TrackmanCache {
    $paths = @(
        'C:\ProgramData\Trackman\Trackman Performance Studio\Cache',
        'C:\ProgramData\Trackman\Trackman Performance Studio\Temp',
        'C:\ProgramData\Trackman\VideoManagement'
    )

    foreach ($p in $paths) {
        Clear-FolderContents -Path $p
    }
}

function Register-StartupTask {
    # Resolve the actual script path reliably
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Cannot determine script path (PSCommandPath is empty)."
    }

    $deployedScript = $PSCommandPath

    if (-not (Test-Path -LiteralPath $deployedScript)) {
        Write-Log "Deployed script not found at: $deployedScript" 'ERROR'
        Write-Log "Cannot enable startup clearing until the file exists at that path." 'ERROR'
        return
    }

    $name = Get-TaskName

    # If it exists, remove first (replace)
    $existing = Get-ExistingTask
    if ($existing) {
        try {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        } catch {
            throw "Failed to remove existing task '$name': $($_.Exception.Message)"
        }
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        $psExe = 'powershell.exe'
    }

    # Run the script in Startup mode (non-interactive)
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$deployedScript`" -Mode Startup"

    $action    = New-ScheduledTaskAction -Execute $psExe -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

    Write-Log "Enabling startup cache clearing (task: '$name')..."
    Register-ScheduledTask -TaskName $name -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Log "Startup cache clearing enabled."
}

function Disable-StartupTask {
    $name = Get-TaskName
    $task = Get-ExistingTask
    if (-not $task) {
        Write-Log "Task '$name' does not exist. Nothing to disable." 'WARN'
        return
    }

    Write-Log "Disabling startup cache clearing by deleting task '$name'..." 'WARN'
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    Write-Log "Startup cache clearing disabled (task deleted)."
}

function Show-Status {
    $task = Get-ExistingTask
    if (-not $task) {
        Write-Host "Startup clearing: DISABLED (task not found)" -ForegroundColor Yellow
        return
    }

    Write-Host "Startup clearing: ENABLED" -ForegroundColor Green
    Write-Host "  Task: $(Get-TaskName)"
    Write-Host "  State: $($task.State)"
}

function Show-Menu {
    Write-Host ""
    Write-Host "Clear TrackMan Cache"
    Write-Host "--------------------"
    Write-Host "  1) Clear TrackMan Cache"

    $task = Get-ExistingTask
    if ($task) {
        Write-Host "  2) Disable clearing cache at startup"
    } else {
        Write-Host "  2) Enable clearing cache at startup"
    }

    Write-Host "  3) Show status"
    Write-Host "  Q) Back"
    Write-Host ""

    return (Read-Host 'Select an option')
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    if ($Mode -eq 'Startup') {
        # Non-interactive mode for Scheduled Task
        Clear-TrackmanCache
        return
    }

    while ($true) {
        Clear-Host
        Show-Status
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        switch ($choice) {
            '1' {
                Clear-TrackmanCache
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '2' {
                $task = Get-ExistingTask
                if ($task) {
                    Disable-StartupTask
                } else {
                    Register-StartupTask
                }
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '3' {
                Show-Status
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            default {
                Write-Host 'Invalid selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Only auto-run when executed directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    RunModule
}