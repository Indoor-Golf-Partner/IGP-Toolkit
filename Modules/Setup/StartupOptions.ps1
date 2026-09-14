<#
.SYNOPSIS
  Startup Options module - central place to enable/disable everything the
  toolkit can run automatically at Windows startup/logon.

.DESCRIPTION
  Lists every startup toggle the toolkit knows about, with live
  Enabled/Disabled status, and lets you flip any of them:
    1) Clear Trackman Cache at Startup   (Trackman Storage)
    2) Auto-update Toolkit at Startup    (Update IGP Toolkit)
    3) Write Serial Number at Startup    (Reseller Setup)
    4) TrackMan Autostart                (Windows Settings)
    5) BGInfo Autostart                  (Windows Settings)

  Each toggle's actual scheduled-task logic (what it runs, how it's
  registered/removed) still lives entirely in its own module - this hub
  never duplicates that logic. Instead, for each toggle it dot-sources
  that module's file inside its own isolated scriptblock (the same trick
  Run-IGPToolkit.ps1's Invoke-Module uses) and calls one specific
  Status/Enable/Disable function out of it. Because each dot-source runs
  in its own throwaway scope, modules that all define same-named helpers
  (Write-Log, Test-IsAdmin, etc.) never collide with each other or with
  this hub.

.NOTES
  Requires Administrator privileges.
#>

function Get-ConfirmText {
@"
Startup Options

This lists everything the toolkit can run automatically at Windows startup
or logon, and lets you enable or disable each one.

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

# $PSScriptRoot here is Modules\Setup, so the toolkit root is two levels up.
$script:ToolkitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Each entry's own module owns its scheduled-task logic; this hub only calls
# into it by name (see Invoke-InModuleScope).
$script:StartupToggles = @(
    [pscustomobject]@{
        Title     = 'Clear Trackman Cache at Startup'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Repair\TrackmanStorage.ps1'
        StatusFn  = 'Get-ExistingTask'
        EnableFn  = 'Register-StartupTask'
        DisableFn = 'Disable-StartupTask'
    }
    [pscustomobject]@{
        Title     = 'Auto-update Toolkit at Startup'
        Path      = Join-Path $script:ToolkitRoot 'Modules\Toolkit\updatetoolkit.ps1'
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
