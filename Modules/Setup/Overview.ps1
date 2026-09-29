<#
.SYNOPSIS
  Overview module - shows Confirmed/Missing/Info status for every checkable
  setting the toolkit knows about.

.DESCRIPTION
  Read-only report. For each module listed in $script:OverviewModulePaths,
  dot-sources it in an isolated scriptblock (the same technique
  Startup Options uses) and calls its Get-Status function, which always
  returns an array of objects shaped like:

    { Title; Status; Detail }

  Status is one of:
    Confirmed - the setting is applied/present
    Missing   - the setting is not applied/present
    Info      - not a right/wrong check, Detail is just the current value
                (e.g. Account Name, Computer Name)

  Adding a new checkable item to an existing module, or a whole new module,
  needs no change here - just add/extend that module's own Get-Status.
  Debloater is intentionally not included: it has no per-item removal
  tracking, so there's nothing reliable to report without re-verifying
  every single app/service it touches.

.NOTES
  Requires Administrator privileges (several of the underlying checks do).
  The NVIDIA Settings row (via Windows Settings' Get-Status) actually
  re-runs NVIDIA Profile Inspector's -exportCustomized each time this page
  loads, so this report may take a few seconds longer than a typical menu.
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

# Every module listed here must define its own Get-Status function, returning an
# array of { Title; Status; Detail } objects (Status: 'Confirmed' | 'Missing' | 'Info').
$script:OverviewModulePaths = @(
    'Modules\Setup\WindowsSettings.ps1'
    'Modules\Setup\Reseller.ps1'
    'Modules\Setup\MachineIdentity.ps1'
    'Modules\Repair\TrackmanStorage.ps1'
    'Modules\Tools\updatetoolkit.ps1'
    'Modules\Tools\CreateRestoreUsb.ps1'
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
        if (Get-Command $Fn -ErrorAction SilentlyContinue) {
            & $Fn
        }
    } $ModulePath $FunctionName
}

function Get-AllStatusRows {
    $rows = @()

    foreach ($rel in $script:OverviewModulePaths) {
        $fullPath = Join-Path $script:ToolkitRoot $rel
        try {
            $result = Invoke-InModuleScope -ModulePath $fullPath -FunctionName 'Get-Status'
            if ($result) { $rows += $result }
        }
        catch {
            Write-Log "Failed to get status from '$rel': $($_.Exception.Message)" 'ERROR'
        }
    }

    return $rows
}

function Format-StatusTag {
    param([Parameter(Mandatory)] [string]$Status)

    switch ($Status) {
        'Confirmed' { return '[Confirmed]' }
        'Missing'   { return '[Missing]' }
        'Info'      { return '[Info]' }
        default     { return "[$Status]" }
    }
}

function Show-Overview {
    Write-Host ""
    Write-Host "Setup Overview"
    Write-Host "--------------"
    Write-Host "Confirmed/Missing status (or current value, for informational items)"
    Write-Host "for every checkable setting under Setup."
    Write-Host ""

    $rows = Get-AllStatusRows
    if ($rows.Count -eq 0) {
        Write-Host "No status information available." -ForegroundColor Yellow
        return
    }

    foreach ($row in $rows) {
        $tag = Format-StatusTag -Status $row.Status
        $color = switch ($row.Status) {
            'Confirmed' { 'Green' }
            'Missing'   { 'Yellow' }
            'Info'      { 'Cyan' }
            default     { 'White' }
        }

        $line = "{0,-12} {1}" -f $tag, $row.Title
        if ($row.Detail) { $line += " - $($row.Detail)" }

        Write-Host $line -ForegroundColor $color
    }
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    Clear-Host
    Show-Overview
    Write-Host ""
    Read-Host 'Press Enter to continue...' | Out-Null
}

# Only auto-run when executed directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    RunModule
}
