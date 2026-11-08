// tools/tk in process: its command line, ppm_diff on two small pictures, the font with a table dropped, the stamps that make a second
// build nothing, font/emoji_data.odin from a small emoji-data.txt, the
// board's list and cells, the command line PowerShell splits (tools/cmdline), and the logo and the icon (drawn by the paint package).
//   odin test tests/tk -vet
package tk_test

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import tk "../../tools/tk"
import "../../tools/cmdline"
import "../../src/testkit"
import "../../src/ascii"
import tk_site "../../src/site"
import toolbox "../../src/toolbox"

@(private = "file") PNG_SIGNATURE :: "\x89PNG\r\n\x1a\n"
@(private = "file") PNG_WIDTH_AT :: 16   // in IHDR, after the signature and the chunk's length and type

@(private = "file") write :: proc(path: string, data: []byte) { _ = os.write_entire_file(path, data) }
@(private = "file") read :: proc(path: string) -> []byte { d, _ := os.read_entire_file(path, context.temp_allocator); return d }

@(test)
the_command_line :: proc(t: ^testing.T) {
	a, why := tk.parse({"fetch_wgpu", "-dest:build/x", "-no-dxc"})
	testing.expect_value(t, why, "")
	testing.expect_value(t, a.command.name, "fetch_wgpu")
	testing.expect_value(t, tk.flag_value(&a, "dest", "?"), "build/x")
	testing.expect_value(t, tk.flag_value(&a, "odin", "odin"), "odin")
	testing.expect(t, tk.has_flag(&a, "no-dxc"))

	a, why = tk.parse({"ppm_diff", "a.ppm", "b.ppm", "-tolerance:5"})
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(a.positionals), 2)
	n, nwhy := tk.int_flag(&a, "tolerance", 2)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, nwhy, "")

	refused := [][]string{
		{},                                    // no command
		{"fetch_fonts"},                       // no such command
		{"fetch_emoji", "-Unicode"},           // the flags are the lower case ones
		{"fetch_emoji", "-unicode:yes"},       // a switch takes no value
		{"fetch_emoji", "-dest"},              // ... and a value flag needs its colon
		{"ppm_diff", "a.ppm"},                 // two pictures
		{"build_naga", "extra"},
	}
	for r in refused {
		_, w := tk.parse(r)
		testing.expectf(t, w != "", "%v is refused", r)
	}
	a, _ = tk.parse({"emoji_board", "-size:big"})
	_, nwhy = tk.int_flag(&a, "size", 32)
	testing.expect(t, nwhy != "", "a size that is not a number is refused")
}

@(private = "file")
ppm :: proc(w, h: int, pixels: []byte) -> []byte {
	head := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, ..transmute([]byte)head)
	append(&out, ..pixels)
	return out[:]
}

@(test)
ppm_diff_of_two_pictures :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tk-ppm")
	a, b := fmt.tprintf("%s/a.ppm", dir), fmt.tprintf("%s/b.ppm", dir)
	// 2x1: the first pixel differs by 1, 0, 3 (worst 3), the second by 10, 0, 0 (worst 10)
	write(a, ppm(2, 1, {10, 20, 30, 100, 100, 100}))
	write(b, ppm(2, 1, {11, 20, 27, 110, 100, 100}))
	d, why := tk.ppm_diff_files(a, b, 2)
	testing.expect_value(t, why, "")
	testing.expect_value(t, d.w, 2)
	testing.expect_value(t, d.h, 1)
	testing.expect_value(t, d.max, 10)
	testing.expect_value(t, d.mean, 14.0 / 6.0)
	testing.expect_value(t, d.over, 2)
	d, _ = tk.ppm_diff_files(a, b, 3)
	testing.expect_value(t, d.over, 1)

	c := fmt.tprintf("%s/c.ppm", dir)
	write(c, ppm(1, 2, {0, 0, 0, 0, 0, 0}))
	_, why = tk.ppm_diff_files(a, c, 2)
	testing.expect_value(t, why, "sizes differ: 2x1 vs 1x2")
	write(c, transmute([]byte)string("P6\n4 4\n255\n\x00"))
	_, why = tk.ppm_diff_files(a, c, 2)
	testing.expect(t, strings.contains(why, "not a P6 PPM"), "a picture cut short is refused")
}

