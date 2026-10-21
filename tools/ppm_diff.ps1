# Compares two P6 PPM files (render_probe output): maximum and mean absolute difference per channel, and the count of pixels
# that differ by more than -Tolerance levels.   tools\ppm_diff.ps1 a.ppm b.ppm [-Tolerance 2]
param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B, [int]$Tolerance = 2)
function Read-Ppm($path) {
	$b = [IO.File]::ReadAllBytes($path)
	$pos = 0; $tok = @()
	while ($tok.Count -lt 4) {
		while ($b[$pos] -le 32) { $pos++ }
		$s = $pos; while ($b[$pos] -gt 32) { $pos++ }
		$tok += [Text.Encoding]::ASCII.GetString($b, $s, $pos - $s)
	}
	$pos++
	[pscustomobject]@{ W = [int]$tok[1]; H = [int]$tok[2]; Data = $b[$pos..($b.Length - 1)] }
}
$x = Read-Ppm $A; $y = Read-Ppm $B
if ($x.W -ne $y.W -or $x.H -ne $y.H) { throw "sizes differ: $($x.W)x$($x.H) vs $($y.W)x$($y.H)" }
$max = 0; $sum = 0; $bad = 0
for ($i = 0; $i -lt $x.Data.Length; $i += 3) {
	$worst = 0
	for ($c = 0; $c -lt 3; $c++) { $d = [Math]::Abs([int]$x.Data[$i + $c] - [int]$y.Data[$i + $c]); $sum += $d; if ($d -gt $worst) { $worst = $d } }
	if ($worst -gt $max) { $max = $worst }
	if ($worst -gt $Tolerance) { $bad++ }
}
"{0}x{1}: max {2}, mean {3:N3}, pixels over {4}: {5}" -f $x.W, $x.H, $max, ($sum / $x.Data.Length), $Tolerance, $bad
