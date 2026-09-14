<#
.SYNOPSIS
  Windows Settings module - collection of Windows configuration tweaks.

.DESCRIPTION
  Provides a submenu:
    1) Power Settings
    2) Graphics Settings
    3) Registry Settings
    4) Network Settings

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
  - Lists all physical network adapters and lets the user pick one, then:
    - Disables "Allow the computer to turn off this device to save
      power" for that adapter.
    - Sets Speed & Duplex to 1.0 Gbps Full Duplex.
    - Sets Jumbo Frame/Jumbo Packet to 9014 bytes (9k).

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
  a hardcoded background path.

.NOTES
  Requires Administrator privileges.
  Uses the fixed, locale-independent GUID for the built-in "High
  performance" scheme (8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c) instead of
  matching its display name, since that name is localized on non-English
  Windows installs.
  Network adapter advanced properties (Speed & Duplex, Jumbo Frame) are
  matched by their driver-defined RegistryKeyword (e.g. "*SpeedDuplex",
  "*JumboPacket") rather than DisplayName, since DisplayName is localized
  in Device Manager depending on Windows display language while
  RegistryKeyword is not.
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

function Test-TrackManExeAllowed([string]$fullPath) {
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if (-not $leaf) { return $false }
    return ($script:TrackManAllowedExeNames -contains $leaf)
}

function Set-HighPerformanceGpuPreference {
    Write-Log "Configuring per-app GPU preference (High performance) for TrackMan..."

    $gfxKey = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    if (-not (Test-Path $gfxKey)) { New-Item -Path $gfxKey -Force | Out-Null }

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

    $uniqueTargets = $targets | Sort-Object -Unique

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

function Disable-NicPowerManagement {
    param([Parameter(Mandatory)] $Adapter)

    $powerMgmt = Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue
    if (-not $powerMgmt) {
        Write-Log "Could not query power management data (MSPower_DeviceEnable)." 'ERROR'
        return
    }

    $match = $powerMgmt | Where-Object { $_.InstanceName -like "*$($Adapter.PnPDeviceID)*" }
    if (-not $match) {
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

function Set-NicAdvancedPropertyBestEffort {
    param(
        [Parameter(Mandatory)] $Adapter,
        [Parameter(Mandatory)] [string]$SettingLabel,
        [Parameter(Mandatory)] [string[]]$RegistryKeywords,
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

function Set-NicSpeedDuplex1G {
    param([Parameter(Mandatory)] $Adapter)

    Set-NicAdvancedPropertyBestEffort -Adapter $Adapter `
        -SettingLabel 'Speed & Duplex' `
        -RegistryKeywords @('*SpeedDuplex') `
        -DisplayNameFallbacks @('Speed & Duplex','Speed and Duplex','Link Speed & Duplex','Speed/Duplex') `
        -ValidValuePattern '(?i)(1\.?0?\s*Gb|1000\s*Mb).*full|(?i)full.*(1\.?0?\s*Gb|1000\s*Mb)' `
        -DisplayValueCandidates @('1.0 Gbps Full Duplex','1.0 Gbps Full','1 Gbps Full Duplex','1000Mbps Full Duplex','1000 Mbps Full Duplex')
}

function Set-NicJumboFrame9014 {
    param([Parameter(Mandatory)] $Adapter)

    # Most drivers use the literal byte size (9014) as the underlying registry value,
    # even though the displayed text differs by vendor ("9014 Bytes", "9 KB", "9k", ...).
    Set-NicAdvancedPropertyBestEffort -Adapter $Adapter `
        -SettingLabel 'Jumbo Frame' `
        -RegistryKeywords @('*JumboPacket') `
        -DisplayNameFallbacks @('Jumbo Frame','Jumbo Packet','JumboPacket','Jumbo MTU','MTU') `
        -RegistryValue '9014' `
        -ValidValuePattern '9014|9\s*k' `
        -DisplayValueCandidates @('9014 Bytes','9014','9 KB','9KB MTU','9k','9K')
}

function Invoke-NetworkSettings {
    $adapter = Get-NetworkAdapterChoice
    if (-not $adapter) {
        Write-Log "No adapter selected. Skipping network settings." 'WARN'
        return
    }

    Disable-NicPowerManagement -Adapter $adapter
    Set-NicSpeedDuplex1G -Adapter $adapter
    Set-NicJumboFrame9014 -Adapter $adapter
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

function Show-Menu {
    Write-Host ""
    Write-Host "Windows Settings"
    Write-Host "----------------"
    Write-Host "  1) Power Settings (USB power saving off + 'Indoor Golf Partner' power plan)"
    Write-Host "  2) Graphics Settings (TrackMan GPU preference)"
    Write-Host "  3) Registry Settings (Explorer startup delay)"
    Write-Host "  4) Network Settings (choose adapter: power/speed/jumbo frame)"
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
