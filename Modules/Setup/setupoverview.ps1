<#
.SYNOPSIS
  Overview/status checks for IGP Windows Baseline settings.

.DESCRIPTION
  This script is meant to be called from the IGP-Toolkit baseline flow.
  It DOES NOT change any settings; it only reports current status.

  Start small: network adapter/binding/advanced NIC properties.
  We'll add more checks later (power plan, BGInfo, scheduled tasks, etc.).

.NOTES
  Author: IGP
#>


 
[CmdletBinding()]
param(
  # Optional: explicitly choose adapter name (otherwise auto-picks primary Ethernet adapter)
  [string]$AdapterName,

  # Output JSON instead of a formatted table
  [switch]$AsJson
)

Set-StrictMode -Version Latest

function Get-ConfirmText {
@"
This module ONLY reads settings and reports their current status.
No changes will be made.

Do you want to continue?
"@
}

function Test-CommandExists {
  param([Parameter(Mandatory)][string]$Name)
  return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-PrimaryEthernetAdapter {
  <#
    Returns the "best" Ethernet adapter candidate:
    1) If a net adapter named "Ethernet" exists, use it.
    2) Else prefer adapters that are Up.
    3) Else pick the lowest ifIndex.
  #>

  if (-not (Test-CommandExists -Name 'Get-NetAdapter')) {
    return $null
  }

  try {
    $all = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
      $_.Status -ne 'Disabled' -and $_.HardwareInterface -eq $true
    }
  } catch {
    return $null
  }

  if (-not $all -or $all.Count -eq 0) { return $null }

  $exact = $all | Where-Object { $_.Name -eq 'Ethernet' } | Select-Object -First 1
  if ($exact) { return $exact }

  $up = $all | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property ifIndex | Select-Object -First 1
  if ($up) { return $up }

  return ($all | Sort-Object -Property ifIndex | Select-Object -First 1)
}

function Get-NicAdvancedPropertyValue {
  param(
    [Parameter(Mandatory)][string]$InterfaceDescription,
    [Parameter(Mandatory)][string[]]$DisplayNames
  )

  if (-not (Test-CommandExists -Name 'Get-NetAdapterAdvancedProperty')) {
    return $null
  }

  foreach ($dn in $DisplayNames) {
    try {
      $p = Get-NetAdapterAdvancedProperty -InterfaceDescription $InterfaceDescription -DisplayName $dn -ErrorAction Stop
      if ($p) {
        return [pscustomobject]@{
          DisplayName  = $p.DisplayName
          DisplayValue = $p.DisplayValue
          RegistryKeyword = $p.RegistryKeyword
          RegistryValue   = $p.RegistryValue
        }
      }
    } catch {
      # continue
    }
  }

  return $null
}

function Get-NetBindingState {
  param(
    [Parameter(Mandatory)][string]$AdapterName,
    [Parameter(Mandatory)][string]$ComponentId
  )

  if (-not (Test-CommandExists -Name 'Get-NetAdapterBinding')) {
    return $null
  }

  try {
    $b = Get-NetAdapterBinding -Name $AdapterName -ComponentID $ComponentId -ErrorAction Stop
    return [bool]$b.Enabled
  } catch {
    return $null
  }
}

function Get-JumboPacketStatus {
  param([Parameter(Mandatory)][string]$InterfaceDescription)

  # Jumbo Packet can be called many things; we try a few.
  $prop = Get-NicAdvancedPropertyValue -InterfaceDescription $InterfaceDescription -DisplayNames @(
    'Jumbo Packet',
    'Jumbo Frame',
    'Jumbo Frames'
  )

  if (-not $prop) {
    return [pscustomobject]@{ Present = $false; Value = $null; DisplayName = $null }
  }

  return [pscustomobject]@{ Present = $true; Value = $prop.DisplayValue; DisplayName = $prop.DisplayName }
}

