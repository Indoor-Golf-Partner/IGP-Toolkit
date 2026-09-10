<#
.SYNOPSIS
  Windows Settings module - collection of Windows configuration tweaks.

.DESCRIPTION
  Provides a submenu:
    1) Power Settings

  Power Settings loops through all USB ports/controllers and disables
  "Allow the computer to turn off this device to save power" so USB
  peripherals (e.g. Trackman sensors, launch monitors) don't get
  suspended by Windows power management.

.NOTES
  Requires Administrator privileges.
#>

function Get-ConfirmText {
@"
Windows Settings

This module applies Windows configuration tweaks for simulator PCs.

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

function Disable-UsbPowerManagement {
    Write-Log "Scanning USB ports and controllers..."

    $usbDevices = Get-PnpDevice -Class 'USB' -ErrorAction SilentlyContinue
    if (-not $usbDevices) {
        Write-Log "No USB devices found." 'WARN'
        return
    }

    $powerMgmt = Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue
    if (-not $powerMgmt) {
        Write-Log "Could not query USB power management data (MSPower_DeviceEnable)." 'ERROR'
        return
    }

    $updated = 0
    $alreadyOff = 0
    $noPowerData = 0

    foreach ($device in $usbDevices) {
        $match = $powerMgmt | Where-Object { $_.InstanceName -like "*$($device.InstanceId)*" }

        if (-not $match) {
            $noPowerData++
            continue
        }

        foreach ($m in $match) {
            if (-not $m.Enable) {
                $alreadyOff++
                continue
            }

            try {
                $m.Enable = $false
                Set-CimInstance -InputObject $m -ErrorAction Stop
                Write-Log "Disabled power saving: $($device.FriendlyName)"
                $updated++
            }
            catch {
                Write-Log "Failed to update '$($device.FriendlyName)': $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    Write-Log "Done. Disabled: $updated, Already disabled: $alreadyOff, No power data: $noPowerData"
}

function Show-Menu {
    Write-Host ""
    Write-Host "Windows Settings"
    Write-Host "----------------"
    Write-Host "  1) Power Settings (disable USB power saving)"
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

        switch ($choice) {
            '1' {
                Disable-UsbPowerManagement
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            default {
                Write-Host 'Invalid selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Only auto-run when executed directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    RunModule
}
