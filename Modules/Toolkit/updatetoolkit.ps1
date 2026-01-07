<#
.SYNOPSIS
  Update the IGP-Toolkit from GitHub (manual or at startup).

.DESCRIPTION
  This module replaces the older GitPullIGP-Tools.ps1 functionality.

  It supports two modes:
    - Interactive (default): shows a submenu in the toolkit.
    - Startup: intended for Task Scheduler; performs update without prompts.

  Features:
    1) Update toolkit now (git clone/fetch + hard reset to origin/<branch>)
    2) Enable/Disable auto update via Scheduled Task "IGP Pull IGP Tools" (AtStartup)

.NOTES
  - Requires Administrator privileges (launcher runs elevated).
  - The scheduled task runs as SYSTEM.
  - Task Scheduler cannot call a PowerShell function directly; it runs a script.
    We pass -Mode Startup so this script knows what to do.
#>

param(
    [ValidateSet('Interactive','Startup')]
    [string]$Mode = 'Interactive',

    [string]$RepoUrl   = 'https://github.com/Indoor-Golf-Partner/IGP-Toolkit.git',
    [string]$Branch    = 'main',

    # Default install location used by your other tooling
    [string]$TargetDir = 'C:\Utilities\Indoor Golf Partner\IGP-Toolkit'
)

function Get-ConfirmText {
@"
This will update the IGP Toolkit from GitHub.

- Local changes in the toolkit folder may be overwritten.
- If the computer is offline, the update will be skipped.

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

function Assert-GitAvailable {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git.exe not found. Install Git for Windows and ensure it is in PATH.'
    }
}

function Test-Online {
    try {
        return Test-NetConnection -ComputerName 'github.com' -Port 443 -InformationLevel Quiet
    }
    catch {
        return $false
    }
}

function Get-TaskName { 'IGP Pull IGP Tools' }

function Get-ExistingTask {
    $name = Get-TaskName
    try {
        return Get-ScheduledTask -TaskName $name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Show-Status {
    $task = Get-ExistingTask
    if ($task) {
        Write-Host "Auto update: ENABLED" -ForegroundColor Green
        Write-Host "  Task:  $(Get-TaskName)"
        Write-Host "  State: $($task.State)"
    }
    else {
        Write-Host "Auto update: DISABLED" -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath (Join-Path $TargetDir '.git')) {
        try {
            $hash = (& git -C $TargetDir rev-parse --short HEAD 2>$null).Trim()
            $br   = (& git -C $TargetDir rev-parse --abbrev-ref HEAD 2>$null).Trim()
            if ($hash) {
                Write-Host "Toolkit repo: $TargetDir" -ForegroundColor Cyan
                Write-Host "  Branch: $br"
                Write-Host "  Commit: $hash"
            }
        }
        catch {
            # ignore
        }
    }
}

function Add-GitSafeDirectory {
    param([Parameter(Mandatory)][string]$Path)

    # Git can block repositories with 'dubious ownership' when running under SYSTEM.
    # Adding a safe.directory avoids failures.
    try {
        & git config --global --add safe.directory "$Path" 2>$null | Out-Null
    }
    catch {
        # ignore if this fails; update may still work depending on git version/config
    }
}

function Update-ToolkitRepo {
    # In startup mode, skip quickly if offline
    if (-not (Test-Online)) {
        Write-Log 'Offline or GitHub unreachable. Skipping toolkit update.' 'WARN'
        return 0
    }

    Assert-GitAvailable

    $parent = Split-Path -Parent $TargetDir
    if (-not (Test-Path -LiteralPath $parent)) {
        Write-Log "Creating parent directory: $parent"
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        Write-Log "Creating target directory: $TargetDir"
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    $gitDir = Join-Path $TargetDir '.git'

    # Avoid interactive prompts in unattended context
    $env:GIT_TERMINAL_PROMPT = '0'

    Add-GitSafeDirectory -Path $TargetDir

    if (-not (Test-Path -LiteralPath $gitDir)) {
        # If folder exists but is not empty, cloning is risky
        if ((Get-ChildItem -Force -LiteralPath $TargetDir | Measure-Object).Count -gt 0) {
            throw "Target directory exists but is not a git repository and is not empty: $TargetDir"
        }

        Write-Log 'Cloning toolkit repository...'
        & git clone --branch $Branch --single-branch $RepoUrl $TargetDir
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "git clone failed with exit code $code" }

        Write-Log 'Clone completed.'
        return 0
    }

    Write-Log 'Repository exists. Fetching updates...'
    & git -C $TargetDir fetch --prune origin
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "git fetch failed with exit code $code" }

    & git -C $TargetDir reset --hard ("origin/" + $Branch)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "git reset failed with exit code $code" }

    # Optional: remove untracked files to keep installs consistent
    & git -C $TargetDir clean -fd

    Write-Log 'Update completed.'
    return 0
}

function Register-StartupTask {
    # Resolve the actual deployed script path
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Cannot determine script path (PSCommandPath is empty).'
    }

    $scriptPath = $PSCommandPath
    $name = Get-TaskName

    # Replace existing task
    $existing = Get-ExistingTask
    if ($existing) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        $psExe = 'powershell.exe'
    }

    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Startup"

    $action    = New-ScheduledTaskAction -Execute $psExe -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

    Write-Log "Enabling auto update at startup (task: '$name')..."
    Register-ScheduledTask -TaskName $name -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Log 'Auto update enabled.'
}

function Disable-StartupTask {
    $name = Get-TaskName
    $task = Get-ExistingTask
    if (-not $task) {
        Write-Log "Task '$name' does not exist. Nothing to disable." 'WARN'
        return
    }

    Write-Log "Disabling auto update by deleting task '$name'..." 'WARN'
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    Write-Log 'Auto update disabled (task deleted).'
}

function Show-Menu {
    Write-Host ""
    Write-Host 'Update Toolkit'
    Write-Host '--------------'
    Write-Host '  1) Update toolkit now'

    $task = Get-ExistingTask
    if ($task) {
        Write-Host '  2) Disable auto update at startup'
    }
    else {
        Write-Host '  2) Enable auto update at startup'
    }

    Write-Host '  3) Show status'
    Write-Host '  Q) Back'
    Write-Host ""
    return (Read-Host 'Select an option')
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    if ($Mode -eq 'Startup') {
        # Unattended mode for Task Scheduler
        try {
            Update-ToolkitRepo | Out-Null
        }
        catch {
            # In startup mode, avoid hard failures that make Task Scheduler look scary.
            Write-Log "Startup update failed: $($_.Exception.Message)" 'WARN'
        }
        return
    }

    while ($true) {
        Clear-Host
        Show-Status
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        switch ($choice) {
            '1' {
                try {
                    Update-ToolkitRepo | Out-Null
                }
                catch {
                    Write-Log "Update failed: $($_.Exception.Message)" 'ERROR'
                }
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '2' {
                try {
                    $task = Get-ExistingTask
                    if ($task) { Disable-StartupTask } else { Register-StartupTask }
                }
                catch {
                    Write-Log "Task operation failed: $($_.Exception.Message)" 'ERROR'
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

# Only auto-run when executed directly (e.g., Task Scheduler), not when dot-sourced by the launcher
if ($MyInvocation.InvocationName -ne '.') {
    RunModule
}