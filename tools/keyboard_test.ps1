# Keyboard test for examples/fidget: real keystrokes WITH modifiers (keybd_event), plus a few real clicks.
# Checks the app state through the window title (--state_title). Hands off the mouse and keyboard while it runs (~40 s).
# Safety: every keystroke is sent only if fidget is the foreground window; otherwise the test stops.
# The user's settings are moved aside for the run and restored at the end.
param([string]$Exe = "$PSScriptRoot\..\build\fidget.exe")
Add-Type @"
using System; using System.Runtime.InteropServices;
public class K2 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
[K2]::SetProcessDPIAware() | Out-Null
$orig = New-Object K2+POINT; [K2]::GetCursorPos([ref]$orig) | Out-Null
$userDir = "$env:APPDATA\gui_toolkit_fidget"; $backup = "$env:TEMP\gui_toolkit_fidget.kbbackup"
Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
if(Test-Path $userDir) { Move-Item $userDir $backup }
$script:fail = 0

$p = Start-Process $Exe -ArgumentList '--page=1 --state_title' -PassThru
$sw = [Diagnostics.Stopwatch]::StartNew()
while(-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
$h = $p.MainWindowHandle
Start-Sleep -Milliseconds 1200
[K2]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null
[K2]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400
$r = New-Object K2+RECT; [K2]::GetWindowRect($h, [ref]$r) | Out-Null
$k = ($r.R - $r.L) / 2000.0   # coordinates are read from a screenshot downscaled to 2000 px wide

function State { $p.Refresh(); return $p.MainWindowTitle }
function Field($name) { $t = State; if($t -match "(?:^|\s)$name=(.*?)(?=\s\w+=|$)") { return $Matches[1] } return '?' }
function Check($label, $name, $expect) {
  $v = Field $name
  $ok = $v -eq $expect
  if(-not $ok) { $script:fail += 1 }
  "{0,-34} {1,-14} = {2,-16} {3}" -f $label, $name, $v, $(if($ok) { 'ok' } else { "FAIL (expected $expect)" })
}
function Click($x, $y) {
  $px = $r.L + [int]($x * $k); $py = $r.T + [int]($y * $k)
  $pt = New-Object K2+POINT; $pt.X = $px; $pt.Y = $py
  [K2]::SetCursorPos($px, $py) | Out-Null
  if([K2]::GetAncestor([K2]::WindowFromPoint($pt), 2) -ne $h) { throw "click target is not fidget; stopping" }
  Start-Sleep -Milliseconds 200
  [K2]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 50; [K2]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 350
}
# real keystroke with modifiers; only when fidget has the keyboard
function Key([string[]]$mods, [int]$vk) {
  if([K2]::GetForegroundWindow() -ne $h) { throw "fidget is not the foreground window; stopping before sending keys" }
  $mvk = @{ ctrl = 0x11; shift = 0x10; alt = 0x12 }
  foreach($m in $mods) { [K2]::keybd_event([byte]$mvk[$m], 0, 0, [UIntPtr]::Zero) }
  [K2]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30
  [K2]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
  [array]::Reverse($mods); foreach($m in $mods) { [K2]::keybd_event([byte]$mvk[$m], 0, 2, [UIntPtr]::Zero) }
  Start-Sleep -Milliseconds 250
}
function TypeText($t) {
  if([K2]::GetForegroundWindow() -ne $h) { throw "fidget is not the foreground window; stopping" }
  foreach($c in [char[]]$t) { [K2]::PostMessage($h, 0x102, [IntPtr][int]$c, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 25 }
  Start-Sleep -Milliseconds 250
}
$VK = @{ A = 0x41; C = 0x43; V = 0x56; Z = 0x5A; Y = 0x59; K = 0x4B; Tab = 0x09; Space = 0x20; Enter = 0x0D; Esc = 0x1B; End = 0x23; Down = 0x28; Up = 0x26; Plus = 0xBB; Minus = 0xBD; Zero = 0x30; Comma = 0xBC }

try {
  "start: $(State)"
  "--- line edit + clipboard (Ctrl+A / C / V) and Tab focus"
  Click 630 320;                                     Check 'click Name' 'focus' 'in_name'
  Key @('ctrl') $VK.A; TypeText 'Grace Hopper';      Check 'Ctrl+A then type' 'name' 'Grace Hopper'
  Key @('ctrl') $VK.A; Key @('ctrl') $VK.C
  Key @() $VK.Tab;                                   Check 'Tab' 'focus' 'in_email'
  Key @('shift') $VK.Tab;                            Check 'Shift+Tab' 'focus' 'in_name'
  Click 1600 1080;                                   Check 'click Title' 'focus' 'in_bio'
  Key @('ctrl') $VK.V;                               Check 'Ctrl+V' 'bio' 'Grace Hopper'
  Key @() $VK.Tab;                                   Check 'Tab to the checkbox' 'focus' 'ck_agree'
  Key @() $VK.Space;                                 Check 'Space activates it' 'agree' '1'
  "--- arrow keys move the focus spatially"
  Key @() $VK.Down;                                  Check 'Down (to Submit)' 'focus' 'b_submit'
  Key @() $VK.Up;                                    Check 'Up (back to the checkbox)' 'focus' 'ck_agree'
  Key @() $VK.Up;                                    Check 'Up (to the Title field)' 'focus' 'in_bio'
  "--- multi-line editor"
  Click 1400 585;                                    Check 'click editor' 'focus' 'editor'
  Key @('ctrl') $VK.End
  TypeText 'hello'; Key @() $VK.Enter; TypeText 'world'
  Check 'type hello Enter world' 'editor_lines' '9'
  Check '' 'editor_len' '202'
  Key @('ctrl') $VK.Z;                               Check 'Ctrl+Z (removes "world")' 'editor_len' '197'
  Key @('ctrl') $VK.Z;                               Check 'Ctrl+Z (removes the new line)' 'editor_lines' '8'
  Key @('ctrl') $VK.Y;                               Check 'Ctrl+Y (redo the new line)' 'editor_lines' '9'
  Key @('ctrl') $VK.A; Key @() 0x2E;                 Check 'Ctrl+A, Delete' 'editor_len' '0'
  Key @('ctrl') $VK.Z;                               Check 'Ctrl+Z restores' 'editor_len' '197'
  Key @() $VK.Esc;                                   Check 'Esc leaves the editor' 'focus' ''
  "--- zoom"
  Key @('ctrl') $VK.Plus;                            Check 'Ctrl +' 'zoom' '110'
  Key @('ctrl') $VK.Minus; Key @('ctrl') $VK.Minus;  Check 'Ctrl - twice' 'zoom' '91'
  Key @('ctrl') $VK.Zero;                            Check 'Ctrl 0' 'zoom' '100'
  "--- overlays and keyboard navigation inside a dialog"
  Key @('ctrl') $VK.K;                               Check 'Ctrl+K' 'pal' '1'
  Key @() $VK.Esc;                                   Check 'Esc' 'pal' '0'
  Key @('ctrl') $VK.Comma;                           Check 'Ctrl+,' 'settings' '1'
  Key @() $VK.Tab;                                   Check 'Tab inside Settings' 'focus' 'st_close'
  Key @() $VK.Tab;                                   Check 'Tab' 'focus' 'st_theme'
  Key @() $VK.Enter; Key @() $VK.Down; Key @() $VK.Enter
  Check 'Enter, Down, Enter in the dropdown' 'theme' '2'   # default theme is Graphite (1)
  Key @() $VK.Esc;                                   Check 'Esc closes Settings' 'settings' '0'
  "--- menus close on a click outside"
  Click 290 83;                                      Check 'click File' 'menu' '1'
  Click 1000 1346;                                   Check 'click the status bar' 'menu' '0'
} catch { "ERROR: $_"; $script:fail += 1 }
finally {
  [K2]::SetCursorPos($orig.X, $orig.Y) | Out-Null
  if(-not $p.HasExited) { $p.Kill() }
  Start-Sleep -Milliseconds 300
  Remove-Item $userDir -Recurse -Force -ErrorAction SilentlyContinue
  if(Test-Path $backup) { Move-Item $backup $userDir }
}
"--- $(if($script:fail -eq 0) { 'all checks passed' } else { "$($script:fail) check(s) failed" })"
