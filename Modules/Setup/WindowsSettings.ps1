<#
.SYNOPSIS
  Windows Settings module - collection of Windows configuration tweaks.

.DESCRIPTION
  Provides a submenu:
    1) Power Settings
    2) Graphics Settings
    3) Registry Settings
    4) Network Settings
    5) Apply NVIDIA Settings
    6) Validate NVIDIA Settings

  Power Settings:
  - Loops through all USB ports/controllers and disables "Allow the
    computer to turn off this device to save power" so USB peripherals
    (e.g. Trackman sensors, launch monitors) don't get suspended by
    Windows power management.
  - Creates (or reuses) a power plan named "Indoor Golf Partner" based
    on the built-in High performance scheme, activates it, and applies
    baseline AC settings (no monitor/standby timeout, USB selective
    suspend disabled, PCIe Link State Power Management off).

  Graphics Settings:
  - Sets the Windows per-app GPU preference to "High performance" for
    the TrackMan executables found under the known TrackMan install/
    staging paths, and prunes stale entries no longer in the allowlist.

  Registry Settings:
  - Disables Explorer's startup-app delay (WaitForIdleState /
    StartupDelayInMSec set to 0) for the current user, so startup
    programs launch immediately at logon.

  Network Settings:
  - Lists all physical network adapters and lets the user pick one, then
    applies everything from the Power Management and Advanced tabs of that
    adapter's Device Manager properties:
    - Disables "Allow the computer to turn off this device to save power".
      Reads AllowComputerToTurnOffDevice via Get-NetAdapterPowerManagement
      first (confirmed the authoritative source on hardware where root\wmi
      MSPower_DeviceEnable has no entry for the NIC at all, e.g. a Realtek
      PCIe 5GbE controller), falling back to the legacy WMI approach only
      if the modern property is unavailable. Live testing showed this
      property is not reachable through any Set-/Disable-
      NetAdapterPowerManagement switch (neither -SelectiveSuspend nor the
      "no switches" form actually changed it) - it has to be mutated
      directly on the CIM object and applied via Set-CimInstance, the same
      pattern already used for USB devices.
    - Disables "Allow this device to wake the computer" (powercfg
      /devicedisablewake - a generic PnP power-policy flag, not a NIC
      advanced property).
    - Disables "Only allow a magic packet to wake the computer"
      (Set-NetAdapterPowerManagement -WakeOnMagicPacket Disabled).
    - Sets Speed & Duplex to 1.0 Gbps Full Duplex.
    - Sets Jumbo Frame/Jumbo Packet to 9014 bytes (9k).
    - Disables Energy Efficient Ethernet (*EEE).
    - Disables Power Saving Mode where the driver exposes it separately
      from EEE (best-effort; not required for the "Confirmed" status
      since many drivers don't expose it as its own property).

  Apply/Validate NVIDIA Settings:
  - Downloads NVIDIA Profile Inspector (github.com/Orbmu2k/
    nvidiaProfileInspector, MIT licensed) into
    C:\Utilities\NvidiaProfileInspector if not already present, alongside
    a copy of its license text.
  - Apply runs it with -silentImport against resources\nvidia\igp.nip
    (shipped in the toolkit) to set the NVIDIA Control Panel 3D settings
    normally configured by hand (Low Latency: Ultra, Power Management
    Mode: Prefer Normal Performance, Texture Filtering Quality, OpenGL
    Rendering GPU, PhysX Processor). Assumes exactly one NVIDIA GPU per
    machine, since the GPU-selection settings are stored by slot rather
    than by model name.
  - Validate runs it with -exportCustomized to dump the machine's current
    customized settings, then compares each setting in igp.nip's "Base
    Profile" against that dump and reports any that are missing or don't
    match - without changing anything.

  TrackMan Autostart and BGInfo Autostart (both Scheduled Tasks, At Logon
  for any interactively logged-on user) are enabled/disabled from the
  toolkit's Startup Options module - the Enable-TrackManAutostart/
  Disable-TrackManAutostart/Get-ExistingTrackManAutostartTask and
  Enable-BgInfoAutostart/Disable-BgInfoAutostart/
  Get-ExistingBgInfoAutostartTask functions below still live here since
  Startup Options calls into them directly rather than duplicating the
  logic. TrackMan Autostart launches TrackMan GUI Shell after a
  configurable delay (prompted at enable-time, default 5 seconds) instead
  of a Startup-folder shortcut. BGInfo Autostart downloads and extracts
  BGInfo from the official Sysinternals source into C:\Utilities\bginfo if
  not already present, then copies igp.bgi/gss.bgi from the toolkit's own
  resources\bgi folder based on the "Reseller" value written by the
  Reseller Setup module (defaults to IGP if not set), and copies the
  matching background image as the current user's desktop wallpaper
  (HKCU, applied once on the master PC before cloning) - the .bgi configs
  are expected to use BGInfo's "Use Current Wallpaper" option rather than
  a hardcoded background path. Copying also removes the other brand's
  stale .bgi/.jpg from C:\Utilities\bginfo, and Reseller Setup calls back
  into Enable-BgInfoAutostart automatically if a PC is switched from one
  reseller to the other after BGInfo Autostart was already enabled. Also
  runs BGInfo immediately (not just at next logon) as a visual
  confirmation that the right branding actually applied.

.NOTES
  Requires Administrator privileges.
  Uses the fixed, locale-independent GUID for the built-in "High
  performance" scheme (8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c) instead of
  matching its display name, since that name is localized on non-English
  Windows installs.
  Network adapter advanced properties (Speed & Duplex, Jumbo Frame, EEE) are
  matched by their driver-defined RegistryKeyword (e.g. "*SpeedDuplex",
  "*JumboPacket", "*EEE" - the last two confirmed against Microsoft's
  "Standardized INF Keywords for Power Management") rather than DisplayName,
  since DisplayName is localized in Device Manager depending on Windows
  display language while RegistryKeyword is not. Power Saving Mode has no
  standardized keyword (matched by DisplayName only). "Allow this device to
  wake the computer" and "Only allow a magic packet to wake the computer"
  are NOT NIC advanced properties at all - the former is a generic PnP
  power-policy flag (powercfg /devicedisablewake, matched by the adapter's
  InterfaceDescription/hardware friendly name, not its connection alias),
  the latter is controlled via Set-NetAdapterPowerManagement's
  -WakeOnMagicPacket parameter.
  .nip files are XmlSerializer output of NVIDIA Profile Inspector's
  "Profiles : List<Profile>" class - parsed directly as XML rather than
  via the tool itself, since it has no query/compare command-line option.
#>

$script:PowerPlanName        = 'Indoor Golf Partner'
$script:HighPerformanceGuid  = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:IGPRegistryBaseKey   = 'HKLM:\SOFTWARE\Indoor Golf Partner\IGP'

# TrackMan install/staging paths to scan for executables (folders are scanned recursively;
# only .exe files matching $script:TrackManAllowedExeNames are touched)
$script:TrackManPaths = @(
    "C:\Program Files\TrackMan Performance Studio",
    "C:\Program Files\TrackMan Performance Studio\Modules\TrackMan.Gui.Shell",
    "C:\ProgramData\TrackMan\Virtual Golf 2\staging\_trackmanchallenge",
    "C:\ProgramData\TrackMan\Virtual Golf 2\staging\_trackmangolf",
    "C:\ProgramData\TrackMan\Virtual Golf 2\staging\_trackmangolf3",
    "C:\ProgramData\TrackMan\Virtual Golf 2\staging\_trackmanpractice",
    "C:\ProgramData\TrackMan\Virtual Golf 2\staging\_trackmandrivingrange",
    "C:\ProgramData\TrackMan\Virtual Golf 2\staging\_trackmandrivingrange3"
)

$script:TrackManAllowedExeNames = @(
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

function Get-PowerPlanGuidByName([string]$name) {
    foreach ($line in (powercfg -l)) {
        if ($line -like "*($name)*" -and $line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return $Matches[1]
        }
    }
    return $null
}

function Ensure-PowerPlan {
    Write-Log "Ensuring power plan '$script:PowerPlanName' exists..."
    $existing = Get-PowerPlanGuidByName -name $script:PowerPlanName
    if ($existing) {
        Write-Log "Found existing plan: $existing"
        return $existing
    }

    # powercfg output varies; extract GUID reliably
    $dupOut = (powercfg -duplicatescheme $script:HighPerformanceGuid 2>&1 | Out-String)
    if ($dupOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $newGuid = $Matches[1]
    } else {
        $newGuid = $dupOut.Trim()
    }

    # Try name+description, then name-only fallback
    try {
        powercfg -changename $newGuid $script:PowerPlanName "Optimized for Indoor Golf Partner simulators" | Out-Null
    } catch {
        powercfg -changename $newGuid $script:PowerPlanName | Out-Null
    }

    Write-Log "Created plan: $newGuid"
    return $newGuid
}

function Configure-PowerPlan([string]$planGuid) {
    Write-Log "Configuring power plan (AC)..."

    powercfg -setactive $planGuid | Out-Null
    powercfg -change -monitor-timeout-ac 0 | Out-Null
    powercfg -change -standby-timeout-ac 0 | Out-Null

    # USB selective suspend: Disabled
    powercfg -setacvalueindex $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null

    # PCIe Link State Power Management: Off
    powercfg -setacvalueindex $planGuid 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null

    powercfg -setactive $planGuid | Out-Null
    Write-Log "Power plan configured."
}

function Invoke-PowerSettings {
    Disable-UsbPowerManagement

    $planGuid = Ensure-PowerPlan
    Configure-PowerPlan -planGuid $planGuid
}

function Test-PowerSettingsApplied {
    # Single-signal check: is the "Indoor Golf Partner" plan the active one.
    return [bool]((powercfg /getactivescheme) -match [regex]::Escape($script:PowerPlanName))
}

function Test-TrackManExeAllowed([string]$fullPath) {
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if (-not $leaf) { return $false }
    return ($script:TrackManAllowedExeNames -contains $leaf)
}

function Get-TrackManGpuTargets {
    $targets = New-Object System.Collections.Generic.List[string]

    foreach ($p in $script:TrackManPaths) {
        if (Test-Path $p -PathType Leaf) {
            if ($p.ToLower().EndsWith(".exe") -and (Test-TrackManExeAllowed $p)) { $targets.Add($p) }
            continue
        }

        if (Test-Path $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Filter *.exe -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { Test-TrackManExeAllowed $_.FullName } |
                ForEach-Object { $targets.Add($_.FullName) }
            continue
        }
    }

    return @($targets | Sort-Object -Unique)
}

function Set-HighPerformanceGpuPreference {
    Write-Log "Configuring per-app GPU preference (High performance) for TrackMan..."

    $gfxKey = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    if (-not (Test-Path $gfxKey)) { New-Item -Path $gfxKey -Force | Out-Null }

    $uniqueTargets = Get-TrackManGpuTargets

    if (-not $uniqueTargets -or $uniqueTargets.Count -eq 0) {
        Write-Log "No allowed TrackMan executables were found in the known paths." 'WARN'
        return
    }

    # Prune old TrackMan GPU prefs that are no longer in the allowlist
    try {
        $existing = Get-ItemProperty -Path $gfxKey -ErrorAction SilentlyContinue
        if ($existing) {
            $keep = @{}
            foreach ($t in $uniqueTargets) { $keep[$t.ToLowerInvariant()] = $true }

            foreach ($prop in $existing.PSObject.Properties) {
                $n = $prop.Name
                if (-not ($n -match '^[A-Za-z]:\\')) { continue }  # only full-path entries
                $lower = $n.ToLowerInvariant()

                if ($lower -like 'c:\program files\trackman performance studio\*' -or
                    $lower -like 'c:\programdata\trackman\virtual golf 2\staging\*') {

                    if (-not $keep.ContainsKey($lower)) {
                        Remove-ItemProperty -Path $gfxKey -Name $n -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Could not prune existing GPU preferences: $($_.Exception.Message)" 'WARN'
    }

    foreach ($exe in $uniqueTargets) {
        try {
            New-ItemProperty -Path $gfxKey -Name $exe -PropertyType String -Value "GpuPreference=2;" -Force | Out-Null
            Write-Log "  High performance GPU: $exe"
        }
        catch {
            Write-Log "  Failed to set GPU preference for '$exe': $($_.Exception.Message)" 'ERROR'
        }
    }

    Write-Log "GPU preferences written. Log out/in may be required for Settings UI to reflect changes."
}

function Invoke-GraphicsSettings {
    Set-HighPerformanceGpuPreference
}

function Test-GraphicsSettingsApplied {
    $gfxKey = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    if (-not (Test-Path $gfxKey)) { return $false }

    $targets = Get-TrackManGpuTargets
    if ($targets.Count -eq 0) { return $false }

    $existing = Get-ItemProperty -Path $gfxKey -ErrorAction SilentlyContinue
    if (-not $existing) { return $false }

    foreach ($t in $targets) {
        $val = $existing.$t
        if ($val -and $val -like '*GpuPreference=2*') { return $true }
    }
    return $false
}

function Set-ExplorerStartupDelay {
    Write-Log "Configuring Explorer startup delay settings (current user)..."

    $keyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize"

    try {
        if (-not (Test-Path $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }

        New-ItemProperty -Path $keyPath -Name "WaitForIdleState" -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $keyPath -Name "StartupDelayInMSec" -PropertyType DWord -Value 0 -Force | Out-Null

        Write-Log "Explorer startup delay disabled."
    }
    catch {
        Write-Log "Failed to configure Explorer startup delay: $($_.Exception.Message)" 'ERROR'
    }
}

function Invoke-RegistrySettings {
    Set-ExplorerStartupDelay
}

function Test-RegistrySettingsApplied {
    $keyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize"
    if (-not (Test-Path $keyPath)) { return $false }

    $props = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
    if (-not $props) { return $false }

    return ($props.WaitForIdleState -eq 0 -and $props.StartupDelayInMSec -eq 0)
}

function Get-NetworkAdapterChoice {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $adapters -or $adapters.Count -eq 0) {
        Write-Log "No physical network adapters found." 'WARN'
        return $null
    }

    Write-Host ""
    Write-Host "Available network adapters:"
    $map = @{}
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $a = $adapters[$i]
        $num = $i + 1
        Write-Host ("  {0}) {1} - {2} [{3}]" -f $num, $a.Name, $a.InterfaceDescription, $a.Status)
        $map["$num"] = $a
    }
    Write-Host ""

    $sel = Read-Host "Select adapter number (or Q to cancel)"
    if ($sel -match '^(?i)q$') { return $null }
    if (-not $map.ContainsKey($sel)) {
        Write-Log "Invalid selection." 'WARN'
        return $null
    }

    return $map[$sel]
}

function Get-DevicePowerManagementEntries {
    param([Parameter(Mandatory)] [string]$InstanceId)

    $powerMgmt = Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue
    if (-not $powerMgmt) { return @() }

    return @($powerMgmt | Where-Object { $_.InstanceName -like "*$InstanceId*" })
}

function Disable-NicPowerManagement {
    param([Parameter(Mandatory)] $Adapter)

    $match = Get-DevicePowerManagementEntries -InstanceId $Adapter.PnPDeviceID
    if ($match.Count -eq 0) {
        Write-Log "No power management data found for '$($Adapter.Name)'." 'WARN'
        return
    }

    foreach ($m in $match) {
        if (-not $m.Enable) {
            Write-Log "Power saving already disabled for '$($Adapter.Name)'."
            continue
        }

        try {
            $m.Enable = $false
            Set-CimInstance -InputObject $m -ErrorAction Stop
            Write-Log "Disabled power saving for '$($Adapter.Name)'."
        }
        catch {
            Write-Log "Failed to disable power saving for '$($Adapter.Name)': $($_.Exception.Message)" 'ERROR'
        }
    }
}

function Disable-NicAllowComputerToTurnOffDevice {
    param([Parameter(Mandatory)] $Adapter)

    # "Allow the computer to turn off this device to save power" for a NIC is not
    # reliably exposed via root\wmi MSPower_DeviceEnable - confirmed on a Realtek
    # PCIe 5GbE controller that simply has no entry there at all, despite the
    # checkbox being present and interactive in Device Manager.
    #
    # AllowComputerToTurnOffDevice (from Get-NetAdapterPowerManagement) is the
    # correct, NIC-specific property - but live testing showed it's NOT reachable
    # through any Set-/Disable-NetAdapterPowerManagement switch (neither
    # -SelectiveSuspend nor the "no switches = disable everything" form actually
    # changed it, and SelectiveSuspend itself didn't change either). The only
    # thing that worked was mutating the CIM object's property directly and
    # calling Set-CimInstance - the same pattern already used for USB devices
    # via MSPower_DeviceEnable - which took effect immediately, no restart needed.
    if (-not (Get-Command Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) {
        Write-Log "Get-NetAdapterPowerManagement not available on this system." 'WARN'
        return
    }

    try {
        $pm = Get-NetAdapterPowerManagement -Name $Adapter.Name -ErrorAction Stop

        if ($pm.AllowComputerToTurnOffDevice -eq 'Disabled') {
            Write-Log "'Allow the computer to turn off this device to save power' already disabled for '$($Adapter.Name)'."
            return
        }

        $pm.AllowComputerToTurnOffDevice = 'Disabled'
        Set-CimInstance -InputObject $pm -ErrorAction Stop
        Write-Log "Disabled 'Allow the computer to turn off this device to save power' for '$($Adapter.Name)'."
    }
    catch {
        Write-Log "Failed to disable NIC power-off setting for '$($Adapter.Name)': $($_.Exception.Message)" 'WARN'
    }
}

function Set-NicAdvancedPropertyBestEffort {
    param(
        [Parameter(Mandatory)] $Adapter,
        [Parameter(Mandatory)] [string]$SettingLabel,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$RegistryKeywords,
        [Parameter(Mandatory)] [string[]]$DisplayNameFallbacks,
        [string]$RegistryValue,
        [Parameter(Mandatory)] [string[]]$DisplayValueCandidates,
        [string]$ValidValuePattern
    )

    if (-not (Get-Command Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)) {
        Write-Log "Get/Set-NetAdapterAdvancedProperty not available on this system." 'WARN'
        return
    }

    $props = Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction SilentlyContinue
    if (-not $props) {
        Write-Log "No advanced properties available for '$($Adapter.Name)'." 'WARN'
        return
    }

    # Match by RegistryKeyword first (locale-independent, driver-defined), then fall back
    # to known English DisplayName variants for drivers that don't expose a keyword.
    $prop = $props | Where-Object { $_.RegistryKeyword -in $RegistryKeywords } | Select-Object -First 1
    if (-not $prop) {
        $prop = $props | Where-Object { $_.DisplayName -in $DisplayNameFallbacks } | Select-Object -First 1
    }

    if (-not $prop) {
        Write-Log "'$($Adapter.Name)' does not expose a $SettingLabel property." 'WARN'
        return
    }

    if ($RegistryValue) {
        try {
            Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $prop.DisplayName -RegistryValue $RegistryValue -NoRestart -ErrorAction Stop
            Write-Log "${SettingLabel}: set on '$($Adapter.Name)' (registry value $RegistryValue)."
            return
        }
        catch {
            # Fall through to display-value attempts
        }
    }

    $matched = @()
    if ($ValidValuePattern -and $prop.ValidDisplayValues) {
        $matched = @($prop.ValidDisplayValues | Where-Object { $_ -match $ValidValuePattern })
    }

    $candidates = @($matched + $DisplayValueCandidates) | Where-Object { $_ } | Select-Object -Unique

    foreach ($val in $candidates) {
        try {
            Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $prop.DisplayName -DisplayValue $val -NoRestart -ErrorAction Stop
            Write-Log "${SettingLabel}: set to '$val' on '$($Adapter.Name)'."
            return
        }
        catch {
            # Try next candidate value
        }
    }

    Write-Log "Failed to set $SettingLabel on '$($Adapter.Name)'. Available values: $($prop.ValidDisplayValues -join ', ')" 'ERROR'
}

# Shared by both the Set- functions below and their Test- counterparts, so the
# "what does correct look like" definition only lives in one place.
$script:SpeedDuplexRegistryKeywords    = @('*SpeedDuplex')
$script:SpeedDuplexDisplayNameFallback = @('Speed & Duplex','Speed and Duplex','Link Speed & Duplex','Speed/Duplex')
$script:SpeedDuplexValidPattern        = '(?i)(1\.?0?\s*Gb|1000\s*Mb).*full|(?i)full.*(1\.?0?\s*Gb|1000\s*Mb)'
$script:SpeedDuplexDisplayCandidates   = @('1.0 Gbps Full Duplex','1.0 Gbps Full','1 Gbps Full Duplex','1000Mbps Full Duplex','1000 Mbps Full Duplex')

$script:JumboFrameRegistryKeywords     = @('*JumboPacket')
$script:JumboFrameDisplayNameFallback  = @('Jumbo Frame','Jumbo Packet','JumboPacket','Jumbo MTU','MTU')
$script:JumboFrameRegistryValue        = '9014'
$script:JumboFrameValidPattern         = '9014|9\s*k'
$script:JumboFrameDisplayCandidates    = @('9014 Bytes','9014','9 KB','9KB MTU','9k','9K')

# *EEE is a standardized NDIS INF keyword (Microsoft: "Standardized INF Keywords for
# Power Management"), so it's matched by keyword first like Speed/Duplex and Jumbo Frame.
$script:EEERegistryKeywords     = @('*EEE')
$script:EEEDisplayNameFallback  = @('Energy Efficient Ethernet','Energy-Efficient Ethernet','EEE','Green Ethernet')
$script:EEEValidPattern         = '(?i)disab|off'
$script:EEEDisplayCandidates    = @('Disabled','Off')

# "Power Saving Mode" has no standardized keyword - on some drivers it's just another
# display name for *EEE, on others a distinct vendor-specific property, so this is
# matched purely by DisplayName (no RegistryKeywords to try first).
$script:PowerSavingModeDisplayNameFallback = @('Power Saving Mode','PowerSaveMode','Power Saving')
$script:PowerSavingModeValidPattern        = '(?i)disab|off'
$script:PowerSavingModeDisplayCandidates   = @('Disabled','Off')

function Set-NicSpeedDuplex1G {
    param([Parameter(Mandatory)] $Adapter)

    Set-NicAdvancedPropertyBestEffort -Adapter $Adapter `
        -SettingLabel 'Speed & Duplex' `
        -RegistryKeywords $script:SpeedDuplexRegistryKeywords `
        -DisplayNameFallbacks $script:SpeedDuplexDisplayNameFallback `
        -ValidValuePattern $script:SpeedDuplexValidPattern `
        -DisplayValueCandidates $script:SpeedDuplexDisplayCandidates
}

function Set-NicJumboFrame9014 {
    param([Parameter(Mandatory)] $Adapter)

    # Most drivers use the literal byte size (9014) as the underlying registry value,
    # even though the displayed text differs by vendor ("9014 Bytes", "9 KB", "9k", ...).
    Set-NicAdvancedPropertyBestEffort -Adapter $Adapter `
        -SettingLabel 'Jumbo Frame' `
        -RegistryKeywords $script:JumboFrameRegistryKeywords `
        -DisplayNameFallbacks $script:JumboFrameDisplayNameFallback `
        -RegistryValue $script:JumboFrameRegistryValue `
        -ValidValuePattern $script:JumboFrameValidPattern `
        -DisplayValueCandidates $script:JumboFrameDisplayCandidates
}

function Set-NicEnergyEfficientEthernetOff {
    param([Parameter(Mandatory)] $Adapter)

    Set-NicAdvancedPropertyBestEffort -Adapter $Adapter `
        -SettingLabel 'Energy Efficient Ethernet' `
        -RegistryKeywords $script:EEERegistryKeywords `
        -DisplayNameFallbacks $script:EEEDisplayNameFallback `
        -ValidValuePattern $script:EEEValidPattern `
        -DisplayValueCandidates $script:EEEDisplayCandidates
}

function Set-NicPowerSavingModeOff {
    param([Parameter(Mandatory)] $Adapter)

    Set-NicAdvancedPropertyBestEffort -Adapter $Adapter `
        -SettingLabel 'Power Saving Mode' `
        -RegistryKeywords @() `
        -DisplayNameFallbacks $script:PowerSavingModeDisplayNameFallback `
        -ValidValuePattern $script:PowerSavingModeValidPattern `
        -DisplayValueCandidates $script:PowerSavingModeDisplayCandidates
}

function Get-NicWakeDeviceName {
    param([Parameter(Mandatory)] $Adapter)

    if ($Adapter.InterfaceDescription) { return $Adapter.InterfaceDescription }
    return $Adapter.Name
}

function Disable-NicWakeCapability {
    param([Parameter(Mandatory)] $Adapter)

    # "Allow this device to wake the computer" is a generic PnP power-policy flag (not
    # NIC-specific), controlled via powercfg rather than any NetAdapter cmdlet. powercfg
    # matches devices by their hardware friendly name (InterfaceDescription), not the
    # connection alias (Name) - e.g. "Intel(R) Ethernet Connection (7) I219-V".
    $deviceName = Get-NicWakeDeviceName -Adapter $Adapter

    try {
        powercfg /devicedisablewake "$deviceName" | Out-Null
        Write-Log "Disabled 'Allow this device to wake the computer' for '$deviceName'."
    }
    catch {
        Write-Log "Failed to disable wake capability for '$deviceName': $($_.Exception.Message)" 'WARN'
    }
}

function Test-NicWakeDisabled {
    param([Parameter(Mandatory)] $Adapter)

    $deviceName = Get-NicWakeDeviceName -Adapter $Adapter

    try {
        $wakeArmed = powercfg /devicequery wake_armed 2>$null
        return -not [bool]($wakeArmed -match [regex]::Escape($deviceName))
    }
    catch {
        return $false
    }
}

function Test-NicAllowComputerToTurnOffDeviceDisabled {
    param([Parameter(Mandatory)] $Adapter)

    # AllowComputerToTurnOffDevice (via Get-NetAdapterPowerManagement) is the
    # authoritative, NIC-specific source of truth - confirmed to report correctly
    # even when the legacy MSPower_DeviceEnable WMI class has no entry for the
    # device at all. Only fall back to that legacy check if the modern property
    # is unavailable or doesn't report a clean Enabled/Disabled.
    if (Get-Command Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue) {
        try {
            $pm = Get-NetAdapterPowerManagement -Name $Adapter.Name -ErrorAction Stop
            if ($pm.AllowComputerToTurnOffDevice -in @('Enabled', 'Disabled')) {
                return [bool]($pm.AllowComputerToTurnOffDevice -eq 'Disabled')
            }
        }
        catch {
            # Fall through to the legacy check
        }
    }

    return Test-NicPowerManagementDisabled -Adapter $Adapter
}

function Disable-NicWakeOnMagicPacket {
    param([Parameter(Mandatory)] $Adapter)

    if (-not (Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) {
        Write-Log "Set-NetAdapterPowerManagement not available on this system." 'WARN'
        return
    }

    try {
        Set-NetAdapterPowerManagement -Name $Adapter.Name -WakeOnMagicPacket Disabled -NoRestart -ErrorAction Stop
        Write-Log "'Only allow a magic packet to wake the computer' disabled for '$($Adapter.Name)'."
    }
    catch {
        Write-Log "Failed to disable Wake on Magic Packet for '$($Adapter.Name)': $($_.Exception.Message)" 'WARN'
    }
}

function Test-NicWakeOnMagicPacketDisabled {
    param([Parameter(Mandatory)] $Adapter)

    if (-not (Get-Command Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) { return $false }

    try {
        $pm = Get-NetAdapterPowerManagement -Name $Adapter.Name -ErrorAction Stop
        return [bool]($pm.WakeOnMagicPacket -eq 'Disabled')
    }
    catch {
        return $false
    }
}

function Invoke-NetworkSettings {
    $adapter = Get-NetworkAdapterChoice
    if (-not $adapter) {
        Write-Log "No adapter selected. Skipping network settings." 'WARN'
        return
    }

    Disable-NicPowerManagement -Adapter $adapter
    Disable-NicAllowComputerToTurnOffDevice -Adapter $adapter
    Disable-NicWakeCapability -Adapter $adapter
    Disable-NicWakeOnMagicPacket -Adapter $adapter
    Set-NicSpeedDuplex1G -Adapter $adapter
    Set-NicJumboFrame9014 -Adapter $adapter
    Set-NicEnergyEfficientEthernetOff -Adapter $adapter
    Set-NicPowerSavingModeOff -Adapter $adapter
}

function Test-NicPowerManagementDisabled {
    param([Parameter(Mandatory)] $Adapter)

    $match = Get-DevicePowerManagementEntries -InstanceId $Adapter.PnPDeviceID
    if ($match.Count -eq 0) { return $false }

    return -not [bool]($match | Where-Object { $_.Enable } | Select-Object -First 1)
}

function Test-NicSettingApplied {
    param(
        [Parameter(Mandatory)] $Adapter,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$RegistryKeywords,
        [Parameter(Mandatory)] [string[]]$DisplayNameFallbacks,
        [Parameter(Mandatory)] [string]$ValidValuePattern
    )

    if (-not (Get-Command Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)) { return $false }

    $props = Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction SilentlyContinue
    if (-not $props) { return $false }

    $prop = $props | Where-Object { $_.RegistryKeyword -in $RegistryKeywords } | Select-Object -First 1
    if (-not $prop) {
        $prop = $props | Where-Object { $_.DisplayName -in $DisplayNameFallbacks } | Select-Object -First 1
    }
    if (-not $prop) { return $false }

    return [bool]($prop.DisplayValue -match $ValidValuePattern)
}

function Test-NetworkSettingsApplied {
    # Power Saving Mode is deliberately not part of this gate: it has no standardized
    # keyword, and on many drivers it doesn't exist as a separate property at all (see
    # Set-NicPowerSavingModeOff), so requiring it would make Confirmed unreachable on
    # those systems even after everything realistically achievable has been applied.
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $matching = @()

    foreach ($a in $adapters) {
        $powerOk       = Test-NicAllowComputerToTurnOffDeviceDisabled -Adapter $a
        $wakeOk        = Test-NicWakeDisabled -Adapter $a
        $magicPacketOk = Test-NicWakeOnMagicPacketDisabled -Adapter $a
        $speedOk       = Test-NicSettingApplied -Adapter $a `
            -RegistryKeywords $script:SpeedDuplexRegistryKeywords `
            -DisplayNameFallbacks $script:SpeedDuplexDisplayNameFallback `
            -ValidValuePattern $script:SpeedDuplexValidPattern
        $jumboOk = Test-NicSettingApplied -Adapter $a `
            -RegistryKeywords $script:JumboFrameRegistryKeywords `
            -DisplayNameFallbacks $script:JumboFrameDisplayNameFallback `
            -ValidValuePattern $script:JumboFrameValidPattern
        $eeeOk = Test-NicSettingApplied -Adapter $a `
            -RegistryKeywords $script:EEERegistryKeywords `
            -DisplayNameFallbacks $script:EEEDisplayNameFallback `
            -ValidValuePattern $script:EEEValidPattern

        if ($powerOk -and $wakeOk -and $magicPacketOk -and $speedOk -and $jumboOk -and $eeeOk) {
            $matching += $a.Name
        }
    }

    return $matching
}

$script:TrackManGuiShellPath       = "C:\Program Files\TrackMan Performance Studio\Modules\TrackMan.Gui.Shell.exe"
$script:TrackManGuiShellWorkingDir = "C:\Program Files\TrackMan Performance Studio\Modules"

function Get-TrackManAutostartTaskName { 'IGP TrackMan Autostart' }

function Get-ExistingTrackManAutostartTask {
    $name = Get-TrackManAutostartTaskName
    try {
        return Get-ScheduledTask -TaskName $name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Read-DelaySeconds {
    param([int]$Default = 5)

    $raw = Read-Host "Seconds until TPS starts ($Default)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

    $parsed = 0
    if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 0) {
        return $parsed
    }

    Write-Log "Invalid input '$raw'. Using default of $Default seconds." 'WARN'
    return $Default
}

function Enable-TrackManAutostart {
    if (-not (Test-Path -LiteralPath $script:TrackManGuiShellPath)) {
        Write-Log "TrackMan GUI Shell not found at: $script:TrackManGuiShellPath" 'ERROR'
        return
    }

    $delaySeconds = Read-DelaySeconds -Default 5
    $name = Get-TrackManAutostartTaskName

    $existing = Get-ExistingTrackManAutostartTask
    if ($existing) {
        try {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        } catch {
            throw "Failed to remove existing task '$name': $($_.Exception.Message)"
        }
    }

    $action = New-ScheduledTaskAction -Execute $script:TrackManGuiShellPath -WorkingDirectory $script:TrackManGuiShellWorkingDir

    # Applies to any interactively logged-on user; -Delay adds the wait before launch
    # (as an ISO 8601 duration) so TrackMan doesn't race ahead of USB hardware enumeration.
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = "PT{0}S" -f $delaySeconds

    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

    Write-Log "Enabling TrackMan autostart at logon (delay: ${delaySeconds}s)..."
    Register-ScheduledTask -TaskName $name -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Log "TrackMan autostart enabled (task: '$name')."
}

function Disable-TrackManAutostart {
    $name = Get-TrackManAutostartTaskName
    $task = Get-ExistingTrackManAutostartTask
    if (-not $task) {
        Write-Log "Task '$name' does not exist. Nothing to disable." 'WARN'
        return
    }

    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    Write-Log "TrackMan autostart disabled (task removed)."
}

$script:BgInfoDir     = "C:\Utilities\bginfo"
$script:BgInfoExePath = Join-Path $script:BgInfoDir "Bginfo64.exe"
$script:BgInfoZipUrl  = "https://download.sysinternals.com/files/BGInfo.zip"

# .bgi configs (igp.bgi / gss.bgi) and their matching wallpaper images ship inside the
# toolkit itself, under resources\bgi. $PSScriptRoot here is Modules\Setup, so the
# toolkit root is two levels up.
$script:ToolkitRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:BgiResourcesDir = Join-Path $script:ToolkitRoot 'resources\bgi'

function Get-BgInfoAutostartTaskName { 'IGP BGInfo Autostart' }

function Get-ExistingBgInfoAutostartTask {
    $name = Get-BgInfoAutostartTaskName
    try {
        return Get-ScheduledTask -TaskName $name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-ConfiguredReseller {
    try {
        $value = (Get-ItemProperty -Path $script:IGPRegistryBaseKey -Name 'Reseller' -ErrorAction Stop).Reseller
        if ($value -in @('IGP', 'GSS')) { return $value }
    }
    catch {
        # Reseller Setup hasn't been run yet - fall through to default
    }
    return $null
}

function Set-DesktopWallpaper {
    param([Parameter(Mandatory)] [string]$ImagePath)

    if (-not (Test-Path -LiteralPath $ImagePath)) {
        Write-Log "Wallpaper image not found: $ImagePath" 'WARN'
        return
    }

    try {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $ImagePath -Force

        if (-not ('IGPToolkit.NativeMethods' -as [type])) {
            Add-Type -Name NativeMethods -Namespace IGPToolkit -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
        }

        $SPI_SETDESKWALLPAPER = 0x0014
        $SPIF_UPDATEINIFILE   = 0x01
        $SPIF_SENDCHANGE      = 0x02

        [IGPToolkit.NativeMethods]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $ImagePath, ($SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE)) | Out-Null

        Write-Log "Desktop wallpaper set to '$ImagePath'."
    }
    catch {
        Write-Log "Failed to set desktop wallpaper: $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-StaleBgiAssets {
    param([Parameter(Mandatory)] [string]$KeepPrefix)

    # A PC that was set up as one reseller and later switched to the other shouldn't
    # keep the old brand's .bgi/.jpg sitting in the bginfo folder alongside the new one.
    $otherPrefix = if ($KeepPrefix -eq 'igp') { 'gss' } else { 'igp' }

    foreach ($ext in @('bgi', 'jpg')) {
        $stale = Join-Path $script:BgInfoDir "$otherPrefix.$ext"
        if (Test-Path -LiteralPath $stale) {
            Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
            Write-Log "Removed stale '$otherPrefix.$ext' from '$script:BgInfoDir'."
        }
    }
}

function Copy-BgiAssets {
    param([Parameter(Mandatory)] [ValidateSet('IGP','GSS')] [string]$Reseller)

    $prefix    = $Reseller.ToLowerInvariant()
    $sourceBgi = Join-Path $script:BgiResourcesDir "$prefix.bgi"
    $sourceJpg = Join-Path $script:BgiResourcesDir "$prefix.jpg"

    if (-not (Test-Path -LiteralPath $sourceBgi)) {
        Write-Log "BGInfo config not found in toolkit resources: $sourceBgi" 'ERROR'
        return $null
    }

    New-Item -ItemType Directory -Force -Path $script:BgInfoDir | Out-Null
    $destBgi = Join-Path $script:BgInfoDir "$prefix.bgi"
    Copy-Item -LiteralPath $sourceBgi -Destination $destBgi -Force

    if (Test-Path -LiteralPath $sourceJpg) {
        $destJpg = Join-Path $script:BgInfoDir "$prefix.jpg"
        Copy-Item -LiteralPath $sourceJpg -Destination $destJpg -Force
        Set-DesktopWallpaper -ImagePath $destJpg
    }
    else {
        Write-Log "No background image found in toolkit resources for '$prefix' ($sourceJpg); wallpaper left unchanged." 'WARN'
    }

    Remove-StaleBgiAssets -KeepPrefix $prefix

    return $destBgi
}

function Install-BgInfoIfMissing {
    if (Test-Path -LiteralPath $script:BgInfoExePath) {
        return $true
    }

    Write-Log "BGInfo not found at '$script:BgInfoDir'. Downloading from Sysinternals..."

    try {
        New-Item -ItemType Directory -Force -Path $script:BgInfoDir | Out-Null

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $zipPath = Join-Path $env:TEMP "BGInfo.zip"
        Invoke-WebRequest -Uri $script:BgInfoZipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop

        Expand-Archive -LiteralPath $zipPath -DestinationPath $script:BgInfoDir -Force -ErrorAction Stop
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $script:BgInfoExePath)) {
            Write-Log "BGInfo download/extract did not produce Bginfo64.exe at the expected path." 'ERROR'
            return $false
        }

        Write-Log "BGInfo installed to '$script:BgInfoDir'."
        return $true
    }
    catch {
        Write-Log "Failed to download/install BGInfo: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Enable-BgInfoAutostart {
    if (-not (Install-BgInfoIfMissing)) { return }

    $reseller = Get-ConfiguredReseller
    if (-not $reseller) {
        Write-Log "No Reseller value found in the registry (run Reseller Setup first). Defaulting to IGP branding." 'WARN'
        $reseller = 'IGP'
    }

    $bgiPath = Copy-BgiAssets -Reseller $reseller
    if (-not $bgiPath) { return }

    $name = Get-BgInfoAutostartTaskName
    $existing = Get-ExistingBgInfoAutostartTask
    if ($existing) {
        try {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        } catch {
            throw "Failed to remove existing task '$name': $($_.Exception.Message)"
        }
    }

    $arguments = "`"$bgiPath`" /timer:0 /silent /nolicprompt"
    $action = New-ScheduledTaskAction -Execute $script:BgInfoExePath -Argument $arguments -WorkingDirectory $script:BgInfoDir

    # Applies to any interactively logged-on user, same as TrackMan autostart.
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

    Write-Log "Enabling BGInfo autostart at logon (config: $([System.IO.Path]::GetFileName($bgiPath)))..."
    Register-ScheduledTask -TaskName $name -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Log "BGInfo autostart enabled (task: '$name')."

    # Run it now too, not just at next logon - an immediate visual confirmation that the
    # right branding actually applied, rather than waiting to see it until signing back in.
    try {
        Start-Process -FilePath $script:BgInfoExePath -ArgumentList $arguments -WorkingDirectory $script:BgInfoDir -Wait -ErrorAction Stop
        Write-Log "BGInfo applied now as a visual confirmation."
    }
    catch {
        Write-Log "Enabled, but failed to run BGInfo immediately: $($_.Exception.Message)" 'WARN'
    }
}

function Disable-BgInfoAutostart {
    $name = Get-BgInfoAutostartTaskName
    $task = Get-ExistingBgInfoAutostartTask
    if (-not $task) {
        Write-Log "Task '$name' does not exist. Nothing to disable." 'WARN'
        return
    }

    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    Write-Log "BGInfo autostart disabled (task removed)."
}

$script:NvidiaToolDir       = "C:\Utilities\NvidiaProfileInspector"
$script:NvidiaExePath       = Join-Path $script:NvidiaToolDir "nvidiaProfileInspector.exe"
$script:NvidiaLicensePath   = Join-Path $script:NvidiaToolDir "LICENSE.txt"
$script:NvidiaReleasesApi   = "https://api.github.com/repos/Orbmu2k/nvidiaProfileInspector/releases/latest"
$script:NvidiaLicenseUrl    = "https://raw.githubusercontent.com/Orbmu2k/nvidiaProfileInspector/master/LICENSE"
$script:NvidiaResourcesDir  = Join-Path $script:ToolkitRoot 'resources\nvidia'
$script:NvidiaNipPath       = Join-Path $script:NvidiaResourcesDir 'igp.nip'
$script:NvidiaBaseProfile   = 'Base Profile'

function Install-NvidiaProfileInspectorIfMissing {
    if (Test-Path -LiteralPath $script:NvidiaExePath) {
        return $true
    }

    Write-Log "NVIDIA Profile Inspector not found. Downloading latest release from GitHub..."

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $release = Invoke-RestMethod -Uri $script:NvidiaReleasesApi -Headers @{ 'User-Agent' = 'IGP-Toolkit' } -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if (-not $asset) {
            Write-Log "Could not find a .zip asset in the latest NVIDIA Profile Inspector release." 'ERROR'
            return $false
        }

        New-Item -ItemType Directory -Force -Path $script:NvidiaToolDir | Out-Null

        $zipPath = Join-Path $env:TEMP "nvidiaProfileInspector.zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop

        Expand-Archive -LiteralPath $zipPath -DestinationPath $script:NvidiaToolDir -Force -ErrorAction Stop
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $script:NvidiaExePath)) {
            Write-Log "Download/extract did not produce nvidiaProfileInspector.exe at the expected path." 'ERROR'
            return $false
        }

        # MIT license requires the license text to travel with distributed copies.
        try {
            Invoke-WebRequest -Uri $script:NvidiaLicenseUrl -OutFile $script:NvidiaLicensePath -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-Log "Could not download LICENSE.txt alongside NVIDIA Profile Inspector: $($_.Exception.Message)" 'WARN'
        }

        Write-Log "NVIDIA Profile Inspector installed to '$script:NvidiaToolDir'."
        return $true
    }
    catch {
        Write-Log "Failed to download/install NVIDIA Profile Inspector: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Set-NvidiaGlobalProfile {
    if (-not (Install-NvidiaProfileInspectorIfMissing)) { return }

    if (-not (Test-Path -LiteralPath $script:NvidiaNipPath)) {
        Write-Log "Settings file not found: $script:NvidiaNipPath" 'ERROR'
        return
    }

    Write-Log "Applying NVIDIA global 3D settings from igp.nip..."
    Start-Process -FilePath $script:NvidiaExePath -ArgumentList "-silentImport `"$script:NvidiaNipPath`"" -Wait -WindowStyle Hidden
    Write-Log "NVIDIA settings applied."
}

function Get-NipProfileSettings {
    param(
        [Parameter(Mandatory)] [string]$NipPath,
        [string]$ProfileName = $script:NvidiaBaseProfile
    )

    if (-not (Test-Path -LiteralPath $NipPath)) { return @() }

    [xml]$xml = Get-Content -LiteralPath $NipPath -Raw

    # .nip files are XmlSerializer output of a "Profiles : List<Profile>" class, so the
    # root element is normally <Profiles>; fall back to the generic <ArrayOfProfile> shape
    # in case a different exporter/serializer produced the file.
    $root = if ($xml.Profiles) { $xml.Profiles } elseif ($xml.ArrayOfProfile) { $xml.ArrayOfProfile } else { $null }
    if (-not $root) { return @() }

    $profileNode = @($root.Profile) | Where-Object { $_.ProfileName -eq $ProfileName }
    if (-not $profileNode) { return @() }

    return @($profileNode.Settings.ProfileSetting) | ForEach-Object {
        [pscustomobject]@{
            SettingId    = [string]$_.SettingID
            SettingValue = [string]$_.SettingValue
        }
    }
}

function Compare-NvidiaGlobalProfile {
    # Core comparison, reused by both the interactive Validate option and Get-Status.
    # Returns $null if the comparison couldn't run at all (tool/file missing), otherwise
    # @{ Expected = <int>; Mismatches = <string[]> }.
    if (-not (Test-Path -LiteralPath $script:NvidiaExePath)) { return $null }
    if (-not (Test-Path -LiteralPath $script:NvidiaNipPath)) { return $null }

    $expected = Get-NipProfileSettings -NipPath $script:NvidiaNipPath
    if ($expected.Count -eq 0) { return @{ Expected = 0; Mismatches = @() } }

    # -exportCustomized writes a timestamped .nip next to the executable; clear old dumps
    # first so the freshly written one can be found reliably.
    Get-ChildItem -LiteralPath $script:NvidiaToolDir -Filter '*.nip' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Start-Process -FilePath $script:NvidiaExePath -ArgumentList '-exportCustomized' -Wait -WindowStyle Hidden

    $dump = Get-ChildItem -LiteralPath $script:NvidiaToolDir -Filter '*.nip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $dump) { return $null }

    $actual = Get-NipProfileSettings -NipPath $dump.FullName
    Remove-Item -LiteralPath $dump.FullName -Force -ErrorAction SilentlyContinue

    $mismatches = @()
    foreach ($exp in $expected) {
        $match = $actual | Where-Object { $_.SettingId -eq $exp.SettingId }
        if (-not $match) {
            $mismatches += "Setting $($exp.SettingId): not applied on this machine (expected $($exp.SettingValue))."
        }
        elseif ($match.SettingValue -ne $exp.SettingValue) {
            $mismatches += "Setting $($exp.SettingId): expected $($exp.SettingValue), found $($match.SettingValue)."
        }
    }

    return @{ Expected = $expected.Count; Mismatches = $mismatches }
}

function Test-NvidiaGlobalProfile {
    if (-not (Test-Path -LiteralPath $script:NvidiaExePath)) {
        Write-Log "NVIDIA Profile Inspector is not installed. Apply the settings first." 'ERROR'
        return
    }

    if (-not (Test-Path -LiteralPath $script:NvidiaNipPath)) {
        Write-Log "Settings file not found: $script:NvidiaNipPath" 'ERROR'
        return
    }

    Write-Log "Exporting current NVIDIA settings for comparison..."
    $result = Compare-NvidiaGlobalProfile

    if (-not $result) {
        Write-Log "Could not find the exported settings dump. Validation aborted." 'ERROR'
        return
    }

    if ($result.Expected -eq 0) {
        Write-Log "No settings found for '$script:NvidiaBaseProfile' in igp.nip - nothing to validate." 'WARN'
        return
    }

    if ($result.Mismatches.Count -eq 0) {
        Write-Log "All NVIDIA settings match igp.nip."
    }
    else {
        $result.Mismatches | ForEach-Object { Write-Log $_ 'WARN' }
        Write-Log "$($result.Mismatches.Count) setting(s) did not match igp.nip." 'WARN'
    }
}

function Get-Status {
    $rows = @(
        [pscustomobject]@{
            Title  = 'Power Settings'
            Status = if (Test-PowerSettingsApplied) { 'Confirmed' } else { 'Missing' }
            Detail = ''
        }
        [pscustomobject]@{
            Title  = 'Graphics Settings'
            Status = if (Test-GraphicsSettingsApplied) { 'Confirmed' } else { 'Missing' }
            Detail = ''
        }
        [pscustomobject]@{
            Title  = 'Registry Settings'
            Status = if (Test-RegistrySettingsApplied) { 'Confirmed' } else { 'Missing' }
            Detail = ''
        }
    )

    $matchingAdapters = Test-NetworkSettingsApplied
    $rows += [pscustomobject]@{
        Title  = 'Network Settings'
        Status = if ($matchingAdapters.Count -gt 0) { 'Confirmed' } else { 'Missing' }
        Detail = ($matchingAdapters -join ', ')
    }

    $nvResult = Compare-NvidiaGlobalProfile
    if (-not $nvResult) {
        $rows += [pscustomobject]@{ Title = 'NVIDIA Settings'; Status = 'Missing'; Detail = 'Not installed or igp.nip missing' }
    }
    elseif ($nvResult.Expected -eq 0) {
        $rows += [pscustomobject]@{ Title = 'NVIDIA Settings'; Status = 'Missing'; Detail = 'igp.nip has no settings to compare' }
    }
    elseif ($nvResult.Mismatches.Count -eq 0) {
        $rows += [pscustomobject]@{ Title = 'NVIDIA Settings'; Status = 'Confirmed'; Detail = '' }
    }
    else {
        $rows += [pscustomobject]@{ Title = 'NVIDIA Settings'; Status = 'Missing'; Detail = "$($nvResult.Mismatches.Count) setting(s) mismatched" }
    }

    $rows += [pscustomobject]@{
        Title  = 'TrackMan Autostart'
        Status = if (Get-ExistingTrackManAutostartTask) { 'Confirmed' } else { 'Missing' }
        Detail = ''
    }

    $rows += [pscustomobject]@{
        Title  = 'BGInfo Autostart'
        Status = if (Get-ExistingBgInfoAutostartTask) { 'Confirmed' } else { 'Missing' }
        Detail = ''
    }

    return $rows
}

function Show-Menu {
    Write-Host ""
    Write-Host "Windows Settings"
    Write-Host "----------------"
    Write-Host "Applies Windows configuration tweaks for simulator PCs."
    Write-Host ""
    Write-Host "  1) Power Settings (USB power saving off + 'Indoor Golf Partner' power plan)"
    Write-Host "  2) Graphics Settings (TrackMan GPU preference)"
    Write-Host "  3) Registry Settings (Explorer startup delay)"
    Write-Host "  4) Network Settings (choose adapter: power/speed/jumbo frame)"
    Write-Host "  5) Apply NVIDIA Settings (Control Panel 3D settings via igp.nip)"
    Write-Host "  6) Validate NVIDIA Settings (compare against igp.nip)"
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
                Invoke-PowerSettings
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '2' {
                Invoke-GraphicsSettings
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '3' {
                Invoke-RegistrySettings
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '4' {
                Invoke-NetworkSettings
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '5' {
                Set-NvidiaGlobalProfile
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '6' {
                Test-NvidiaGlobalProfile
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
