// What is downloaded, each file pinned by SHA-256: the emoji font, Unicode's emoji data, wgpu-native, DXC.
package tk

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "../../src/toolbox"

Pinned :: struct {
	name, url, sha256: string,
}

// Noto Color Emoji (COLR v1), the font of the built-in emoji (font.set_emoji_source). Source: Google Fonts' build (SIL OFL 1.1,
// https://github.com/google/fonts/tree/main/ofl/notocoloremoji), the font googlefonts/noto-emoji produces: COLR v1 / CPAL outlines
// plus an OT-SVG table (googlefonts/noto-emoji does not keep built fonts in its tree). Result: the same font without its `SVG `
// table (20 MB of the 25 MB; the paint trees in COLR draw the same emoji and font/colr*.odin does not read SVG). Nothing else
// changes: tables are copied byte for byte, the directory is rebuilt and head.checkSumAdjustment computed again.
EMOJI_COMMIT :: "142c8963e7606b510c93a644c82a4c4cdeae6ef9"   // google/fonts, "Add updated emoji 18 font with the correct version in name table"
EMOJI_BASE :: "https://raw.githubusercontent.com/google/fonts/" + EMOJI_COMMIT + "/ofl/notocoloremoji/"
EMOJI_DEST :: "build/emoji"
// Where the source font is kept between runs, in the system's temporary folder.
EMOJI_CACHE :: "wren-emoji-src"
EMOJI_DROPPED_TABLE :: "SVG "
@(rodata) EMOJI_SOURCE := Pinned{"NotoColorEmoji-Regular.ttf", EMOJI_BASE + "NotoColorEmoji-Regular.ttf", "4d82a18d8d95f60ba883ce242bbadbf84a576e987745dd7ba38d71c67cff2d73"}
@(rodata) EMOJI_LICENCE := Pinned{"OFL.txt", EMOJI_BASE + "OFL.txt", "ac564676d10054a8445923dfc2dfb13c042d97888bd27c1b6ec6dfe89a9d8d62"}
@(rodata) EMOJI_RESULT := Pinned{"NotoColorEmoji-COLRv1.ttf", "", "307e7d40ee1e5e9415abe3301bb6e2204b1045113ea0ee566a758faa6e9f6d13"}
// Unicode 18.0: what the shaping tests and font/emoji_data.odin use.
@(rodata) UNICODE_FILES := [?]Pinned {
	{"emoji-test.txt", "https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt", "8f3735cda1f92a779d78af67cf86066bb1f07143dc22f2ac29394d9bc57ab21a"},
	{"emoji-data.txt", "https://www.unicode.org/Public/18.0.0/ucd/emoji/emoji-data.txt", "80d00f8e616a0ef27fd6b8de3b758c06383b5d917e2977709578e68baf733bf1"},
}
BYTES_PER_KIB :: 1024

// wgpu-native, the library vendor:wgpu links. Odin's Windows release archive ships it in vendor/wgpu/lib (checked here, downloaded
// when it is not as pinned); its Linux archives do not (it is put there).
WGPU_VERSION :: "29.0.1.1"
WGPU_RELEASES :: "https://github.com/gfx-rs/wgpu-native/releases/download/v" + WGPU_VERSION + "/"
@(rodata) WGPU_WINDOWS_ZIP := Pinned{"wgpu-windows-x86_64-msvc-release.zip", WGPU_RELEASES + "wgpu-windows-x86_64-msvc-release.zip", "7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132"}
WGPU_WINDOWS_LIB :: "vendor/wgpu/lib/wgpu-windows-x86_64-msvc-release/lib"
// the files of that archive, as vendor:wgpu expects them
@(rodata) WGPU_WINDOWS_FILES := [?]Pinned {
	{name = "wgpu_native.lib", sha256 = "c47ed51546823c02c6d33e24a58e62e0535442ca1897a17d2305b2e55df35729"},
	{name = "wgpu_native.dll", sha256 = "5e26249c40dcdac43f5adca3195fcf40e4ec6c67472b38510165f411fcc198e7"},
	{name = "wgpu_native.dll.lib", sha256 = "261adb64aef86a3ebaf7f6f370d14bed083f93e25e2eec70a7c54d33954e4572"},
}
WGPU_WINDOWS_EXTRACT :: "wgpu-native-extract"
// The shared library (-define:WGPU_SHARED=true: a program that already links another Rust static library, as Wren does with its
// image decoders, cannot link wgpu_native.lib too: both carry the Rust runtime, "rust_eh_personality is multiply defined").
WGPU_SHARED_LIB :: "wgpu_native.dll"
@(rodata) WGPU_LINUX_ZIP := Pinned{"wgpu-linux-x86_64-release.zip", WGPU_RELEASES + "wgpu-linux-x86_64-release.zip", "95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a"}
WGPU_LINUX_DIR :: "vendor/wgpu/lib/wgpu-linux-x86_64-release"
WGPU_LINUX_LIB :: "lib/libwgpu_native.a"
WGPU_LINUX_STAMP :: "VERSION"