// A font of three tables: `abcd` (3 bytes), `SVG ` (5) and `head` (54, its checkSumAdjustment not yet right).
@(private = "file")
three_table_font :: proc() -> []byte {
	tags := [3]string{"abcd", "SVG ", "head"}
	sizes := [3]int{3, 5, 54}
	font := make([dynamic]byte, 12 + 16 * 3, context.temp_allocator)
	endian.put_u32(font[0:], .Big, 0x00010000)
	endian.put_u16(font[4:], .Big, 3)
	for tag, i in tags {
		r := font[12 + 16 * i:]
		copy(r, tag)
		endian.put_u32(r[4:], .Big, u32(0x1000 + i))   // a checksum, copied as it is
		endian.put_u32(r[8:], .Big, u32(len(font)))
		endian.put_u32(r[12:], .Big, u32(sizes[i]))
		for k in 0 ..< sizes[i] { append(&font, u8(i * 16 + k)) }
		for len(font) % 4 != 0 { append(&font, 0) }
	}
	return font[:]
}

@(test)
a_font_without_its_svg_table :: proc(t: ^testing.T) {
	src := three_table_font()
	out, why := tk.strip_table(src, "SVG ", context.temp_allocator)
	testing.expect_value(t, why, "")
	be16 :: proc(b: []byte, o: int) -> int { v, _ := endian.get_u16(b[o:], .Big); return int(v) }
	be32 :: proc(b: []byte, o: int) -> int { v, _ := endian.get_u32(b[o:], .Big); return int(v) }
	testing.expect_value(t, be16(out, 4), 2)    // numTables
	testing.expect_value(t, be16(out, 6), 32)   // searchRange: the largest power of 2 <= 2, times 16
	testing.expect_value(t, be16(out, 8), 1)    // entrySelector
	testing.expect_value(t, be16(out, 10), 0)   // rangeShift
	testing.expect_value(t, string(out[12:16]), "abcd")
	testing.expect_value(t, string(out[28:32]), "head")
	testing.expect_value(t, be32(out, 12 + 4), 0x1000)
	testing.expect_value(t, be32(out, 12 + 8), 44)        // right after the directory of two
	testing.expect_value(t, be32(out, 28 + 8), 48)        // 3 bytes padded to 4
	testing.expect_value(t, len(out), 44 + 4 + 56)
	testing.expect(t, slice.equal(out[44:47], []byte{0, 1, 2}), "abcd copied byte for byte")
	testing.expect_value(t, out[48], u8(32))             // head's first byte, as it was
	testing.expect_value(t, tk.sfnt_sum(out), u32(tk.SFNT_CHECKSUM_MAGIC))   // what head.checkSumAdjustment is for

	_, why = tk.strip_table(out, "SVG ", context.temp_allocator)
	testing.expect_value(t, why, "no SVG  table in the source font")
	_, why = tk.strip_table(src[:20], "SVG ", context.temp_allocator)
	testing.expect(t, why != "", "a directory cut short is refused")
}

