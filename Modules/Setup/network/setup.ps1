<#
.SYNOPSIS
  Applies IGP baseline network adapter settings.

.DESCRIPTION
  Uses Set-NetAdapterAdvancedProperty (when available) to apply driver advanced settings
  by RegistryKeyword + RegistryValue (language independent).

  NOTE ABOUT REGISTRY EDITS:
  You *can* write directly to the NIC class registry keys, but most drivers will not
  reliably apply changes until the adapter/driver reloads, and mapping differs by vendor.
  The supported way is to use NetAdapter cmdlets (or vendor utilities) and then restart
  the adapter.

.NOTES
  PowerShell: Windows PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Test-CommandExists {
  param([Parameter(Mandatory)][string]$Name)
  return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-ScalarRegistryValue {
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $null }

  if ($Value -is [System.Array]) {
    if ($Value.Length -gt 0) { return $Value[0] }
    return $null
  }

  return $Value
}

function Get-AdapterVendor {
  param([Parameter(Mandatory)]$Adapter)

  $d = "$($Adapter.InterfaceDescription)".ToLowerInvariant()

  if ($d -match 'realtek') { return 'Realtek' }
  if ($d -match 'intel')   { return 'Intel' }
  if ($d -match 'marvell') { return 'Marvell' }
  if ($d -match 'broadcom'){ return 'Broadcom' }

  return 'Unknown'
}

function Import-NetworkBaselineSpec {
  # Loads Modules/Setup/network/values.ps1 and returns spec array.

  $thisDir = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($thisDir)) {
    $path = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($path)) { return @() }
    $thisDir = Split-Path -Parent $path
  }

  $specPath = Join-Path $thisDir 'values.ps1'
  if (-not (Test-Path -LiteralPath $specPath)) { return @() }

  try { . $specPath } catch { return @() }

  $cmd = Get-Command Get-IGPNetworkBaselineSpec -ErrorAction SilentlyContinue
  if (-not $cmd) { return @() }

  try { return @(Get-IGPNetworkBaselineSpec) } catch { return @() }
}

function Get-PrimaryEthernetAdapter {
  if (-not (Test-CommandExists -Name 'Get-NetAdapter')) { return $null }

  try {
    $all = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
      $_.Status -ne 'Disabled' -and $_.HardwareInterface -eq $true
    }
  } catch {
    return $null
  }

  if ($null -eq $all -or @($all).Count -eq 0) { return $null }

  $exact = $all | Where-Object { $_.Name -eq 'Ethernet' } | Select-Object -First 1
  if ($exact) { return $exact }

  $up = $all | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property ifIndex | Select-Object -First 1
  if ($up) { return $up }

  return ($all | Sort-Object -Property ifIndex | Select-Object -First 1)
}

function Get-EligibleEthernetAdapters {
  <#
    Returns likely onboard/PCIe Ethernet adapters for configuration.

    Excludes:
      - Wi-Fi / WLAN / 802.11
      - Bluetooth
      - USB NICs
      - Virtual adapters

    Notes:
      - We do not use -Physical because some real NICs are not returned by -Physical on some systems.
  #>

  if (-not (Test-CommandExists -Name 'Get-NetAdapter')) { return @() }

  try {
    $all = Get-NetAdapter -ErrorAction Stop | Where-Object {
      $_.HardwareInterface -eq $true -and $_.Status -ne 'Not Present'
    }
  } catch {
    return @()
  }

  $filtered = @($all | Where-Object {
    $desc = "$($_.InterfaceDescription)"
    $name = "$($_.Name)"
    $pnp  = "$($_.PnPDeviceID)"

    # Exclude obvious wireless/bluetooth
    ($desc -notmatch '(?i)wi-?fi|wireless|wlan|802\.11|bluetooth') -and
    ($name -notmatch '(?i)wi-?fi|wireless|wlan|bluetooth') -and

    # Exclude virtual
    ($desc -notmatch '(?i)virtual|hyper-?v|vmware|vbox|tap|tunneling|loopback') -and
    ($name -notmatch '(?i)vEthernet|virtual|hyper-?v|vmware|vbox|tap') -and

    # Exclude USB NICs
    ($pnp  -notmatch '^(?i)usb')
  })

  return @($filtered | Sort-Object -Property ifIndex)
}


function Format-AdapterLabel {
  param(
    [Parameter(Mandatory)]$Adapter,
    [Parameter(Mandatory)][string]$Vendor
  )

  $desc = "$($Adapter.InterfaceDescription)"
  if ($Vendor -eq 'Realtek') { $desc = "$desc (Trackman?)" }

  return "{0} | {1} | {2} | {3}" -f $Adapter.Name, $desc, $Adapter.Status, $Adapter.LinkSpeed
}


