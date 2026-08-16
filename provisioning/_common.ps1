#
# Shared helpers for the Windows (PowerShell) half of the provisioning kit.
#
# ** COMPATIBILITY: Windows PowerShell 5.1 AND PowerShell 7 (pwsh). **
#
# 5.1 is the version that is already on every Windows 10/11 machine, so it is
# the floor: nothing here may use syntax newer than that. In practice that
# rules out the ternary operator, the ?? operators, ForEach-Object -Parallel,
# Get-Error, and $PSStyle. Parallelism is done with Start-Process, which
# behaves identically on both.
#
# ** ASCII ONLY. **
#
# Windows PowerShell 5.1 reads a .ps1 that has no byte-order mark using the
# system ANSI code page, not UTF-8. A single non-ASCII character (an arrow, a
# warning sign, an em dash) therefore reaches the operator as mojibake, in the
# one document they are supposed to read carefully. Keep every one of these
# files 7-bit clean.

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ output ---

function Say  { param([string]$Message) Write-Host ">>> $Message" }
function Note { param([string]$Message) Write-Host "    $Message" }

function Warn {
	param([string]$Message)
	Write-Host "!!! $Message" -ForegroundColor Yellow
}

function Die {
	param([string]$Message)
	Write-Host "ERROR: $Message" -ForegroundColor Red
	exit 1
}

# ------------------------------------------------------------ prerequisites ---

# PowerShell 2.0 (Windows 7) lacks [pscustomobject], Unblock-File and
# Get-FileHash, so fail here with a plain sentence rather than several
# scripts deep with a parser error.
function Assert-PowerShellVersion {
	if ($PSVersionTable.PSVersion.Major -lt 5) {
		Die ("this kit needs Windows PowerShell 5.1 or newer (found " +
			"$($PSVersionTable.PSVersion)). Windows 10 and 11 have it already; " +
			"on anything older install Windows Management Framework 5.1.")
	}
}

# Files extracted from a downloaded .zip carry Windows' mark-of-the-web, and
# under the default RemoteSigned policy that blocks them with a message about
# signing that has nothing to do with the real cause. Clearing it on our own
# scripts costs nothing and removes the single most likely first-five-minutes
# failure. It also matters for the batch scripts specifically: they launch the
# per-phone scripts as child processes, which are subject to the same check.
function Unblock-KitScripts {
	if (-not (Get-Command Unblock-File -ErrorAction SilentlyContinue)) { return }
	try {
		Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -ErrorAction SilentlyContinue |
			Unblock-File -ErrorAction SilentlyContinue
	} catch { }
}

function Initialize-Kit {
	Assert-PowerShellVersion
	Unblock-KitScripts
}

# ------------------------------------------------------------------- tools ---

# adb.exe / fastboot.exe. Looked for beside the kit BEFORE $PATH, because
# "unzip platform-tools into this folder" is the shortest instruction that
# works on a machine where the operator may not be able to edit the system
# PATH, and it keeps the tool version pinned to the folder rather than to
# whatever some other Android install left behind.
function Resolve-AndroidTool {
	param([Parameter(Mandatory=$true)][string]$Name)

	# Built with nested Join-Path rather than a "dir\file" literal so the path
	# separator is the shell's to choose, not ours.
	foreach ($p in @(
			(Join-Path (Join-Path $PSScriptRoot 'platform-tools') "$Name.exe"),
			(Join-Path $PSScriptRoot "$Name.exe"))) {
		if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
	}
	$cmd = Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue |
		Select-Object -First 1
	if ($cmd) { return $cmd.Source }
	return $null
}

function Get-AndroidTool {
	param([Parameter(Mandatory=$true)][string]$Name)

	$path = Resolve-AndroidTool -Name $Name
	if (-not $path) {
		Die ("$Name.exe not found.`n" +
			"    Get Google's platform-tools (developer.android.com/tools/releases/platform-tools)`n" +
			"    and unzip it into this folder, so that`n" +
			"        $PSScriptRoot\platform-tools\$Name.exe`n" +
			"    exists. Adding it to your PATH works too.")
	}
	return $path
}