@(test)
the_stamps_of_the_builds :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tk-stamp")
	crate := fmt.tprintf("%s/crate", dir)
	_ = os.make_directory_all(fmt.tprintf("%s/src/deep", crate))
	files := []string{"Cargo.toml", "Cargo.lock", "src/lib.rs", "src/deep/more.rs", "src/main.rs"}
	for f in files { write(fmt.tprintf("%s/%s", crate, f), transmute([]byte)f) }
	steps := fmt.tprintf("%s/steps.odin", dir)
	write(steps, transmute([]byte)string("steps"))

	first, ok := tk.rust_stamp(crate, steps)
	testing.expect(t, ok)
	again, _ := tk.rust_stamp(crate, steps)
	testing.expect_value(t, again, first)
	lib, stamp := fmt.tprintf("%s/x.lib", dir), fmt.tprintf("%s/STAMP", dir)
	testing.expect(t, !tk.stamp_holds(lib, stamp, first), "nothing built yet")
	write(lib, {1})
	write(stamp, transmute([]byte)first)
	testing.expect(t, tk.stamp_holds(lib, stamp, first), "built: the second build does nothing")
	write(fmt.tprintf("%s/src/deep/more.rs", crate), transmute([]byte)string("changed"))
	changed, _ := tk.rust_stamp(crate, steps)
	testing.expect(t, changed != first, "a source changed: built again")
	write(steps, transmute([]byte)string("other steps"))
	moved, _ := tk.rust_stamp(crate, steps)
	testing.expect(t, moved != changed, "the build steps changed: built again")

	sources, sok := tk.naga_sources(crate)
	testing.expect(t, sok)
	parts := strings.split(sources, ",", context.temp_allocator)
	testing.expect_value(t, len(parts), 3)
	sum, _ := toolbox.sha256_file(fmt.tprintf("%s/Cargo.toml", crate))
	testing.expect_value(t, parts[0], ascii.upper(sum))
	// a stamp PowerShell's Set-Content wrote ends with a line end
	write(stamp, transmute([]byte)fmt.tprintf("%s\r\n", sources))
	testing.expect(t, tk.stamp_holds(lib, stamp, sources))
}

@(private = "file")
EMOJI_DATA :: `# emoji-data.txt
# Version: 99.1.0
0023          ; Emoji                # E0.0   [1] (#️)
1F600..1F602  ; Emoji                # E1.0   [3]
1f603         ; Emoji                # lower case digits too
1F601..1F610  ; Emoji                # overlaps the one above
1F612         ; Emoji                # a neighbour of nothing
1F611         ; Emoji                # ... now of both
231A..231B    ; Emoji_Presentation   # E0.6   [2]
1F600         ; Extended_Pictographic# another property
1F700         ; Emoji                  no comment mark: not a line of data
`

@(private = "file")
EMOJI_SOURCE :: "package font\n\n// Generated by tools/tk gen_emoji_data from Unicode 99.1.0 emoji-data.txt (the file tools/tk fetch_emoji -unicode pins). Do not edit.\n\n" +
	"// Emoji=Yes: characters that have an emoji presentation (with U+FE0F, or by default).\n@(rodata)\nEMOJI_RANGES := [?][2]rune{\n\t{0x23, 0x23}, {0x1F600, 0x1F612},\n}\n\n" +
	"// Emoji_Presentation=Yes: characters drawn as emoji unless U+FE0E follows.\n@(rodata)\nEMOJI_PRESENTATION_RANGES := [?][2]rune{\n\t{0x231A, 0x231B},\n}\n"

@(test)
emoji_data_from_unicode :: proc(t: ^testing.T) {
	d := tk.emoji_data_source(EMOJI_DATA)
	testing.expect_value(t, d.version, "99.1.0")
	testing.expect_value(t, d.emoji, 6)
	testing.expect_value(t, d.presentation, 1)
	testing.expect_value(t, d.source, EMOJI_SOURCE)

	// a line of ranges ends before 118 bytes
	many := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20 { fmt.sbprintf(&many, "%X ; Emoji # x\n", 0x10000 + 4 * i) }
	long := tk.emoji_data_source(strings.to_string(many))
	lines := 0
	for l in strings.split_lines(long.source, context.temp_allocator) {
		if strings.has_prefix(l, "\t{") { lines += 1; testing.expectf(t, len(l) <= tk.EMOJI_DATA_LINE, "%d bytes: %q", len(l), l) }
	}
	testing.expect_value(t, lines, 4)   // 5 ranges of 20 bytes a line
}

