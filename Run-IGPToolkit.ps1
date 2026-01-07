# Resolve script folder reliably
$ScriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    throw "Cannot determine script path. Run this as a file: powershell -File <path>\Run-IGPToolkit.ps1"
}
$ToolkitRoot = Split-Path -Parent $ScriptPath

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-RunningAsAdmin {
    param([string]$LauncherPath)

    if (Test-IsAdmin) { return }

    Write-Host "Not running as administrator. Relaunching elevated..." -ForegroundColor Yellow

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$LauncherPath`""
    ) -join " "

    Start-Process powershell.exe -Verb RunAs -ArgumentList $args
    exit
}

Ensure-RunningAsAdmin -LauncherPath $ScriptPath

function Pause-IfNeeded {
    Write-Host ""
    Read-Host "Press Enter to continue..."
}

function Confirm-ModuleExecution([string]$Message) {
    Write-Host ""
    Write-Host $Message
    Write-Host ""
    $answer = Read-Host "Continue (y/N)"
    return ($answer -match '^(y|yes)$')
}

function Invoke-Module {
    param([Parameter(Mandatory)][string]$ModulePath)

    if (-not (Test-Path -LiteralPath $ModulePath)) {
        Write-Host "Module not found: $ModulePath" -ForegroundColor Red
        return
    }

    # Run in an isolated scope so functions don't leak between modules
    & {
        param($Path)

        . $Path

        $confirmCmd = Get-Command Get-ConfirmText -ErrorAction SilentlyContinue
        if ($confirmCmd) {
            $msg = Get-ConfirmText
            if ($msg -and -not (Confirm-ModuleExecution $msg)) { return }
        }

        $runCmd = Get-Command RunModule -ErrorAction SilentlyContinue
        if (-not $runCmd) { throw "Module '$Path' does not define RunModule." }

        RunModule
    } $ModulePath
}

# Manual registry
$ModuleRegistry = @(
    @{
        Path  = "Modules\Trackman\ResetTrackManSettings.ps1"
        Title = "Reset TrackMan Settings"
    },
    @{
        Path  = "Modules\Windows\ResetTouchScreen.ps1"
        Title = "Reset Touch Screen Calibration"
    }, 
    @{
        Path  = "Modules\Windows\RepairWindowsImage.ps1"
        Title = "Repair Windows System Files (DISM + SFC)"
    }, 
    #@{
    #    Path  = "Modules\Operation\autoshutdown.ps1"
    #    Title = "Manage automatic shutdown"
    #}
    @{
        Path  = "Modules\Trackman\ClearTrackmanCache.ps1"
        Title = "Clear Trackman Cache"
    }
)


# Build items
$items = foreach ($m in $ModuleRegistry) {
    $rel = ([string]$m.Path).Trim()
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }

    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($ToolkitRoot, $rel))
    $parts = $rel -split '[\\/]' | Where-Object { $_ }
    $cat = if ($parts.Count -ge 2 -and $parts[0] -eq "Modules") { $parts[1] } else { "General" }

    [pscustomobject]@{ Category=$cat; Title=$m.Title; FullPath=$full }
}

while ($true) {
    Clear-Host
    Write-Host "IGP Toolkit Menu"
    Write-Host "Root: $ToolkitRoot"
    Write-Host ""

    $map = @{}
    $i = 1

    foreach ($g in ($items | Sort-Object Category, Title | Group-Object Category)) {
        Write-Host "--- $($g.Name) ---"
        foreach ($it in $g.Group) {
            Write-Host ("{0,2}) {1}" -f $i, $it.Title)
            $map["$i"] = $it.FullPath
            $i++
        }
        Write-Host ""
    }

    Write-Host "Q) Quit"
    $c = Read-Host "Select"
    if ($c -match '^(?i)q$') { break }

    if ($map.ContainsKey($c)) {
        Invoke-Module -ModulePath $map[$c]
        Pause-IfNeeded
    }
    else {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        Pause-IfNeeded
    }
}
