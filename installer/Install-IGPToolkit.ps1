<#
.SYNOPSIS
  Installs the IGP Toolkit onto a fresh Windows machine.

.DESCRIPTION
  Deliberately self-contained (no dependency on the rest of the toolkit,
  since it doesn't exist on the machine yet). Run this on its own, before
  IGP-Toolkit is cloned anywhere:
    1) Installs Git for Windows if 'git' isn't already on PATH - via winget
       if available, otherwise by downloading the latest official Git for
       Windows installer directly from GitHub and running it silently.
    2) Clones the IGP-Toolkit repo into
       C:\Utilities\Indoor Golf Partner\IGP-Toolkit (or pulls the latest
       changes if it's already there from a previous run).
    3) Adds an "IGP Toolkit" shortcut to the All Users Start Menu, pointing
       at IGP-toolkit.cmd in that folder.

  Safe to re-run: an existing Git install is left alone, an existing clone
  is pulled (fast-forward only - it errors out rather than overwriting any
  local changes) instead of re-cloned, and an existing shortcut is
  overwritten.

.NOTES
  Requires Administrator privileges (installing Git and writing to the
  All Users Start Menu both need it).
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

function Ensure-RunningAsAdmin {
    if (Test-IsAdmin) { return }

    Write-Log "Not running as administrator. Relaunching elevated..." 'WARN'

    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw "Cannot determine script path. Run this as a file: powershell -File <path>\Install-IGPToolkit.ps1"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`""
    ) -join " "

    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit
}

Ensure-RunningAsAdmin

$script:RepoUrl     = 'https://github.com/Indoor-Golf-Partner/IGP-Toolkit.git'
$script:InstallRoot = 'C:\Utilities\Indoor Golf Partner\IGP-Toolkit'
$script:LauncherCmd = Join-Path $script:InstallRoot 'IGP-toolkit.cmd'

function Update-SessionPathFromRegistry {
    # Picks up a PATH change (e.g. Git just added itself to it) without needing
    # to start a new process.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Install-GitFromGitHubRelease {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'IGP-Toolkit-Installer' } -ErrorAction Stop
    $asset = $release.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } | Select-Object -First 1
    if (-not $asset) {
        throw "Could not find a 64-bit Git for Windows installer in the latest GitHub release."
    }

    $installerPath = Join-Path $env:TEMP $asset.name
    Write-Log "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath -UseBasicParsing -ErrorAction Stop

    Write-Log "Running Git installer silently..."
    Start-Process -FilePath $installerPath -ArgumentList '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS' -Wait -ErrorAction Stop

    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
}

function Install-GitIfMissing {
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        Write-Log "Git is already installed."
        return
    }

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Log "Installing Git via winget..."
        & winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements | ForEach-Object { Write-Log $_ }
    }
    else {
        Write-Log "winget not available - downloading Git for Windows directly from GitHub instead..." 'WARN'
        Install-GitFromGitHubRelease
    }

    Update-SessionPathFromRegistry

    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        throw "Git installation did not complete successfully - 'git' is still not on PATH."
    }

    Write-Log "Git installed successfully."
}

function Install-OrUpdateToolkitRepo {
    $parent = Split-Path -Parent $script:InstallRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    if (Test-Path -LiteralPath (Join-Path $script:InstallRoot '.git')) {
        Write-Log "IGP Toolkit is already installed at '$script:InstallRoot' - pulling the latest changes..."
        & git -C $script:InstallRoot pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            throw "git pull failed with exit code $LASTEXITCODE - check for local changes at '$script:InstallRoot'."
        }
    }
    else {
        if (Test-Path -LiteralPath $script:InstallRoot) {
            throw "'$script:InstallRoot' already exists but isn't a git repository - remove it manually and re-run this installer."
        }
        Write-Log "Cloning IGP Toolkit into '$script:InstallRoot'..."
        & git clone $script:RepoUrl $script:InstallRoot
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed with exit code $LASTEXITCODE."
        }
    }

    Write-Log "IGP Toolkit is up to date at '$script:InstallRoot'."
}

function Add-StartMenuShortcut {
    if (-not (Test-Path -LiteralPath $script:LauncherCmd)) {
        throw "Launcher not found at '$script:LauncherCmd' - the clone/pull may not have completed correctly."
    }

    $startMenuPrograms = [Environment]::GetFolderPath('CommonPrograms')
    $shortcutPath = Join-Path $startMenuPrograms 'IGP Toolkit.lnk'

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $script:LauncherCmd
    $shortcut.WorkingDirectory = $script:InstallRoot
    $shortcut.Description = 'IGP Toolkit'
    $shortcut.Save()

    Write-Log "Start Menu shortcut created: '$shortcutPath'."
}

try {
    Install-GitIfMissing
    Install-OrUpdateToolkitRepo
    Add-StartMenuShortcut
    Write-Log "Installation complete. IGP Toolkit is available from the Start Menu."
}
catch {
    Write-Log "Installation failed: $($_.Exception.Message)" 'ERROR'
    Read-Host 'Press Enter to close...' | Out-Null
    exit 1
}

Read-Host 'Press Enter to close...' | Out-Null