@(test)
the_emoji_board :: proc(t: ^testing.T) {
	tests := "# group\n1F600 ; fully-qualified # a\n1F601 ; fully-qualified # b\n263A ; unqualified # c\n1F602 ; fully-qualified # d\n1f603 ; fully-qualified # e\n"
	list := tk.board_list(tests, 2)
	testing.expect_value(t, len(list), 2 + len(tk.BOARD_HARD))
	testing.expect_value(t, list[0], "1F600")
	testing.expect_value(t, list[1], "1F602")
	testing.expect_value(t, list[2], tk.BOARD_HARD[0])
	w, h := tk.board_cell(32)
	testing.expect_value(t, w, 60)   // 57.6 -> 58 -> 60
	testing.expect_value(t, h, 52)   // 51.2 -> 51 -> 52
	w, h = tk.board_cell(16)
	testing.expect_value(t, w, 32)
	testing.expect_value(t, h, 28)
	testing.expect_value(t, tk.number_text(1), "1")
	testing.expect_value(t, tk.number_text(1.5), "1.5")
}

@(test)
the_logo_and_its_icon :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tk-logo")
	logo := fmt.tprintf("%s/logo.png", dir)
	testing.expect_value(t, tk.make_logo(logo), "")
	data := read(logo)
	testing.expect(t, strings.has_prefix(string(data), PNG_SIGNATURE), "a PNG")
	width, _ := endian.get_u32(data[PNG_WIDTH_AT:], .Big)
	testing.expect_value(t, width, u32(tk.LOGO_PIXELS))
	pngs, why := tk.icon_pngs(logo, tk.ICON_SIZES[:])
	testing.expect_value(t, why, "")
	for p, i in pngs {
		testing.expect(t, strings.has_prefix(string(p), PNG_SIGNATURE), "a PNG")
		w, _ := endian.get_u32(p[PNG_WIDTH_AT:], .Big)
		testing.expect_value(t, int(w), tk.ICON_SIZES[i])
		delete(p)
	}
	delete(pngs)
	icon := fmt.tprintf("%s/icon.ico", dir)
	testing.expect_value(t, tk.make_icon(logo, icon), "")
	ico := read(icon)
	count, _ := endian.get_u16(ico[4:], .Little)
	testing.expect_value(t, int(count), len(tk.ICON_SIZES))
}

// PowerShell 7 hands `-name:value` typed after `--` to a program as `-name:` and `value`: the tools join them again; what
// another shell passes whole stays as it is.
@(test)
a_flag_split_at_its_colon_is_joined :: proc(t: ^testing.T) {
	got := cmdline.joined({"-backend:", "wgpu", "-group:", "ci1", "text", "-list", "-define:A=b"}, context.temp_allocator)
	testing.expect(t, slice.equal(got, []string{"-backend:wgpu", "-group:ci1", "text", "-list", "-define:A=b"}), fmt.tprint(got))
	last := cmdline.joined({"text", "-group:"}, context.temp_allocator)   // (nothing after it: left as it is)
	testing.expect(t, slice.equal(last, []string{"text", "-group:"}), fmt.tprint(last))
	a, why := tk.parse(cmdline.joined({"fetch_wgpu", "-dest:", "build/x"}, context.temp_allocator))
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(a.flags), 1)
}
// site_docs: docs/*.md as pages (their Markdown: src/site's tests).
@(private = "file") has :: proc(t: ^testing.T, html, part: string, loc := #caller_location) {
	testing.expect(t, strings.contains(html, part), fmt.tprintf("%q is not in %q", part, html), loc = loc)
}

@(test)
markdown_links_become_pages_or_github :: proc(t: ^testing.T) {
	testing.expect_value(t, tk.doc_link("update.md"), "update.html")
	testing.expect_value(t, tk.doc_link("./update.md#section"), "update.html#section")
	testing.expect_value(t, tk.doc_link("#same-page"), "#same-page")
	testing.expect_value(t, tk.doc_link("https://rustup.rs"), "https://rustup.rs")
	testing.expect_value(t, tk.doc_link("../CONTRIBUTING.md"), tk.GITHUB_BLOB + "CONTRIBUTING.md")
	testing.expect_value(t, tk.doc_link("../src/ui/ui.odin#L3"), tk.GITHUB_BLOB + "src/ui/ui.odin#L3")
	testing.expect_value(t, tk.doc_link("screenshots/a.png"), tk.GITHUB_BLOB + "docs/screenshots/a.png")
	has(t, tk_site.markdown_html("[c](../CONTRIBUTING.md) and [d](draw.md)", tk.doc_link), `<a href="`+tk.GITHUB_BLOB+`CONTRIBUTING.md">c</a> and <a href="draw.html">d</a>`)
}

