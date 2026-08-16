#
# Step 3 (Windows): unlock the bootloader on every phone in fastboot.
#
# Windows twin of unlock-bootloaders.sh.
#
# ** Each phone will show a confirmation you must accept with the VOLUME and
# POWER buttons. This cannot be automated. ** Unlocking also FACTORY RESETS the
# phone, which is fine here -- we are about to erase it anyway.
#
# "OEM unlocking" must already be enabled in Android's developer settings, or
# this fails with a permission error.

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '_common.ps1')
Initialize-Kit

$fastboot = Get-AndroidTool -Name 'fastboot'
$devices = Get-FastbootDevices -Fastboot $fastboot

if ($devices.Count -eq 0) { Die "No devices in fastboot." }

foreach ($d in $devices) {
	Write-Host "  unlocking $d -- accept the prompt on the phone"
	& $fastboot -s $d flashing unlock
}

Write-Host "Done. Confirm every phone shows an unlocked bootloader before continuing."
