<#
.SYNOPSIS
  Startup Options module - central place to enable/disable everything the
  toolkit can run automatically at Windows startup/logon.

.DESCRIPTION
  Lists every startup toggle the toolkit knows about, with live
  Enabled/Disabled status, and lets you flip any of them:
    1) Run IGP Toolkit at Startup        (this file)
    2) Clear Trackman Cache at Startup   (Trackman Storage)
    3) Auto-update Toolkit at Startup    (Update IGP Toolkit)
    4) Write Serial Number at Startup    (Reseller Setup)
    5) TrackMan Autostart                (Windows Settings)
    6) BGInfo Autostart                  (Windows Settings)

  Each toggle's actual scheduled-task logic (what it runs, how it's
  registered/removed) still lives entirely in its own module - this hub
  never duplicates that logic. Instead, for each toggle it dot-sources
  that module's file inside its own isolated scriptblock (the same trick
  Run-IGPToolkit.ps1's Invoke-Module uses) and calls one specific
  Status/Enable/Disable function out of it. Because each dot-source runs
  in its own throwaway scope, modules that all define same-named helpers
  (Write-Log, Test-IsAdmin, etc.) never collide with each other or with
  this hub.

  Run IGP Toolkit at Startup is the one exception with nowhere else to
  live - it points straight at Run-IGPToolkit.ps1 rather than calling
  into a function defined by it, so its own Get-Existing/Enable/Disable
  functions are defined right here instead. Its scheduled task is
  registered with RunLevel Highest for BUILTIN\Administrators - Task
  Scheduler launches tasks like that pre-elevated, so it opens with no
  UAC prompt (unlike a normal double-click launch, which hits
  Run-IGPToolkit.ps1's own Ensure-RunningAsAdmin relaunch-and-prompt
  logic). That only works for accounts that are already local
  Administrators, which every machine this toolkit runs on requires
  anyway.

.NOTES
  Requires Administrator privileges.
#>

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

# $PSScriptRoot here is Modules\Setup, so the toolkit root is two levels up.
$script:ToolkitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ToolkitLauncherPath = Join-Path $script:ToolkitRoot 'Run-IGPToolkit.ps1'

function Get-ToolkitAutostartTaskName {
    return 'IGP-Toolkit-Autostart'
}

function Get-ExistingToolkitAutostartTask {
    Get-ScheduledTask -TaskName (Get-ToolkitAutostartTaskName) -ErrorAction SilentlyContinue
}