@(test)
site_docs_writes_pages_and_index :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "tk-site-docs")
	site, docs, out := fmt.tprintf("%s/site", dir), fmt.tprintf("%s/docs", dir), fmt.tprintf("%s/out", dir)
	_ = os.make_directory_all(site)
	_ = os.make_directory_all(docs)
	write(fmt.tprintf("%s/index.html", site), transmute([]byte)string(`<header class="bar"><a href="#features">F</a><a href="changelog.html">C</a><img src="img/l.png"><a href="https://x.y/z">G</a></header><script>var menu = 1</script>`))
	write(fmt.tprintf("%s/getting-started.md", docs), transmute([]byte)string("# Getting started\n\nSee [the draw page](draw.md).\n"))
	write(fmt.tprintf("%s/draw.md", docs), transmute([]byte)string("# Drawing\n\nText.\n"))
	write(fmt.tprintf("%s/zzz.md", docs), transmute([]byte)string("# Not in a group\n"))
	testing.expect_value(t, tk.build_docs(docs, site, out), "")

	page := string(read(fmt.tprintf("%s/docs/getting-started.html", out)))
	has(t, page, "<title>Getting started · gui_toolkit</title>")
	has(t, page, `<a href="../index.html#features">F</a><a href="../changelog.html">C</a><img src="../img/l.png"><a href="https://x.y/z">G</a>`)
	has(t, page, `<a href="getting-started.html" aria-current="page">Getting started</a>`)
	has(t, page, `<a href="draw.html">the draw page</a>`)
	has(t, page, "var menu = 1")
	index := string(read(fmt.tprintf("%s/docs/index.html", out)))
	start, drawing, other := strings.index(index, "<h2>Start</h2>"), strings.index(index, "<h2>Drawing and text</h2>"), strings.index(index, "<h2>Other</h2>")
	testing.expect(t, 0 <= start && start < drawing && drawing < other, "the groups are in order, the ungrouped document last")
	has(t, index, `<li><a href="zzz.html">Not in a group</a></li>`)
}


// A command that reads its own arguments (cdp, doc_check, site_check) gets them all, its "--name value" ones too.
@(test)
a_raw_command_gets_every_argument :: proc(t: ^testing.T) {
	a, why := tk.parse({"cdp", "--port", "9300", "click", "--name", "nav0", ",", "idle"})
	testing.expect_value(t, why, "")
	testing.expect_value(t, strings.join(a.positionals[:], " ", context.temp_allocator), "--port 9300 click --name nav0 , idle")
	testing.expect_value(t, len(a.flags), 0)
	_, why = tk.parse({"screenshots", "--only", "about"})
	testing.expect(t, why != "", "the others still read their flags")
}

// theme_shots: the palettes' names, from the toolkit's one list of them.
@(test)
the_palettes_are_named_by_the_source :: proc(t: ^testing.T) {
	names := tk.palette_names("x := 1\nNAMED_PALETTES := [?]Named_Palette{\n\t{\"Midnight\", PALETTE_MIDNIGHT},\n\t{\"Gruvbox Light\", PALETTE_GRUVBOX_LIGHT},\n}\nOTHER := {\"No\", PALETTE_NO}\n")
	testing.expect_value(t, strings.join(names, "|", context.temp_allocator), "Midnight|Gruvbox Light")
	source, ok := tk.read_text(fmt.tprintf("%s/../../src/ui/theme_default.odin", #directory))
	testing.expect(t, ok && len(tk.palette_names(source)) > 10, "the toolkit's list is read")
}
