#
# Step 4 (Windows): run Google's own flash-all.bat on every phone in fastboot,
# in parallel. Windows twin of flash-google-batch.sh.
#
# This calls Google's script unmodified, out of factory\. We do not reimplement
# it -- it flashes the bootloader and radio, reboots between each, and then runs
# `fastboot -w update`, and that sequence is Google's to get right.
#
# ** WHY A WRAPPER IS NEEDED AT ALL: flash-all.bat issues bare `fastboot`
# commands, which target "the single attached device". With a hub full of phones
# that is whichever one fastboot happens to pick. fastboot honours ANDROID_SERIAL
# for every invocation, so setting it per phone is what makes parallel flashing
# safe. It also has to run from its own directory, because it refers to its
# images by relative path.
#
# ** This WIPES each phone (`-w`). That is intended -- step 5 replaces the
# system anyway.

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '_common.ps1')
Initialize-Kit

$factory = Join-Path $PSScriptRoot 'factory'
$flashAll = Join-Path $factory 'flash-all.bat'
if (-not (Test-Path -LiteralPath $flashAll)) {
	Die ("no factory\flash-all.bat -- this kit is incomplete.`n" +
		"    (flash-all.sh is the Linux one and will not run here.)")
}

$fastboot = Get-AndroidTool -Name 'fastboot'
# flash-all.bat calls `fastboot` by name, so the copy we resolved has to be the
# one a child process finds.
Add-ToolDirToPath -ToolPath $fastboot

# flash-all.bat needs a reasonably recent fastboot; the failure otherwise is
# obscure, so check it here where the message can be plain.
$verLine = (& $fastboot --version 2>&1 | Select-Object -First 1)
if ("$verLine" -match 'version\s+(\d+)\.(\d+)\.(\d+)') {
	$have = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
	if ($have -lt [version]'33.0.1') {
		Write-Host "fastboot $have is too old -- need 33.0.1 or newer." -ForegroundColor Red
		Die "Get current platform-tools from developer.android.com."
	}
} else {
	Warn "could not read the fastboot version from: $verLine"
	Warn "continuing anyway -- 33.0.1 or newer is required."
}

$devices = Get-FastbootDevices -Fastboot $fastboot
if ($devices.Count -eq 0) {
	Write-Host "No phones in fastboot. Do step 2 first." -ForegroundColor Red
	exit 1
}

Write-Host ("Flashing Google's image onto " + $devices.Count + " phone(s): " + ($devices -join ' '))
Write-Host "This reboots each phone several times. Do not unplug anything."
Write-Host ""

# ** flash-all.bat ENDS IN `pause`, which waits for a keypress forever. **
#
# That is fine when a human double-clicks it and is fatal when twenty of them
# run unattended: every child would sit at "Press any key to exit" with the
# flash already finished and the batch never returning. Handing each child an
# empty stdin makes `pause` return immediately. This is the one thing about the
# Windows path that has no counterpart in the shell version.
$empties = @()
# The command interpreter by its full path from ComSpec rather than the bare
# name: Start-Process does not search PATH the way the shell does.
$cmdExe = $env:ComSpec
if (-not $cmdExe) { $cmdExe = 'cmd.exe' }
$tempDir = [System.IO.Path]::GetTempPath()   # not $env:TEMP, which a locked-down
                                             # or service account may not have

$procs = @()
foreach ($d in $devices) {
	$log = Join-Path $PSScriptRoot "google-$d.log"
	$nul = Join-Path $tempDir ("junkyard-empty-$d.in")
	New-Item -ItemType File -Path $nul -Force | Out-Null
	$empties += $nul

	# ANDROID_SERIAL is set on THIS process immediately before spawning: a child
	# takes a snapshot of the environment when it is created, so each one gets
	# its own serial even though the variable is reused.
	$env:ANDROID_SERIAL = $d
	$p = Start-Process -FilePath $cmdExe -ArgumentList '/c flash-all.bat' `
		-WorkingDirectory $factory `
		-NoNewWindow -PassThru `
		-RedirectStandardInput $nul `
		-RedirectStandardOutput $log -RedirectStandardError "$log.err"
	$procs += New-Object PSObject -Property @{ Serial = $d; Proc = $p; Log = $log }
}
Remove-Item Env:\ANDROID_SERIAL -ErrorAction SilentlyContinue

$results = @()
foreach ($e in $procs) {
	$e.Proc.WaitForExit()
	Merge-ChildLogs -LogPath $e.Log

	# ** THE EXIT CODE ALONE IS NOT ENOUGH ON WINDOWS. **
	#
	# flash-all.bat finishes with a bare `exit`, whose status is whatever cmd
	# happens to be carrying, so a phone that failed can still come back 0. The
	# log is scanned as well -- fastboot prints "FAILED (remote: ...)" on a
	# rejected command, and that is the string that actually distinguishes a bad
	# flash from a good one.
	#
	# Erring towards false FAILEDs on purpose: re-running a phone that was
	# actually fine costs one repeated flash, and this step is idempotent.
	# Missing a real failure ships a phone that was never flashed.
	$ok = ($e.Proc.ExitCode -eq 0)
	if ($ok -and (Test-Path -LiteralPath $e.Log)) {
		$bad = Select-String -LiteralPath $e.Log -Pattern 'FAILED|^error:|Command failed' `
			-ErrorAction SilentlyContinue | Select-Object -First 1
		if ($bad) { $ok = $false }
	}
	$results += New-Object PSObject -Property @{ Serial = $e.Serial; Ok = $ok }
}

foreach ($f in $empties) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

$fail = Write-BatchSummary -Results $results -LogPrefix 'google-'

Write-Host ""
if ($fail -eq 0) {
	Write-Host ("All " + $devices.Count + " phone(s) flashed with Google's image.")
	Write-Host "They reboot into stock Android. Leave them at the welcome screen and"
	Write-Host "put them back into fastboot (hold volume down + power while restarting),"
	Write-Host "then continue with step 5."
	exit 0
}

Write-Host ("$fail of " + $devices.Count + " FAILED. Re-run just those:") -ForegroundColor Red
Write-Host "    cd factory"
Write-Host "    `$env:ANDROID_SERIAL = '<serial>'; .\flash-all.bat"
exit 1