function Enable-ToolkitAutostart {
    $name = Get-ToolkitAutostartTaskName
    $existing = Get-ExistingToolkitAutostartTask
    if ($existing) {
        try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop }
        catch { throw "Failed to remove existing task '$name': $($_.Exception.Message)" }
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:ToolkitLauncherPath`""
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

    # AtLogOn with no -User fires for any interactive logon matching the principal
    # below (same pattern as TrackMan/BGInfo Autostart) - here that's members of
    # BUILTIN\Administrators. RunLevel Highest is what lets Task Scheduler launch it
    # already elevated, with no UAC prompt.
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Administrators" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

    Write-Log "Enabling IGP Toolkit autostart at logon..."
    Register-ScheduledTask -TaskName $name -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Log "IGP Toolkit autostart enabled (task: '$name')."
}

function Disable-ToolkitAutostart {
    $name = Get-ToolkitAutostartTaskName
    $existing = Get-ExistingToolkitAutostartTask
    if (-not $existing) {
        Write-Log "IGP Toolkit autostart is already disabled."
        return
    }
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    Write-Log "IGP Toolkit autostart disabled."
}

# Each entry's own module owns its scheduled-task logic; this hub only calls
# into it by name (see Invoke-InModuleScope). "Run IGP Toolkit at Startup" is the
# one exception - it points at this file itself, since Get-ExistingToolkitAutostartTask/
# Enable-ToolkitAutostart/Disable-ToolkitAutostart are defined right above.
$script:StartupToggles = @(
    [pscustomobject]@{
        Title     = 'Run IGP Toolkit at Startup'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Setup\StartupOptions.ps1'
        StatusFn  = 'Get-ExistingToolkitAutostartTask'
        EnableFn  = 'Enable-ToolkitAutostart'
        DisableFn = 'Disable-ToolkitAutostart'
    }
    [pscustomobject]@{
        Title     = 'Clear Trackman Cache at Startup'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Repair\TrackmanStorage.ps1'
        StatusFn  = 'Get-ExistingTask'
        EnableFn  = 'Register-StartupTask'
        DisableFn = 'Disable-StartupTask'
    }
    [pscustomobject]@{
        Title     = 'Auto-update Toolkit at Startup'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Tools\updatetoolkit.ps1'
        StatusFn  = 'Get-ExistingTask'
        EnableFn  = 'Register-StartupTask'
        DisableFn = 'Disable-StartupTask'
    }
    [pscustomobject]@{
        Title     = 'Write Serial Number at Startup'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Setup\Reseller.ps1'
        StatusFn  = 'Get-ExistingSerialTask'
        EnableFn  = 'Register-SerialStartupTask'
        DisableFn = 'Disable-SerialStartupTask'
    }
    [pscustomobject]@{
        Title     = 'TrackMan Autostart'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Setup\WindowsSettings.ps1'
        StatusFn  = 'Get-ExistingTrackManAutostartTask'
        EnableFn  = 'Enable-TrackManAutostart'
        DisableFn = 'Disable-TrackManAutostart'
    }
    [pscustomobject]@{
        Title     = 'BGInfo Autostart'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Setup\WindowsSettings.ps1'
        StatusFn  = 'Get-ExistingBgInfoAutostartTask'
        EnableFn  = 'Enable-BgInfoAutostart'
        DisableFn = 'Disable-BgInfoAutostart'
    }
)

function Invoke-InModuleScope {
    param(
        [Parameter(Mandatory)] [string]$ModulePath,
        [Parameter(Mandatory)] [string]$FunctionName
    )

    if (-not (Test-Path -LiteralPath $ModulePath)) {
        Write-Log "Module not found: $ModulePath" 'ERROR'
        return $null
    }

    # Isolated scope so each module's helpers (Write-Log, Test-IsAdmin, etc.) never
    # leak into this hub or collide with another module's own copies of the same names.
    & {
        param($Path, $Fn)
        . $Path
        & $Fn
    } $ModulePath $FunctionName
}

function Get-ToggleStatus {
    param([Parameter(Mandatory)] $Toggle)

    $task = Invoke-InModuleScope -ModulePath $Toggle.Path -FunctionName $Toggle.StatusFn
    return [bool]$task
}

function Invoke-ToggleAction {
    param([Parameter(Mandatory)] $Toggle)

    $enabled = Get-ToggleStatus -Toggle $Toggle
    $fn = if ($enabled) { $Toggle.DisableFn } else { $Toggle.EnableFn }

    Invoke-InModuleScope -ModulePath $Toggle.Path -FunctionName $fn | Out-Null
}

function Show-Menu {
    Write-Host ""
    Write-Host "Startup Options"
    Write-Host "---------------"
    Write-Host "Lists everything the toolkit can run automatically at Windows startup"
    Write-Host "or logon, and lets you enable or disable each one."
    Write-Host ""

    for ($i = 0; $i -lt $script:StartupToggles.Count; $i++) {
        $t = $script:StartupToggles[$i]
        $num = $i + 1
        $status = if (Get-ToggleStatus -Toggle $t) { 'Enabled' } else { 'Disabled' }
        Write-Host ("  {0}) {1} [{2}]" -f $num, $t.Title, $status)
    }

    Write-Host "  Q) Back"
    Write-Host ""

    return (Read-Host 'Select an option')
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    while ($true) {
        Clear-Host
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $script:StartupToggles.Count) {
            $toggle = $script:StartupToggles[$idx - 1]
            try {
                Invoke-ToggleAction -Toggle $toggle
            }
            catch {
                Write-Log "Failed to toggle '$($toggle.Title)': $($_.Exception.Message)" 'ERROR'
            }
            Read-Host 'Press Enter to continue...' | Out-Null
        }
        else {
            Write-Host 'Invalid selection.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

# Only auto-run when executed directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    RunModule
}