function Compare-Desired {
  param(
    [Parameter(Mandatory)][AllowNull()]$Actual,
    [Parameter(Mandatory)][AllowNull()]$Desired
  )

  if ($null -eq $Actual) {
    return [pscustomobject]@{ Status = 'Unknown'; Actual = $null; Desired = $Desired }
  }

  $ok = $false

  # Allow list of desired values
  if ($Desired -is [System.Collections.IEnumerable] -and -not ($Desired -is [string])) {
    foreach ($d in $Desired) {
      if ("$Actual" -eq "$d") { $ok = $true; break }
    }
  } else {
    $ok = ("$Actual" -eq "$Desired")
  }

  $status = if ($ok) { 'OK' } else { 'Mismatch' }

  return [pscustomobject]@{
    Status  = $status
    Actual  = $Actual
    Desired = $Desired
  }
}

function Get-IGPSetupOverview {
  [CmdletBinding()]
  param(
    # If you run this remotely, you may want to check a specific adapter
    [string]$AdapterName
  )

  $adapter = $null

  if (-not (Test-CommandExists -Name 'Get-NetAdapter')) {
    return [pscustomobject]@{
      Timestamp = (Get-Date)
      ComputerName = $env:COMPUTERNAME
      Network = [pscustomobject]@{ Available = $false; Reason = 'NetAdapter cmdlets not available' }
    }
  }

  if ($AdapterName) {
    try { $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop } catch { $adapter = $null }
  }
  if (-not $adapter) {
    $adapter = Get-PrimaryEthernetAdapter
  }

  if (-not $adapter) {
    return [pscustomobject]@{
      Timestamp = (Get-Date)
      ComputerName = $env:COMPUTERNAME
      Network = [pscustomobject]@{ Available = $false; Reason = 'No suitable physical adapter found' }
    }
  }

  # Desired baselines for now (we can extend later)
  # Note: values differ by driver; we allow multiple accepted strings.
  $desired = @{
    SpeedDuplex = @(
      '1.0 Gbps Full Duplex',
      '1.0Gbps Full Duplex',
      '1.0 Gbps Full',
      '1 Gbps Full Duplex',
      'Auto Negotiation' # keep as allowed if you decide to not force 1G
    )
    EnergyEfficientEthernet = @('Disabled','Off')
    GreenEthernet           = @('Disabled','Off')
    PowerSavingMode         = @('Disabled','Off')
    InterruptModeration     = @('Enabled','On')
    ReceiveSideScaling      = @('Enabled','On')
    # Jumbo is site/profile-dependent; treat "Unknown" as acceptable for now.
  }

  $ifaceDesc = $adapter.InterfaceDescription

  $speed = Get-NicAdvancedPropertyValue -InterfaceDescription $ifaceDesc -DisplayNames @(
    'Speed & Duplex',
    'Speed and Duplex'
  )

  $eee = Get-NicAdvancedPropertyValue -InterfaceDescription $ifaceDesc -DisplayNames @(
    'Energy Efficient Ethernet',
    'EEE'
  )

  $green = Get-NicAdvancedPropertyValue -InterfaceDescription $ifaceDesc -DisplayNames @(
    'Green Ethernet'
  )

  $psm = Get-NicAdvancedPropertyValue -InterfaceDescription $ifaceDesc -DisplayNames @(
    'Power Saving Mode',
    'Power Saving'
  )

  $im = Get-NicAdvancedPropertyValue -InterfaceDescription $ifaceDesc -DisplayNames @(
    'Interrupt Moderation'
  )

  $rss = Get-NicAdvancedPropertyValue -InterfaceDescription $ifaceDesc -DisplayNames @(
    'Receive Side Scaling',
    'Receive Side Scaling (RSS)'
  )

  $jumbo = Get-JumboPacketStatus -InterfaceDescription $ifaceDesc

  $ipv6Enabled = Get-NetBindingState -AdapterName $adapter.Name -ComponentId 'ms_tcpip6'

  $checks = [ordered]@{}

  $speedVal = if ($null -ne $speed) { $speed.DisplayValue } else { $null }
  $eeeVal   = if ($null -ne $eee)   { $eee.DisplayValue }   else { $null }
  $greenVal = if ($null -ne $green) { $green.DisplayValue } else { $null }
  $psmVal   = if ($null -ne $psm)   { $psm.DisplayValue }   else { $null }
  $imVal    = if ($null -ne $im)    { $im.DisplayValue }    else { $null }
  $rssVal   = if ($null -ne $rss)   { $rss.DisplayValue }   else { $null }

  $checks['Speed & Duplex'] = Compare-Desired -Actual $speedVal -Desired $desired.SpeedDuplex
  $checks['Energy Efficient Ethernet'] = Compare-Desired -Actual $eeeVal -Desired $desired.EnergyEfficientEthernet
  $checks['Green Ethernet'] = Compare-Desired -Actual $greenVal -Desired $desired.GreenEthernet
  $checks['Power Saving Mode'] = Compare-Desired -Actual $psmVal -Desired $desired.PowerSavingMode
  $checks['Interrupt Moderation'] = Compare-Desired -Actual $imVal -Desired $desired.InterruptModeration
  $checks['Receive Side Scaling'] = Compare-Desired -Actual $rssVal -Desired $desired.ReceiveSideScaling

  # IPv6 baseline depends on your stance. Here we just report state.
  $ipv6Status = if ($null -eq $ipv6Enabled) {
    'Unknown'
  } elseif ($ipv6Enabled -eq $true) {
    'Enabled'
  } else {
    'Disabled'
  }

  $checks['IPv6 Binding (ms_tcpip6)'] = [pscustomobject]@{
    Status  = $ipv6Status
    Actual  = $ipv6Enabled
    Desired = $null
  }

  # Jumbo frame: report only (profile-based)
  $jumboStatus = if ($jumbo.Present) { 'Present' } else { 'NotPresent' }

  $checks['Jumbo Packet'] = [pscustomobject]@{
    Status  = $jumboStatus
    Actual  = $jumbo.Value
    Desired = $null
  }

  return [pscustomobject]@{
    Timestamp    = (Get-Date)
    ComputerName = $env:COMPUTERNAME
    Network      = [pscustomobject]@{
      Available = $true
      Adapter   = [pscustomobject]@{
        Name                 = $adapter.Name
        InterfaceDescription = $adapter.InterfaceDescription
        Status               = $adapter.Status
        LinkSpeed            = $adapter.LinkSpeed
        MacAddress           = $adapter.MacAddress
        ifIndex              = $adapter.ifIndex
      }
      Checks = [pscustomobject]$checks
    }
  }
}