function Select-NetworkAdapterFromMenu {
  <#
    Interactive picker for eligible Ethernet adapters.

    If running non-interactively, falls back to the primary Ethernet adapter.
  #>

  $adapters = @(Get-EligibleEthernetAdapters)
  if ($null -eq $adapters -or @($adapters).Count -eq 0) {
    return (Get-PrimaryEthernetAdapter)
  }

  # Prefer Realtek first (Trackman?), then other onboard-like, then the rest.
  $scored = foreach ($a in $adapters) {
    $vendor = Get-AdapterVendor -Adapter $a

    # Simple scoring heuristic:
    #  0: Realtek
    #  1: Others
    $score = 1
    if ($vendor -eq 'Realtek') { $score = 0 }

    # Prefer Up adapters within each group
    $upScore = 1
    if ($a.Status -eq 'Up') { $upScore = 0 }

    [pscustomobject]@{ Adapter=$a; Vendor=$vendor; Score=$score; UpScore=$upScore }
  }

  $ordered = @($scored | Sort-Object -Property Score, UpScore, @{Expression={ $_.Adapter.ifIndex }} )

  Write-Host ''
  Write-Host 'Select network adapter to apply settings:'

  for ($i = 0; $i -lt $ordered.Count; $i++) {
    $a = $ordered[$i].Adapter
    $vendor = $ordered[$i].Vendor
    $label = Format-AdapterLabel -Adapter $a -Vendor $vendor
    Write-Host ("[{0}] {1}" -f ($i + 1), $label)
  }

  Write-Host ''
  $choice = Read-Host 'Enter number (or press Enter to cancel)'
  if ([string]::IsNullOrWhiteSpace($choice)) { return $null }

  $n = $null
  if (-not [int]::TryParse($choice, [ref]$n)) { return $null }
  if ($n -lt 1 -or $n -gt $ordered.Count) { return $null }

  return $ordered[$n - 1].Adapter
}


function Build-AdvancedPropMap {
  param([Parameter(Mandatory)][string]$AdapterName)

  $map = @{}

  if (-not (Test-CommandExists -Name 'Get-NetAdapterAdvancedProperty')) { return $map }

  try {
    $allProps = Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction Stop |
      Select-Object DisplayName, DisplayValue, RegistryKeyword, RegistryValue

    foreach ($p in $allProps) {
      $k = "$($p.RegistryKeyword)".Trim()
      if ([string]::IsNullOrWhiteSpace($k)) { continue }

      $map[$k] = [pscustomobject]@{
        Value        = (Get-ScalarRegistryValue -Value $p.RegistryValue)
        DisplayName  = $p.DisplayName
        DisplayValue = $p.DisplayValue
      }
    }
  } catch {
    # return empty
  }

  return $map
}

function Convert-ToRegistryValueType {
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $null }

  # Desired values are commonly numeric; pass int when possible.
  if ($Value -is [int] -or $Value -is [long]) { return [int]$Value }

  $s = "$Value"
  $i = $null
  if ([int]::TryParse($s, [ref]$i)) { return $i }

  return $s
}

function Set-AdvancedPropertyByKeyword {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory)][string]$AdapterName,
    [Parameter(Mandatory)][string]$RegistryKeyword,
    [Parameter(Mandatory)]$RegistryValue
  )

  if (-not (Test-CommandExists -Name 'Set-NetAdapterAdvancedProperty')) {
    throw 'Set-NetAdapterAdvancedProperty is not available on this system.'
  }

  $rv = Convert-ToRegistryValueType -Value $RegistryValue

  if ($PSCmdlet.ShouldProcess("$AdapterName / $RegistryKeyword", "Set RegistryValue=$rv")) {
    Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $RegistryKeyword -RegistryValue $rv -NoRestart -ErrorAction Stop | Out-Null
  }
}

function Restart-NetworkAdapter {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param([Parameter(Mandatory)][string]$AdapterName)

  if (-not (Test-CommandExists -Name 'Disable-NetAdapter') -or -not (Test-CommandExists -Name 'Enable-NetAdapter')) {
    throw 'Disable-NetAdapter/Enable-NetAdapter are not available on this system.'
  }

  if ($PSCmdlet.ShouldProcess($AdapterName, 'Restart network adapter (disable/enable)')) {
    Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 2
    Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop | Out-Null
  }
}

