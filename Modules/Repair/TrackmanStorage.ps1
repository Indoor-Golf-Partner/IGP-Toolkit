<#
.SYNOPSIS
  Trackman Storage module - clear TrackMan cache or reset stored settings
  (mirrors Android's per-app "Storage" screen: Clear Cache vs Clear Storage).

.DESCRIPTION
  Provides a submenu:
    1) Clear Cache
    2) Clear Storage

  Clear Cache:
  - Clears (deletes contents of) cache/temp folders:
      C:\ProgramData\Trackman\Trackman Performance Studio\Cache
      C:\ProgramData\Trackman\Trackman Performance Studio\Temp
      C:\ProgramData\Trackman\VideoManagement
  - Safe, non-destructive; no re-login needed afterwards.

  Clear Storage:
  - Deletes TrackMan's per-user settings folders (LOCALAPPDATA, APPDATA,
    LocalLow) and C:\ProgramData\Trackman\DeviceId.txt.
  - Destructive - requires logging back into TrackMan afterwards. Prompts
    for an explicit confirmation before running.

  Enabling/disabling automatic cache clearing at startup (Scheduled Task
  "IGP Clear Trackman Cache") is managed from the toolkit's Startup Options
  module - the Register-StartupTask/Disable-StartupTask/Get-ExistingTask
  functions below still live here since Startup Options calls into them
  directly rather than duplicating the logic.

.NOTES
  Requires Administrator privileges.
#>

param(
    [ValidateSet('Interactive','Startup')]
    [string]$Mode = 'Interactive'
)

function Get-ConfirmText {
@"
Trackman Storage

This module can:
- Clear Cache: delete TrackMan Performance Studio cache/temp data (safe).
- Clear Storage: delete TrackMan's stored settings and device ID (destructive
  - you will need to log in again).

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

function Confirm-Action([string]$Message) {
    Write-Host ""
    Write-Host $Message
    Write-Host ""
    $answer = Read-Host "Continue (y/N)"
    return ($answer -match '^(y|yes)$')
}

#region Clear Cache
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
#endregion Clear Cache

#region Clear Storage
function Get-TrackManPathsForCurrentUser {
    $local    = Join-Path $env:LOCALAPPDATA "TrackMan"
    $roaming  = Join-Path $env:APPDATA "TrackMan"
    $localLow = Join-Path $env:USERPROFILE "AppData\LocalLow\TrackMan"
    return @($local, $localLow, $roaming)
}

function Remove-FolderIfExists {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Not found (skip): $Path"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log "Deleted folder: $Path"
    }
    catch {
        Write-Log "Failed to delete folder '$Path': $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-FileIfExists {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Not found (skip): $Path"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Log "Deleted file: $Path"
    }
    catch {
        Write-Log "Failed to delete file '$Path': $($_.Exception.Message)" 'ERROR'
    }
}

function Clear-TrackmanStorage {
    foreach ($p in (Get-TrackManPathsForCurrentUser)) {
        Remove-FolderIfExists -Path $p
    }

    Remove-FileIfExists -Path "C:\ProgramData\Trackman\DeviceId.txt"
}
#endregion Clear Storage

#region Startup task (cache clearing) - called directly by Startup Options
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

function Register-StartupTask {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Cannot determine script path (PSCommandPath is empty)."
    }

    $deployedScript = $PSCommandPath
    $name = Get-TaskName

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
#endregion Startup task

function Show-Menu {
    Write-Host ""
    Write-Host "Trackman Storage"
    Write-Host "----------------"
    Write-Host "  1) Clear Cache"
    Write-Host "  2) Clear Storage"
    Write-Host "  Q) Back"
    Write-Host ""

    return (Read-Host 'Select an option')
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    if ($Mode -eq 'Startup') {
        # Non-interactive mode for Scheduled Task - cache clearing only
        Clear-TrackmanCache
        return
    }

    while ($true) {
        Clear-Host
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        switch ($choice) {
            '1' {
                Clear-TrackmanCache
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '2' {
                if (Confirm-Action "This will delete all TrackMan settings and the device ID for the current user. You will need to log in again. Make sure TrackMan Performance Studio is closed.") {
                    Clear-TrackmanStorage
                } else {
                    Write-Log "Cancelled." 'WARN'
                }
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
