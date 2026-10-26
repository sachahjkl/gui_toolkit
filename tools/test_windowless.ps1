# The test packages that need no window of their own (pixel tests draw on WARP, the Direct3D 11 backend), then the native
# text backend against DirectWrite, the UI Automation adapter, the font package on other targets and the COLR interpreter.
# Run by the CI ("tests" job of .github/workflows/ci.yml) after tools\fetch_emoji.ps1 -Unicode; needs cargo for the
# native libraries (tools\build_text.ps1, tools\build_a11y.ps1: skipped when their STAMP is current).
#   powershell -NoProfile -File tools\test_windowless.ps1
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot)
New-Item -ItemType Directory build -Force | Out-Null
$failed = 0

# (a package of one test says 'The test was successful', not 'All tests were successful': text_backends did, and failed the CI)
function Test-Package([string]$name, [string[]]$odinArgs) {
	$sw = [Diagnostics.Stopwatch]::StartNew()
	$o = & odin @odinArgs 2>&1 | Out-String
	# (Write-Host: what a function writes to the pipeline would join its result)
	if ($o -match 'All tests were successful|The test was successful') { Write-Host ("PASS $name ({0:N0} s)" -f $sw.Elapsed.TotalSeconds); return $true }
	Write-Host "FAIL $name"
	Write-Host $o
	return $false
}

foreach ($t in 'affine', 'layers', 'effects', 'blend_space', 'gradients', 'shadows', 'retained', 'text', 'color_glyphs', 'masks', 'keyboard', 'status', 'states', 'chrome', 'ui_robust', 'gpufx', 'shaders', 'appshaders', 'slug', 'colr', 'text_backends', 'a11y') {
	# @( ) around the if: a statement unwraps a one-element array to a string, and @extra would splat its characters
	$extra = @(if ($t -in 'keyboard', 'status', 'states', 'ui_robust', 'a11y') { '-define:ODIN_TEST_THREADS=1' })
	if (-not (Test-Package $t (@('test', "tests/$t", '-vet', "-out:build/${t}_test.exe") + $extra))) { $failed++ }
}
# the native text backend (Fontations, HarfRust, ICU4X) against DirectWrite on the corpus
& ./tools/build_text.ps1
if ($LASTEXITCODE) { 'FAIL build_text'; exit 1 }
if (-not (Test-Package 'text_backends (native)' @('test', 'tests/text_backends', '-vet', '-define:FONT_BACKEND=native', '-out:build/text_backends_native_test.exe'))) { $failed++ }
# accessibility: AccessKit's UI Automation adapter, a window read by a UI Automation client (no screen reader)
& ./tools/build_a11y.ps1
if ($LASTEXITCODE) { 'FAIL build_a11y'; exit 1 }
if (-not (Test-Package 'a11y (UI Automation)' @('test', 'tests/a11y', '-vet', '-define:ODIN_TEST_THREADS=1', '-define:A11Y_ACCESSKIT=true', '-out:build/a11y_uia_test.exe'))) { $failed++ }
odin build tools/uia_probe -vet -out:build/uia_probe.exe
if ($LASTEXITCODE) { 'FAIL uia_probe'; $failed++ } else { 'PASS uia_probe' }
foreach ($tg in 'linux_amd64', 'darwin_arm64') {
	$o = odin check font -target:$tg -no-entry-point -vet 2>&1 | Out-String
	if ($LASTEXITCODE) { "FAIL font on $tg"; $o; $failed++ } else { "PASS font on $tg" }
}
# the color glyph tests again with the COLR interpreter in place of Direct2D
if (-not (Test-Package 'color_glyphs (builtin)' @('test', 'tests/color_glyphs', '-vet', '-define:COLR_ENGINE=builtin', '-out:build/color_glyphs_builtin_test.exe'))) { $failed++ }
if ($failed) { "$failed failed"; exit 1 }
exit 0
