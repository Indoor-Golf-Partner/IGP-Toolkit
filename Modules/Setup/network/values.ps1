

<#
.SYNOPSIS
  Network baseline specification for IGP Toolkit.

.DESCRIPTION
  This file contains a reusable, language-independent lookup table used by:
    - Setup Overview (status/report)
    - Network baseline apply/remediation (later)

  IMPORTANT:
    - Do NOT compare on DisplayName/DisplayValue (they are localized).
    - Compare on RegistryKeyword + RegistryValue instead.

  Data model per entry:
    Name             : Friendly label shown in output
    Category         : Grouping label (e.g. Network)
    RegistryKeyword  : Primary NIC advanced property keyword (e.g. *EEE)
    AlternateKeywords: Optional list of alternate keywords for other vendors/drivers
    DesiredValues    : Array of allowed desired registry values (numbers or strings)
    Severity         : Info | Warn | Error
    AppliesTo        : Hashtable filters (e.g. Vendor='Realtek')
    Remediation      : Human hint for how to fix
    Notes            : Rationale / context
    Order            : Sort order in reports

.NOTES
  PowerShell: Windows PowerShell 5.1 compatible.
#>

function Get-IGPNetworkBaselineSpec {
  <#
    Returns an array of baseline spec objects.

    Extend by adding more [pscustomobject] entries.
    Keep DesiredValues as an ARRAY even if only one value is allowed.
  #>

  $spec = @()

  # --- Realtek (2.5GbE Family Controller) baseline ---
  # Values below were observed on Realtek Gaming 2.5GbE Family Controller.
  # Different vendors/drivers may use different RegistryKeyword names and/or values.

  $spec += [pscustomobject]@{
    Name              = 'Energy Efficient Ethernet (EEE)'
    Category          = 'Network'
    RegistryKeyword   = '*EEE'
    AlternateKeywords = @('AdvancedEEE','EEE')
    DesiredValues     = @(0)      # 0 = disabled
    Severity          = 'Error'
    AppliesTo         = @{ Vendor = 'Realtek' }
    Remediation       = 'Disable EEE in NIC advanced properties.'
    Notes             = 'EEE can cause link stability/latency issues in some environments.'
    Order             = 10
  }

  $spec += [pscustomobject]@{
    Name              = 'Green Ethernet'
    Category          = 'Network'
    RegistryKeyword   = 'EnableGreenEthernet'
    AlternateKeywords = @('GreenEthernet','*GreenEthernet')
    DesiredValues     = @(0)      # 0 = disabled, 1 = enabled
    Severity          = 'Error'
    AppliesTo         = @{ Vendor = 'Realtek' }
    Remediation       = 'Disable Green Ethernet in NIC advanced properties.'
    Notes             = 'Power-saving features may reduce link reliability/performance.'
    Order             = 20
  }

  $spec += [pscustomobject]@{
    Name              = 'Power Saving Mode'
    Category          = 'Network'
    RegistryKeyword   = 'PowerSavingMode'
    AlternateKeywords = @('*PowerSavingMode')
    DesiredValues     = @(0)      # 0 = disabled, 1 = enabled
    Severity          = 'Error'
    AppliesTo         = @{ Vendor = 'Realtek' }
    Remediation       = 'Disable Power Saving Mode in NIC advanced properties.'
    Notes             = 'If enabled, may cause intermittent issues after sleep/reboots or reduced throughput.'
    Order             = 30
  }

  $spec += [pscustomobject]@{
    Name              = 'Jumbo Frame'
    Category          = 'Network'
    RegistryKeyword   = '*JumboPacket'
    AlternateKeywords = @('JumboPacket','Jumbo Frame','Jumbo Frames')
    DesiredValues     = @(1514)   # Realtek uses 1514 for "disabled" (standard frame size)
    Severity          = 'Warn'
    AppliesTo         = @{ Vendor = 'Realtek' }
    Remediation       = 'Keep Jumbo Frame disabled unless the entire network path supports jumbo MTU.'
    Notes             = 'Jumbo frames require end-to-end support (switches/uplinks/VLAN path).' 
    Order             = 40
  }

  $spec += [pscustomobject]@{
    Name              = 'Speed & Duplex'
    Category          = 'Network'
    RegistryKeyword   = '*SpeedDuplex'
    AlternateKeywords = @('SpeedDuplex')
    DesiredValues     = @(0)      # 0 = Auto Negotiation on observed Realtek driver
    Severity          = 'Warn'
    AppliesTo         = @{ Vendor = 'Realtek' }
    Remediation       = 'Policy decision: allow Auto, or force 1.0 Gbps Full Duplex if needed for stability.'
    Notes             = 'Value mapping is driver-specific; confirm numeric mapping before enforcing forced speed.'
    Order             = 50
  }

  $spec += [pscustomobject]@{
    Name              = 'Interrupt Moderation'
    Category          = 'Network'
    RegistryKeyword   = '*InterruptModeration'
    AlternateKeywords = @('InterruptModeration')
    DesiredValues     = @(1)      # 1 = enabled on observed driver
    Severity          = 'Info'
    AppliesTo         = @{ Vendor = 'Realtek' }
    Remediation       = 'Enable Interrupt Moderation (usually default).'
    Notes             = 'May reduce CPU load; environment-dependent.'
    Order             = 60
  }

  $spec += [pscustomobject]@{
    Name              = 'Receive Side Scaling (RSS)'
    Category          = 'Network'
    RegistryKeyword   = '*RSS'
    AlternateKeywords = @('*Rsc','ReceiveSideScaling','*ReceiveSideScaling')
    DesiredValues     = @(1)      # Commonly 1 = enabled
    Severity          = 'Info'
    AppliesTo         = @{ Vendor = 'Realtek' }
    Remediation       = 'Enable RSS (usually default).'
    Notes             = 'Keyword/value can vary; confirm on target NIC model if RSS appears mismatched.'
    Order             = 70
  }

  # --- Generic / cross-vendor placeholders ---
  # Add Intel/Marvell/etc. baselines here later using their RegistryKeyword/value mappings.

  return $spec
}

# Note: This file is usually dot-sourced by other modules.
# It intentionally does not auto-execute.