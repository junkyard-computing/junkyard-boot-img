#
# Flash ONE phone with the Junkyard image. Windows twin of ../flash-fastboot.sh.
#
#   powershell -ExecutionPolicy Bypass -File .\flash-fastboot.ps1 <serial>
#
# ** THIS IS A PORT, NOT A REWRITE. ** flash-fastboot.sh is the tested flashing
# path and the sequence below mirrors it step for step -- both slots, AVB
# disabled per slot, super last. If one changes, change the other. The comments
# explaining WHY each step is there are kept in full rather than trimmed to a
# reference, because the operator hitting a problem has this file and not the
# repo.
#
# One deliberate difference from the shell version: the image paths default to
# the kit layout (images\), since this copy only ever runs from the kit -- there
# is no repo checkout on Windows. Everything else is the same sequence with the
# same guards.

[CmdletBinding()]
param(
	[Parameter(Position=0)][string]$Serial,
	[string]$ImageDir,
	[string]$Dtbo,
	[switch]$CommitSlot
)

. (Join-Path $PSScriptRoot '_common.ps1')
Initialize-Kit

# ------------------------------------------------------------------ inputs ---

# Env vars are honoured as well as parameters so flash-batch.ps1 can hand the
# same settings to every child, and so the shell script's documented knobs
# (FASTBOOT_SERIAL, IMAGE_DIR, DTBO, COMMIT_SLOT) mean the same thing here.
function Resolve-KitPath {
	param([string]$Path, [string]$Default)
	if (-not $Path) { $Path = $Default }
	if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
	return (Join-Path $PSScriptRoot $Path)
}

if (-not $Serial -and $env:FASTBOOT_SERIAL) { $Serial = $env:FASTBOOT_SERIAL }
if (-not $ImageDir) { $ImageDir = $env:IMAGE_DIR }
if (-not $Dtbo)     { $Dtbo     = $env:DTBO }

$ImageDir = Resolve-KitPath -Path $ImageDir -Default 'images'
$Dtbo     = Resolve-KitPath -Path $Dtbo     -Default (Join-Path 'images' 'dtbo.img')

$doCommit = [bool]$CommitSlot
if (-not $doCommit -and $env:COMMIT_SLOT -eq '1') { $doCommit = $true }

$fastboot = Get-AndroidTool -Name 'fastboot'

# Which device to flash. REQUIRED -- bare `fastboot` commands target "the single
# attached device", and this script runs `erase super` (the rootfs) among
# others, so with more than one phone on the hub an unscoped run destroys
# whichever one fastboot happened to pick.
if (-not $Serial) {
	Write-Host "refusing to flash: no serial given (this script erases super)." -ForegroundColor Red
	Write-Host "pass one as the first argument or set FASTBOOT_SERIAL. attached devices:"
	& $fastboot devices
	exit 2
}

# ------------------------------------------------------------- preflight ---

# How many phones are attached, recorded BEFORE we flash -- the slot commit at
# the end needs to know, and by the time it runs this phone has rebooted out of
# fastboot.
$attachedList = Get-FastbootDevices -Fastboot $fastboot
$attached = $attachedList.Count

# Confirm the named device is actually in fastboot, so a typo'd serial fails
# here rather than after the first few commands have already run against
# nothing.
if ($attachedList -notcontains $Serial) {
	Write-Host "refusing to flash: '$Serial' is not in fastboot. attached devices:" -ForegroundColor Red
	& $fastboot devices
	exit 2
}

# ** CHECK EVERY IMAGE BEFORE TOUCHING THE PHONE. **
#
# These checks belong before the first fastboot command, not beside the
# partition each one feeds: a super.img test placed after `erase super` leaves a
# phone with no rootfs when the kit turns out to be incomplete. Checking up
# front costs nothing and means an incomplete kit is caught with every phone
# still intact. (The shell version had exactly that ordering bug; both are
# preflighted now.)
$boot       = Join-Path $ImageDir 'boot.img'
$vendorBoot = Join-Path $ImageDir 'vendor_boot.img'
$super      = Join-Path $ImageDir 'super.img'

foreach ($img in @($boot, $vendorBoot, $Dtbo, $super)) {
	if (-not (Test-Path -LiteralPath $img)) {
		Die ("missing $img`n" +
			"    The kit is incomplete or was not fully extracted. Re-extract the`n" +
			"    zip (7-Zip is recommended for it) and run verify-kit.ps1.")
	}
}

# The staleness check the shell script does with debugfs needs rootfs.img
# beside super.img, which only exists in a repo checkout -- the kit ships
# super.img alone and package-provisioning.sh does that comparison at packaging
# time instead. What the kit does carry is images\VERSION, so print it: the
# operator is going to compare this against the phone's screen in step 6.
$versionFile = Join-Path $ImageDir 'VERSION'
if (Test-Path -LiteralPath $versionFile) {
	$kitVersion = "" + (Get-Content -LiteralPath $versionFile -TotalCount 1)
	if ($kitVersion.Trim()) { Say ("image version in this kit: " + $kitVersion.Trim()) }
}

