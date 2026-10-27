# Starts a program, waits, writes a PNG of its main window (the visible frame, screen capture), kills it.
#   tools\window_shot.ps1 -Exe build\smoke_wgpu.exe -Out shot.png [-WaitMs 2500] [-Args ...]
# The window is raised above the others for the capture; the screen is the real one (do not move the mouse meanwhile).
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Out, [int]$WaitMs = 2500, [string[]]$ProgramArgs)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WS1 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@
Add-Type -AssemblyName System.Drawing
[WS1]::SetProcessDPIAware() | Out-Null
$exe = (Resolve-Path $Exe).Path
$p = if ($ProgramArgs) { Start-Process $exe -ArgumentList $ProgramArgs -PassThru -WorkingDirectory (Split-Path $exe) } else { Start-Process $exe -PassThru -WorkingDirectory (Split-Path $exe) }
try {
	$sw = [Diagnostics.Stopwatch]::StartNew()
	while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
	$h = $p.MainWindowHandle
	if ($h -eq 0) { throw 'no window' }
	[WS1]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null
	[WS1]::SetForegroundWindow($h) | Out-Null
	Start-Sleep -Milliseconds $WaitMs
	$r = New-Object WS1+RECT
	if ([WS1]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [WS1]::GetWindowRect($h, [ref]$r) | Out-Null }
	$w = $r.R - $r.L; $hh = $r.B - $r.T
	$bmp = New-Object Drawing.Bitmap $w, $hh
	[Drawing.Graphics]::FromImage($bmp).CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
	# (an absolute -Out stays as it is; a relative one is under the current directory)
	$full = [IO.Path]::Combine((Get-Location).Path, $Out)
	[IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
	$bmp.Save($full, [Drawing.Imaging.ImageFormat]::Png)
	"{0}x{1} -> {2}" -f $w, $hh, $Out
} finally {
	if (-not $p.HasExited) { $p.Kill() }
}
