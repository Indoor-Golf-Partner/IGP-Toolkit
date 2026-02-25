<#
.SYNOPSIS
    IGP Toolkit module template.

.DESCRIPTION
    Copy this file when creating a new module. Fill in ModuleName and implement
    functions as needed. Mandatory functions: Get-ConfirmText, RunModule.

.NOTES
    Keep structure consistent across modules.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module identity
$script:ModuleName    = 'Template Module'
$script:RequiresAdmin = $false

#region Confirm Text (Mandatory)
function Get-ConfirmText {
    return @"
$script:ModuleName

This module does:
- (describe what it does)

It may change:
- (settings/files)

Press Y to continue.
"@
}
#endregion Confirm Text

#region Logging (Optional)
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string] $Level = 'INFO'
    )

    # Placeholder: replace with your preferred logging later
    Write-Host "[$Level] $Message"
}
#endregion Logging

#region Helpers (Optional)
function Test-IsAdmin {
    # Placeholder helper; implement if needed
    return $true
}

function Pause-Continue {
    Read-Host 'Press Enter to continue...' | Out-Null
}
#endregion Helpers

#region Operations (Optional)
function Invoke-ModuleOperation {
    # Placeholder for the module’s main work
    Write-Log "Operation not implemented yet." 'WARN'
}
#endregion Operations

#region Menu (Optional)
function Show-Menu {
    Clear-Host
    Write-Host $script:ModuleName
    Write-Host "1) Run"
    Write-Host "Q) Back"
}
#endregion Menu

#region Entry Point (Mandatory)
function RunModule {
    # Keep all execution inside this function

    # Optional admin gate (only if needed)
    if ($script:RequiresAdmin -and -not (Test-IsAdmin)) {
        Write-Log "Admin rights required to run $script:ModuleName." 'ERROR'
        Pause-Continue
        return
    }

    # Placeholder: interactive loop (remove if module is non-interactive)
    while ($true) {
        Show-Menu
        $choice = (Read-Host 'Select').Trim().ToUpperInvariant()

        switch ($choice) {
            '1' { Invoke-ModuleOperation; Pause-Continue }
            'Q' { return }
            default { Write-Host "Invalid choice."; Pause-Continue }
        }
    }
}
#endregion Entry Point