function Set-AdapterAllowPowerOff {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory)][string]$AdapterName,
    [Parameter(Mandatory)][bool]$Enabled
  )

  if (-not (Test-CommandExists -Name 'Set-NetAdapterPowerManagement')) {
    throw 'Set-NetAdapterPowerManagement is not available on this system.'
  }

  if ($PSCmdlet.ShouldProcess($AdapterName, "Set AllowComputerToTurnOffDevice=$Enabled")) {
    Set-NetAdapterPowerManagement -Name $AdapterName -AllowComputerToTurnOffDevice:$Enabled -ErrorAction Stop | Out-Null
  }
}

function Set-AdapterIPv6Binding {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory)][string]$AdapterName,
    [Parameter(Mandatory)][bool]$Enabled
  )

  if (-not (Test-CommandExists -Name 'Get-NetAdapterBinding')) {
    throw 'Get-NetAdapterBinding is not available on this system.'
  }

  $b = $null
  try {
    $b = Get-NetAdapterBinding -Name $AdapterName -ComponentID 'ms_tcpip6' -ErrorAction Stop | Select-Object -First 1
  } catch {
    $b = $null
  }

  if ($null -eq $b) {
    throw 'IPv6 binding (ms_tcpip6) could not be queried for this adapter.'
  }

  if ($Enabled) {
    if (-not (Test-CommandExists -Name 'Enable-NetAdapterBinding')) {
      throw 'Enable-NetAdapterBinding is not available on this system.'
    }
    if ($PSCmdlet.ShouldProcess($AdapterName, 'Enable IPv6 binding (ms_tcpip6)')) {
      Enable-NetAdapterBinding -Name $AdapterName -ComponentID 'ms_tcpip6' -ErrorAction Stop | Out-Null
    }
  } else {
    if (-not (Test-CommandExists -Name 'Disable-NetAdapterBinding')) {
      throw 'Disable-NetAdapterBinding is not available on this system.'
    }
    if ($PSCmdlet.ShouldProcess($AdapterName, 'Disable IPv6 binding (ms_tcpip6)')) {
      Disable-NetAdapterBinding -Name $AdapterName -ComponentID 'ms_tcpip6' -ErrorAction Stop | Out-Null
    }
  }
}

