# Interaction test for examples/fidget. REAL mouse clicks inside the app window: hands off while it runs (~30 s).
# Coordinates are read from screenshots downscaled to 2000 px wide (the image viewer shrinks them), so they are scaled
# by window width / 2000. Aborts if another window covers the target.
param([string]$Exe = "$PSScriptRoot\..\build\fidget.exe", [string]$OutDir = "$env:TEMP")
Add-Type @"
using System; using System.Runtime.InteropServices;
public class U1 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
Add-Type -AssemblyName System.Drawing
[U1]::SetProcessDPIAware() | Out-Null
$orig = New-Object U1+POINT; [U1]::GetCursorPos([ref]$orig) | Out-Null
# keep the user's settings: move them aside for the run, put them back at the end
$userDir = "$env:APPDATA\gui_toolkit_fidget"; $backup = "$env:TEMP\gui_toolkit_fidget.backup"
Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
if(Test-Path $userDir) { Move-Item $userDir $backup }
$p = Start-Process $Exe -PassThru
$sw = [Diagnostics.Stopwatch]::StartNew()
while(-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
$h = $p.MainWindowHandle
Start-Sleep -Milliseconds 1500
[U1]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null
[U1]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500
$r = New-Object U1+RECT; [U1]::GetWindowRect($h, [ref]$r) | Out-Null
$f = ($r.R - $r.L) / 2000.0

function At($x, $y) { return @(($r.L + [int]($x * $f)), ($r.T + [int]($y * $f))) }
function Ours($a) { $pt = New-Object U1+POINT; $pt.X = $a[0]; $pt.Y = $a[1]; return ([U1]::GetAncestor([U1]::WindowFromPoint($pt), 2) -eq $h) }
function Click($x, $y, $right = $false) {
  $a = At $x $y
  [U1]::SetCursorPos($a[0], $a[1]) | Out-Null
  if(-not (Ours $a)) { throw "target ($x,$y) is not our window; aborting" }
  Start-Sleep -Milliseconds 250
  $d = 2; $u = 4; if($right) { $d = 8; $u = 16 }
  [U1]::mouse_event($d,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [U1]::mouse_event($u,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 450
}
function Hover($x, $y, $ms = 900) { $a = At $x $y; [U1]::SetCursorPos($a[0], $a[1]) | Out-Null; if(-not (Ours $a)) { throw "hover not ours" }; Start-Sleep -Milliseconds $ms }
function Drag($x0, $y0, $x1, $y1) {
  $a = At $x0 $y0; $b = At $x1 $y1
  [U1]::SetCursorPos($a[0], $a[1]) | Out-Null
  if(-not (Ours $a)) { throw "drag start not ours" }
  Start-Sleep -Milliseconds 200
  [U1]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
  for($i = 1; $i -le 12; $i++) { [U1]::SetCursorPos([int]($a[0] + ($b[0]-$a[0])*$i/12), [int]($a[1] + ($b[1]-$a[1])*$i/12)) | Out-Null; Start-Sleep -Milliseconds 16 }
  Start-Sleep -Milliseconds 60
  [U1]::mouse_event(4,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 400
}
function Wheel([int]$notches) {
  $pos = New-Object U1+POINT; [U1]::GetCursorPos([ref]$pos) | Out-Null
  $d = 120; if($notches -lt 0) { $d = -120 }
  $amt = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$d), 0)
  for($i = 0; $i -lt [math]::Abs($notches); $i++) { [U1]::mouse_event(0x800,0,0,$amt,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70 }
  Start-Sleep -Milliseconds 600
}
function TypeText($t) { foreach($c in [char[]]$t) { [U1]::PostMessage($h, 0x102, [IntPtr][int]$c, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 30 }; Start-Sleep -Milliseconds 350 }
function Key($vk) { [U1]::PostMessage($h, 0x100, [IntPtr]$vk, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 30; [U1]::PostMessage($h, 0x101, [IntPtr]$vk, [IntPtr]0xC0000001) | Out-Null; Start-Sleep -Milliseconds 400 }
function Shot($name) {
  $rr = New-Object U1+RECT; [U1]::GetWindowRect($h, [ref]$rr) | Out-Null
  $bmp = New-Object Drawing.Bitmap ($rr.R-$rr.L), ($rr.B-$rr.T)
  [Drawing.Graphics]::FromImage($bmp).CopyFromScreen($rr.L, $rr.T, 0, 0, $bmp.Size)
  $bmp.Save("$OutDir\$name.png")
}
function Title { $p.Refresh(); return $p.MainWindowTitle }
function Zoom { $s = "$env:APPDATA\gui_toolkit_fidget\settings.txt"; if(Test-Path $s) { (Get-Content $s | Select-String 'zoom') -replace 'zoom=','' } else { '(none)' } }

try {
  "start          : $(Title)"
  Click 1888 375;        "toggle Bluetooth clicked"
  Click 851 653;         "segmented Month"
  Click 469 710;         "chip Beta"
  Click 629 777;         "dropdown open"
  Shot "ft_dd"
  Click 640 1070;        "dropdown pick (Odin)"
  Click 1465 901;        "slider Volume ~35%"
  Hover 338 393 1000;    Shot "ft_tip"; "tooltip shown"
  Click 515 1064 $true;  Shot "ft_ctx"; "context menu"
  Key 0x1B
  Hover 500 700 100; Wheel -6;  Shot "ft_scrolled"; "wheel x6 down"
  Wheel 8
  Click 1700 83;         "palette via button"
  TypeText "nord"
  Key 0x0D;              "palette Enter -> $(Title)"
  Key 0x70;              Shot "ft_about"; "F1 -> About"
  Key 0x1B;              "Esc closes About"
  Click 1888 375;        "(sanity) still responding: $($p.Responding)"
  "end            : $(Title)  zoom=$(Zoom)"
} catch { "ERROR: $_" }
finally {
  [U1]::SetCursorPos($orig.X, $orig.Y) | Out-Null; if(-not $p.HasExited) { $p.Kill() }
  Start-Sleep -Milliseconds 300; Remove-Item $userDir -Recurse -Force -ErrorAction SilentlyContinue; if(Test-Path $backup) { Move-Item $backup $userDir }
}
