<#
.SYNOPSIS
  Reseller module - writes reseller/support identification to the registry.

.DESCRIPTION
  Provides a submenu:
    1) Setup for IGP
    2) Setup for GSS

  Both options write the same support/diagnostics metadata to
  HKLM:\SOFTWARE\Indoor Golf Partner\IGP, including both the IGP and GSS
  support contact lines (GSS phone number is a placeholder "xxx" until
  known). The only difference between the two options is the "Reseller"
  value written (IGP or GSS), identifying which company supplied the PC.

  Enabling/disabling BIOS serial write-back at startup (Scheduled Task
  "IGP Write Serial") is managed from the toolkit's Startup Options module
  - the Register-SerialStartupTask/Disable-SerialStartupTask/
  Get-ExistingSerialTask functions below still live here since Startup
  Options calls into them directly rather than duplicating the logic.
  Enable it once on a master PC before cloning: since the task persists
  (it isn't a one-time/self-deleting task), it survives imaging and
  self-corrects the serial number automatically on every future boot of
  every cloned PC, with no manual step required on the cloned units
  themselves.

.NOTES
  Requires Administrator privileges (writes to HKLM).
#>

param(
    [ValidateSet('Interactive','Startup')]
    [string]$Mode = 'Interactive'
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

$script:IGPRegistryBaseKey = "HKLM:\SOFTWARE\Indoor Golf Partner\IGP"

function Set-IGPRegistryInfo {
    param(
        [string]$SerialNumber   = "REPLACE-ME",
        [string]$CustomerName   = "REPLACE-ME",
        [string]$SupportPortal  = "REPLACE-ME",
        [string]$ImageID        = "IGP-MI202512.1",
        [string]$Notes          = "",
        [Parameter(Mandatory)] [ValidateSet('IGP','GSS')] [string]$Reseller
    )

    Write-Log "Writing registry information (Reseller: $Reseller)..."

    try {
        if (-not (Test-Path $script:IGPRegistryBaseKey)) {
            New-Item -Path $script:IGPRegistryBaseKey -Force | Out-Null
        }

        $values = @{
            SerialNumber    = $SerialNumber
            CustomerName    = $CustomerName
            TrackManSupport = "support@trackman.com | +45 4574 4742"
            IGPSupport      = "support@igpartner.dk | +46 470-52 82 70"
            GSSSupport      = "xxx"
            Reseller        = $Reseller
            SupportPortal   = $SupportPortal
            ImageID         = $ImageID
            Notes           = $Notes
        }

        foreach ($name in $values.Keys) {
            New-ItemProperty `
                -Path $script:IGPRegistryBaseKey `
                -Name $name `
                -PropertyType String `
                -Value $values[$name] `
                -Force | Out-Null
        }

        Write-Log "Registry information written."
    }
    catch {
        Write-Log "Failed to write registry info: $($_.Exception.Message)" 'ERROR'
    }
}

function Invoke-RegistrySetupIGP {
    Set-IGPRegistryInfo -Reseller 'IGP'
}

function Invoke-RegistrySetupGSS {
    Set-IGPRegistryInfo -Reseller 'GSS'
}

function Write-IGPSerialToRegistry {
    Write-Log "Reading BIOS serial number..."

    try {
        $serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber
        if (-not $serial) {
            Write-Log "BIOS did not report a serial number." 'WARN'
            return
        }

        if (-not (Test-Path $script:IGPRegistryBaseKey)) {
            New-Item -Path $script:IGPRegistryBaseKey -Force | Out-Null
        }

        # Only touch SerialNumber - leave CustomerName/Reseller/etc. untouched.
        Set-ItemProperty -Path $script:IGPRegistryBaseKey -Name "SerialNumber" -Value $serial -Force
        Write-Log "Serial number written: $serial"
    }
    catch {
        Write-Log "Failed to write serial number: $($_.Exception.Message)" 'ERROR'
    }
}

function Get-SerialTaskName { 'IGP Write Serial' }

function Get-ExistingSerialTask {
    $name = Get-SerialTaskName
    try {
        return Get-ScheduledTask -TaskName $name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Register-SerialStartupTask {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Cannot determine script path (PSCommandPath is empty)."
    }

    $deployedScript = $PSCommandPath
    $name = Get-SerialTaskName

    $existing = Get-ExistingSerialTask
    if ($existing) {
        try {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        } catch {
            throw "Failed to remove existing task '$name': $($_.Exception.Message)"
        }
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        $psExe = 'powershell.exe'
    }

    # Runs at every startup (not one-time): this is intentional, since the task needs to
    # survive Clonezilla imaging and self-correct the serial on every clone's first (and
    # subsequent) boots without any manual "arm right before cloning" step.
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$deployedScript`" -Mode Startup"

    $action    = New-ScheduledTaskAction -Execute $psExe -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

    Write-Log "Enabling serial write-back at startup (task: '$name')..."
    Register-ScheduledTask -TaskName $name -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Log "Serial write-back at startup enabled."
}

function Disable-SerialStartupTask {
    $name = Get-SerialTaskName
    $task = Get-ExistingSerialTask
    if (-not $task) {
        Write-Log "Task '$name' does not exist. Nothing to disable." 'WARN'
        return
    }

    Write-Log "Disabling serial write-back at startup by deleting task '$name'..." 'WARN'
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    Write-Log "Serial write-back at startup disabled."
}

function Test-ResellerSetupApplied {
    try {
        $value = (Get-ItemProperty -Path $script:IGPRegistryBaseKey -Name 'Reseller' -ErrorAction Stop).Reseller
        return [bool]($value -in @('IGP', 'GSS'))
    }
    catch {
        return $false
    }
}

function Get-Status {
    return @(
        [pscustomobject]@{
            Title  = 'Reseller Setup'
            Status = if (Test-ResellerSetupApplied) { 'Confirmed' } else { 'Missing' }
            Detail = ''
        }
        [pscustomobject]@{
            Title  = 'Write Serial Number at Startup'
            Status = if (Get-ExistingSerialTask) { 'Confirmed' } else { 'Missing' }
            Detail = ''
        }
    )
}

function Show-Menu {
    Write-Host ""
    Write-Host "Reseller Setup"
    Write-Host "--------------"
    Write-Host "Writes reseller/support identification info to the registry."
    Write-Host ""
    Write-Host "  1) Setup for IGP"
    Write-Host "  2) Setup for GSS"
    Write-Host "  Q) Back"
    Write-Host ""

    return (Read-Host 'Select an option')
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    if ($Mode -eq 'Startup') {
        # Non-interactive mode for the scheduled task
        Write-IGPSerialToRegistry
        return
    }

    while ($true) {
        Clear-Host
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        switch ($choice) {
            '1' {
                Invoke-RegistrySetupIGP
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '2' {
                Invoke-RegistrySetupGSS
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
