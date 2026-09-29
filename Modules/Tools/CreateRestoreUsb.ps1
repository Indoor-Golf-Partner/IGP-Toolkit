<#
.SYNOPSIS
  Create Restore USB - builds a bootable, self-contained USB drive that can
  restore any IGP golf-simulator PC back to the current baseline image.

.DESCRIPTION
  Walks through:
    1) Pick a USB drive (>= 50 GB, removable, never the boot/system disk).
    2) Warn that the drive will be completely wiped.
    3) Connect over SFTP to deploy.igpartner.dk:2223 as sftpuser, using the
       igp_images private key and a shipped known_hosts file (no interactive
       host-key prompt, no StrictHostKeyChecking=no either).
    4) List the available baseline images under /deploy/current/ on the
       server and let you pick one.
    5) Wipe and partition the USB as GPT:
         - Partition 1: 1 GB, EFI System Partition type, FAT32, label
           IGP-RESTORE.
         - Partition 2: rest of the drive, NTFS, label IMAGES.
    6) Download /deploy/igprestore/igprestore.zip (small) to a local temp
       file and extract it onto the IGP-RESTORE partition.
    7) Download the chosen image folder straight onto the IMAGES partition
       (no local staging - these are large).

  Why an EFI System Partition and not a syslinux/MBR install: a GPT
  partition flagged with the ESP type and formatted FAT32 is bootable to
  UEFI firmware directly (it loads \EFI\BOOT\BOOTX64.EFI) - no boot-sector
  or bootloader-install step is needed, which matches how these sticks are
  already built by hand (partition, format, copy files - nothing else).
  This only works on UEFI-capable target PCs.

  Both SFTP downloads run in the background while this script polls the
  destination's on-disk size against the size reported by the server, to
  drive a normal Write-Progress bar - sftp.exe's own progress meter doesn't
  survive being run non-interactively.

.NOTES
  Requires Administrator privileges.

  The igp_images private key is never stored in this repo (it's public on
  GitHub). It has to be placed by hand on each machine that will run this:
  see Test-SshKeyPresent's error message, or the project's own setup notes,
  for the exact path and permissions this expects.
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

# $PSScriptRoot here is Modules\Tools, so the toolkit root is two levels up.
$script:ToolkitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$script:SftpHost         = 'deploy.igpartner.dk'
$script:SftpPort         = 2223
$script:SftpUser         = 'sftpuser'
$script:SshKeyDir        = 'C:\ProgramData\Indoor Golf Partner\ssh'
$script:SshKeyPath       = Join-Path $script:SshKeyDir 'igp_images'
$script:KnownHostsPath   = Join-Path $script:ToolkitRoot 'resources\ssh\known_hosts'
$script:RemoteImagesDir  = '/deploy/current'
$script:RemoteRestoreKit = '/deploy/igprestore/igprestore.zip'

# Well-known SIDs (not localized names) for the same reason the power plan lookup
# uses a fixed GUID instead of matching "High performance" by name - Administrators
# and SYSTEM's display names are localized on non-English Windows installs.
$script:SidSystem         = '*S-1-5-18'
$script:SidAdministrators = '*S-1-5-32-544'

# GPT partition type GUID for an EFI System Partition.
$script:EspGptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

$script:MinUsbSizeBytes = 50GB

# ---------------------------------------------------------------------------
# SSH key / OpenSSH client setup
# ---------------------------------------------------------------------------

function Install-OpenSshClientIfMissing {
    if (Get-Command sftp.exe -ErrorAction SilentlyContinue) { return $true }

    Write-Log "OpenSSH Client not found - installing the Windows optional feature..." 'WARN'
    try {
        Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Failed to install OpenSSH Client: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    if (-not (Get-Command sftp.exe -ErrorAction SilentlyContinue)) {
        Write-Log "OpenSSH Client install reported success but 'sftp.exe' still isn't on PATH." 'ERROR'
        return $false
    }

    Write-Log "OpenSSH Client installed."
    return $true
}

function Set-RestrictedAcl {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$InheritanceFlags)

    & icacls.exe $Path /inheritance:r | Out-Null
    & icacls.exe $Path /grant:r "$($script:SidSystem):$InheritanceFlags" "$($script:SidAdministrators):$InheritanceFlags" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed to restrict permissions on '$Path' (exit code $LASTEXITCODE)."
    }
}

