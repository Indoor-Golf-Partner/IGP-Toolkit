Set-StrictMode -Version Latest

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

  $specPath = Join-Path $thisDir 'values.ps1'
  if (-not (Test-Path -LiteralPath $specPath)) { return @() }

  try { . $specPath } catch { return @() }

  $cmd = Get-Command Get-IGPNetworkBaselineSpec -ErrorAction SilentlyContinue
  if (-not $cmd) { return @() }

  try { return @(Get-IGPNetworkBaselineSpec) } catch { return @() }
}

function Get-PrimaryEthernetAdapter {
  <#
    Returns the "best" Ethernet adapter candidate:
    1) If a net adapter named "Ethernet" exists, use it.
    2) Else prefer adapters that are Up.
    3) Else pick the lowest ifIndex.
  #>

  if (-not (Test-CommandExists -Name 'Get-NetAdapter')) { return $null }

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

  if (-not (Test-CommandExists -Name 'Get-NetAdapterAdvancedProperty')) { return $null }

  foreach ($dn in $DisplayNames) {
    try {
      $p = Get-NetAdapterAdvancedProperty -InterfaceDescription $InterfaceDescription -DisplayName $dn -ErrorAction Stop
      if ($p) {
        return [pscustomobject]@{
          DisplayName     = $p.DisplayName
          DisplayValue    = $p.DisplayValue
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

  if (-not (Test-CommandExists -Name 'Get-NetAdapterBinding')) { return $null }

  try {
    $b = Get-NetAdapterBinding -Name $AdapterName -ComponentID $ComponentId -ErrorAction Stop
    return [bool]$b.Enabled
  } catch {
    return $null
  }
}

function Get-NetworkStatus {
  [CmdletBinding()]
  param(
    [string]$AdapterName
  )

  $adapter = $null

  if (-not (Test-CommandExists -Name 'Get-NetAdapter')) {
    return [pscustomobject]@{
      Timestamp    = (Get-Date)
      ComputerName = $env:COMPUTERNAME
      Network      = [pscustomobject]@{ Available = $false; Reason = 'NetAdapter cmdlets not available' }
    }
  }

  if ($AdapterName) {
    try { $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop } catch { $adapter = $null }
  }
  if (-not $adapter) { $adapter = Get-PrimaryEthernetAdapter }

  if (-not $adapter) {
    return [pscustomobject]@{
      Timestamp    = (Get-Date)
      ComputerName = $env:COMPUTERNAME
      Network      = [pscustomobject]@{ Available = $false; Reason = 'No suitable physical adapter found' }
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
        $k = "$($p.RegistryKeyword)".Trim()
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
      $kk = "$k".Trim()
      if ([string]::IsNullOrWhiteSpace($kk)) { continue }

      if ($propMap.ContainsKey($kk)) {
        $foundKey = $kk
        $actual = $propMap[$kk].Value
        break
      }
    }

    $status = 'Unknown'

    # Desired value: human-readable labels (fallback to raw if no label)
    $desiredParts = @()
    foreach ($dv in @($s.DesiredValues)) {
      $lbl = Get-ValueLabel -Spec $s -Value $dv
      if ([string]::IsNullOrWhiteSpace($lbl)) { $desiredParts += "$dv" }
      else { $desiredParts += $lbl }
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

    # Actual value: human-readable label (fallback to raw if no label)
    $actualLabel = Get-ValueLabel -Spec $s -Value $actual
    $actualText = ''
    if ($null -eq $actual) { $actualText = '' }
    elseif ([string]::IsNullOrWhiteSpace($actualLabel)) { $actualText = "$actual" }
    else { $actualText = $actualLabel }

    $statusText = 'UNKNOWN'
    if ($status -eq 'OK') { $statusText = 'OK' }
    elseif ($status -eq 'Mismatch') { $statusText = 'NOT OK' }

    $baselineReport += [pscustomobject]@{
      Order   = $s.Order
      Name    = $s.Name
      Status  = $statusText
      Value   = $actualText
      Desired = $desiredText
      Notes   = $s.Notes
      Remedy  = $s.Remediation
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
      Vendor             = $vendor
      BaselineSpecLoaded = [bool]($baselineSpec -and $baselineSpec.Count -gt 0)
      BaselineReport     = $baselineReport
      IPv6Enabled        = $ipv6Enabled
      AdvancedProperties = $allProps
    }
  }
}

function Show-NetworkStatus {
  [CmdletBinding()]
  param()

  # Defaults for now (wrapper does not pass parameters)
  $showAllProperties = $false

  $o = Get-NetworkStatus

  if (-not $o.Network.Available) {
    Write-Host "[IGP] Network status: not available: $($o.Network.Reason)" -ForegroundColor Yellow
    return
  }

  Write-Host "[IGP] Network status: $($o.ComputerName) @ $($o.Timestamp)"
  Write-Host "Adapter: $($o.Network.Adapter.Name) | $($o.Network.Adapter.InterfaceDescription) | $($o.Network.Adapter.Status) | $($o.Network.Adapter.LinkSpeed)"
  Write-Host "Vendor: $($o.Network.Vendor)"
  Write-Host "Baseline spec loaded: $($o.Network.BaselineSpecLoaded)"
  Write-Host "IPv6 Enabled: $($o.Network.IPv6Enabled)"
  Write-Host ""

  if ($o.Network.BaselineReport -and $o.Network.BaselineReport.Count -gt 0) {
    $o.Network.BaselineReport |
      Sort-Object Order |
      Select-Object Name, Value, @{Name='Desired value';Expression={$_.Desired}}, Status |
      Format-Table -AutoSize

    Write-Host ""
  } else {
    Write-Host "No baseline report entries (spec missing or no applicable entries)." -ForegroundColor Yellow
    Write-Host ""
  }

  if (-not $showAllProperties) { return }

  if (-not $o.Network.AdvancedProperties -or $o.Network.AdvancedProperties.Count -eq 0) {
    Write-Host "No advanced adapter properties found." -ForegroundColor Yellow
    return
  }

  Write-Host "All advanced NIC properties:" -ForegroundColor Cyan
  $o.Network.AdvancedProperties |
    Sort-Object DisplayName |
    Format-Table DisplayName, DisplayValue, RegistryKeyword, RegistryValue -AutoSize
}