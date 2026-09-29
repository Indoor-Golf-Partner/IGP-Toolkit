<#
.SYNOPSIS
  Reset and recalibrate Windows touch input for all displays.

.DESCRIPTION
  - Clears existing touch calibration for all detected displays
  - Launches tabcal.exe so the user can reconfigure touch mapping

.NOTES
  Requires administrator privileges.
#>

function Get-ConfirmText {
@"
This will reset touch calibration for ALL displays.

You will need to recalibrate touch input afterwards.
Please make sure you can see and access all screens.

Do you want to continue?
"@
}

function Get-DisplayIds {
    # Windows display device paths typically look like \\.\DISPLAY1, DISPLAY2, etc.
    $ids = @()

    try {
        $screens = [System.Windows.Forms.Screen]::AllScreens
        for ($i = 0; $i -lt $screens.Count; $i++) {
            # Screen.DeviceName already matches \\.\DISPLAYX
            $ids += $screens[$i].DeviceName
        }
    }
    catch {
        # Fallback: assume DISPLAY1–DISPLAY6
        $ids = 1..6 | ForEach-Object { "\\.\DISPLAY$_" }
    }

    return $ids | Select-Object -Unique
}

function Clear-TouchCalibration {
    param(
        [Parameter(Mandatory)]
        [string[]]$DisplayIds
    )

    $tabcal = Join-Path $env:SystemRoot "System32\tabcal.exe"
    if (-not (Test-Path -LiteralPath $tabcal)) {
        throw "tabcal.exe not found at expected path: $tabcal"
    }

    foreach ($id in $DisplayIds) {
        Write-Host "Clearing touch calibration for $id"
        Start-Process -FilePath $tabcal `
            -ArgumentList "ClearCal DisplayID=$id" `
            -Wait
    }
}

function Test-HasTouchDigitizer {
    # Best-effort detection:
    # - "HID-compliant touch screen"
    # - "HID-compliant pen"
    # - generic "Touch" in PnP name
    try {
        $devices = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object {
                $_.Name -match 'HID-compliant touch screen' -or
                $_.Name -match 'HID-compliant pen' -or
                $_.Name -match '\btouch\b'
            }
        return ($devices.Count -gt 0)
    }
    catch {
        # If detection fails (CIM blocked, etc.), return $null to mean "unknown"
        return $null
    }
}

function RunModule {
    Write-Host "Reset Touch Screen Calibration - started"

    $hasTouch = Test-HasTouchDigitizer
    if ($hasTouch -eq $false) {
        Write-Host ""
        Write-Host "No touch digitizer detected on this machine." -ForegroundColor Yellow
        Write-Host "Skipping tabcal reset/calibration." -ForegroundColor Yellow
        return
    }
    elseif ($hasTouch -eq $null) {
        Write-Host "Could not confirm touch hardware presence. Continuing anyway..." -ForegroundColor Yellow
    }

    $displayIds = Get-DisplayIds
    if (-not $displayIds -or $displayIds.Count -eq 0) {
        throw "No displays detected."
    }

    Write-Host "Detected displays:"
    $displayIds | ForEach-Object { Write-Host " - $_" }

    Clear-TouchCalibration -DisplayIds $displayIds

    Write-Host ""
    Write-Host "Launching touch calibration tool (tabcal.exe)..."
    Start-Process -FilePath (Join-Path $env:SystemRoot "System32\tabcal.exe")

    Write-Host "Reset Touch Screen Calibration - finished"
}

