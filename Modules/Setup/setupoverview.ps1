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
param()

Set-StrictMode -Version Latest

$networkStatusPath = Join-Path $PSScriptRoot 'network\status.ps1'
if (-not (Test-Path -LiteralPath $networkStatusPath)) {
  throw "Missing module dependency: $networkStatusPath"
}
. $networkStatusPath

function Get-ConfirmText {
@"
This module ONLY reads settings and reports their current status.
No changes will be made.

Do you want to continue?
"@
}

function RunModule {
  Show-NetworkStatus
}

# If executed directly (not dot-sourced), run the module.
if ($MyInvocation.InvocationName -ne '.') {
  RunModule
}
