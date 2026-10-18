# Regenerates docs/screenshots/*.png (window captures, resized to 1400 px wide).
# Uses clean default settings (the user's settings are moved aside and restored). The mouse cursor is parked outside
# each window while it is captured (otherwise the app shows hover states), then put back.
#   powershell -File tools/screenshots.ps1 [-Only name]
param([string]$Only = "")
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo 'docs\screenshots'
New-Item -ItemType Directory -Force $out | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class S1 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
Add-Type -AssemblyName System.Drawing
[S1]::SetProcessDPIAware() | Out-Null

$script:cursor = New-Object S1+POINT
[S1]::GetCursorPos([ref]$script:cursor) | Out-Null

function Capture($exe, $argList, $name, $waitMs) {
  if($Only -ne "" -and $name -ne $Only) { return }
  if($argList) { $p = Start-Process $exe -ArgumentList $argList -PassThru -WorkingDirectory (Split-Path $exe) }
  else { $p = Start-Process $exe -PassThru -WorkingDirectory (Split-Path $exe) }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while(-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
  $h = $p.MainWindowHandle
  # park the cursor just outside the window before it can produce hover states (left of it, or above if no room)
  $r0 = New-Object S1+RECT; [S1]::GetWindowRect($h, [ref]$r0) | Out-Null
  if($r0.L -gt 20) { [S1]::SetCursorPos($r0.L - 15, $r0.T + 200) | Out-Null } else { [S1]::SetCursorPos($r0.R + 15, $r0.T + 200) | Out-Null }
  [S1]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null
  [S1]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds $waitMs
  # the visible frame only (DWMWA_EXTENDED_FRAME_BOUNDS): GetWindowRect includes the invisible resize border,
  # through which whatever is behind the window would end up in the capture
  $r = New-Object S1+RECT
  if([S1]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [S1]::GetWindowRect($h, [ref]$r) | Out-Null }
  $w = $r.R - $r.L; $hh = $r.B - $r.T
  # only capture when our window is really what is visible (never grab someone else's window)
  $pt = New-Object S1+POINT; $pt.X = $r.L + [int]($w / 2); $pt.Y = $r.T + [int]($hh / 2)
  if([S1]::GetAncestor([S1]::WindowFromPoint($pt), 2) -ne $h) { $p.Kill(); throw "window covered, not capturing $name" }
  $grab = New-Object Drawing.Bitmap $w, $hh
  [Drawing.Graphics]::FromImage($grab).CopyFromScreen($r.L, $r.T, 0, 0, $grab.Size)
  $p.Kill()
  # Windows 11 rounds window corners and the frame bounds can include a 1 px seam: whatever is behind the window
  # shows there. Inset by 1 px and make the corners transparent so nothing from the desktop ends up in the image.
  $inset = 1
  $w -= 2 * $inset; $hh -= 2 * $inset
  $full = New-Object Drawing.Bitmap $w, $hh, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $gf = [Drawing.Graphics]::FromImage($full); $gf.Clear([Drawing.Color]::Transparent); $gf.SmoothingMode = 'AntiAlias'
  $rad = [Math]::Max(8, [int]((($r.R - $r.L) / 2089.0) * 16))   # ~8 logical px at 175 %
  $path = New-Object Drawing.Drawing2D.GraphicsPath; $d = 2 * $rad
  $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90)
  $path.AddArc($w - $d, $hh - $d, $d, $d, 0, 90); $path.AddArc(0, $hh - $d, $d, $d, 90, 90); $path.CloseFigure()
  $gf.SetClip($path)
  $gf.DrawImage($grab, (New-Object Drawing.Rectangle 0, 0, $w, $hh), (New-Object Drawing.Rectangle $inset, $inset, $w, $hh), [Drawing.GraphicsUnit]::Pixel)
  $gf.Dispose(); $grab.Dispose()
  $tw = [Math]::Min(1400, $w); $th = [int]($hh * $tw / $w)
  $small = New-Object Drawing.Bitmap $tw, $th, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($small)
  $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.SmoothingMode = 'AntiAlias'
  $g.DrawImage($full, 0, 0, $tw, $th)
  $small.Save((Join-Path $out "$name.png"), [Drawing.Imaging.ImageFormat]::Png)
  "{0,-16} {1}x{2}  {3:N0} KB" -f $name, $tw, $th, ((Get-Item (Join-Path $out "$name.png")).Length / 1KB)
  Start-Sleep -Milliseconds 300
}

$dirs = @("$env:APPDATA\gui_toolkit_fidget", "$env:APPDATA\gui_toolkit_todo")
foreach($d in $dirs) { $b = "$d.shotbackup"; Remove-Item $b -Recurse -Force -ErrorAction SilentlyContinue; if(Test-Path $d) { Move-Item $d $b } }
try {
  $fidget = Join-Path $repo 'build\fidget.exe'
  $todo = Join-Path $repo 'build\todo.exe'
  Capture $fidget '--page=0 --anim=on' 'controls' 1500
  Capture $fidget '--page=1 --anim=on' 'inputs' 1500
  Capture $fidget '--page=2 --anim=on' 'data' 1500
  Capture $fidget '--page=3 --anim=on' 'playground' 3200
  Capture $fidget '--palette_query=theme --theme=3 --anim=on' 'palette' 1500
  Capture $fidget '--settings --anim=on' 'settings' 1500
  Capture $fidget '--page=2 --toasts --toast_pos=2 --anim=on' 'toasts' 1800
  Capture $fidget '--about --theme=4 --anim=on' 'about' 1500
  Capture $fidget '--page=0 --theme=2 --anim=on' 'light' 1500
  Capture $fidget '--page=0 --theme=7 --anim=on' 'bootstrap' 1500
  Capture $fidget '--page=2 --compact --anim=on' 'compact' 1500
  Capture $todo '' 'todo' 1500
  Capture (Join-Path $repo 'build\transforms.exe') '--time=2.0' 'transforms' 1500
  Capture (Join-Path $repo 'build\effects.exe') '--time=2.0' 'effects' 1500
} finally {
  [S1]::SetCursorPos($script:cursor.X, $script:cursor.Y) | Out-Null
  foreach($d in $dirs) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; $b = "$d.shotbackup"; if(Test-Path $b) { Move-Item $b $d } }
}
