<#
.SYNOPSIS
  Machine Identity module - account name, computer name, and Windows license.

.DESCRIPTION
  Provides a submenu:
    1) Set Windows Account Name
    2) Set Computer Name
    3) Set Windows License

  Set Windows Account Name:
  - Renames the currently logged-in local account.

  Set Computer Name:
  - Suggests a name based on the machine's serial number: the BIOS
    serial (Get-CimInstance Win32_BIOS) if available, otherwise the
    "SerialNumber" registry value written by Reseller Setup - unless
    that value is still the "REPLACE-ME" placeholder. A leading "IGP-"
    is stripped from the serial before suggesting it. Press Enter to
    accept the suggestion, or type a different name. Requires a restart
    to take effect.

  Set Windows License:
  - Only proceeds if Windows isn't already activated; otherwise reports
    the current status and does nothing. Prompts for a product key and
    runs it through slmgr.vbs (/ipk then /ato).

.NOTES
  Requires Administrator privileges.
#>

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "$ts [$Level] $Message"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:IGPRegistryBaseKey = 'HKLM:\SOFTWARE\Indoor Golf Partner\IGP'

function Set-WindowsAccountName {
    $currentName = $env:USERNAME

    $newName = Read-Host "New account name for '$currentName'"
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Log "No name entered. Cancelled." 'WARN'
        return
    }

    try {
        Rename-LocalUser -Name $currentName -NewName $newName -ErrorAction Stop
        Write-Log "Renamed local account '$currentName' to '$newName'."
    }
    catch {
        Write-Log "Failed to rename account: $($_.Exception.Message)" 'ERROR'
    }
}

function Get-SuggestedComputerName {
    $serial = $null

    try {
        $biosSerial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber
        if (-not [string]::IsNullOrWhiteSpace($biosSerial)) {
            $serial = $biosSerial.Trim()
        }
    }
    catch {
        # Fall through to registry
    }

    if (-not $serial) {
        try {
            $regSerial = (Get-ItemProperty -Path $script:IGPRegistryBaseKey -Name 'SerialNumber' -ErrorAction Stop).SerialNumber
            if ($regSerial -and $regSerial -ne 'REPLACE-ME') {
                $serial = $regSerial.Trim()
            }
        }
        catch {
            # No registry value either
        }
    }

    if ([string]::IsNullOrWhiteSpace($serial)) { return $null }

    # Strip a leading "IGP-" prefix, if present
    return ($serial -replace '^(?i)IGP-', '')
}

function Set-ComputerNameInteractive {
    $suggested = Get-SuggestedComputerName

    $prompt = if ($suggested) {
        "Computer name ($suggested)"
    } else {
        "Computer name (no serial number available - enter manually)"
    }

    $raw = Read-Host $prompt
    $newName = if ([string]::IsNullOrWhiteSpace($raw)) { $suggested } else { $raw.Trim() }

    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Log "No computer name provided. Cancelled." 'WARN'
        return
    }

    if ($newName.Length -gt 15) {
        Write-Log "'$newName' is longer than 15 characters; older NetBIOS-only tools may not see the full name." 'WARN'
    }

    try {
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        Write-Log "Computer renamed to '$newName'. A restart is required for this to take effect."
    }
    catch {
        Write-Log "Failed to rename computer: $($_.Exception.Message)" 'ERROR'
    }
}

function Get-WindowsLicenseProduct {
    try {
        return Get-CimInstance -Query "SELECT * FROM SoftwareLicensingProduct WHERE PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop |
            Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Get-WindowsLicenseStatusText {
    $product = Get-WindowsLicenseProduct
    if (-not $product) { return "Unknown" }

    switch ($product.LicenseStatus) {
        0 { return "Unlicensed" }
        1 { return "Licensed" }
        2 { return "Out-of-Box Grace Period" }
        3 { return "Out-of-Tolerance Grace Period" }
        4 { return "Non-Genuine Grace Period" }
        5 { return "Notification" }
        6 { return "Extended Grace Period" }
        default { return "Unknown ($($product.LicenseStatus))" }
    }
}

function Test-WindowsLicensed {
    $product = Get-WindowsLicenseProduct
    return ($product -and $product.LicenseStatus -eq 1)
}

function Set-WindowsLicense {
    if (Test-WindowsLicensed) {
        Write-Log "Windows is already activated. Nothing to do." 'WARN'
        return
    }

    Write-Log "Current license status: $(Get-WindowsLicenseStatusText)"

    $key = Read-Host "Enter Windows product key (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)"
    if ($key -notmatch '^[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}$') {
        Write-Log "That doesn't look like a valid product key format. Cancelled." 'ERROR'
        return
    }

    $slmgr = Join-Path $env:SystemRoot 'System32\slmgr.vbs'
    if (-not (Test-Path -LiteralPath $slmgr)) {
        Write-Log "slmgr.vbs not found at expected path: $slmgr" 'ERROR'
        return
    }

    try {
        Write-Log "Installing product key..."
        & cscript.exe //Nologo $slmgr /ipk $key | ForEach-Object { Write-Log $_ }

        Write-Log "Activating Windows..."
        & cscript.exe //Nologo $slmgr /ato | ForEach-Object { Write-Log $_ }

        Write-Log "License status after activation attempt: $(Get-WindowsLicenseStatusText)"
    }
    catch {
        Write-Log "Failed to set/activate Windows license: $($_.Exception.Message)" 'ERROR'
    }
}

function Get-Status {
    return @(
        [pscustomobject]@{
            Title  = 'Account Name'
            Status = 'Info'
            Detail = $env:USERNAME
        }
        [pscustomobject]@{
            Title  = 'Computer Name'
            Status = 'Info'
            Detail = $env:COMPUTERNAME
        }
        [pscustomobject]@{
            Title  = 'Windows License'
            Status = if (Test-WindowsLicensed) { 'Confirmed' } else { 'Missing' }
            Detail = Get-WindowsLicenseStatusText
        }
    )
}

function Show-Menu {
    Write-Host ""
    Write-Host "Machine Identity"
    Write-Host "----------------"
    Write-Host "Sets the account name, computer name, and Windows license."
    Write-Host ""
    Write-Host "  1) Set Windows Account Name"
    Write-Host "  2) Set Computer Name"
    Write-Host "  3) Set Windows License (status: $(Get-WindowsLicenseStatusText))"
    Write-Host "  Q) Back"
    Write-Host ""

    return (Read-Host 'Select an option')
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    while ($true) {
        Clear-Host
        $choice = Show-Menu

        if ($choice -match '^(?i)q$') { return }

        switch ($choice) {
            '1' {
                Set-WindowsAccountName
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '2' {
                Set-ComputerNameInteractive
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            '3' {
                Set-WindowsLicense
                Read-Host 'Press Enter to continue...' | Out-Null
            }
            default {
                Write-Host 'Invalid selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Only auto-run when executed directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    RunModule
}