# Google's flash-all.bat issues bare `fastboot` commands, so whichever copy we
# resolved above has to be findable by name in a child process too. Prepending
# rather than appending means our pinned copy wins over any other Android
# install on the machine.
function Add-ToolDirToPath {
	param([Parameter(Mandatory=$true)][string]$ToolPath)
	$dir = Split-Path -Parent $ToolPath
	$sep = [System.IO.Path]::PathSeparator
	if (($env:PATH -split $sep) -notcontains $dir) { $env:PATH = "$dir$sep$env:PATH" }
}

# ----------------------------------------------------------------- devices ---

# `fastboot devices` prints "<serial>\tfastboot" per device. Match that shape
# rather than taking the first token of every line, so a stray diagnostic on
# stdout cannot be mistaken for a serial and flashed.
function Get-FastbootDevices {
	param([Parameter(Mandatory=$true)][string]$Fastboot)

	$serials = @()
	$out = & $Fastboot devices 2>$null
	foreach ($line in $out) {
		if ("$line" -match '^\s*(\S+)\s+fastboot\s*$') { $serials += $Matches[1] }
	}
	return ,$serials
}

# `adb devices` prints "<serial>\t<state>", where state is device, unauthorized,
# offline or similar. The state is reported rather than filtered, because a
# phone silently missing from a batch is exactly the failure this kit is trying
# to prevent.
function Get-AdbDevices {
	param([Parameter(Mandatory=$true)][string]$Adb)

	$rows = @()
	$out = & $Adb devices 2>$null
	foreach ($line in $out) {
		$s = "$line"
		if ($s -match '^\s*$') { continue }
		if ($s -match '^List of devices') { continue }
		if ($s -match '^\s*(\S+)\s+(\S+)\s*$') {
			$rows += New-Object PSObject -Property @{ Serial = $Matches[1]; State = $Matches[2] }
		}
	}
	return ,$rows
}

# ------------------------------------------------------- parallel execution ---

# The PowerShell (or pwsh) we are running under, so a child process is the same
# edition as the parent. Start-Job is deliberately not used: a job inherits the
# session's execution policy, whereas a child process can be handed
# -ExecutionPolicy Bypass, and a real process gives a real exit code.
function Get-PSExecutable {
	try {
		$p = (Get-Process -Id $PID).Path
		if ($p -and (Test-Path -LiteralPath $p)) { return $p }
	} catch { }
	if ($PSVersionTable.PSEdition -eq 'Core') { return 'pwsh' }
	return (Join-Path $PSHOME 'powershell.exe')
}

# Start-Process refuses to send stdout and stderr to the same file, but the
# operator was promised ONE log per phone, so the two are merged once the
# process is done.
function Merge-ChildLogs {
	param([Parameter(Mandatory=$true)][string]$LogPath)

	$errPath = "$LogPath.err"
	if (-not (Test-Path -LiteralPath $errPath)) { return }
	$len = (Get-Item -LiteralPath $errPath).Length
	if ($len -gt 0) {
		Add-Content -LiteralPath $LogPath -Value (Get-Content -LiteralPath $errPath)
	}
	Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
}

# Print the OK/FAILED summary both batch scripts end with, and return the
# number that failed. Backgrounding without reporting per phone would let one
# failure in a batch of twenty scroll past unnoticed, and an unnoticed failure
# here is a phone that ships broken.
function Write-BatchSummary {
	param(
		[Parameter(Mandatory=$true)][array]$Results,
		[Parameter(Mandatory=$true)][string]$LogPrefix
	)

	$fail = 0
	foreach ($r in $Results) {
		if ($r.Ok) {
			Write-Host ("  OK      " + $r.Serial)
		} else {
			Write-Host ("  FAILED  " + $r.Serial + "   (see $LogPrefix" + $r.Serial + ".log)") -ForegroundColor Red
			$fail++
		}
	}
	return $fail
}
