[CmdletBinding()]
param(
    # Where the toolkit is expected to live (must match your updater defaults)
    [string]$ToolkitDir = 'C:\Utilities\Indoor Golf Partner\IGP-Toolkit',

    # Start menu scope: AllUsers (ProgramData) or CurrentUser (AppData)
    [ValidateSet('AllUsers','CurrentUser')]
    [string]$StartMenuScope = 'AllUsers'
)

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

function New-StartMenuShortcut {
    param(
        [Parameter(Mandatory)] [string]$ToolkitDir,
        [Parameter(Mandatory)] [ValidateSet('AllUsers','CurrentUser')] [string]$Scope
    )

    $cmdPath = Join-Path $ToolkitDir 'IGP-toolkit.cmd'
    if (-not (Test-Path -LiteralPath $cmdPath)) {
        throw "Cannot create shortcut because cmd file was not found: $cmdPath"
    }

    $programsRoot = if ($Scope -eq 'AllUsers') {
        Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    } else {
        Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    }

    $folder = Join-Path $programsRoot 'Indoor Golf Partner'
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $shortcutPath = Join-Path $folder 'IGP Toolkit.lnk'

    $wsh = New-Object -ComObject WScript.Shell
    $s = $wsh.CreateShortcut($shortcutPath)

    # Use cmd.exe so double-click behaves consistently, even if file associations change
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
    # cmd.exe parsing is picky; wrap the command in an extra set of quotes so paths with spaces work reliably
    # Resulting arguments look like: /c ""C:\Path With Spaces\IGP-toolkit.cmd""
    $s.Arguments  = "/c `"`"$cmdPath`"`""
    $s.WorkingDirectory = $ToolkitDir
    $s.WindowStyle = 1

    # Optional: if you later add an .ico in the toolkit folder, you can switch this
    $s.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',0'

    $s.Save()

    Write-Log "Start Menu shortcut created: $shortcutPath"
}

if (-not (Test-IsAdmin)) {
    throw 'Please run this installer in an elevated PowerShell (Administrator).'
}

Write-Log '=== IGP Toolkit bootstrap installer started ==='

$u = 'https://raw.githubusercontent.com/Indoor-Golf-Partner/IGP-Toolkit/main/Modules/Toolkit/updatetoolkit.ps1'
$p = Join-Path $env:TEMP 'updatetoolkit.ps1'

Write-Log "Downloading updater: $u"
Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $p

try {
    Write-Log 'Running updater (Startup mode) to install/update toolkit...'

    # Use -Mode Startup to avoid menus/prompts and perform the update/clone
    # (Updater will use its own default TargetDir unless you change it there)
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Mode Startup

    Write-Log 'Updater finished.'
}
finally {
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        Write-Log 'Removed temporary updater script.'
    }
}

# Confirm toolkit folder exists (best-effort)
if (-not (Test-Path -LiteralPath $ToolkitDir)) {
    Write-Log "Toolkit directory not found at expected path: $ToolkitDir" 'WARN'
    Write-Log 'Shortcut creation may fail if the toolkit did not install correctly.' 'WARN'
}

New-StartMenuShortcut -ToolkitDir $ToolkitDir -Scope $StartMenuScope

Write-Log '=== IGP Toolkit bootstrap installer finished ==='