// DXC: dxcompiler.dll + dxil.dll, next to the program, the HLSL compiler wgpu uses on Direct3D 12 when they are there. Without them
// wgpu falls back to FXC (d3dcompiler), about 2.8 s to compile the main shader instead of 0.33 s (docs/webgpu.md). Only needed to run.
DXC_VERSION :: "1.9.2609"
@(rodata) DXC_ZIP := Pinned{"dxc_2026_09_29.zip", "https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2609/dxc_2026_09_29.zip", "ad31b1fc8443175d204f77a611fdb3ef2ec42759bdc2f1167368de24a4a7e7f1"}
@(rodata) DXC_FILES := [?]string{"dxcompiler.dll", "dxil.dll"}
DXC_ARCH :: "x64"
DXC_EXTRACT :: "dxc-extract"
// Beside the DLLs: the SHA-256 of the archive they came from.
DXC_STAMP :: "dxc.version"

// The sfnt header and table directory.
SFNT_HEADER :: 12
SFNT_RECORD :: 16
// head.checkSumAdjustment: at this offset in head, the whole font's checksum taken from this.
HEAD_ADJUSTMENT :: 8
SFNT_CHECKSUM_MAGIC :: 0xB1B0AFBA

Emoji_Options :: struct {
	dest:    string,
	unicode: bool,   // emoji-test.txt and emoji-data.txt too
	quiet:   bool,   // say nothing but why it failed
}

Wgpu_Options :: struct {
	dest:   string,   // where wgpu_native.dll and DXC's DLLs go
	no_dxc: bool,
	odin:   string,   // the compiler whose vendor folder has wgpu-native
}

temp_folder :: proc() -> string {
	t, _ := os.temp_directory(context.temp_allocator)
	return t
}

fetch_emoji :: proc(o: Emoji_Options) -> string {
	_ = os.make_directory_all(o.dest)
	cache := join({temp_folder(), EMOJI_CACHE})
	_ = os.make_directory_all(cache)
	dst := join({o.dest, EMOJI_RESULT.name})
	if sum, ok := toolbox.sha256_file(dst); ok && sum == EMOJI_RESULT.sha256 {
		if !o.quiet { fmt.printfln("%s: as pinned", EMOJI_RESULT.name) }
	} else {
		src := join({cache, fmt.tprintf("%s-%s", EMOJI_COMMIT, EMOJI_SOURCE.name)})
		if why := toolbox.download_pinned(EMOJI_SOURCE.url, src, EMOJI_SOURCE.sha256, quiet = o.quiet); why != "" { return why }
		font, err := os.read_entire_file(src, context.allocator)
		if err != nil { return fmt.tprintf("%s cannot be read", src) }
		defer delete(font)
		stripped, why := strip_table(font, EMOJI_DROPPED_TABLE)
		if why != "" { return why }
		defer delete(stripped)
		if os.write_entire_file(dst, stripped) != nil { return fmt.tprintf("%s cannot be written", dst) }
		if got := toolbox.sha256_hex(stripped); got != EMOJI_RESULT.sha256 {
			_ = os.remove(dst)
			return fmt.tprintf("%s: SHA-256 mismatch after stripping (%s, expected %s)", EMOJI_RESULT.name, got, EMOJI_RESULT.sha256)
		}
		if !o.quiet { fmt.printfln("%s: %d KiB", EMOJI_RESULT.name, (len(stripped) + BYTES_PER_KIB / 2) / BYTES_PER_KIB) }
	}
	if why := toolbox.download_pinned(EMOJI_LICENCE.url, join({o.dest, EMOJI_LICENCE.name}), EMOJI_LICENCE.sha256, quiet = o.quiet); why != "" { return why }
	if o.unicode {
		for u in UNICODE_FILES {
			if why := toolbox.download_pinned(u.url, join({o.dest, u.name}), u.sha256, quiet = o.quiet); why != "" { return why }
		}
	}
	return ""
}

