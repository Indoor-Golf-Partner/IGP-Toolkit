<#
.SYNOPSIS
  Repair Windows system files (DISM + SFC) with a submenu.

.DESCRIPTION
  This module provides an internal menu with the following options:

  1) DISM + SFC (recommended order)
     - DISM /Online /Cleanup-Image /RestoreHealth
       Repairs the Windows component store (WinSxS). This is the source SFC uses.
       May download repair content from Windows Update if needed.
     - sfc /scannow
       Scans protected Windows system files and replaces corrupted/modified files
       using known-good copies from the component store.

  2) SFC only (faster)
     - sfc /scannow
       Useful as a quick first attempt. If the component store is corrupted,
       SFC may be unable to fix everything (then run DISM + SFC).

.NOTES
  - Requires Administrator privileges.
  - DISM can take a long time (sometimes 10–45+ minutes) and may appear to stall.
#>

function Get-ConfirmText {
@"
This module can repair Windows system files.

DISM can take a long time and may require internet access.
SFC is usually faster.

Do you want to continue?
"@
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$ts [$Level] $Message"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    Write-Log ("Running: {0} {1}" -f $FilePath, ($Arguments -join ' '))

    $p = Start-Process -FilePath $FilePath `
        -ArgumentList $Arguments `
        -NoNewWindow `
        -Wait `
        -PassThru

    return $p.ExitCode
}



function Run-DismRestoreHealth {
    $dismExe = Join-Path $env:SystemRoot "System32\dism.exe"
    if (-not (Test-Path -LiteralPath $dismExe)) {
        throw "dism.exe not found: $dismExe"
    }

    Write-Log "DISM will show progress below. It may pause at certain percentages." "WARN"
    $code = Invoke-NativeCommand -FilePath $dismExe -Arguments @("/Online","/Cleanup-Image","/RestoreHealth")

    switch ($code) {
        0     { Write-Log "DISM completed successfully." "INFO" }
        3010  { Write-Log "DISM completed; a reboot is required to finish applying changes." "WARN" }
        default { Write-Log "DISM returned exit code $code. Review output above." "WARN" }
    }

    return $code
}

function Run-SfcScanNow {
    $sfcExe = Join-Path $env:SystemRoot "System32\sfc.exe"
    if (-not (Test-Path -LiteralPath $sfcExe)) {
        throw "sfc.exe not found: $sfcExe"
    }

    $code = Invoke-NativeCommand -FilePath $sfcExe -Arguments @("/scannow")

    switch ($code) {
        0 { Write-Log "SFC: No integrity violations found." "INFO" }
        1 { Write-Log "SFC: Integrity violations found; repairs were made (or attempted)." "WARN" }
        2 { Write-Log "SFC: Could not perform the requested operation (often pending reboot)." "WARN" }
        default { Write-Log "SFC returned exit code $code. Review output above." "WARN" }
    }

    return $code
}


function Show-RepairMenu {
    Write-Host ""
    Write-Host "Windows Repair Menu"
    Write-Host "-------------------"
    Write-Host "  1) Run DISM + SFC (recommended)"
    Write-Host "  2) Run SFC only (faster)"
    Write-Host "  Q) Cancel"
    Write-Host ""
    return (Read-Host "Select an option")
}

function RunModule {
    Write-Log "Task: Windows Repair - started"

    if (-not (Test-IsAdmin)) {
        throw "Administrator privileges are required. Run the toolkit elevated."
    }

    $choice = Show-RepairMenu

    if ($choice -match '^(?i)q$') {
        Write-Log "User cancelled Windows repair." "WARN"
        return
    }

    switch ($choice) {
        '1' {
            $dismCode = Run-DismRestoreHealth
            if ($dismCode -eq 3010) {
                Write-Log "Reboot recommended. You can run SFC again after reboot if issues persist." "WARN"
            }
            Run-SfcScanNow | Out-Null
        }
        '2' {
            Run-SfcScanNow | Out-Null
        }
        default {
            Write-Log "Invalid selection. No actions performed." "WARN"
        }
    }

    Write-Log "Task: Windows Repair - finished"
}
