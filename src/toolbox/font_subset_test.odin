package tk_toolbox

import "core:slice"
import "core:testing"

@(private = "file") LUCIDE_TTF :: #load("../lucide/lucide.ttf")
@(private = "file") LUCIDE_ODIN :: #load("../lucide/lucide.odin", string)
@(private = "file") ROBOTO :: #load("../font/data/Roboto-Regular.ttf")

// A font's glyph tables, read back.
@(private = "file")
Read_Font :: struct { glyf, loca: []u8, long: bool, chars: map[rune]int, glyphs: int }

@(private = "file")
read_font :: proc(t: ^testing.T, data: []u8) -> (f: Read_Font, ok: bool) {
	tables, why := sfnt_tables(data)
	if !testing.expect_value(t, why, "") { return }
	head, maxp := sfnt_table(tables, "head"), sfnt_table(tables, "maxp")
	f.glyf, f.loca = sfnt_table(tables, "glyf"), sfnt_table(tables, "loca")
	f.long = head[50] == 0 && head[51] == 1
	f.glyphs = int(maxp[4]) << 8 | int(maxp[5])
	f.chars, why = sfnt_cmap(sfnt_table(tables, "cmap"))
	return f, testing.expect_value(t, why, "")
}

// A subset of the icon font keeps each icon asked for with its outline as it was, and nothing else: an icon left out has
// no glyph; the file is a small part of the whole.
@(test)
a_subset_keeps_the_icons_asked_for :: proc(t: ^testing.T) {
	kept := lucide_codes(LUCIDE_ODIN, {"SEARCH", "X", "CHECK", "TRASH_2"})
	dropped := lucide_codes(LUCIDE_ODIN, {"ANCHOR"})
	if !testing.expect_value(t, len(kept), 4) || !testing.expect_value(t, len(dropped), 1) { return }
	sub, why := font_subset(LUCIDE_TTF, kept, context.temp_allocator)
	if !testing.expect_value(t, why, "") { return }
	testing.expectf(t, len(sub) * 20 < len(LUCIDE_TTF), "the subset is small: %d of %d bytes", len(sub), len(LUCIDE_TTF))

	full, fok := read_font(t, LUCIDE_TTF)
	part, pok := read_font(t, sub)
	if !fok || !pok { return }
	testing.expect_value(t, part.glyphs, len(kept) + 1)   // (and .notdef)
	testing.expect_value(t, len(part.chars), len(kept))
	for c in kept {
		gid, mapped := part.chars[c]
		if !testing.expectf(t, mapped && gid != 0, "U+%04X has a glyph", c) { continue }
		was := sfnt_glyph(full.glyf, full.loca, full.long, full.chars[c])
		now := sfnt_glyph(part.glyf, part.loca, part.long, gid)
		testing.expectf(t, len(was) > 0 && len(now) >= len(was) && slice.equal(now[:len(was)], was), "U+%04X: the same outline", c)
		for b in now[len(was):] { testing.expect_value(t, b, 0) }   // (only the padding after it)
	}
	_, has := part.chars[dropped[0]]
	testing.expect(t, !has, "an icon not asked for is not there")
}

// A composite glyph comes with the glyphs it is made of, renumbered: each part's outline is the original part's.
@(test)
a_composite_glyph_keeps_its_parts :: proc(t: ^testing.T) {
	full, ok := read_font(t, ROBOTO)
	if !ok { return }
	char: rune = -1
	for c in 'A' ..= rune(0x17f) {
		if g, has := full.chars[c]; has && len(composite_parts(sfnt_glyph(full.glyf, full.loca, full.long, g))) > 0 { char = c; break }
	}
	if !testing.expect(t, char >= 0, "Roboto has a composite glyph in Latin-1 or Latin Extended-A") { return }
	sub, why := font_subset(ROBOTO, {char}, context.temp_allocator)
	if !testing.expect_value(t, why, "") { return }
	part, pok := read_font(t, sub)
	if !pok { return }
	was_parts := composite_parts(sfnt_glyph(full.glyf, full.loca, full.long, full.chars[char]))
	now_parts := composite_parts(sfnt_glyph(part.glyf, part.loca, part.long, part.chars[char]))
	if !testing.expect_value(t, len(now_parts), len(was_parts)) { return }
	for p, i in now_parts {
		testing.expect(t, p > 0 && p < part.glyphs, "a part is a glyph of the subset")
		was := sfnt_glyph(full.glyf, full.loca, full.long, was_parts[i])
		now := sfnt_glyph(part.glyf, part.loca, part.long, p)
		testing.expectf(t, len(now) >= len(was) && slice.equal(now[:len(was)], was), "part %d: the same glyph", i)
	}
}

// What a source takes from the lucide package: by the alias it imports it as, or by its package name without one; the
// names that are not icons drop out with lucide_codes.
@(test)
the_icons_a_source_names :: proc(t: ^testing.T) {
	aliased := "package x\nimport lucide \"../lucide\"\nf :: proc() { a := lucide.SEARCH; b := lucide.DATA; c := notlucide.X }\n"
	testing.expect(t, slice.equal(lucide_names_in(aliased), []string{"SEARCH", "DATA"}))
	plain := "package x\nimport \"gt:lucide\"\nf :: proc() { a := tk_lucide.TRASH_2 }\n"
	testing.expect(t, slice.equal(lucide_names_in(plain), []string{"TRASH_2"}))
	other := "package x\nimport ic \"gt:lucide\"\nf :: proc() { a := lucide.SEARCH; b := ic.X }\n"
	testing.expect(t, slice.equal(lucide_names_in(other), []string{"X"}))
	testing.expect_value(t, len(lucide_names_in("package x\nf :: proc() { a := lucide.SEARCH }\n")), 0)
	codes := lucide_codes(LUCIDE_ODIN, {"SEARCH", "DATA", "LUCIDE_SUBSET", "NO_SUCH_ICON"})
	testing.expect_value(t, len(codes), 1)
}

// A project's features: their defines for each system (Native_Text and Accessibility are Windows' choices), the subset's
// path only once it is made, and the crates of its notices.
@(test)
the_defines_of_the_features :: proc(t: ^testing.T) {
	all := Features{.Native_Text, .Accessibility, .Mermaid, .Devtools, .Lucide_Subset, .No_Fallback_Fonts}
	windows := feature_defines(all, .Windows, "/b/lucide_subset.ttf")
	testing.expect(t, slice.equal(windows, []string{"-define:FONT_BACKEND=native", "-define:A11Y_ACCESSKIT=true", "-define:TOOLKIT_DEVTOOLS=true",
		"-define:LUCIDE_SUBSET=/b/lucide_subset.ttf", "-define:FONT_EMBED_FALLBACK=false"}))
	linux := feature_defines(all, .Linux, "")
	testing.expect(t, slice.equal(linux, []string{"-define:TOOLKIT_DEVTOOLS=true", "-define:FONT_EMBED_FALLBACK=false"}))
	testing.expect_value(t, len(feature_defines({}, .Windows, "x")), 0)
	testing.expect(t, slice.equal(native_crates({}), []string{"native/text"}))
	testing.expect(t, slice.equal(native_crates({.Mermaid, .Accessibility}), []string{"native/text", "native/a11y", "native/mermaid"}))
}
