# Draws the gui_toolkit logo (512x512 PNG): a cobalt rounded square with a soft vertical gradient and a darker border,
# carrying a white switch above a white slider ("a toolkit of widgets"). Knob holes show the background through.
#   powershell -File tools/make_logo.ps1 [-Out .project/image.png]
param([string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) '.project\image.png'))
Add-Type -AssemblyName System.Drawing
$S = 4; $N = 512 * $S   # supersampled, then downscaled

function Hex($v) { return [Drawing.Color]::FromArgb(255, ($v -shr 16) -band 255, ($v -shr 8) -band 255, $v -band 255) }
function RoundRect($x, $y, $w, $h, $r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = 2 * $r
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $p.CloseFigure(); return $p
}
function Pt($x, $y) { return New-Object Drawing.PointF ([single]($x * $S)), ([single]($y * $S)) }

$b = New-Object Drawing.Bitmap $N, $N
$g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)

# cobalt body: lighter at the top, deeper at the bottom
$fill = New-Object Drawing.Drawing2D.LinearGradientBrush (Pt 0 56), (Pt 0 456), (Hex 0x2f6fd8), (Hex 0x0b3f9c)
$g.FillPath($fill, (RoundRect (56*$S) (56*$S) (400*$S) (400*$S) (100*$S)))

# darker border, drawn just inside the edge (also a gradient, so it stays darker than the body everywhere)
$bw = 10
$edge = New-Object Drawing.Drawing2D.LinearGradientBrush (Pt 0 56), (Pt 0 456), (Hex 0x1a4fae), (Hex 0x062a6e)
$pen = New-Object Drawing.Pen $edge, ([single]($bw * $S))
$g.DrawPath($pen, (RoundRect ((56 + $bw/2)*$S) ((56 + $bw/2)*$S) ((400 - $bw)*$S) ((400 - $bw)*$S) ((100 - $bw/2)*$S)))

# a faint highlight along the top inner edge
$hl = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(40, 255, 255, 255)), ([single](2 * $S))
$g.DrawPath($hl, (RoundRect ((56 + $bw + 1)*$S) ((56 + $bw + 1)*$S) ((400 - 2*$bw - 2)*$S) ((400 - 2*$bw - 2)*$S) ((100 - $bw)*$S)))

$white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
# switch (on): white track, knob hole shows the body gradient
$g.FillPath($white, (RoundRect (136*$S) (150*$S) (240*$S) (104*$S) (52*$S)))
$g.FillEllipse($fill, [single]((324-38)*$S), [single]((202-38)*$S), [single](76*$S), [single](76*$S))
# slider: track + knob with a hole
$g.FillPath($white, (RoundRect (136*$S) (326*$S) (240*$S) (30*$S) (15*$S)))
$g.FillEllipse($white, [single]((222-40)*$S), [single]((341-40)*$S), [single](80*$S), [single](80*$S))
$g.FillEllipse($fill, [single]((222-18)*$S), [single]((341-18)*$S), [single](36*$S), [single](36*$S))

$o = New-Object Drawing.Bitmap 512, 512
$g2 = [Drawing.Graphics]::FromImage($o); $g2.InterpolationMode = 'HighQualityBicubic'; $g2.PixelOffsetMode = 'HighQuality'
$g2.DrawImage($b, 0, 0, 512, 512)
$o.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
"wrote $Out"
