<#
.SYNOPSIS
    Removes common consumer bloat from dedicated Windows sim PCs.

.DESCRIPTION
    Removes common preinstalled Windows consumer apps and disables selected
    consumer services, tasks, and content features. Designed for appliance-like
    Trackman / sim bay PCs.

.NOTES
    Conservative by design. Does not remove Microsoft Store, Defender, or core
    Windows components.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module identity
$script:ModuleName    = 'Windows Debloater'
$script:RequiresAdmin = $true

#region Confirm Text (Mandatory)
function Get-ConfirmText {
    return @"
$script:ModuleName

This module does:
- Removes common consumer Appx packages such as Teams, Xbox apps, OneNote app,
  Office Hub, Clipchamp, and other preinstalled extras
- Removes classic OneDrive when present
- Disables Xbox-related services
- Disables selected consumer scheduled tasks
- Disables Windows consumer experiences, chat, widgets, and feed content

It may change:
- Installed Appx packages
- Provisioned Appx packages for future users
- OneDrive installation and startup entries
- Service startup modes
- Scheduled task state
- Registry policy settings

Recommended for:
- Dedicated simulator / appliance-style PCs
- Systems where consumer apps are not needed

Press Y to continue.
"@
}
#endregion Confirm Text

#region Logging
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG','OK')]
        [string] $Level = 'INFO'
    )

    $prefix = switch ($Level) {
        'INFO'  { '[INFO ]' }
        'WARN'  { '[WARN ]' }
        'ERROR' { '[ERROR]' }
        'DEBUG' { '[DEBUG]' }
        'OK'    { '[ OK  ]' }
    }

    Write-Host "$prefix $Message"
}
#endregion Logging

#region Helpers
function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-Continue {
    Read-Host 'Press Enter to continue...' | Out-Null
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)]
        [string] $Description,
        [Parameter(Mandatory)]
        [scriptblock] $Script
    )

    Write-Log $Description 'INFO'

    try {
        & $Script
        Write-Log 'Done.' 'OK'
    }
    catch {
        Write-Log $_.Exception.Message 'ERROR'
    }
}

