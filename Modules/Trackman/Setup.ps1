<#
.SYNOPSIS
    IGP Toolkit module template.

.DESCRIPTION
    Copy this file when creating a new module. Fill in ModuleName and implement
    functions as needed. Mandatory functions: Get-ConfirmText, RunModule.

.NOTES
    Keep structure consistent across modules.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleName    = 'TrackMan Setup'
$script:RequiresAdmin = $false

#region Confirm Text (Mandatory)
function Get-ConfirmText {
    return @"
$script:ModuleName

This module will:
- Perform general TrackMan setup and configuration
- Apply system optimizations
- Configure required components (GPU, network, etc.)

It may change:
- System settings
- Registry entries
- Application configurations

Press Y to continue.
"@
}
#endregion Confirm Text

#region Logging (Optional)
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string] $Level = 'INFO'
    )

    # Placeholder: replace with your preferred logging later
    Write-Host "[$Level] $Message"
}
#endregion Logging

#region Helpers (Optional)
function Test-IsAdmin {
    # Placeholder helper; implement if needed
    return $true
}

function Pause-Continue {
    Read-Host 'Press Enter to continue...' | Out-Null
}
#endregion Helpers

 #region Operations
#region New TPS Autostart/Executable Functions
function Get-TPSExecutablePath {
    # Try to locate TPS exe in common locations
    $candidates = @(
        "C:\Program Files\TrackMan Performance Studio\TrackMan Performance Studio.exe",
        "C:\Program Files\TrackMan Performance Studio\Modules\TrackMan.Gui.Shell\TrackMan.Gui.Shell.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            return $c
        }
    }

    return $null
}

function Test-TPSAutostartEnabled {
    $taskName = "IGP - Start TPS"
    return [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
}

function Set-TPSAutostart {
    param(
        [string]$ExePath,
        [int]$DelaySeconds = 10
    )

    if (-not (Test-Path $ExePath)) {
        Write-Log "TPS executable not found: $ExePath" 'ERROR'
        return
    }

    $taskName = "IGP - Start TPS"

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute $ExePath
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = "PT${DelaySeconds}S"

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Description "Start TrackMan Performance Studio at logon"

    Write-Log "TPS autostart enabled."
}

function Disable-TPSAutostart {
    $taskName = "IGP - Start TPS"

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Log "TPS autostart disabled."
    } else {
        Write-Log "TPS autostart was not enabled." 'WARN'
    }
}

function Toggle-TPSAutostart {
    if (Test-TPSAutostartEnabled) {
        Disable-TPSAutostart
    } else {
        $exe = Get-TPSExecutablePath
        if (-not $exe) {
            Write-Log "Could not locate TPS executable." 'ERROR'
            return
        }
        Set-TPSAutostart -ExePath $exe
    }
}
#endregion New TPS Autostart/Executable Functions

function Test-TrackManInstalled {
    param()

    # Known default install locations
    $defaultPaths = @(
        "C:\Program Files\TrackMan Performance Studio",
        "C:\Program Files\TrackMan Performance Studio\Modules\TrackMan.Gui.Shell",
        "C:\ProgramData\TrackMan\Virtual Golf 2"
    )

    # Check if any of the known paths exist
    foreach ($p in $defaultPaths) {
        if (Test-Path $p) {
            return $true
        }
    }

    return $false
}

function Install-TPS {
    param(
        [string]$DownloadPath = "$env:TEMP\TPSInstaller.exe",
        [string]$Arguments = ""
    )

    $url = "https://link.trackman.dk/tpsrelease"

    try {
        Write-Log "Downloading latest TPS installer..." 'INFO'

        Invoke-WebRequest `
            -Uri $url `
            -OutFile $DownloadPath `
            -MaximumRedirection 5 `
            -ErrorAction Stop

        if (-not (Test-Path $DownloadPath)) {
            throw "Download completed but installer not found."
        }

        Write-Log "Download complete: $DownloadPath" 'INFO'
        Write-Log "Starting TPS installer..." 'INFO'

        $process = Start-Process `
            -FilePath $DownloadPath `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru

        if ($process.ExitCode -eq 0) {
            Write-Log "TPS installation completed successfully." 'INFO'
        } else {
            Write-Log "TPS installer exited with code $($process.ExitCode)" 'WARN'
        }
    }
    catch {
        Write-Log "Failed to install TPS: $_" 'ERROR'
    }
}

