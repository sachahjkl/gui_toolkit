# Builds tools\wgsl2hlsl (the WGSL -> HLSL translator of the shaders, naga) into build\naga\wgsl2hlsl.exe.
#   powershell -File tools\build_naga.ps1
# naga is pinned exactly in tools\wgsl2hlsl\Cargo.toml and by Cargo.lock, which carries the SHA-256 of every crate; this script pins
# Cargo.lock itself (below) and builds with --locked, so the HLSL the toolkit embeds comes from the translator that was reviewed. Rebuilt
# only when its sources change. Needs a Rust toolchain (cargo); the crates are fetched from crates.io the first time.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dir = Join-Path $root 'tools\wgsl2hlsl'
$out = Join-Path $root 'build\naga'
$exe = Join-Path $out 'wgsl2hlsl.exe'
$stamp = Join-Path $out 'wgsl2hlsl.sources'
# SHA-256 of Cargo.lock (naga 29.0.4 and its dependencies); update it with the lock file when naga is moved on purpose
$LockSha256 = '04ee5ed81addbb30903d1b79ce3b1080d810f2a8465ed37fe7842fc3eb8a06ad'

$lock = Join-Path $dir 'Cargo.lock'
if (-not (Test-Path $lock)) { throw 'tools\wgsl2hlsl\Cargo.lock is missing' }
$got = (Get-FileHash $lock -Algorithm SHA256).Hash.ToLower()
if ($got -ne $LockSha256) { throw "tools\wgsl2hlsl\Cargo.lock does not match the pinned SHA-256 ($got); review the change, then update build_naga.ps1" }

$sources = (Get-FileHash (Join-Path $dir 'Cargo.toml'), $lock, (Join-Path $dir 'src\main.rs') -Algorithm SHA256 | ForEach-Object Hash) -join ','
if ((Test-Path $exe) -and (Test-Path $stamp) -and ((Get-Content $stamp) -eq $sources)) { Write-Host "naga: $exe is up to date"; exit 0 }
New-Item -ItemType Directory $out -Force | Out-Null
Push-Location $dir
try {
	$env:CARGO_TARGET_DIR = Join-Path $out 'target'
	$ErrorActionPreference = 'Continue'   # cargo writes its progress to stderr
	& cargo build --release --locked 2>&1 | ForEach-Object { "$_" } | Write-Host
	if ($LASTEXITCODE) { throw 'cargo build failed' }
} finally { Pop-Location }
Copy-Item (Join-Path $out 'target\release\wgsl2hlsl.exe') $exe -Force
Set-Content $stamp $sources
Write-Host "naga: built $exe"