function Show-IGPSetupOverview {
  [CmdletBinding()]
  param(
    [string]$AdapterName,
    [switch]$AsJson
  )

  $o = Get-IGPSetupOverview -AdapterName $AdapterName

  if ($AsJson) {
    $o | ConvertTo-Json -Depth 8
    return
  }

  if (-not $o.Network.Available) {
    Write-Host "[IGP] Setup overview: network checks not available: $($o.Network.Reason)" -ForegroundColor Yellow
    return
  }

  Write-Host "[IGP] Setup overview: $($o.ComputerName) @ $($o.Timestamp)" 
  Write-Host "Adapter: $($o.Network.Adapter.Name) | $($o.Network.Adapter.InterfaceDescription) | $($o.Network.Adapter.Status) | $($o.Network.Adapter.LinkSpeed)"
  Write-Host ""

  $rows = foreach ($k in $o.Network.Checks.PSObject.Properties.Name) {
    $c = $o.Network.Checks.$k
    [pscustomobject]@{
      Setting = $k
      Status  = $c.Status
      Actual  = $c.Actual
      Desired = if ($null -eq $c.Desired) { '' } elseif ($c.Desired -is [System.Collections.IEnumerable] -and -not ($c.Desired -is [string])) { ($c.Desired -join ' | ') } else { $c.Desired }
    }
  }

  $rows | Format-Table -AutoSize
}


function RunModule {
  if ($AsJson) {
    Show-IGPSetupOverview -AdapterName $AdapterName -AsJson
  } else {
    Show-IGPSetupOverview -AdapterName $AdapterName
  }
}

# If executed directly (not dot-sourced), run the module.
if ($MyInvocation.InvocationName -ne '.') {
  RunModule
}
