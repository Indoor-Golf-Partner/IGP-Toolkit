

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

  if (-not $all -or $all.Count -eq 0) { return $null }

  $exact = $all | Where-Object { $_.Name -eq 'Ethernet' } | Select-Object -First 1
  if ($exact) { return $exact }

  $up = $all | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property ifIndex | Select-Object -First 1
  if ($up) { return $up }

  return ($all | Sort-Object -Property ifIndex | Select-Object -First 1)
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
  if (-not $adapter) { $adapter = Get-PrimaryEthernetAdapter }
  if (-not $adapter) { throw 'No suitable physical network adapter found.' }

  $vendor = Get-AdapterVendor -Adapter $adapter
  $spec = Import-NetworkBaselineSpec
  if (-not $spec -or $spec.Count -eq 0) { throw 'Network baseline spec could not be loaded (values.ps1 missing or invalid).' }

  $propMap = Build-AdvancedPropMap -AdapterName $adapter.Name

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

  if (-not $NoRestart -and $changed.Count -gt 0) {
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