function Remove-AppxTargets {
    param(
        [Parameter(Mandatory)]
        [string[]] $Patterns
    )

    foreach ($pattern in $Patterns) {
        Write-Log "Checking installed Appx packages matching: $pattern" 'DEBUG'

        $installed = Get-AppxPackage -AllUsers | Where-Object {
            $_.Name -like $pattern
        }

        foreach ($pkg in $installed) {
            try {
                Write-Log "Removing installed package: $($pkg.Name) ($($pkg.PackageFullName))" 'INFO'
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                Write-Log "Failed to remove installed package $($pkg.Name): $($_.Exception.Message)" 'WARN'
            }
        }

        $provisioned = Get-AppxProvisionedPackage -Online | Where-Object {
            $_.DisplayName -like $pattern
        }

        foreach ($prov in $provisioned) {
            try {
                Write-Log "Removing provisioned package: $($prov.DisplayName) ($($prov.PackageName))" 'INFO'
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Failed to remove provisioned package $($prov.DisplayName): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Remove-ClassicOneDrive {
    $paths = @(
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
        "$env:SystemRoot\System32\OneDriveSetup.exe"
    ) | Where-Object { Test-Path $_ }

    if (-not $paths) {
        Write-Log 'OneDriveSetup.exe not found. OneDrive may already be absent.' 'WARN'
        return
    }

    foreach ($path in $paths) {
        Write-Log "Running OneDrive uninstaller: $path /uninstall" 'INFO'
        Start-Process -FilePath $path -ArgumentList '/uninstall' -Wait -NoNewWindow
    }

    $onedriveFolders = @(
        "$env:UserProfile\OneDrive",
        "$env:LocalAppData\Microsoft\OneDrive",
        "$env:ProgramData\Microsoft OneDrive",
        'C:\OneDriveTemp'
    )

    foreach ($folder in $onedriveFolders) {
        if (Test-Path $folder) {
            try {
                Write-Log "Removing leftover folder: $folder" 'INFO'
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Log "Failed to remove ${folder}: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    )

    foreach ($key in $runKeys) {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($null -ne $props -and ($props.PSObject.Properties.Name -contains 'OneDrive')) {
                Write-Log "Removing OneDrive startup entry from $key" 'INFO'
                Remove-ItemProperty -Path $key -Name 'OneDrive' -ErrorAction Stop
            }
        }
        catch {
            Write-Log "Failed to clean OneDrive autorun in ${key}: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Disable-ServicesIfPresent {
    param(
        [Parameter(Mandatory)]
        [string[]] $ServiceNames
    )

    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            try {
                if ($svc.Status -ne 'Stopped') {
                    Write-Log "Stopping service: $name" 'INFO'
                    Stop-Service -Name $name -Force -ErrorAction Stop
                }

                Write-Log "Disabling service: $name" 'INFO'
                Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
            }
            catch {
                Write-Log "Failed to disable service ${name}: $($_.Exception.Message)" 'WARN'
            }
        }
        else {
            Write-Log "Service not present: $name" 'DEBUG'
        }
    }
}

function Disable-ScheduledTasksIfPresent {
    param(
        [Parameter(Mandatory)]
        [string[]] $TaskPathsLike
    )

    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
    foreach ($pattern in $TaskPathsLike) {
        $matches = $allTasks | Where-Object {
            ($_.TaskPath + $_.TaskName) -like $pattern
        }

        foreach ($task in $matches) {
            try {
                Write-Log "Disabling scheduled task: $($task.TaskPath)$($task.TaskName)" 'INFO'
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log ("Failed to disable task {0}{1}: {2}" -f $task.TaskPath, $task.TaskName, $_.Exception.Message) 'WARN'
            }
        }
    }
}

function Set-RegistryValueSafe {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [object] $Value,
        [Microsoft.Win32.RegistryValueKind] $Type = [Microsoft.Win32.RegistryValueKind]::DWord
    )

    try {
        if (-not (Test-Path $Path)) {
            Write-Log "Creating registry key: $Path" 'INFO'
            New-Item -Path $Path -Force | Out-Null
        }

        Write-Log "Setting registry value: $Path -> $Name = $Value" 'INFO'
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
    catch {
        Write-Log "Failed to set registry ${Path}\${Name} : $($_.Exception.Message)" 'WARN'
    }
}
#endregion Helpers

#region Operations
function Invoke-ModuleOperation {
    $appxPatterns = @(
        '*MicrosoftTeams*',
        '*MSTeams*',
        '*Teams*',
        '*Microsoft.Office.OneNote*',
        '*Microsoft.OfficeHub*',
        '*Microsoft.GetHelp*',
        '*Microsoft.Getstarted*',
        '*Microsoft.XboxApp*',
        '*Microsoft.Xbox.TCUI*',
        '*Microsoft.XboxGameOverlay*',
        '*Microsoft.XboxGamingOverlay*',
        '*Microsoft.XboxIdentityProvider*',
        '*Microsoft.XboxSpeechToTextOverlay*',
        '*Microsoft.GamingApp*',
        '*Microsoft.YourPhone*',
        '*Microsoft.WindowsFeedbackHub*',
        '*Clipchamp.Clipchamp*',
        '*MicrosoftCorporationII.QuickAssist*',
        '*Microsoft.BingNews*',
        '*Microsoft.BingWeather*',
        '*Microsoft.People*',
        '*Microsoft.SkypeApp*',
        '*Microsoft.ZuneMusic*',
        '*Microsoft.ZuneVideo*',
        '*Microsoft.MicrosoftSolitaireCollection*',
        '*Microsoft.Todos*',
        '*Microsoft.PowerAutomateDesktop*'
    )

    $servicesToDisable = @(
        'XblAuthManager',
        'XblGameSave',
        'XboxGipSvc',
        'XboxNetApiSvc'
    )

    $taskPatterns = @(
        '*\Microsoft\XblGameSave\*',
        '*\Microsoft\Windows\CloudExperienceHost\*',
        '*\Microsoft\Windows\Shell\FamilySafety*',
        '*\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    )

    Invoke-Step -Description 'Removing consumer Appx packages and deprovisioning them for new users' -Script {
        Remove-AppxTargets -Patterns $appxPatterns
    }

    Invoke-Step -Description 'Uninstalling classic OneDrive and removing leftovers' -Script {
        Remove-ClassicOneDrive
    }

    Invoke-Step -Description 'Disabling Xbox-related services' -Script {
        Disable-ServicesIfPresent -ServiceNames $servicesToDisable
    }

    Invoke-Step -Description 'Disabling selected consumer scheduled tasks' -Script {
        Disable-ScheduledTasksIfPresent -TaskPathsLike $taskPatterns
    }

    Invoke-Step -Description 'Disabling Windows consumer experiences and content suggestions' -Script {
        Set-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1
        Set-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableConsumerAccountStateContent' -Value 1
        Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Value 0
        Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338388Enabled' -Value 0
        Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338389Enabled' -Value 0
        Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-353694Enabled' -Value 0
        Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-353696Enabled' -Value 0
    }

    Invoke-Step -Description 'Disabling Widgets / news features where policy applies' -Script {
        Set-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0
        Set-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' -Name 'EnableFeeds' -Value 0
    }

    Invoke-Step -Description 'Disabling consumer chat integration' -Script {
        Set-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' -Name 'ChatIcon' -Value 3
    }

    Write-Log 'Debloat routine completed. Reboot recommended.' 'OK'
}
#endregion Operations

#region Menu
function Show-Menu {
    Clear-Host
    Write-Host $script:ModuleName
    Write-Host '1) Run debloat routine'
    Write-Host 'Q) Back'
}
#endregion Menu

#region Entry Point (Mandatory)
function RunModule {
    if ($script:RequiresAdmin -and -not (Test-IsAdmin)) {
        Write-Log "Admin rights required to run $script:ModuleName." 'ERROR'
        Pause-Continue
        return
    }

    while ($true) {
        Show-Menu
        $choice = (Read-Host 'Select').Trim().ToUpperInvariant()

        switch ($choice) {
            '1' {
                Invoke-ModuleOperation
                Pause-Continue
            }
            'Q' { return }
            default {
                Write-Host 'Invalid choice.'
                Pause-Continue
            }
        }
    }
}
#endregion Entry Point