# Dependencies of the WebGPU render backend (TOOLKIT_RENDER=wgpu), each pinned by SHA-256.
#
#   wgpu-native 29.0.1.1  the library `vendor:wgpu` links (static: wgpu_native.lib). Odin's release archive ships it in
#                         vendor\wgpu\lib; this script checks the files there and downloads the release when they are missing.
#   DXC 1.9.2609          dxcompiler.dll + dxil.dll, next to the program: the HLSL compiler wgpu uses on Direct3D 12 when
#                         they are present. Without them wgpu falls back to FXC (d3dcompiler), which needs about 2.8 s to compile
#                         the main shader instead of 0.33 s (see docs/WEBGPU.md). Only needed at run time, not to build.
#
#   tools\fetch_wgpu.ps1                 check wgpu-native, fetch DXC into build\
#   tools\fetch_wgpu.ps1 -Dest dist\app  put the DXC DLLs next to a program instead
#   tools\fetch_wgpu.ps1 -NoDxc          only the library check
param(
	[string]$Dest = (Join-Path (Split-Path $PSScriptRoot) 'build'),
	[switch]$NoDxc
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WgpuVersion = '29.0.1.1'
$WgpuZip = @{
	Url = "https://github.com/gfx-rs/wgpu-native/releases/download/v$WgpuVersion/wgpu-windows-x86_64-msvc-release.zip"
	Sha256 = '7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132'
}
# the files inside it, as Odin's vendor/wgpu expects them (lib\wgpu-windows-x86_64-msvc-release\lib\)
$WgpuFiles = [ordered]@{
	'wgpu_native.lib'     = 'c47ed51546823c02c6d33e24a58e62e0535442ca1897a17d2305b2e55df35729'
	'wgpu_native.dll'     = '5e26249c40dcdac43f5adca3195fcf40e4ec6c67472b38510165f411fcc198e7'
	'wgpu_native.dll.lib' = '261adb64aef86a3ebaf7f6f370d14bed083f93e25e2eec70a7c54d33954e4572'
}
$Dxc = @{
	Url = 'https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2609/dxc_2026_09_29.zip'
	Sha256 = 'ad31b1fc8443175d204f77a611fdb3ef2ec42759bdc2f1167368de24a4a7e7f1'
}

# (not Get-FileHash: a CI build step, run from cmd after the MSVC environment was set, did not find the cmdlet: "not recognized")
function Sha256Lower($path) {
	$h = [Security.Cryptography.SHA256]::Create()
	$s = [IO.File]::OpenRead($path)
	try { return ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToLower() } finally { $s.Dispose(); $h.Dispose() }
}

function Get-Verified($spec, $name) {
	$tmp = Join-Path ([IO.Path]::GetTempPath()) $name
	if (-not (Test-Path $tmp) -or (Sha256Lower $tmp) -ne $spec.Sha256) {
		Write-Host "downloading $($spec.Url)"
		Invoke-WebRequest $spec.Url -OutFile $tmp
	}
	$got = Sha256Lower $tmp
	if ($got -ne $spec.Sha256) { Remove-Item $tmp -Force; throw "${name}: SHA-256 mismatch ($got, expected $($spec.Sha256))" }
	$tmp
}

# --- wgpu-native -----------------------------------------------------------------------------------------------
$odin = Get-Command odin -ErrorAction Stop
$root = (& $odin.Source root).Trim().TrimEnd('\', '/')
$libDir = Join-Path $root 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib'
$ok = $true
foreach ($f in $WgpuFiles.Keys) {
	$p = Join-Path $libDir $f
	if (-not (Test-Path $p) -or (Sha256Lower $p) -ne $WgpuFiles[$f]) { $ok = $false }
}
if ($ok) {
	Write-Host "wgpu-native ${WgpuVersion}: $libDir is as pinned"
} else {
	$zip = Get-Verified $WgpuZip 'wgpu-windows-x86_64-msvc-release.zip'
	$tmpDir = Join-Path ([IO.Path]::GetTempPath()) 'wgpu-native-extract'
	if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
	Expand-Archive $zip -DestinationPath $tmpDir
	New-Item -ItemType Directory $libDir -Force | Out-Null
	foreach ($f in $WgpuFiles.Keys) {
		$src = Get-ChildItem $tmpDir -Recurse -Filter $f | Select-Object -First 1
		if (-not $src) { throw "$f is not in the wgpu-native archive" }
		$got = Sha256Lower $src.FullName
		if ($got -ne $WgpuFiles[$f]) { throw "$f from the archive does not match its pinned SHA-256 ($got)" }
		Copy-Item $src.FullName (Join-Path $libDir $f) -Force
	}
	Remove-Item $tmpDir -Recurse -Force
	Write-Host "wgpu-native ${WgpuVersion} installed in $libDir"
}

# --- the shared library (-define:WGPU_SHARED=true: a program that already links another Rust static library, as Wren does with its image decoders,
# cannot link wgpu_native.lib too: both carry the Rust runtime, "rust_eh_personality is multiply defined") ----------------------------
New-Item -ItemType Directory $Dest -Force | Out-Null
Copy-Item (Join-Path $libDir 'wgpu_native.dll') (Join-Path $Dest 'wgpu_native.dll') -Force

# --- DXC -------------------------------------------------------------------------------------------------------
if (-not $NoDxc) {
	$have = (Test-Path (Join-Path $Dest 'dxcompiler.dll')) -and (Test-Path (Join-Path $Dest 'dxil.dll')) -and (Test-Path (Join-Path $Dest 'dxc.version'))
	if ($have -and (Get-Content (Join-Path $Dest 'dxc.version')) -eq $Dxc.Sha256) {
		Write-Host "DXC: ${Dest} is as pinned"
	} else {
		$zip = Get-Verified $Dxc 'dxc_2026_09_29.zip'
		$tmpDir = Join-Path ([IO.Path]::GetTempPath()) 'dxc-extract'
		if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
		Expand-Archive $zip -DestinationPath $tmpDir
		foreach ($f in 'dxcompiler.dll', 'dxil.dll') {
			$src = Get-ChildItem $tmpDir -Recurse -Filter $f | Where-Object { $_.FullName -match '[\\/]x64[\\/]' } | Select-Object -First 1
			if (-not $src) { throw "$f (x64) is not in the DXC archive" }
			Copy-Item $src.FullName (Join-Path $Dest $f) -Force
		}
		Set-Content (Join-Path $Dest 'dxc.version') $Dxc.Sha256
		Remove-Item $tmpDir -Recurse -Force
		Write-Host "DXC 1.9.2609 installed in $Dest"
	}
}