function Initialize-SshKeyFolder {
    if (-not (Test-Path -LiteralPath $script:SshKeyDir)) {
        New-Item -ItemType Directory -Force -Path $script:SshKeyDir | Out-Null
        Write-Log "Created '$script:SshKeyDir'."
    }

    # Only SYSTEM and Administrators can read anything placed in this folder - the key
    # itself is restricted again below, but locking the folder too keeps this true for
    # anything dropped into it in the future.
    Set-RestrictedAcl -Path $script:SshKeyDir -InheritanceFlags '(OI)(CI)F'
}

function Repair-SshKeyPermissions {
    if (-not (Test-Path -LiteralPath $script:SshKeyPath)) { return }

    # Windows' OpenSSH client refuses to use a private key file that other accounts can
    # read ("UNPROTECTED PRIVATE KEY FILE") - this is what actually makes that key usable,
    # not just a defense-in-depth nicety.
    Set-RestrictedAcl -Path $script:SshKeyPath -InheritanceFlags 'F'
}

function Test-SshKeyPresent {
    return (Test-Path -LiteralPath $script:SshKeyPath)
}

function Assert-SshKeyPresent {
    Initialize-SshKeyFolder

    if (Test-SshKeyPresent) {
        Repair-SshKeyPermissions
        return $true
    }

    Write-Log "The igp_images private key isn't installed on this machine." 'ERROR'
    Write-Log "Copy the key file to: $script:SshKeyPath" 'ERROR'
    Write-Log "The folder has already been created with restricted permissions (SYSTEM/Administrators only) - just place the key file (named exactly 'igp_images', no extension) inside it and run this again. Permissions on the file itself are fixed automatically." 'ERROR'
    return $false
}

# ---------------------------------------------------------------------------
# SFTP plumbing
# ---------------------------------------------------------------------------

function Get-SftpBaseArguments {
    return @(
        '-P', "$script:SftpPort",
        '-i', "`"$script:SshKeyPath`"",
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', "UserKnownHostsFile=`"$script:KnownHostsPath`"",
        '-o', 'StrictHostKeyChecking=yes'
    )
}