be32 :: proc(b: []byte, o: int) -> u32 { return u32(b[o]) << 24 | u32(b[o + 1]) << 16 | u32(b[o + 2]) << 8 | u32(b[o + 3]) }
put16 :: proc(b: []byte, o: int, v: int) { b[o], b[o + 1] = u8(v >> 8), u8(v) }
put32 :: proc(b: []byte, o: int, v: u32) { b[o], b[o + 1], b[o + 2], b[o + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v) }
align4 :: proc(n: u32) -> int { return int((n + 3) & ~u32(3)) }

// The sfnt checksum: the sum of the big-endian 32-bit words, the last one padded with zeros.
sfnt_sum :: proc(b: []byte) -> (s: u32) {
	for i := 0; i < len(b); i += 4 {
		w: u32
		for k in 0 ..< 4 { w = w << 8 | (i + k < len(b) ? u32(b[i + k]) : 0) }
		s += w
	}
	return
}

// The font `src` without its table `drop`: the other tables copied byte for byte (each on 4 bytes), the directory rebuilt and
// head.checkSumAdjustment computed again. why != "": the font has no such table, or is not one.
strip_table :: proc(src: []byte, drop: string, allocator := context.allocator) -> (out: []byte, why: string) {
	if len(src) < SFNT_HEADER { return nil, "not a font" }
	n := int(src[4]) << 8 | int(src[5])
	if len(src) < SFNT_HEADER + SFNT_RECORD * n { return nil, "its table directory is cut short" }
	keep := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< n {
		o := SFNT_HEADER + SFNT_RECORD * i
		if string(src[o:o + 4]) == drop { continue }
		if int(be32(src, o + 8)) + int(be32(src, o + 12)) > len(src) { return nil, "a table lies outside the font" }
		append(&keep, o)
	}
	if len(keep) == n { return nil, fmt.tprintf("no %s table in the source font", drop) }
	m, po, es := len(keep), 1, 0
	for po * 2 <= m { po *= 2; es += 1 }
	dir := SFNT_HEADER + SFNT_RECORD * m
	total := dir
	for o in keep { total += align4(be32(src, o + 12)) }
	out = make([]byte, total, allocator)
	copy(out[:4], src[:4])
	put16(out, 4, m)
	put16(out, 6, po * SFNT_RECORD)
	put16(out, 8, es)
	put16(out, 10, m * SFNT_RECORD - po * SFNT_RECORD)
	pos, head := dir, -1
	for o, i in keep {
		d := SFNT_HEADER + SFNT_RECORD * i
		copy(out[d:d + SFNT_RECORD], src[o:o + SFNT_RECORD])
		off, size := int(be32(src, o + 8)), be32(src, o + 12)
		put32(out, d + 8, u32(pos))
		copy(out[pos:pos + int(size)], src[off:off + int(size)])
		if string(src[o:o + 4]) == "head" { head = pos }
		pos += align4(size)
	}
	if head < 0 { delete(out, allocator); return nil, "no head table" }
	put32(out, head + HEAD_ADJUSTMENT, 0)
	put32(out, head + HEAD_ADJUSTMENT, SFNT_CHECKSUM_MAGIC - sfnt_sum(out))
	return out, ""
}

// Every file of `files` in `dir`, with its pinned SHA-256.
files_as_pinned :: proc(dir: string, files: []Pinned) -> bool {
	for f in files {
		if sum, ok := toolbox.sha256_file(join({dir, f.name})); !ok || sum != f.sha256 { return false }
	}
	return true
}

fetch_wgpu :: proc(o: Wgpu_Options) -> string {
	root_text, code := toolbox.capture({o.odin, "root"})
	if code != 0 { return fmt.tprintf("%s root failed", o.odin) }
	odin_root := strings.trim_right(strings.trim_space(root_text), "\\/")
	when ODIN_OS == .Windows {
		return fetch_wgpu_windows(odin_root, o)
	} else {
		return fetch_wgpu_linux(odin_root)
	}
}

