<#
.SYNOPSIS
    IGP Toolkit module template.

.DESCRIPTION
    Copy this file when creating a new module. Fill in ModuleName and implement
    functions as needed. Mandatory function: RunModule.

    Confirmation text: if the module has a real submenu (like this template's
    Show-Menu), don't define Get-ConfirmText - instead print a short
    description (statement, not a question) at the top of Show-Menu, above
    the numbered options. Only define Get-ConfirmText - a classic Y/N "Do you
    want to continue?" gate shown before anything runs - for a module that
    runs a single action immediately with no menu at all, since that's its
    only chance to back out.

.NOTES
    Keep structure consistent across modules.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module identity
$script:ModuleName    = 'Template Module'
$script:RequiresAdmin = $false

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
    Write-Host "(describe what this module does, as a statement)"
    Write-Host ""
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