$product = (& $fastboot -s $Serial getvar product 2>&1 | Select-Object -First 1)

# ** REFUSE A PHONE THIS KIT WAS NOT BUILT FOR.
#
# images\DEVICE is written by package-provisioning.sh and names the one device
# this kit holds images for. felix and lynx are both gs201 and both accept every
# fastboot command here happily, but the images are incompatible -- and this
# script erases `super` and writes both slots, so a wrong-device run destroys the
# phone's rootfs and both boot chains before anything can reject it.
#
# Matched loosely: `getvar product` output is the raw fastboot line, which
# carries the value plus decoration that differs across platform-tools versions.
$deviceFile = Join-Path $ImageDir 'DEVICE'
if (Test-Path -LiteralPath $deviceFile) {
	$kitDevice = ("" + (Get-Content -LiteralPath $deviceFile -TotalCount 1)).Trim()
	if ($kitDevice -and ($product -notmatch [regex]::Escape($kitDevice))) {
		Die ("this kit is for '$kitDevice', but $Serial reports: $product`n" +
			"    Use the kit built for that phone. Flashing this one would`n" +
			"    erase its rootfs and write a boot chain it cannot run.")
	}
	if ($kitDevice) { Say ("kit device: $kitDevice") }
}

Say "flashing $Serial ($product)"

# Every fastboot command goes through this, so none of them can pick a device.
function Invoke-Fastboot {
	param([Parameter(Mandatory=$true)][string[]]$FbArgs, [switch]$AllowFail)

	& $fastboot -s $Serial @FbArgs
	$code = $LASTEXITCODE
	if ($code -ne 0 -and -not $AllowFail) {
		throw ("fastboot " + ($FbArgs -join ' ') + " failed (exit $code)")
	}
}

try {
	# ** FLASH THE BOOT CHAIN TO BOTH SLOTS, and disable AVB on both.
	#
	# Flashing unsuffixed partitions targets whichever slot is active, so only
	# ONE slot would get our boot chain. `super` is not slotted and super.img
	# seeds both halves with our rootfs, so the other slot would end up pairing
	# a stock/stale kernel with our Debian rootfs half.
	#
	# That is the rollback target. A unit that rolls back -- because its slot
	# was never committed and the bootloader's retry counter hit zero -- lands
	# on a chain that cannot bring our system up, on hardware with no screen and
	# no buttons. Flashing both slots makes a rollback survivable instead of
	# terminal.
	#
	# ** The set-active dance is REQUIRED, not decoration: `oem
	# disable-verification` and `oem disable-verity` apply ONLY to the slot that
	# is active when they run. Flashing our unsigned repacked chain into a slot
	# whose AVB is still enforcing produces a silent rollback -- the flash
	# reports success, the hashes match, and the slot simply never boots.
	foreach ($slot in @('a', 'b')) {
		Say "preparing slot $slot (set-active, then disable AVB for THAT slot)"
		Invoke-Fastboot @('--set-active=' + $slot)
		Invoke-Fastboot @('oem', 'disable-verification')
		Invoke-Fastboot @('oem', 'disable-verity')

		Invoke-Fastboot @('erase', "init_boot_$slot")          -AllowFail
		Invoke-Fastboot @('erase', "boot_$slot")               -AllowFail
		Invoke-Fastboot @('flash', "boot_$slot", $boot)
		Invoke-Fastboot @('erase', "vendor_boot_$slot")        -AllowFail
		Invoke-Fastboot @('flash', "vendor_boot_$slot", $vendorBoot)
		Invoke-Fastboot @('erase', "dtbo_$slot")               -AllowFail
		Invoke-Fastboot @('flash', "dtbo_$slot", $Dtbo)
		Invoke-Fastboot @('erase', "vendor_kernel_boot_$slot") -AllowFail
	}

	# Leave slot A active. Both slots now carry an identical, AVB-permissive
	# chain, so this is a choice of starting point rather than a fallback
	# arrangement.
	Invoke-Fastboot @('--set-active=a')

	Invoke-Fastboot @('erase', 'super')

	# ** super.img, NOT rootfs.img -- this is the FULL FLASH, and it is what
	# leaves the device in a valid A/B state. rootfs.img is one rootfs sized to
	# fit ONE HALF of super; flashing it here would land it at offset 0 (slot A)
	# and leave slot B holding whatever was there before, so the very first OTA
	# would switch into a half that has never contained a filesystem.
	#
	# That matters most for the case with no recovery path. A device whose
	# fallback half is garbage looks completely healthy -- it boots, it is
	# reachable, nothing reports a problem -- right up until an update fails its
	# retries and the bootloader rolls back into an unmountable half.
	Say "flashing super (7.9 GB -- this is the slow one, do not unplug)"
	Invoke-Fastboot @('flash', 'super', $super)

	Invoke-Fastboot @('reboot')
} catch {
	Write-Host ""
	Write-Host ("FAILED on $Serial : " + $_.Exception.Message) -ForegroundColor Red
	Write-Host "The phone has NOT been left in a known state. Put it back into" -ForegroundColor Red
	Write-Host "fastboot and re-run this script for that serial." -ForegroundColor Red
	exit 1
}

