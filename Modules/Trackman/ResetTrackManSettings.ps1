<#
.SYNOPSIS
  Reset TrackMan settings (current user) and remove DeviceId.

.DESCRIPTION
  Deletes these folders if they exist:
    - %LOCALAPPDATA%\TrackMan
    - %USERPROFILE%\AppData\LocalLow\TrackMan
    - %APPDATA%\TrackMan

  And deletes:
    - C:\ProgramData\Trackman\DeviceId.txt

  Supports -WhatIf / -Confirm.

.NOTES
  Admin is recommended for the ProgramData file.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

# ---------------------------
# Helper functions
# ---------------------------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$ts [$Level] $Message"
}

function Get-TrackManPathsForCurrentUser {
    $local    = Join-Path $env:LOCALAPPDATA "TrackMan"
    $roaming  = Join-Path $env:APPDATA "TrackMan"

    # LocalLow isn’t an env var; it sits next to Local under the user profile.
    $localLow = Join-Path $env:USERPROFILE "AppData\LocalLow\TrackMan"

    return @($local, $localLow, $roaming)
}

function Remove-FolderIfExists {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Not found (skip): $Path"
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, "Remove directory recursively")) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Deleted folder: $Path"
        } catch {
            Write-Log "Failed to delete folder '$Path': $($_.Exception.Message)" "ERROR"
        }
    }
}

function Remove-FileIfExists {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Not found (skip): $Path"
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, "Remove file")) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            Write-Log "Deleted file: $Path"
        } catch {
            Write-Log "Failed to delete file '$Path': $($_.Exception.Message)" "ERROR"
        }
    }
}

# ---------------------------
# Run function (task entrypoint)
# ---------------------------

function Run-ResetTrackManSettings {
    Write-Log "Task: Reset TrackMan Settings - started"

    if (-not (Test-IsAdmin)) {
        Write-Log "Not running as admin. Relaunching elevated..." "WARN"
        Start-Process powershell.exe `
            -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }


    $paths = Get-TrackManPathsForCurrentUser
    foreach ($p in $paths) {
        Remove-FolderIfExists -Path $p
    }

    Remove-FileIfExists -Path "C:\ProgramData\Trackman\DeviceId.txt"

    Write-Log "Task: Reset TrackMan Settings - finished"
}

# ---------------------------
# Main
# ---------------------------

Run-ResetTrackManSettings
