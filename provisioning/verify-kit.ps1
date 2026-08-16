#
# Step 0 (Windows): check the kit arrived intact.
#
# The Linux instruction is `sha256sum -c SHA256SUMS`. Windows has no sha256sum,
# and certutil can only hash one file at a time and cannot compare against a
# list, so this reads the same SHA256SUMS file and does the same job.
#
# Worth the ten minutes it takes: the kit is several GB, and a truncated
# super.img does not fail loudly -- it fails as a phone that flashes fine and
# then will not boot, which is a far more expensive thing to debug.

[CmdletBinding()]
param(
	[string]$SumsFile
)

. (Join-Path $PSScriptRoot '_common.ps1')
Initialize-Kit

if (-not $SumsFile) { $SumsFile = Join-Path $PSScriptRoot 'SHA256SUMS' }
if (-not (Test-Path -LiteralPath $SumsFile)) { Die "no SHA256SUMS beside this script ($SumsFile)" }

$entries = @()
foreach ($line in (Get-Content -LiteralPath $SumsFile)) {
	# GNU sha256sum: "<64 hex>  <path>", or "<64 hex> *<path>" in binary mode.
	if ("$line" -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
		$rel = $Matches[2] -replace '^\./', '' -replace '/', '\'
		$entries += New-Object PSObject -Property @{
			Hash = $Matches[1].ToLower()
			Rel  = $rel
			Path = (Join-Path $PSScriptRoot $rel)
		}
	}
}

if ($entries.Count -eq 0) { Die "SHA256SUMS has no usable lines -- was it mangled in transit?" }

$total = ($entries | Where-Object { Test-Path -LiteralPath $_.Path } |
	ForEach-Object { (Get-Item -LiteralPath $_.Path).Length } |
	Measure-Object -Sum).Sum
if (-not $total) { $total = 0 }
Say ("checking " + $entries.Count + " files (" + [math]::Round($total / 1GB, 1) + " GB) -- this takes a while")

$bad = 0
$i = 0
foreach ($e in $entries) {
	$i++
	Write-Progress -Activity 'Verifying kit' -Status $e.Rel `
		-PercentComplete ([int](100 * $i / $entries.Count))

	if (-not (Test-Path -LiteralPath $e.Path)) {
		Write-Host ("  MISSING   " + $e.Rel) -ForegroundColor Red
		$bad++
		continue
	}
	$got = (Get-FileHash -LiteralPath $e.Path -Algorithm SHA256).Hash.ToLower()
	if ($got -ne $e.Hash) {
		Write-Host ("  CORRUPT   " + $e.Rel) -ForegroundColor Red
		$bad++
	} else {
		Write-Host ("  OK        " + $e.Rel)
	}
}
Write-Progress -Activity 'Verifying kit' -Completed

Write-Host ""
if ($bad -eq 0) {
	Write-Host ("All " + $entries.Count + " files verified. The kit is intact -- start at step 1.")
	exit 0
}

Write-Host "$bad file(s) did not verify." -ForegroundColor Red
Write-Host "Do not flash anything with this copy. Get the kit again and re-extract it"
Write-Host "(use 7-Zip -- Windows Explorer's built-in unzip is unreliable at this size)."
exit 1