function Invoke-SftpBatch {
    # Runs a short-lived sftp batch (listing commands etc.) synchronously and returns
    # its stdout as an array of lines. Throws on a non-zero exit code.
    param([Parameter(Mandatory)] [string[]]$Commands)

    $batchFile = [System.IO.Path]::GetTempFileName()
    $outFile   = [System.IO.Path]::GetTempFileName()
    $errFile   = [System.IO.Path]::GetTempFileName()

    try {
        Set-Content -LiteralPath $batchFile -Value $Commands -Encoding ascii

        $arguments = (Get-SftpBaseArguments) + @('-b', "`"$batchFile`"", "$($script:SftpUser)@$($script:SftpHost)")

        $proc = Start-Process -FilePath 'sftp.exe' -ArgumentList $arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait

        $stdout = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue)
        $stderr = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)

        if ($proc.ExitCode -ne 0) {
            throw "sftp exited with code $($proc.ExitCode): $($stderr -join ' | ')"
        }

        return $stdout
    }
    finally {
        Remove-Item -LiteralPath $batchFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-SftpLongListing {
    # Parses "ls -la"-style lines (permissions links owner group size month day time/year name)
    # into objects. Best-effort - relies on the server's ls formatting looking like standard
    # OpenSSH/coreutils output, which is what internal-sftp on Debian produces.
    param([Parameter(Mandatory)] [string[]]$Lines)

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim() -split '\s+', 9
        if ($parts.Count -lt 9) { continue }
        if ($parts[8] -eq '.' -or $parts[8] -eq '..') { continue }

        [pscustomobject]@{
            IsDirectory = $parts[0].StartsWith('d')
            Size        = [int64]$parts[4]
            Name        = $parts[8]
        }
    }
}

function Get-RemoteImageFolders {
    $lines = Invoke-SftpBatch -Commands @("ls -la $script:RemoteImagesDir")
    $entries = @(ConvertFrom-SftpLongListing -Lines $lines | Where-Object { $_.IsDirectory })
    return $entries | Sort-Object Name
}

function Get-SftpFileSize {
    param([Parameter(Mandatory)] [string]$RemotePath)

    $remoteDir  = ($RemotePath -replace '/[^/]+$', '')
    $remoteName = ($RemotePath -split '/')[-1]
    $lines = Invoke-SftpBatch -Commands @("ls -la $remoteDir")
    $entry = ConvertFrom-SftpLongListing -Lines $lines | Where-Object { $_.Name -eq $remoteName } | Select-Object -First 1
    if (-not $entry) { throw "Could not find '$RemotePath' on the server." }
    return $entry.Size
}

function Get-SftpDirectorySize {
    # Non-recursive by design for now - Clonezilla image folders are flat (partclone
    # chunks + metadata sit directly inside the image folder, no subfolders).
    param([Parameter(Mandatory)] [string]$RemotePath)

    $lines = Invoke-SftpBatch -Commands @("ls -la $RemotePath")
    $entries = @(ConvertFrom-SftpLongListing -Lines $lines | Where-Object { -not $_.IsDirectory })
    return ($entries | Measure-Object -Property Size -Sum).Sum
}

function Get-LocalPathSize {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        return [int64]($sum)
    }
    return $item.Length
}

function Invoke-SftpDownloadWithProgress {
    param(
        [Parameter(Mandatory)] [string]$RemotePath,
        [Parameter(Mandatory)] [string]$LocalPath,
        [Parameter(Mandatory)] [int64]$TotalBytes,
        [Parameter(Mandatory)] [bool]$IsDirectory,
        [Parameter(Mandatory)] [string]$Activity
    )

    $getCommand = if ($IsDirectory) { "get -r `"$RemotePath`" `"$LocalPath`"" } else { "get `"$RemotePath`" `"$LocalPath`"" }
    $batchFile = [System.IO.Path]::GetTempFileName()
    $outFile   = [System.IO.Path]::GetTempFileName()
    $errFile   = [System.IO.Path]::GetTempFileName()

    try {
        Set-Content -LiteralPath $batchFile -Value @($getCommand) -Encoding ascii
        $arguments = (Get-SftpBaseArguments) + @('-b', "`"$batchFile`"", "$($script:SftpUser)@$($script:SftpHost)")

        $proc = Start-Process -FilePath 'sftp.exe' -ArgumentList $arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        while (-not $proc.HasExited) {
            $current = Get-LocalPathSize -Path $LocalPath
            $percent = if ($TotalBytes -gt 0) { [Math]::Min(100, [int](($current / $TotalBytes) * 100)) } else { 0 }
            Write-Progress -Activity $Activity -Status "$([Math]::Round($current / 1MB)) MB / $([Math]::Round($TotalBytes / 1MB)) MB" -PercentComplete $percent
            Start-Sleep -Seconds 1
        }

        Write-Progress -Activity $Activity -Completed

        if ($proc.ExitCode -ne 0) {
            $stderr = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) -join ' | '
            throw "sftp download of '$RemotePath' failed (exit code $($proc.ExitCode)): $stderr"
        }
    }
    finally {
        Remove-Item -LiteralPath $batchFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# USB disk selection and partitioning
# ---------------------------------------------------------------------------

function Get-CandidateUsbDisks {
    return @(Get-Disk | Where-Object {
        $_.BusType -eq 'USB' -and
        $_.Size -ge $script:MinUsbSizeBytes -and
        -not $_.IsBoot -and
        -not $_.IsSystem
    } | Sort-Object Number)
}

function Select-UsbDisk {
    $disks = @(Get-CandidateUsbDisks)
    if ($disks.Count -eq 0) {
        Write-Log "No USB drive of at least $($script:MinUsbSizeBytes / 1GB) GB was found. Plug one in and try again." 'WARN'
        return $null
    }

    Write-Host ""
    Write-Host "USB drives found:"
    $map = @{}
    $num = 0
    # foreach (not an indexed for loop) so this works identically whether $disks is a
    # real array or - when Get-Disk only matches one drive - a single CIM instance that
    # PowerShell may not treat as index-able the same way an array is.
    foreach ($d in $disks) {
        $num++
        $sizeGb = [Math]::Round($d.Size / 1GB, 1)
        Write-Host ("  {0}) Disk {1}: {2} ({3} GB)" -f $num, $d.Number, $d.FriendlyName, $sizeGb)
        $map["$num"] = $d
    }
    Write-Host ""

    $sel = Read-Host "Select the USB drive to use (or Q to cancel)"
    if ($sel -match '^(?i)q$') { return $null }
    if (-not $map.ContainsKey($sel)) {
        Write-Log "Invalid selection." 'WARN'
        return $null
    }

    return $map[$sel]
}

function Confirm-UsbWipe {
    param([Parameter(Mandatory)] $Disk)

    $sizeGb = [Math]::Round($Disk.Size / 1GB, 1)
    Write-Host ""
    Write-Host "This will PERMANENTLY ERASE everything on:" -ForegroundColor Yellow
    Write-Host ("  Disk {0}: {1} ({2} GB)" -f $Disk.Number, $Disk.FriendlyName, $sizeGb) -ForegroundColor Yellow
    Write-Host ""
    $typed = Read-Host "Type ERASE to confirm"
    return ($typed -ceq 'ERASE')
}

function Invoke-DiskpartScript {
    # diskpart.exe almost always exits 0 even when an internal command inside the script
    # failed, so $LASTEXITCODE alone can't be trusted - the transcript itself has to be
    # checked for diskpart's own error phrasing.
    param([Parameter(Mandatory)] [string[]]$Commands)

    $scriptFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $scriptFile -Value $Commands -Encoding ascii

        $output = & diskpart.exe /s $scriptFile 2>&1
        $text = $output -join "`n"

        if ($LASTEXITCODE -ne 0 -or $text -match '(?i)error|failed|incorrect parameter|cannot|unable to') {
            throw "diskpart reported a problem:`n$text"
        }

        return $text
    }
    finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-DiskRaw {
    # After an external diskpart.exe process cleans the disk, PowerShell's Storage
    # cmdlets can still report a stale cached view of it for a moment - confirmed on
    # real hardware: Initialize-Disk immediately after diskpart's clean failed with
    # "The disk has already been initialized" even though diskpart just cleaned it.
    # Update-Disk forces a refresh; poll until the cache actually catches up rather than
    # trusting a fixed delay.
    param([Parameter(Mandatory)] [int]$DiskNumber, [int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if ($disk -and $disk.PartitionStyle -eq 'RAW') { return }
        Start-Sleep -Seconds 1
    }

    throw "Disk $DiskNumber still doesn't report as RAW (uninitialized) $TimeoutSeconds seconds after diskpart cleaned it - PowerShell's Storage cmdlets may be seeing stale cached state."
}

function Initialize-RestoreUsbPartitions {
    # diskpart.exe's own CLI refuses "create partition efi"/format on media flagged
    # removable ("The operation is not supported on removable media" - confirmed on real
    # hardware), even though the same disk fully supports a GPT ESP partition when
    # created the normal way. So diskpart is used ONLY for wiping the disk; everything
    # else goes back to the native PowerShell Storage cmdlets, which got past this exact
    # step cleanly before diskpart was involved at all.
    #
    # Plain "clean" only wipes the front of the disk and can leave the backup GPT header
    # at the very end intact - confirmed on real hardware: the disk still reported as
    # GPT-initialized (never RAW) after a plain clean, even with Update-Disk/polling
    # ruling out a caching delay. "clean all" zeroes every sector, guaranteeing no
    # leftover GPT signature survives - much slower (writes to the whole drive, not just
    # the first few sectors) but the only way that's actually reliable here.
    param([Parameter(Mandatory)] $Disk)

    Write-Log "Wiping disk $($Disk.Number) via diskpart (clean all - this writes zeros to the entire drive, so it can take several minutes)..."
    Invoke-DiskpartScript -Commands @(
        "select disk $($Disk.Number)",
        "clean all"
    ) | Out-Null

    Wait-DiskRaw -DiskNumber $Disk.Number
    Initialize-Disk -Number $Disk.Number -PartitionStyle GPT -ErrorAction Stop

    Write-Log "Creating boot partition (1 GB, FAT32, EFI System Partition)..."
    $bootPartition = New-Partition -DiskNumber $Disk.Number -Size 1GB -GptType $script:EspGptType -AssignDriveLetter -ErrorAction Stop
    Format-Volume -Partition $bootPartition -FileSystem FAT32 -NewFileSystemLabel 'IGP-RESTORE' -Confirm:$false -ErrorAction Stop | Out-Null

    Write-Log "Creating image partition (remaining space, NTFS)..."
    $imagePartition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    Format-Volume -Partition $imagePartition -FileSystem NTFS -NewFileSystemLabel 'IMAGES' -Confirm:$false -ErrorAction Stop | Out-Null

    $bootPartition = Get-Partition -DiskNumber $Disk.Number -PartitionNumber $bootPartition.PartitionNumber
    $imagePartition = Get-Partition -DiskNumber $Disk.Number -PartitionNumber $imagePartition.PartitionNumber

    return [pscustomobject]@{
        BootDriveLetter  = $bootPartition.DriveLetter
        ImageDriveLetter = $imagePartition.DriveLetter
    }
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

function Install-RestoreKit {
    param([Parameter(Mandatory)] [char]$BootDriveLetter)

    $size = Get-SftpFileSize -RemotePath $script:RemoteRestoreKit
    $tempZip = Join-Path $env:TEMP 'igprestore.zip'
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }

    Write-Log "Downloading igprestore.zip ($([Math]::Round($size / 1MB)) MB)..."
    Invoke-SftpDownloadWithProgress -RemotePath $script:RemoteRestoreKit -LocalPath $tempZip -TotalBytes $size -IsDirectory $false -Activity 'Downloading igprestore.zip'

    Write-Log "Extracting igprestore.zip to $($BootDriveLetter):\..."
    Expand-Archive -LiteralPath $tempZip -DestinationPath "$($BootDriveLetter):\" -Force
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
}

function Install-DiskImage {
    param(
        [Parameter(Mandatory)] [string]$ImageName,
        [Parameter(Mandatory)] [char]$ImageDriveLetter
    )

    $remotePath = "$script:RemoteImagesDir/$ImageName"
    $size = Get-SftpDirectorySize -RemotePath $remotePath

    Write-Log "Downloading image '$ImageName' ($([Math]::Round($size / 1GB, 1)) GB)..."
    Invoke-SftpDownloadWithProgress -RemotePath $remotePath -LocalPath "$($ImageDriveLetter):\" -TotalBytes $size -IsDirectory $true -Activity "Downloading $ImageName"
}

function Get-Status {
    return @(
        [pscustomobject]@{
            Title  = 'igp_images SSH Key'
            Status = if (Test-SshKeyPresent) { 'Confirmed' } else { 'Missing' }
            Detail = $script:SshKeyPath
        }
    )
}

function Get-ConfirmText {
    return "Builds a bootable Restore USB from the current IGP baseline image. This will ERASE the USB drive you pick - everything on it will be lost."
}

function RunModule {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator privileges are required. Run the toolkit elevated.'
    }

    if (-not (Install-OpenSshClientIfMissing)) { return }
    if (-not (Assert-SshKeyPresent)) { return }

    $disk = Select-UsbDisk
    if (-not $disk) { return }

    Write-Log "Connecting to $($script:SftpHost):$($script:SftpPort)..."
    $images = @()
    try {
        $images = @(Get-RemoteImageFolders)
    }
    catch {
        Write-Log "Failed to connect or list images: $($_.Exception.Message)" 'ERROR'
        return
    }

    if ($images.Count -eq 0) {
        Write-Log "No image folders found under $script:RemoteImagesDir on the server." 'ERROR'
        return
    }

    Write-Host ""
    Write-Host "Available baseline images:"
    $map = @{}
    $num = 0
    foreach ($image in $images) {
        $num++
        Write-Host ("  {0}) {1}" -f $num, $image.Name)
        $map["$num"] = $image.Name
    }
    Write-Host ""

    $sel = Read-Host "Select the image to restore (or Q to cancel)"
    if ($sel -match '^(?i)q$') { return }
    if (-not $map.ContainsKey($sel)) {
        Write-Log "Invalid selection." 'WARN'
        return
    }
    $imageName = $map[$sel]

    # Everything above only reads from the server and the disk list - nothing
    # destructive has happened yet. This is the one and only wipe confirmation,
    # placed here (not right after picking the drive) so it's the last thing that
    # happens before anything irreversible actually does.
    if (-not (Confirm-UsbWipe -Disk $disk)) {
        Write-Log "Cancelled - nothing was changed." 'WARN'
        return
    }

    try {
        $drives = Initialize-RestoreUsbPartitions -Disk $disk
        Install-RestoreKit -BootDriveLetter $drives.BootDriveLetter
        Install-DiskImage -ImageName $imageName -ImageDriveLetter $drives.ImageDriveLetter
        Write-Log "Restore USB is ready (boot: $($drives.BootDriveLetter): / images: $($drives.ImageDriveLetter):)."
    }
    catch {
        Write-Log "Failed to build the Restore USB: $($_.Exception.Message)" 'ERROR'
    }
}

# Only auto-run when executed directly (not when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    RunModule
}