fetch_wgpu_windows :: proc(odin_root: string, o: Wgpu_Options) -> string {
	lib_dir := join({odin_root, WGPU_WINDOWS_LIB})
	if files_as_pinned(lib_dir, WGPU_WINDOWS_FILES[:]) {
		fmt.printfln("wgpu-native %s: %s is as pinned", WGPU_VERSION, lib_dir)
	} else {
		zip := join({temp_folder(), WGPU_WINDOWS_ZIP.name})
		if why := toolbox.download_pinned(WGPU_WINDOWS_ZIP.url, zip, WGPU_WINDOWS_ZIP.sha256); why != "" { return why }
		x := join({temp_folder(), WGPU_WINDOWS_EXTRACT})
		_ = os.remove_all(x)
		_ = os.make_directory_all(x)
		if !unzip(zip, x) { return "the wgpu-native archive cannot be unpacked" }
		_ = os.make_directory_all(lib_dir)
		for f in WGPU_WINDOWS_FILES {
			src := find_file(x, f.name, "")
			if src == "" { return fmt.tprintf("%s is not in the wgpu-native archive", f.name) }
			if got, _ := toolbox.sha256_file(src); got != f.sha256 { return fmt.tprintf("%s from the archive does not match its pinned SHA-256 (%s)", f.name, got) }
			if os.copy_file(join({lib_dir, f.name}), src) != nil { return fmt.tprintf("%s cannot be written", join({lib_dir, f.name})) }
		}
		_ = os.remove_all(x)
		fmt.printfln("wgpu-native %s installed in %s", WGPU_VERSION, lib_dir)
	}

	_ = os.make_directory_all(o.dest)
	if os.copy_file(join({o.dest, WGPU_SHARED_LIB}), join({lib_dir, WGPU_SHARED_LIB})) != nil { return fmt.tprintf("%s cannot be copied to %s", WGPU_SHARED_LIB, o.dest) }

	if o.no_dxc { return "" }
	stamp := join({o.dest, DXC_STAMP})
	have := os.exists(stamp)
	for f in DXC_FILES { have &&= os.exists(join({o.dest, f})) }
	if have && toolbox.stamp_holds(stamp, stamp, DXC_ZIP.sha256) {
		fmt.printfln("DXC: %s is as pinned", o.dest)
		return ""
	}
	zip := join({temp_folder(), DXC_ZIP.name})
	if why := toolbox.download_pinned(DXC_ZIP.url, zip, DXC_ZIP.sha256); why != "" { return why }
	x := join({temp_folder(), DXC_EXTRACT})
	_ = os.remove_all(x)
	_ = os.make_directory_all(x)
	if !unzip(zip, x) { return "the DXC archive cannot be unpacked" }
	for f in DXC_FILES {
		src := find_file(x, f, DXC_ARCH)
		if src == "" { return fmt.tprintf("%s (%s) is not in the DXC archive", f, DXC_ARCH) }
		if os.copy_file(join({o.dest, f}), src) != nil { return fmt.tprintf("%s cannot be written", join({o.dest, f})) }
	}
	if !toolbox.write_stamp(stamp, DXC_ZIP.sha256) { return fmt.tprintf("%s cannot be written", stamp) }
	_ = os.remove_all(x)
	fmt.printfln("DXC %s installed in %s", DXC_VERSION, o.dest)
	return ""
}

fetch_wgpu_linux :: proc(odin_root: string) -> string {
	dest := join({odin_root, WGPU_LINUX_DIR})
	stamp := join({dest, WGPU_LINUX_STAMP})
	if toolbox.stamp_holds(join({dest, WGPU_LINUX_LIB}), stamp, WGPU_VERSION) {
		fmt.printfln("wgpu-native %s in %s", WGPU_VERSION, dest)
		return ""
	}
	zip := join({temp_folder(), WGPU_LINUX_ZIP.name})
	if why := toolbox.download_pinned(WGPU_LINUX_ZIP.url, zip, WGPU_LINUX_ZIP.sha256); why != "" { return why }
	defer { _ = os.remove(zip) }
	_ = os.make_directory_all(dest)
	if !unzip(zip, dest) { return "the wgpu-native archive cannot be unpacked" }
	if os.write_entire_file(stamp, fmt.tprintf("%s\n", WGPU_VERSION)) != nil { return fmt.tprintf("%s cannot be written", stamp) }
	fmt.printfln("wgpu-native %s -> %s", WGPU_VERSION, dest)
	return ""
}

