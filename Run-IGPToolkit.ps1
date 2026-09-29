# Resolve script folder reliably
$ScriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    throw "Cannot determine script path. Run this as a file: powershell -File <path>\Run-IGPToolkit.ps1"
}
$ToolkitRoot = Split-Path -Parent $ScriptPath
$ToolkitVersion = '2.0.0'

function Show-ToolkitBanner {
    $title = "IGP TOOLKIT"
    $versionText = "v$ToolkitVersion"
    $innerWidth = [Math]::Max($title.Length, $versionText.Length) + 8

    function Get-CenteredLine([string]$Text, [int]$Width) {
        $padTotal = [Math]::Max(0, $Width - $Text.Length)
        $padLeft  = [Math]::Floor($padTotal / 2)
        $padRight = $padTotal - $padLeft
        return (' ' * $padLeft) + $Text + (' ' * $padRight)
    }

    Write-Host ""
    Write-Host ("=" * ($innerWidth + 2)) -ForegroundColor Cyan
    Write-Host "|" -ForegroundColor Cyan -NoNewline
    Write-Host (Get-CenteredLine $title $innerWidth) -ForegroundColor White -NoNewline
    Write-Host "|" -ForegroundColor Cyan
    Write-Host "|" -ForegroundColor Cyan -NoNewline
    Write-Host (Get-CenteredLine $versionText $innerWidth) -ForegroundColor DarkGray -NoNewline
    Write-Host "|" -ForegroundColor Cyan
    Write-Host ("=" * ($innerWidth + 2)) -ForegroundColor Cyan
    Write-Host ""
}

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

# Fixed display order for menu categories (anything not listed falls back to
# alphabetical, after these).
$CategoryOrder = @('Repair', 'Operation', 'Setup', 'Toolkit')

# Fixed display order for items within a category, by Title (anything not listed
# falls back to alphabetical, after these). Only Setup needs one so far; other
# categories just fall through to alphabetical unaffected.
$TitleOrder = @(
    'Machine Identity',
    'Reseller Setup',
    'Windows Settings',
    'Debloater',
    'Startup Options',
    'Overview'
)

# Manual registry
$ModuleRegistry = @(
    @{
        Path  = "Modules\Repair\TrackmanStorage.ps1"
        Title = "Trackman Storage"
    },
    @{
        Path  = "Modules\Repair\ResetTouchScreen.ps1"
        Title = "Reset Touch Screen Calibration"
    },
    @{
        Path  = "Modules\Repair\RepairWindowsImage.ps1"
        Title = "Repair Windows System Files (DISM + SFC)"
    },
    @{
        Path  = "Modules\Operation\autoshutdown.ps1"
        Title = "Manage automatic shutdown"
    },
    @{
        Path  = "Modules\Setup\WindowsSettings.ps1"
        Title = "Windows Settings"
    },
    @{
        Path  = "Modules\Setup\Reseller.ps1"
        Title = "Reseller Setup"
    },
    @{
        Path  = "Modules\Setup\MachineIdentity.ps1"
        Title = "Machine Identity"
    },
    @{
        Path  = "Modules\Setup\StartupOptions.ps1"
        Title = "Startup Options"
    },
    @{
        Path  = "Modules\Setup\debloater.ps1"
        Title = "Debloater"
    },
    @{
        Path  = "Modules\Setup\Overview.ps1"
        Title = "Overview"
    },
    @{
        Path  = "Modules\Toolkit\updatetoolkit.ps1"
        Title = "Update IGP Toolkit"
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
    Show-ToolkitBanner
    Write-Host "Root: $ToolkitRoot"
    Write-Host ""

    $map = @{}
    $i = 1

    # Group-Object always re-sorts its output groups alphabetically by key, regardless
    # of upstream Sort-Object order - so the category display order is built explicitly
    # here instead of relying on Group-Object's own ordering.
    $categoryRank = {
        $idx = $CategoryOrder.IndexOf($_)
        if ($idx -ge 0) { $idx } else { [int]::MaxValue }
    }
    $orderedCategories = $items.Category | Select-Object -Unique | Sort-Object $categoryRank, { $_ }

    $titleRank = {
        $idx = $TitleOrder.IndexOf($_.Title)
        if ($idx -ge 0) { $idx } else { [int]::MaxValue }
    }

    foreach ($catName in $orderedCategories) {
        Write-Host "--- $catName ---"
        $group = $items | Where-Object { $_.Category -eq $catName } | Sort-Object $titleRank, Title
        foreach ($it in $group) {
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
