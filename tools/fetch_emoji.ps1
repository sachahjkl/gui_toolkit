# Noto Color Emoji (COLR v1), the emoji font of the built-in emoji (font.set_emoji_source), pinned by commit and SHA-256.
#
#   Source   Google Fonts' build of Noto Color Emoji (SIL OFL 1.1, https://github.com/google/fonts/tree/main/ofl/notocoloremoji),
#            the font googlefonts/noto-emoji produces: COLR v1 / CPAL outlines plus an OT-SVG table. googlefonts/noto-emoji does
#            not keep built fonts in its tree.
#   Result   the same font without its `SVG ` table (20 MB of the 25 MB; the paint trees in COLR draw the same emoji and the
#            interpreter in font/colr*.odin does not read SVG), written as NotoColorEmoji-COLRv1.ttf. Nothing else changes:
#            tables are copied byte for byte, the directory is rebuilt and head.checkSumAdjustment recomputed.
#
#   tools\fetch_emoji.ps1                       -> build\emoji\NotoColorEmoji-COLRv1.ttf (+ OFL.txt)
#   tools\fetch_emoji.ps1 -Dest dist\app\emoji  put them elsewhere
#   tools\fetch_emoji.ps1 -Unicode              also fetch emoji-test.txt and emoji-data.txt (Unicode 18.0: what the shaping tests and font/emoji_data.odin use) into -Dest
param(
	[string]$Dest = (Join-Path (Split-Path $PSScriptRoot) 'build\emoji'),
	[switch]$Unicode
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Commit = '142c8963e7606b510c93a644c82a4c4cdeae6ef9'   # google/fonts, "Add updated emoji 18 font with the correct version in name table"
$Base = "https://raw.githubusercontent.com/google/fonts/$Commit/ofl/notocoloremoji"
$Source = @{ Name = 'NotoColorEmoji-Regular.ttf'; Sha256 = '4d82a18d8d95f60ba883ce242bbadbf84a576e987745dd7ba38d71c67cff2d73' }
$Licence = @{ Name = 'OFL.txt'; Sha256 = 'ac564676d10054a8445923dfc2dfb13c042d97888bd27c1b6ec6dfe89a9d8d62' }
$Result = @{ Name = 'NotoColorEmoji-COLRv1.ttf'; Sha256 = '307e7d40ee1e5e9415abe3301bb6e2204b1045113ea0ee566a758faa6e9f6d13' }
$UnicodeFiles = @(
	@{ Name = 'emoji-test.txt'; Url = 'https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt'; Sha256 = '8f3735cda1f92a779d78af67cf86066bb1f07143dc22f2ac29394d9bc57ab21a' },
	@{ Name = 'emoji-data.txt'; Url = 'https://www.unicode.org/Public/18.0.0/ucd/emoji/emoji-data.txt'; Sha256 = '80d00f8e616a0ef27fd6b8de3b758c06383b5d917e2977709578e68baf733bf1' }
)

# (not Get-FileHash: a CI build step, run from cmd after the MSVC environment was set, did not find the cmdlet: "not recognized")
function Sha256($path) {
	$h = [Security.Cryptography.SHA256]::Create()
	$s = [IO.File]::OpenRead($path)
	try { return ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToLower() } finally { $s.Dispose(); $h.Dispose() }
}
function Get-Verified($url, $path, $sha) {
	if (-not (Test-Path $path) -or (Sha256 $path) -ne $sha) {
		Write-Host "downloading $url"
		Invoke-WebRequest $url -OutFile $path
	}
	$got = Sha256 $path
	if ($got -ne $sha) { Remove-Item $path -Force; throw "$(Split-Path -Leaf $path): SHA-256 mismatch ($got, expected $sha)" }
}

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Linq;
using System.Text;
public static class SfntStrip {
	static uint BE32(byte[] b, int o) { return (uint)(b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]); }
	static void Put32(byte[] b, int o, uint v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }
	static uint Sum(byte[] b) {
		uint s = 0;
		for (int i = 0; i < b.Length; i += 4) {
			uint w = 0;
			for (int k = 0; k < 4; k++) w = w << 8 | (i + k < b.Length ? b[i + k] : (byte)0);
			s += w;
		}
		return s;
	}
	// Removes table `drop` from the font `src`: the other tables are copied byte for byte, the directory is rebuilt and
	// head.checkSumAdjustment recomputed.
	public static void Strip(string src, string dst, string drop) {
		byte[] b = File.ReadAllBytes(src);
		int n = b[4] << 8 | b[5];
		var keep = Enumerable.Range(0, n).Select(i => 12 + 16 * i).Where(o => Encoding.ASCII.GetString(b, o, 4) != drop).ToArray();
		if (keep.Length == n) throw new Exception("no " + drop + " table in the source font");
		int m = keep.Length, po = 1, es = 0;
		while (po * 2 <= m) { po *= 2; es++; }
		int dir = 12 + 16 * m, total = dir;
		foreach (int o in keep) total += (int)((BE32(b, o + 12) + 3) & ~3u);
		byte[] r = new byte[total];
		Array.Copy(b, 0, r, 0, 4);
		r[4] = (byte)(m >> 8); r[5] = (byte)m;
		r[6] = (byte)(po * 16 >> 8); r[7] = (byte)(po * 16);
		r[8] = (byte)(es >> 8); r[9] = (byte)es;
		int rs = m * 16 - po * 16;
		r[10] = (byte)(rs >> 8); r[11] = (byte)rs;
		int pos = dir, head = -1;
		for (int i = 0; i < m; i++) {
			int o = keep[i], d = 12 + 16 * i;
			Array.Copy(b, o, r, d, 16);
			uint off = BE32(b, o + 8), len = BE32(b, o + 12);
			Put32(r, d + 8, (uint)pos);
			Array.Copy(b, (int)off, r, pos, (int)len);
			if (Encoding.ASCII.GetString(b, o, 4) == "head") head = pos;
			pos += (int)((len + 3) & ~3u);
		}
		if (head < 0) throw new Exception("no head table");
		Put32(r, head + 8, 0);
		Put32(r, head + 8, 0xB1B0AFBAu - Sum(r));
		File.WriteAllBytes(dst, r);
	}
}
"@
New-Item -ItemType Directory -Force $Dest | Out-Null
$cache = Join-Path ([IO.Path]::GetTempPath()) 'wren-emoji-src'
New-Item -ItemType Directory -Force $cache | Out-Null
$dst = Join-Path $Dest $Result.Name
if ((Test-Path $dst) -and (Sha256 $dst) -eq $Result.Sha256) {
	Write-Host "$($Result.Name): as pinned"
} else {
	$src = Join-Path $cache "$Commit-$($Source.Name)"
	Get-Verified "$Base/$($Source.Name)" $src $Source.Sha256
	[SfntStrip]::Strip($src, $dst, 'SVG ')
	$got = Sha256 $dst
	if ($got -ne $Result.Sha256) { Remove-Item $dst -Force; throw "$($Result.Name): SHA-256 mismatch after stripping ($got, expected $($Result.Sha256))" }
	Write-Host "$($Result.Name): $([int]((Get-Item $dst).Length / 1024)) KiB"
}
Get-Verified "$Base/$($Licence.Name)" (Join-Path $Dest $Licence.Name) $Licence.Sha256
if ($Unicode) { foreach ($u in $UnicodeFiles) { Get-Verified $u.Url (Join-Path $Dest $u.Name) $u.Sha256 } }
