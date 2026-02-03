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
    Interactive adapter picker. Returns the selected NetAdapter object or $null if cancelled.
  #>

  $adapters = @(Get-EligibleEthernetAdapters)

  if ($null -eq $adapters -or @($adapters).Count -eq 0) {
    Write-Host "No eligible Ethernet adapters found." -ForegroundColor Yellow
    return $null
  }

  Write-Host "Select network adapter to apply IGP baseline settings:" -ForegroundColor Cyan
  Write-Host ""

  for ($i = 0; $i -lt @($adapters).Count; $i++) {
    $a = $adapters[$i]
    $v = Get-AdapterVendor -Adapter $a
    $label = Format-AdapterLabel -Adapter $a -Vendor $v
    Write-Host ("[{0}] {1}" -f ($i + 1), $label)
  }

  Write-Host ""
  Write-Host "[Q] Cancel" -ForegroundColor DarkGray

  while ($true) {
    $choice = Read-Host "Enter selection"

    if ([string]::IsNullOrWhiteSpace($choice)) { continue }

    if ($choice -match '^(?i)q$') {
      return $null
    }

    $n = $null
    if ([int]::TryParse($choice, [ref]$n)) {
      if ($n -ge 1 -and $n -le @($adapters).Count) {
        return $adapters[$n - 1]
      }
    }

    Write-Host "Invalid selection. Try again." -ForegroundColor Yellow
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