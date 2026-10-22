# Conformance board of the COLR interpreter against Chrome / Edge on the same font file (tools\colrboard).
#   tools\emoji_board.ps1 [-Size 32] [-Scale 1] [-Step 37] [-Font <ttf>] [-OutDir build\board]
# Takes every -Step-th fully qualified emoji of Unicode's emoji-test.txt (plus a few hand-picked sequences), has the
# interpreter and a headless Edge draw them, writes side.png (browser | interpreter | difference) and prints the numbers.
param(
	[int]$Size = 32,
	[double]$Scale = 1,
	[int]$Step = 37,
	[string]$Font = '',
	[string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Set-Location $root
if (-not $Font) {
	& powershell -NoProfile -File tools\fetch_emoji.ps1 -Unicode | Out-Null
	$Font = Join-Path $root 'build\emoji\NotoColorEmoji-COLRv1.ttf'
}
if (-not $OutDir) { $OutDir = "build\board_${Size}_$Scale" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tests = Get-Content (Join-Path (Split-Path $Font) 'emoji-test.txt') -Encoding UTF8 | Where-Object { $_ -match '^[0-9A-F]' -and $_ -match '; fully-qualified' }
$list = @()
for ($i = 0; $i -lt $tests.Count; $i += $Step) { $list += ($tests[$i] -split ';')[0].Trim() }
# a few that are known to be hard: flags, family ZWJ, skin tone ZWJ, keycap, rainbow flag, tags
$list += '1F3F3 FE0F 200D 1F308', '1F468 200D 1F469 200D 1F467 200D 1F466', '1F9D1 1F3FD 200D 1F680', '0031 FE0F 20E3', '1F1EB 1F1F7', '1F3F4 E0067 E0062 E0065 E006E E0067 E007F', '2764 FE0F 200D 1F525'
$listFile = Join-Path $OutDir 'list.txt'
[IO.File]::WriteAllLines((Join-Path $root $listFile), $list)
New-Item -ItemType Directory -Force build | Out-Null
& odin build tools/colrboard -vet -out:build/colrboard.exe
if ($LASTEXITCODE) { throw 'build failed' }
& build\colrboard.exe write $Font $listFile $OutDir $Size $Scale
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$cols = 12
$cw = (([int]($Size * 9 / 5)) + 3) -band (-bnot 3)
$ch = (([int]($Size * 8 / 5)) + 3) -band (-bnot 3)
$rows = [Math]::Ceiling($list.Count / $cols)
$wpx = $cols * $cw; $hpx = $rows * $ch
$png = Join-Path $OutDir 'edge.png'
Remove-Item $png -ErrorAction SilentlyContinue
$prof = Join-Path ([IO.Path]::GetTempPath()) "board-edge-$PID"
$html = (Resolve-Path (Join-Path $OutDir 'board.html')).Path.Replace('\', '/')
$p = Start-Process $edge -ArgumentList @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--disable-extensions', "--user-data-dir=$prof",
	'--allow-file-access-from-files', "--force-device-scale-factor=$([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Scale))",
	"--window-size=$wpx,$hpx", '--virtual-time-budget=4000', "--screenshot=$((Join-Path $root $png))", "file:///$html") -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'edge timed out' }
if (-not (Test-Path $png)) { throw 'no screenshot' }
& build\colrboard.exe compare $Font $listFile $png $OutDir $Size $Scale
