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
  [switch]$AsJson,

  # Show the raw list of ALL advanced properties after the baseline report
  [switch]$ShowAllProperties
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

function Get-ScalarRegistryValue {
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $null }

  # RegistryValue is often a single-element array printed like {1}
  if ($Value -is [System.Array]) {
    if ($Value.Length -gt 0) { return $Value[0] }
    return $null
  }

  return $Value
}

function Get-ValueLabel {
  param(
    [Parameter(Mandatory)]$Spec,
    [AllowNull()]$Value
  )

  if ($null -eq $Value) { return $null }

  if ($Spec -and $Spec.PSObject.Properties.Name -contains 'ValueNames' -and $Spec.ValueNames) {
    try {
      # Hashtable keys may be int or string; try both.
      if ($Spec.ValueNames.ContainsKey($Value)) {
        return "$($Spec.ValueNames[$Value])"
      }

      $sv = "$Value"
      if ($Spec.ValueNames.ContainsKey($sv)) {
        return "$($Spec.ValueNames[$sv])"
      }

      # Try numeric conversion if the value is a string.
      $iv = $null
      if ([int]::TryParse($sv, [ref]$iv)) {
        if ($Spec.ValueNames.ContainsKey($iv)) {
          return "$($Spec.ValueNames[$iv])"
        }
      }
    } catch {
      # ignore
    }
  }

  return $null
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

  # Prefer $PSScriptRoot for script-relative paths (works when dot-sourced)
  $thisDir = $PSScriptRoot

  if ([string]::IsNullOrWhiteSpace($thisDir)) {
    $path = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($path)) { return @() }
    $thisDir = Split-Path -Parent $path
  }

  $specPath = Join-Path $thisDir 'network\values.ps1'

  if (-not (Test-Path -LiteralPath $specPath)) { return @() }

  try {
    . $specPath
  } catch {
    return @()
  }

  $cmd = Get-Command Get-IGPNetworkBaselineSpec -ErrorAction SilentlyContinue
  if (-not $cmd) { return @() }

  try {
    return @(Get-IGPNetworkBaselineSpec)
  } catch {
    return @()
  }
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

  $vendor = Get-AdapterVendor -Adapter $adapter
  $baselineSpec = Import-NetworkBaselineSpec

  # Build a map: keyword -> { Value, DisplayName, DisplayValue }
  $propMap = @{}

  # Collect ALL advanced NIC properties (language-independent fields included)
  $allProps = @()

  if (Test-CommandExists -Name 'Get-NetAdapterAdvancedProperty') {
    try {
      $allProps = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop |
        Select-Object DisplayName, DisplayValue, RegistryKeyword, RegistryValue

      foreach ($p in $allProps) {
        $k = $p.RegistryKeyword
        if ([string]::IsNullOrWhiteSpace($k)) { continue }

        $propMap[$k] = [pscustomobject]@{
          Value        = (Get-ScalarRegistryValue -Value $p.RegistryValue)
          DisplayName  = $p.DisplayName
          DisplayValue = $p.DisplayValue
        }
      }
    } catch {
      $allProps = @()
    }
  }

  $ipv6Enabled = Get-NetBindingState -AdapterName $adapter.Name -ComponentId 'ms_tcpip6'

  $baselineReport = @()

  foreach ($s in ($baselineSpec | Sort-Object Order)) {
    # AppliesTo filtering (only Vendor for now)
    $applies = $true
    if ($s.AppliesTo -and $s.AppliesTo.ContainsKey('Vendor')) {
      $wantVendor = "$($s.AppliesTo.Vendor)"
      if (-not [string]::IsNullOrWhiteSpace($wantVendor)) {
        $applies = ($vendor -eq $wantVendor)
      }
    }
    if (-not $applies) { continue }

    $keywordsToTry = @()
    if (-not [string]::IsNullOrWhiteSpace($s.RegistryKeyword)) { $keywordsToTry += $s.RegistryKeyword }
    if ($s.AlternateKeywords) { $keywordsToTry += @($s.AlternateKeywords) }

    $foundKey = $null
    $actual = $null

    foreach ($k in $keywordsToTry) {
      if ([string]::IsNullOrWhiteSpace($k)) { continue }
      if ($propMap.ContainsKey($k)) {
        $foundKey = $k
        $actual = $propMap[$k].Value
        break
      }
    }

    $status = 'Unknown'

    # Build desired text as human-readable labels (fallback to raw if no label)
    $desiredParts = @()
    foreach ($dv in @($s.DesiredValues)) {
      $lbl = Get-ValueLabel -Spec $s -Value $dv
      if ([string]::IsNullOrWhiteSpace($lbl)) {
        $desiredParts += "$dv"
      } else {
        $desiredParts += $lbl
      }
    }
    $desiredText = ($desiredParts -join ' | ')

    if ($null -ne $foundKey) {
      if ($null -eq $actual) {
        $status = 'Unknown'
      } else {
        $ok = $false
        foreach ($dv in @($s.DesiredValues)) {
          if ("$actual" -eq "$dv") { $ok = $true; break }
        }
        if ($ok) { $status = 'OK' } else { $status = 'Mismatch' }
      }
    }

    # Build actual text as human-readable label (fallback to raw if no label)
    $actualLabel = Get-ValueLabel -Spec $s -Value $actual
    $actualText = ''
    if ($null -eq $actual) {
      $actualText = ''
    } elseif ([string]::IsNullOrWhiteSpace($actualLabel)) {
      $actualText = "$actual"
    } else {
      $actualText = $actualLabel
    }

    $statusIcon = '❓'
    if ($status -eq 'OK') { $statusIcon = '✅' }
    elseif ($status -eq 'Mismatch') { $statusIcon = '❌' }

    $baselineReport += [pscustomobject]@{
      Order    = $s.Order
      Name     = $s.Name
      Status   = $statusIcon
      Value    = $actualText
      Desired  = $desiredText
      Notes    = $s.Notes
      Remedy   = $s.Remediation
    }
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
      Vendor = $vendor
      BaselineSpecLoaded = [bool]($baselineSpec -and $baselineSpec.Count -gt 0)
      BaselineReport = $baselineReport
      IPv6Enabled = $ipv6Enabled
      AdvancedProperties = $allProps
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
  Write-Host "Vendor: $($o.Network.Vendor)"
  Write-Host "Baseline spec loaded: $($o.Network.BaselineSpecLoaded)"
  Write-Host "IPv6 Enabled: $($o.Network.IPv6Enabled)"
  Write-Host ""

  if ($o.Network.BaselineReport -and $o.Network.BaselineReport.Count -gt 0) {
    $o.Network.BaselineReport |
      Sort-Object Order |
      Select-Object Name, Value, Desired, Status |
      Format-Table -AutoSize

    Write-Host ""
  } else {
    Write-Host "No baseline report entries (spec missing or no applicable entries)." -ForegroundColor Yellow
    Write-Host ""
  }

  if (-not $ShowAllProperties) {
    return
  }

  if (-not $o.Network.AdvancedProperties -or $o.Network.AdvancedProperties.Count -eq 0) {
    Write-Host "No advanced adapter properties found." -ForegroundColor Yellow
    return
  }

  Write-Host "All advanced NIC properties:" -ForegroundColor Cyan
  $o.Network.AdvancedProperties |
    Sort-Object DisplayName |
    Format-Table DisplayName, DisplayValue, RegistryKeyword, RegistryValue -AutoSize
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
