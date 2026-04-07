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

# Module identity
$script:ModuleName    = 'Set TrackMan GPU Preferences'
$script:RequiresAdmin = $false

#region Confirm Text (Mandatory)
function Get-ConfirmText {
    return @"
$script:ModuleName

This module will:
- Scan TrackMan installation paths for known executables
- Set them to use High Performance GPU
- Clean up invalid GPU preference entries

It may change:
- Registry: HKCU\Software\Microsoft\DirectX\UserGpuPreferences

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
    Write-Host "1) Apply GPU settings"
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

    Write-Log "Running $script:ModuleName..."
    Invoke-ModuleOperation
    Write-Log "$script:ModuleName completed."
}
#endregion Entry Point