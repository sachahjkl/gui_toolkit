# Builds the accessibility adapter (native\a11y: AccessKit, its UI Automation adapter) into build\a11y\gt_a11y.lib, the
# static library platform\a11y_accesskit.odin links when a program is built with -define:A11Y_ACCESSKIT=true.
#   powershell -NoProfile -File tools\build_a11y.ps1 [-Force]
# Every crate is pinned by exact version in native\a11y\Cargo.toml and by SHA-256 in native\a11y\Cargo.lock (--locked).
# Rust: the stable toolchain of rustup (x86_64-pc-windows-msvc). Nothing is done when build\a11y\STAMP matches the hash
# of the sources, Cargo.lock and this script.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$crate = Join-Path $root 'native\a11y'
$out = Join-Path $root 'build\a11y'
$lib = Join-Path $out 'gt_a11y.lib'
$stampFile = Join-Path $out 'STAMP'

$inputs = @(Get-ChildItem (Join-Path $crate 'src') -Recurse -File) + @(Get-Item (Join-Path $crate 'Cargo.toml'), (Join-Path $crate 'Cargo.lock'), $PSCommandPath)
$sha = [Security.Cryptography.SHA256]::Create()
$all = New-Object IO.MemoryStream
foreach ($f in ($inputs | Sort-Object FullName)) { $b = [IO.File]::ReadAllBytes($f.FullName); $all.Write($b, 0, $b.Length) }
$stamp = ([BitConverter]::ToString($sha.ComputeHash($all.ToArray())) -replace '-', '').ToLower()
if (-not $Force -and (Test-Path $lib) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)) {
    "gt_a11y up to date in $out"
    exit 0
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw 'cargo not found: install Rust with rustup (stable, x86_64-pc-windows-msvc)' }

$target = Join-Path $out 'target'
$t0 = Get-Date
$ErrorActionPreference = 'Continue'   # cargo writes its progress to stderr
# The static library alone (the crate is an rlib in Cargo.toml): with an rlib among the crate types, rustc ignores the
# profile's fat LTO.
& cargo rustc --release --locked --lib --crate-type staticlib --manifest-path (Join-Path $crate 'Cargo.toml') --target-dir $target 2>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw "cargo build failed ($code)" }
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $target 'release\gt_a11y.lib') $lib -Force

# An application may link other Rust static libraries: each carries its own standard library, and all define the
# unmangled rust_eh_personality. Ours is renamed in the object that defines it (with fat LTO, the crate's single
# object) so that they link together.
$sysroot = (& rustc --print sysroot).Trim()
$bin = Join-Path $sysroot 'lib\rustlib\x86_64-pc-windows-msvc\bin'
if (-not (Test-Path (Join-Path $bin 'llvm-objcopy.exe'))) {
    & rustup component add llvm-tools
    if ($LASTEXITCODE -ne 0) { throw 'rustup component add llvm-tools failed' }
}
$ar = Join-Path $bin 'llvm-ar.exe'
$objcopy = Join-Path $bin 'llvm-objcopy.exe'
$work = Join-Path $out 'rename'
if (Test-Path $work) { [IO.Directory]::Delete($work, $true) }
New-Item -ItemType Directory -Force $work | Out-Null
$members = @(& $ar t $lib)
$member = $members | Where-Object { $_ -like 'gt_a11y-*.rcgu.o' } | Select-Object -First 1
if (-not $member) { throw 'gt_a11y.lib: the crate object was not found' }
# Fat LTO leaves the crate's object and compiler_builtins (never part of LTO): an object of another crate means LTO
# did not run (an rlib among the crate types).
$unmerged = @($members | Where-Object { $_ -like '*.rcgu.o' -and $_ -notlike 'gt_a11y-*' -and $_ -notlike 'compiler_builtins-*' })
if ($unmerged.Count) { throw "gt_a11y.lib was not built with fat LTO ($($unmerged.Count) objects of other crates, $($unmerged[0]))" }
Push-Location $work
try {
    & $ar x $lib $member
    & $objcopy --redefine-sym=rust_eh_personality=gt_a11y_rust_eh_personality $member
    if ($LASTEXITCODE -ne 0) { throw 'llvm-objcopy failed' }
    & $ar r $lib $member
    if ($LASTEXITCODE -ne 0) { throw 'llvm-ar failed' }
} finally { Pop-Location }
[IO.Directory]::Delete($work, $true)
[IO.File]::WriteAllText($stampFile, $stamp)
"built $lib ($([math]::Round((Get-Item $lib).Length / 1MB, 1)) MB) in $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s"