# ---------------------------------------------------------- commit the slot ---
#
# ** COMMIT THE FLASHED SLOT.
#
# fastboot leaves slot metadata alone, and `--set-active` above marks the slot
# active but NOT successful. Nothing on the device commits a slot until netcheck
# proves a network -- so a factory-flashed unit that never sees one spends its 7
# bootloader retries and rolls back, silently, having looked healthy the whole
# time.
#
# ** OPT-IN (COMMIT_SLOT=1), AND ONLY WITH ONE PHONE ATTACHED.
#
# EVERY phone serves its USB gadget on the SAME address, 10.42.0.1. With a hub
# full of them the host ends up with several 10.42.0.x interfaces all routing to
# that one address, and the connection lands on whichever route wins -- not on
# the phone we just flashed.
#
# Defaulting this OFF is safe because this script writes the boot chain to BOTH
# slots: an uncommitted slot that rolls back lands on an identical system.
if (-not $doCommit) {
	Say "not committing the slot (COMMIT_SLOT=0; both slots hold this image)"
	exit 0
}
if ($attached -gt 1) {
	Warn "$attached phones were attached -- skipping the slot commit."
	Note "Every phone answers on 10.42.0.1, so it cannot be aimed at one of them."
	Note "Harmless: both slots carry this image, so a rollback changes nothing."
	exit 0
}

$gadget = $env:GADGET
if (-not $gadget) { $gadget = '10.42.0.1' }
$sshKey = $env:SSH_KEY
if (-not $sshKey) { $sshKey = Join-Path (Join-Path $env:USERPROFILE '.ssh') 'junkyard-fleet' }

$ssh = Get-Command 'ssh.exe' -CommandType Application -ErrorAction SilentlyContinue |
	Select-Object -First 1
if (-not $ssh) {
	Warn "COMMIT_SLOT was asked for but ssh.exe is not installed."
	Note "Windows 10/11: Settings > Apps > Optional features > OpenSSH Client."
	Note "Harmless here: both slots carry this image."
	exit 0
}
if (-not (Test-Path -LiteralPath $sshKey)) {
	Warn "COMMIT_SLOT was asked for but no SSH key at $sshKey."
	Note "Set SSH_KEY to the fleet key, or leave COMMIT_SLOT off."
	exit 0
}

# UserKnownHostsFile=NUL is the Windows spelling of /dev/null. The remote
# commands are passed as separate words with no quoting of their own: ssh joins
# them for the remote shell, and PowerShell's native-argument quoting mangles
# embedded quotes often enough that it is not worth relying on. The serial is
# parsed HERE instead, out of the raw bootconfig line.
$sshOpts = @(
	'-i', $sshKey,
	'-o', 'IdentitiesOnly=yes',
	'-o', 'BatchMode=yes',
	'-o', 'StrictHostKeyChecking=no',
	'-o', 'UserKnownHostsFile=NUL',
	'-o', 'LogLevel=ERROR',
	'-o', 'ConnectTimeout=6'
)
$target = "kalm@$gadget"

Say "waiting for $Serial to come back on the USB gadget to commit its slot"
$committed = $false
for ($i = 1; $i -le 40; $i++) {
	Start-Sleep -Seconds 15

	$line = & $ssh.Source @sshOpts $target grep -m1 androidboot.serialno /proc/bootconfig 2>$null
	if ($LASTEXITCODE -ne 0) { continue }

	$seen = ''
	if ("$line" -match 'androidboot\.serialno\s*=\s*"?([A-Za-z0-9]+)"?') { $seen = $Matches[1] }

	# Confirm it is the unit we just flashed -- the gadget address is fixed, so
	# a different phone on the same bench would answer to it just as readily.
	if ($seen -ne $Serial) { continue }

	& $ssh.Source @sshOpts $target sudo /usr/local/bin/pixel-bootctl mark-successful 2>$null | Out-Null
	if ($LASTEXITCODE -eq 0) {
		Say "slot committed on $Serial"
		& $ssh.Source @sshOpts $target sudo /usr/local/bin/pixel-bootctl status 2>$null |
			ForEach-Object { Note $_ }
		$committed = $true
	}
	break
}

if (-not $committed) {
	Write-Host ""
	Warn "could not commit the slot on $Serial over the USB gadget."
	Warn "The slot is ACTIVE but NOT SUCCESSFUL. If this unit reboots ~7 times"
	Warn "before something proves a network, the bootloader will roll it back."
	Warn "Both slots now carry the same chain, so a rollback is survivable --"
	Warn "but the unit would be running the other slot, not the one you flashed."
	Warn "Fix: boot it, confirm reachability, and run:"
	Warn "    sudo pixel-bootctl mark-successful"
}
exit 0
