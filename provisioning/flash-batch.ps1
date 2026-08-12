#
# Step 5 (Windows): flash every phone currently in fastboot, in parallel.
# Windows twin of flash-batch.sh.
#
# The actual flashing is done by flash-fastboot.ps1 -- the port of the same
# script used to flash our own development phones. It is pointed at this
# folder's images\ directory. One flashing path instead of a second copy that
# drifts out of step with it.
#
# ** super.img is 7.9 GB PER PHONE. Eight phones on one hub is ~63 GB through a
# single USB controller, so this is limited by host USB bandwidth, not by the
# phones. Slow is normal here and slow is not stalled. A powered hub is not
# optional.

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '_common.ps1')
Initialize-Kit

$fastboot = Get-AndroidTool -Name 'fastboot'
Add-ToolDirToPath -ToolPath $fastboot

$devices = Get-FastbootDevices -Fastboot $fastboot
if ($devices.Count -eq 0) {
	Write-Host "No phones in fastboot. Do step 2 first." -ForegroundColor Red
	exit 1
}

# COMMIT_SLOT=0: flash-fastboot.ps1 can commit a phone's boot slot over its USB
# gadget, but every phone presents itself on the SAME address (10.42.0.1), so
# that cannot work with more than one plugged in. It is also unnecessary here --
# both slots receive the same image, so a phone that rolls back lands on an
# identical system. See README, "About slots".
#
# These go through the environment because a child process inherits it, which is
# also how the shell version passes them.
$env:COMMIT_SLOT = '0'
$env:IMAGE_DIR   = (Join-Path $PSScriptRoot 'images')
$env:DTBO        = (Join-Path $env:IMAGE_DIR 'dtbo.img')

$psExe  = Get-PSExecutable
$script = Join-Path $PSScriptRoot 'flash-fastboot.ps1'

Write-Host ("Flashing " + $devices.Count + " phone(s): " + ($devices -join ' '))
Write-Host ""

# -ExecutionPolicy Bypass on the child too: the parent may have been started
# that way, but the policy is not inherited by a new process, and a kit
# extracted from a downloaded zip is exactly the case the default policy
# blocks.
$procs = @()
foreach ($d in $devices) {
	$log = Join-Path $PSScriptRoot "flash-$d.log"
	$argStr = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $script, $d
	$p = Start-Process -FilePath $psExe -ArgumentList $argStr `
		-NoNewWindow -PassThru `
		-RedirectStandardOutput $log -RedirectStandardError "$log.err"
	$procs += New-Object PSObject -Property @{ Serial = $d; Proc = $p; Log = $log }
}

# Wait on each child individually and report per phone.
$results = @()
foreach ($e in $procs) {
	$e.Proc.WaitForExit()
	Merge-ChildLogs -LogPath $e.Log
	$results += New-Object PSObject -Property @{ Serial = $e.Serial; Ok = ($e.Proc.ExitCode -eq 0) }
}

$fail = Write-BatchSummary -Results $results -LogPrefix 'flash-'

Write-Host ""
if ($fail -eq 0) {
	Write-Host ("All " + $devices.Count + " phone(s) flashed. They are rebooting now.")
	Write-Host "Next: check each screen -- see README step 6."
	exit 0
}

Write-Host ("$fail of " + $devices.Count + " FAILED. Re-run just those:") -ForegroundColor Red
Write-Host "    powershell -ExecutionPolicy Bypass -File .\flash-fastboot.ps1 <serial>"
exit 1
