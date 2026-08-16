#
# Step 2 (Windows): reboot every adb-visible phone into fastboot.
#
# Windows twin of reboot-to-fastboot.sh. Phones you have not used before will
# show an "allow USB debugging?" dialog. Accept it on each, then run this
# again -- devices stuck at "unauthorized" are reported rather than silently
# skipped.

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '_common.ps1')
Initialize-Kit

$adb = Get-AndroidTool -Name 'adb'
$devices = Get-AdbDevices -Adb $adb

if ($devices.Count -eq 0) {
	Write-Host "No devices found by adb."
	Note "If the phones are plugged in and powered on, Windows may be missing the"
	Note "Google USB driver, or the cable may be charge-only. See README.md,"
	Note "'Windows setup'."
	exit 1
}

$n = 0
foreach ($d in $devices) {
	switch ($d.State) {
		'device' {
			Write-Host ("  rebooting " + $d.Serial + " to fastboot")
			& $adb -s $d.Serial reboot bootloader
			$n++
		}
		'unauthorized' {
			Warn ($d.Serial + " is UNAUTHORIZED -- accept the dialog on the phone, then re-run")
		}
		default {
			Warn ($d.Serial + " is '" + $d.State + "' -- skipped")
		}
	}
}

Write-Host "$n device(s) sent to fastboot. Wait for the fastboot screen on each."
