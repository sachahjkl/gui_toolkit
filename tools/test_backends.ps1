# Runs the toolkit's test packages with one render backend (the pixel tests draw on the offscreen renderer, WARP).
#   tools\test_backends.ps1 [-Backend d3d11|wgpu] [-Only shadows,text] [-TimeoutSec 600]
# Prints PASS / FAIL per package; a log of each run is written to build\test_<backend>_<package>.log.
param(
	[ValidateSet('d3d11', 'wgpu')][string]$Backend = 'd3d11',
	[string[]]$Only,
	[int]$TimeoutSec = 600
)
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot)
New-Item -ItemType Directory build -Force | Out-Null
$all = 'affine', 'layers', 'effects', 'blend_space', 'gradients', 'shadows', 'retained', 'text', 'color_glyphs', 'masks', 'keyboard', 'status', 'states', 'chrome', 'gpufx', 'shaders'
$list = if ($Only) { $Only | ForEach-Object { $_ -split ',' } } else { $all }
$failed = 0
foreach ($t in $list) {
	# wgpu: one test at a time. WARP's D3D12 (d3d10warp.dll) crashes (access violation) now and then when several devices are made and used at once
	$extra = @(if ($t -in 'keyboard', 'status', 'states' -or $Backend -eq 'wgpu') { '-define:ODIN_TEST_THREADS=1' })
	$log = "build\test_${Backend}_$t.log"
	$exe = "build\${t}_${Backend}_test.exe"
	$args = @('test', "tests/$t", '-vet', "-define:TOOLKIT_RENDER=$Backend", "-out:$exe") + $extra
	$sw = [Diagnostics.Stopwatch]::StartNew()
	$p = Start-Process -FilePath odin -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
	if (-not $p.WaitForExit($TimeoutSec * 1000)) {
		Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
		Get-Process -Name "${t}_${Backend}_test" -ErrorAction SilentlyContinue | Stop-Process -Force
		"TIMEOUT $t ($TimeoutSec s)"; $failed++; continue
	}
	$o = (Get-Content $log, "$log.err" -ErrorAction SilentlyContinue | Out-String)
	Add-Content $log $o
	if ($o -match 'All tests were successful') { "PASS $t ({0:N0} s)" -f $sw.Elapsed.TotalSeconds }
	else { "FAIL $t"; ($o -split "`n" | Select-String -Pattern 'Error|FATAL|failed|panick|expected' | Select-Object -First 8) | ForEach-Object { '   ' + $_.Line.Trim() }; $failed++ }
}
if ($failed) { exit 1 }
