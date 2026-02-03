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

$networkSetupPath = Join-Path $PSScriptRoot 'network\setup.ps1'
if (-not (Test-Path -LiteralPath $networkSetupPath)) {
  throw "Missing module dependency: $networkSetupPath"
}
. $networkSetupPath

function Get-ConfirmText {
@"
This module ONLY reads settings and reports their current status.
No changes will be made.

Do you want to continue?
"@
}

function RunModule {
  #Show the menu
  while ($true) {
        Clear-Host
        Show-NetworkStatus
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        switch ($choice) {
            '1' {
                try {
                    Set-NetworkSettings
                }
                catch {
                    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
                }
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            default {
                Write-Host 'Invalid selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host "Setup Overview"
    Write-Host "--------------"
    Write-Host "  1) Update Network Settings "
    Write-Host "  Q) Back"
    Write-Host ""

    return (Read-Host 'Select an option')
}

# If executed directly (not dot-sourced), run the module.
if ($MyInvocation.InvocationName -ne '.') {
  RunModule
}