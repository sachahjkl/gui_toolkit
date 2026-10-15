# Builds a multi-size .ico (PNG-compressed, 16..256 px) from a 512x512 logo with the rounded square at (56,56)-(456,456).
#   powershell -File tools/make_icon.ps1 -Png .project/image.png -Out examples/todo/icon.ico
param([Parameter(Mandatory=$true)][string]$Png, [Parameter(Mandatory=$true)][string]$Out)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$src = [Drawing.Image]::FromFile((Resolve-Path $Png))
$crop = New-Object Drawing.Rectangle 56, 56, 400, 400   # drop the transparent margin so the icon fills its frame
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach($s in $sizes) {
  $bmp = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([Drawing.Color]::Transparent)
  $g.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $s, $s), $crop, [Drawing.GraphicsUnit]::Pixel)
  $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $pngs += , $ms.ToArray()
  $g.Dispose(); $bmp.Dispose()
}
$src.Dispose()
$stream = [IO.MemoryStream]::new()
$w = [IO.BinaryWriter]::new($stream)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $dim = if($s -ge 256) { 0 } else { $s }
  $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
  $offset += $pngs[$i].Length
}
foreach($p in $pngs) { $w.Write($p) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path (Get-Location) $Out), $stream.ToArray())
"wrote $Out"
