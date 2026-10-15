# Scripted interaction test for examples/todo (Windows). Uses a few REAL mouse clicks inside the app window:
# do not touch the mouse or keyboard while it runs (~15 s). It aborts if another window covers the target point.
param([string]$Exe = "$PSScriptRoot\..\build\todo.exe", [string]$OutDir = "$env:TEMP", [string]$ErrFile = "")
Add-Type @"
using System; using System.Runtime.InteropServices;
public class T1 {
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
[T1]::SetProcessDPIAware() | Out-Null
$orig = New-Object T1+POINT; [T1]::GetCursorPos([ref]$orig) | Out-Null
Remove-Item "$env:APPDATA\gui_toolkit_todo" -Recurse -Force -ErrorAction SilentlyContinue
if($ErrFile -ne "") { $p = Start-Process $Exe -PassThru -RedirectStandardError $ErrFile -WorkingDirectory (Split-Path $Exe) } else { $p = Start-Process $Exe -PassThru }
$sw = [Diagnostics.Stopwatch]::StartNew()
while(-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
$h = $p.MainWindowHandle
Start-Sleep -Milliseconds 1200
[T1]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null
[T1]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500
$r = New-Object T1+RECT; [T1]::GetWindowRect($h, [ref]$r) | Out-Null
$W = $r.R - $r.L
$f = $W / 1144.0      # coordinates below were read from a 1144 px wide screenshot of the window

function Click($x, $y, $right = $false) {
  $px = $r.L + [int]($x * $f); $py = $r.T + [int]($y * $f)
  $pt = New-Object T1+POINT; $pt.X = $px; $pt.Y = $py
  [T1]::SetCursorPos($px, $py) | Out-Null
  if([T1]::GetAncestor([T1]::WindowFromPoint($pt), 2) -ne $h) { throw "target ($x,$y) is not our window; aborting" }
  Start-Sleep -Milliseconds 250
  $d = if($right) { 8 } else { 2 }; $u = if($right) { 16 } else { 4 }
  [T1]::mouse_event($d,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [T1]::mouse_event($u,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}
function Hover($x, $y, $ms = 900) {
  $px = $r.L + [int]($x * $f); $py = $r.T + [int]($y * $f)
  $pt = New-Object T1+POINT; $pt.X = $px; $pt.Y = $py
  [T1]::SetCursorPos($px, $py) | Out-Null
  if([T1]::GetAncestor([T1]::WindowFromPoint($pt), 2) -ne $h) { throw "hover target is not our window; aborting" }
  Start-Sleep -Milliseconds $ms
}
function TypeText($t) { foreach($c in [char[]]$t) { [T1]::PostMessage($h, 0x102, [IntPtr][int]$c, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 30 }; Start-Sleep -Milliseconds 300 }
function Key($vk) { [T1]::PostMessage($h, 0x100, [IntPtr]$vk, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 30; [T1]::PostMessage($h, 0x101, [IntPtr]$vk, [IntPtr]0xC0000001) | Out-Null; Start-Sleep -Milliseconds 350 }
function Shot($name) {
  $rr = New-Object T1+RECT; [T1]::GetWindowRect($h, [ref]$rr) | Out-Null
  $w = $rr.R - $rr.L; $hh = $rr.B - $rr.T
  $bmp = New-Object Drawing.Bitmap $w, $hh; $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rr.L, $rr.T, 0, 0, (New-Object Drawing.Size $w, $hh)); $bmp.Save("$OutDir\$name.png")
}
function Saved { $f2 = "$env:APPDATA\gui_toolkit_todo\todos.tsv"; if(Test-Path $f2) { (Get-Content $f2) -join ' | ' } else { '(no file)' } }

try {
  "start        : responding=$($p.Responding)"
  Click 500 295;                 TypeText "Test the Odin port"; Key 0x0D; "typed+Enter  : $(Saved)"
  Shot "tk_1_added"
  Click 103 563;                 "checkbox #2  : $(Saved)"
  Click 248 380;                 "filter Active"
  Shot "tk_2_filter"
  Click 115 380;                 "filter All"
  Hover 1038 470;                Shot "tk_3_tooltip"
  Click 760 470 $true;           Shot "tk_4_ctxmenu"
  Key 0x1B;                      "Esc closes menu"
  Click 1048 133;                Start-Sleep -Milliseconds 600; Shot "tk_5_light"; "theme toggled : $(Saved)"
  Click 1038 470;                "delete #1     : $(Saved)"
  "end          : responding=$($p.Responding) exited=$($p.HasExited)"
} catch { "ERROR: $_" }
finally { [T1]::SetCursorPos($orig.X, $orig.Y) | Out-Null; if(-not $p.HasExited) { $p.Kill() } }
