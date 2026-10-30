# Runs the toolkit's test packages with one render backend (the pixel tests draw on the offscreen renderer, WARP).
#   tools\test_backends.ps1 [-Backend d3d11|wgpu] [-Only shadows,text | -Group ci1] [-Define NAME=value] [-TimeoutSec 600]
# Prints PASS / FAIL per package; a log of each run is written to build\test_<backend>_<package>.log.
#   -Group   one of the sets of packages below (the CI runs one per job: .github/workflows/ci.yml); ci1..ci4 together are
#            every package, each once (checked here: a package added to $all and to no group fails the CI)
#   -Define  extra -define:NAME=value for odin test, e.g. TOOLKIT_WGPU_DX12_COMPILER=fxc
param(
	[ValidateSet('d3d11', 'wgpu')][string]$Backend = 'd3d11',
	[string[]]$Only,
	[string]$Group,
	[string[]]$Define,
	[int]$TimeoutSec = 600
)
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot)
New-Item -ItemType Directory build -Force | Out-Null
$all = 'affine', 'layers', 'planes', 'effects', 'blend_space', 'gradients', 'shadows', 'retained', 'text', 'color_glyphs', 'masks', 'keyboard', 'status', 'states', 'chrome', 'ui_robust', 'gpufx', 'slug', 'shaders', 'appshaders', 'colr', 'video', 'textures'
# Balanced on the time each package takes on WARP with DXC (wgpu, about 1.5 to 2 min of tests per group locally, 4 min on a
# CI runner); 'sample' is the quick set of a pull request: Slug text, video, filters and blends, layers and offscreen draws.
$groups = [ordered]@{
	ci1    = 'gpufx', 'slug', 'colr', 'text', 'shaders', 'affine', 'status', 'states', 'chrome', 'ui_robust'
	ci2    = 'planes', 'effects', 'gradients', 'keyboard', 'video'
	ci3    = 'appshaders', 'blend_space', 'color_glyphs', 'masks'
	ci4    = 'retained', 'layers', 'shadows', 'textures'
	sample = 'slug', 'video', 'effects', 'layers'
}
$inGroups = @($groups.Keys | Where-Object { $_ -like 'ci*' } | ForEach-Object { $groups[$_] })
$missing = @($all | Where-Object { $_ -notin $inGroups })
$twice = @($inGroups | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$unknown = @($inGroups | Where-Object { $_ -notin $all })
if ($missing.Count -or $twice.Count -or $unknown.Count) {
	"FAIL groups: in no group: $($missing -join ', '); in two: $($twice -join ', '); not a package: $($unknown -join ', ')"
	exit 1
}
if ($Group) {
	if (-not $groups.Contains($Group)) { "FAIL unknown group $Group ($($groups.Keys -join ', '))"; exit 1 }
	$list = $groups[$Group]
} elseif ($Only) { $list = $Only | ForEach-Object { $_ -split ',' } } else { $list = $all }
$defines = @($Define | Where-Object { $_ } | ForEach-Object { "-define:$_" })
$failed = 0
foreach ($t in $list) {
	# wgpu: one test at a time. WARP's D3D12 (d3d10warp.dll) crashes (access violation) now and then when several devices are made and used at once
	$extra = @(if ($t -in 'keyboard', 'status', 'states', 'ui_robust', 'a11y' -or $Backend -eq 'wgpu') { '-define:ODIN_TEST_THREADS=1' })
	$log = "build\test_${Backend}_$t.log"
	$exe = "build\${t}_${Backend}_test.exe"
	$args = @('test', "tests/$t", '-vet', "-define:TOOLKIT_RENDER=$Backend", "-out:$exe") + $extra + $defines
	$sw = [Diagnostics.Stopwatch]::StartNew()
	$p = Start-Process -FilePath odin -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
	$null = $p.Handle   # (kept open: without it ExitCode is empty once the process has ended)
	if (-not $p.WaitForExit($TimeoutSec * 1000)) {
		Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
		Get-Process -Name "${t}_${Backend}_test" -ErrorAction SilentlyContinue | Stop-Process -Force
		"TIMEOUT $t ($TimeoutSec s)"; $failed++; continue
	}
	$o = (Get-Content $log, "$log.err" -ErrorAction SilentlyContinue | Out-String)
	Add-Content $log $o
	$name = if ($defines.Count) { "$t ($($Define -join ' '))" } else { $t }
	# (a package of one test says 'The test was successful', not 'All tests were successful')
	if ($o -match 'All tests were successful|The test was successful') { "PASS $name ({0:N0} s)" -f $sw.Elapsed.TotalSeconds }
	else { "FAIL $name (exit code 0x{0:X8})" -f $p.ExitCode; ($o -split "`n" | Select-String -Pattern 'Error|FATAL|failed|panick|expected' | Select-Object -First 8) | ForEach-Object { '   ' + $_.Line.Trim() }; $failed++ }
}
if ($failed) { exit 1 }
exit 0