function Set-NetworkSettings {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    # Optional: explicitly choose adapter name (otherwise auto-picks primary Ethernet adapter)
    [string]$AdapterName,

    # Skip adapter restart after applying changes
    [switch]$NoRestart
  )

  if (-not (Test-CommandExists -Name 'Get-NetAdapterAdvancedProperty')) {
    throw 'NetAdapter advanced property cmdlets are not available. This function requires Windows NetAdapter cmdlets.'
  }

  $adapter = $null

  if ($AdapterName) {
    try { $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop } catch { $adapter = $null }
  }

  if (-not $adapter) {
    # Interactive selection when no adapter name is provided
    $adapter = Select-NetworkAdapterFromMenu
  }

  if (-not $adapter) {
    throw 'No network adapter selected.'
  }

  $vendor = Get-AdapterVendor -Adapter $adapter
  $spec = @(Import-NetworkBaselineSpec)
  if ($null -eq $spec -or @($spec).Count -eq 0) { throw 'Network baseline spec could not be loaded (values.ps1 missing or invalid).' }

  $propMap = Build-AdvancedPropMap -AdapterName $adapter.Name
  # Desired non-advanced settings
  $desiredAllowPowerOff = $false   # Device Manager > Power Management checkbox should be OFF
  $desiredIPv6Enabled   = $false   # IPv6 binding (ms_tcpip6) should be disabled

  $results = @()
  $changed = @()
  $alreadyOk = @()
  $failed = @()
  $skipped = @()

  foreach ($s in ($spec | Sort-Object Order)) {
    # AppliesTo filtering (only Vendor for now)
    $applies = $true
    if ($s.AppliesTo -and $s.AppliesTo.ContainsKey('Vendor')) {
      $wantVendor = "$($s.AppliesTo.Vendor)"
      if (-not [string]::IsNullOrWhiteSpace($wantVendor)) {
        $applies = ($vendor -eq $wantVendor)
      }
    }
    if (-not $applies) { continue }

    # Determine which keyword exists on this adapter
    $keywordsToTry = @()
    if (-not [string]::IsNullOrWhiteSpace($s.RegistryKeyword)) { $keywordsToTry += $s.RegistryKeyword }
    if ($s.AlternateKeywords) { $keywordsToTry += @($s.AlternateKeywords) }

    $foundKey = $null
    foreach ($k in $keywordsToTry) {
      if ([string]::IsNullOrWhiteSpace($k)) { continue }
      $kk = "$k".Trim()
      if ([string]::IsNullOrWhiteSpace($kk)) { continue }
      if ($propMap.ContainsKey($kk)) { $foundKey = $kk; break }
    }

    if ($null -eq $foundKey) {
      $skipped += $s.Name
      $results += [pscustomobject]@{ Name=$s.Name; Keyword=$null; Action='Skipped'; Reason='Property not present on adapter'; Before=$null; After=$null; Desired=@($s.DesiredValues) }
      continue
    }

    $before = $propMap[$foundKey].Value

    # Decide if already OK (any desired value matches)
    $isOk = $false
    foreach ($dv in @($s.DesiredValues)) {
      if ("$before" -eq "$dv") { $isOk = $true; break }
    }

    if ($isOk) {
      $alreadyOk += $s.Name
      $results += [pscustomobject]@{ Name=$s.Name; Keyword=$foundKey; Action='NoChange'; Reason='Already desired'; Before=$before; After=$before; Desired=@($s.DesiredValues) }
      continue
    }

    # Apply first desired value as the target
    $target = $null
    if ($s.DesiredValues -and @($s.DesiredValues).Count -gt 0) { $target = @($s.DesiredValues)[0] }

    try {
      Set-AdvancedPropertyByKeyword -AdapterName $adapter.Name -RegistryKeyword $foundKey -RegistryValue $target

      # Refresh map (no restart yet; but cmdlet may update immediately)
      $propMap = Build-AdvancedPropMap -AdapterName $adapter.Name
      $after = $null
      if ($propMap.ContainsKey($foundKey)) { $after = $propMap[$foundKey].Value }

      $changed += $s.Name
      $results += [pscustomobject]@{ Name=$s.Name; Keyword=$foundKey; Action='Changed'; Reason='Applied desired value'; Before=$before; After=$after; Desired=@($s.DesiredValues) }
    } catch {
      $failed += $s.Name
      $results += [pscustomobject]@{ Name=$s.Name; Keyword=$foundKey; Action='Failed'; Reason="$($_.Exception.Message)"; Before=$before; After=$before; Desired=@($s.DesiredValues) }
    }
  }

  # --- Power Management: Allow the computer to turn off this device to save power ---
  if (Test-CommandExists -Name 'Get-NetAdapterPowerManagement') {
    try {
      $pm = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop | Select-Object -First 1
      $before = $null
      if ($pm -and ($pm.PSObject.Properties.Name -contains 'AllowComputerToTurnOffDevice')) {
        $before = [bool]$pm.AllowComputerToTurnOffDevice
      }

      if ($null -eq $before) {
        $skipped += 'Allow computer to turn off device'
        $results += [pscustomobject]@{ Name='Allow computer to turn off device'; Keyword=$null; Action='Skipped'; Reason='Power management state not available'; Before=$null; After=$null; Desired=@('Disabled') }
      } elseif ($before -eq $desiredAllowPowerOff) {
        $alreadyOk += 'Allow computer to turn off device'
        $results += [pscustomobject]@{ Name='Allow computer to turn off device'; Keyword=$null; Action='NoChange'; Reason='Already desired'; Before=$before; After=$before; Desired=@('Disabled') }
      } else {
        try {
          Set-AdapterAllowPowerOff -AdapterName $adapter.Name -Enabled:$desiredAllowPowerOff
          $after = $null
          try {
            $pm2 = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop | Select-Object -First 1
            if ($pm2 -and ($pm2.PSObject.Properties.Name -contains 'AllowComputerToTurnOffDevice')) {
              $after = [bool]$pm2.AllowComputerToTurnOffDevice
            }
          } catch { $after = $null }

          $changed += 'Allow computer to turn off device'
          $results += [pscustomobject]@{ Name='Allow computer to turn off device'; Keyword=$null; Action='Changed'; Reason='Applied desired value'; Before=$before; After=$after; Desired=@('Disabled') }
        } catch {
          $failed += 'Allow computer to turn off device'
          $results += [pscustomobject]@{ Name='Allow computer to turn off device'; Keyword=$null; Action='Failed'; Reason="$($_.Exception.Message)"; Before=$before; After=$before; Desired=@('Disabled') }
        }
      }
    } catch {
      $failed += 'Allow computer to turn off device'
      $results += [pscustomobject]@{ Name='Allow computer to turn off device'; Keyword=$null; Action='Failed'; Reason="$($_.Exception.Message)"; Before=$null; After=$null; Desired=@('Disabled') }
    }
  } else {
    $skipped += 'Allow computer to turn off device'
    $results += [pscustomobject]@{ Name='Allow computer to turn off device'; Keyword=$null; Action='Skipped'; Reason='Get-NetAdapterPowerManagement not available'; Before=$null; After=$null; Desired=@('Disabled') }
  }

  # --- IPv6 binding (ms_tcpip6) ---
  if (Test-CommandExists -Name 'Get-NetAdapterBinding') {
    try {
      $b = Get-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop | Select-Object -First 1
      $before = $null
      if ($b -and ($b.PSObject.Properties.Name -contains 'Enabled')) {
        $before = [bool]$b.Enabled
      }

      if ($null -eq $before) {
        $skipped += 'IPv6 binding (ms_tcpip6)'
        $results += [pscustomobject]@{ Name='IPv6 binding (ms_tcpip6)'; Keyword='ms_tcpip6'; Action='Skipped'; Reason='Binding state not available'; Before=$null; After=$null; Desired=@('Disabled') }
      } elseif ($before -eq $desiredIPv6Enabled) {
        $alreadyOk += 'IPv6 binding (ms_tcpip6)'
        $results += [pscustomobject]@{ Name='IPv6 binding (ms_tcpip6)'; Keyword='ms_tcpip6'; Action='NoChange'; Reason='Already desired'; Before=$before; After=$before; Desired=@('Disabled') }
      } else {
        try {
          Set-AdapterIPv6Binding -AdapterName $adapter.Name -Enabled:$desiredIPv6Enabled
          $after = $null
          try {
            $b2 = Get-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop | Select-Object -First 1
            if ($b2 -and ($b2.PSObject.Properties.Name -contains 'Enabled')) {
              $after = [bool]$b2.Enabled
            }
          } catch { $after = $null }

          $changed += 'IPv6 binding (ms_tcpip6)'
          $results += [pscustomobject]@{ Name='IPv6 binding (ms_tcpip6)'; Keyword='ms_tcpip6'; Action='Changed'; Reason='Applied desired value'; Before=$before; After=$after; Desired=@('Disabled') }
        } catch {
          $failed += 'IPv6 binding (ms_tcpip6)'
          $results += [pscustomobject]@{ Name='IPv6 binding (ms_tcpip6)'; Keyword='ms_tcpip6'; Action='Failed'; Reason="$($_.Exception.Message)"; Before=$before; After=$before; Desired=@('Disabled') }
        }
      }
    } catch {
      $failed += 'IPv6 binding (ms_tcpip6)'
      $results += [pscustomobject]@{ Name='IPv6 binding (ms_tcpip6)'; Keyword='ms_tcpip6'; Action='Failed'; Reason="$($_.Exception.Message)"; Before=$null; After=$null; Desired=@('Disabled') }
    }
  } else {
    $skipped += 'IPv6 binding (ms_tcpip6)'
    $results += [pscustomobject]@{ Name='IPv6 binding (ms_tcpip6)'; Keyword='ms_tcpip6'; Action='Skipped'; Reason='Get-NetAdapterBinding not available'; Before=$null; After=$null; Desired=@('Disabled') }
  }

  if (-not $NoRestart -and @($changed).Count -gt 0) {
    try {
      Restart-NetworkAdapter -AdapterName $adapter.Name
    } catch {
      # Record restart failure but do not throw
      $results += [pscustomobject]@{ Name='AdapterRestart'; Keyword=$null; Action='Failed'; Reason="$($_.Exception.Message)"; Before=$null; After=$null; Desired=@() }
    }
  }

  return [pscustomobject]@{
    Timestamp    = (Get-Date)
    ComputerName = $env:COMPUTERNAME
    Adapter      = [pscustomobject]@{
      Name                 = $adapter.Name
      InterfaceDescription = $adapter.InterfaceDescription
      Vendor               = $vendor
      LinkSpeed            = $adapter.LinkSpeed
    }
    Summary      = [pscustomobject]@{
      Changed   = $changed
      AlreadyOk = $alreadyOk
      Failed    = $failed
      Skipped   = $skipped
    }
    Results      = $results
  }
}

# If executed directly (not dot-sourced), prompt for adapter and apply settings.
if ($MyInvocation.InvocationName -ne '.') {
  try {
    Set-NetworkSettings
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host 'Press Enter to exit'
  }
}