function Normalize-ExeName {
    param([string]$Name)
    return ($Name -replace '\s','').ToLowerInvariant()
}

function Is-AllowedExe {
    param([string]$ExeName, [array]$AllowedNormalized)

    $normalized = Normalize-ExeName $ExeName
    return $AllowedNormalized -contains $normalized
}

function Invoke-ModuleOperation {

    # Check if TrackMan is installed
    if (-not (Test-TrackManInstalled)) {
        Write-Log "TrackMan installation not detected. Aborting setup." 'WARN'
        return
    }

    Write-Log "TrackMan installation detected. Continuing setup..."

    $gpuKey = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"

    if (-not (Test-Path $gpuKey)) {
        New-Item -Path $gpuKey -Force | Out-Null
    }

    # Known TrackMan executables
    $allowedExe = @(
        "TrackMan Performance Studio.exe",
        "TrackMan.Gui.Shell.exe",
        "Trackman Challenge.exe",
        "Trackman Golf.exe",
        "Trackman Golf3.exe",
        "Trackman Golf 3.exe",
        "Trackman Practice.exe",
        "Trackman DrivingRange.exe",
        "Trackman Driving Range.exe",
        "Trackman DrivingRange3.exe",
        "Trackman Driving Range 3.exe"
    )

    $allowNormalized = $allowedExe | ForEach-Object { Normalize-ExeName $_ }

    if (-not $global:TrackManPaths) {
        Write-Log "TrackManPaths is not defined." 'ERROR'
        return
    }

    $targets = New-Object System.Collections.Generic.List[string]

    foreach ($p in $global:TrackManPaths) {
        if (-not (Test-Path $p)) { continue }

        if ((Get-Item $p).PSIsContainer) {
            Get-ChildItem -Path $p -Recurse -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object {
                if (Is-AllowedExe $_.Name $allowNormalized) {
                    $targets.Add($_.FullName)
                }
            }
        } else {
            if (Is-AllowedExe (Split-Path $p -Leaf) $allowNormalized) {
                $targets.Add($p)
            }
        }
    }

    $targets = $targets | Sort-Object -Unique

    # Clean existing TrackMan entries
    $existing = Get-ItemProperty -Path $gpuKey

    foreach ($prop in $existing.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }) {
        $path = $prop.Name
        $lower = $path.ToLowerInvariant()

        if ($lower -like '*trackman*' -and -not ($targets -contains $path)) {
            try {
                Remove-ItemProperty -Path $gpuKey -Name $path -ErrorAction Stop
                Write-Log "Removed stale entry: $path" 'DEBUG'
            } catch {
                Write-Log "Failed to remove $path" 'WARN'
            }
        }
    }

    # Apply GPU preference
    foreach ($exe in $targets) {
        try {
            Set-ItemProperty -Path $gpuKey -Name $exe -Value "GpuPreference=2;"
            Write-Log "Set High Performance GPU for $exe"
        } catch {
            Write-Log "Failed to set GPU preference for $exe" 'ERROR'
        }
    }

    Write-Log "Completed GPU preference configuration."
}

#endregion Operations

#region Menu (Optional)
function Show-Menu {
    Clear-Host
    Write-Host $script:ModuleName

    $autoLabel = if (Test-TPSAutostartEnabled) { "Disable TPS Autostart" } else { "Enable TPS Autostart" }

    Write-Host "1) Install latest version of TPS"
    Write-Host "2) Apply GPU settings"
    Write-Host "3) $autoLabel"
    Write-Host "Q) Back"
}
#endregion Menu

#region Entry Point (Mandatory)
function RunModule {
    # Keep all execution inside this function

    # Optional admin gate (only if needed)
    if ($script:RequiresAdmin -and -not (Test-IsAdmin)) {
        Write-Log "Admin rights required to run $script:ModuleName." 'ERROR'
        Pause-Continue
        return
    }

    while ($true) {
        Show-Menu
        $choice = (Read-Host 'Select').Trim().ToUpperInvariant()

        switch ($choice) {
            '1' { Install-TPS; Pause-Continue }
            '2' { Invoke-ModuleOperation; Pause-Continue }
            '3' { Toggle-TPSAutostart; Pause-Continue }
            'Q' { return }
            default { Write-Host "Invalid choice."; Pause-Continue }
        }
    }
}
#endregion Entry Point