# Description: Boxstarter Script
# Author: Jean-Louis Jouannic <jean-louis.jouannic@zenika.com>
# Last Updated: 2019-06-10
# Tested on: Windows 10 Professional 64 bits v1903 (released in May 2019)
#
# Install Boxstarter from an _elevated_ PowerShell session:
# > Set-ExecutionPolicy RemoteSigned -Scope Process -Force; . { iwr -useb http://boxstarter.org/bootstrapper.ps1 } | iex; get-boxstarter -Force
#
# Run this Boxstarter script by calling the following from the Boxstarter shell:
#
# > Install-BoxstarterPackage -PackageName <FILE-PATH-OR-URL> -DisableReboots
#
# Learn more: http://boxstarter.org/Learn/WebLauncher

# ⚠ Temporary disable UAC
Disable-UAC

############
# Cleaning #
############

# Remove every uninstallable app except Windows Store
# Adapted from https://matteu31.wordpress.com/2017/04/03/windows-suppression-des-application-du-store/
$AppsToDelete = Get-AppxPackage -AllUsers | Where-Object {$_.NonRemovable -ne $true -and $_.Name -notlike "*store*"}

foreach ($App in $AppsToDelete) {

    $PackageName = $App.PackageFullName

    if ($PackageName) {
        Remove-AppxPackage -Package $PackageName
    }

    $ProvisionedPackageName = (Get-AppxProvisionedPackage -Online | Where-Object {$_.DisplayName -eq $App.Name}).PackageName

    if ($ProvisionedPackageName) {
        Remove-AppxProvisionedPackage -Online -Package $ProvisionedPackageName
    }
}

# Remove OneDrive
& "$env:systemroot\SysWOW64\OneDriveSetup.exe" /uninstall

###########
# Privacy #
###########

# Stop and disable DiagTrack service
Get-Service DiagTrack | Stop-Service -PassThru | Set-Service -StartupType Disabled

# Disable Bing search results in Start menu
Disable-BingSearch

# Prevent apps to use my advertising ID
If (-Not (Test-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo")) {
    New-Item -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo | Out-Null
}
Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo -Name Enabled -Type DWord -Value 0

# Disable WiFi Sense hotspot sharing
If (-Not (Test-Path "HKLM:\Software\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting")) {
    New-Item -Path HKLM:\Software\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting | Out-Null
}
Set-ItemProperty -Path HKLM:\Software\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting -Name value -Type DWord -Value 0

# Disable auto-connect to WiFi Sense shared hotspot
Set-ItemProperty -Path HKLM:\Software\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots -Name value -Type DWord -Value 0

#####################
# Customize desktop #
#####################

# Better file explorer and taskbar
Set-WindowsExplorerOptions -EnableShowHiddenFilesFoldersDrives -DisableOpenFileExplorerToQuickAccess -EnableShowFileExtensions
Set-TaskbarOptions -Size Large -Dock Bottom -Combine Full -AlwaysShowIconsOn

# ⚠ Re-enable UAC
Enable-UAC

###########
# Updates #
###########

Enable-MicrosoftUpdate
# Install not-optional software updates
Install-WindowsUpdate -AcceptEula -Criteria "IsHidden=0 and IsInstalled=0 and BrowseOnly=0 and Type='Software'"
# Install not-optional driver updates
Install-WindowsUpdate -AcceptEula -Criteria "IsHidden=0 and IsInstalled=0 and BrowseOnly=0 and Type='Driver'"
