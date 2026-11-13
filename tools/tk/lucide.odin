package tk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import ascii "../../src/ascii"

// gen_lucide: src/lucide/lucide.odin from src/lucide/lucide.ttf, one constant per icon of the font, named after the
// glyph's name in its 'post' table ("arrow-up-down" is ARROW_UP_DOWN), its character from the 'cmap' table. Every icon
// is then named: none is added by hand, and a newer font gives its new icons by running this again.
run_gen_lucide :: proc(args: []string) -> string {
	root := toolkit_root()
	ttf := join({root, "src", "lucide", "lucide.ttf"})
	data, err := os.read_entire_file(ttf, context.temp_allocator)
	if err != nil { return fmt.tprintf("%s cannot be read", ttf) }
	icons, why := lucide_icons(data)
	if why != "" { return why }
	out := join({root, "src", "lucide", "lucide.odin"})
	if os.write_entire_file(out, transmute([]u8)lucide_source(icons)) != nil { return fmt.tprintf("%s cannot be written", out) }
	fmt.printfln("wrote %s: %d icons", out, len(icons))
	return ""
}

Lucide_Icon :: struct { name: string, code: rune }

// The icons of a Lucide font: each character of its character map and its glyph's name, sorted by name.
lucide_icons :: proc(data: []u8) -> (icons: []Lucide_Icon, why: string) {
	be16 :: proc(d: []u8, at: int) -> int { return int(d[at]) << 8 | int(d[at + 1]) }
	be32 :: proc(d: []u8, at: int) -> int { return be16(d, at) << 16 | be16(d, at + 2) }
	if len(data) < 12 { return nil, "not a font" }
	cmap, post := -1, -1
	for i in 0 ..< be16(data, 4) {
		at := 12 + 16 * i
		if at + 16 > len(data) { return nil, "a truncated table directory" }
		tag := string(data[at:at + 4])
		if tag == "cmap" { cmap = be32(data, at + 8) }
		if tag == "post" { post = be32(data, at + 8) }
	}
	if cmap < 0 || post < 0 { return nil, "no cmap or post table" }
	if be32(data, post) != 0x00020000 { return nil, "the post table has no glyph names (not version 2.0)" }

	// the glyphs' names: post 2.0, the names past the 258 standard Macintosh ones are Pascal strings after the indexes
	glyphs := be16(data, post + 32)
	index_at := post + 34
	strings_at := index_at + 2 * glyphs
	extra := make([dynamic]string, context.temp_allocator)
	for p := strings_at; p < len(data); {
		n := int(data[p])
		if p + 1 + n > len(data) { break }
		append(&extra, string(data[p + 1:p + 1 + n]))
		p += 1 + n
		if len(extra) >= glyphs { break }
	}
	name_of :: proc(data: []u8, index_at, gid: int, extra: []string) -> string {
		k := int(data[index_at + 2 * gid]) << 8 | int(data[index_at + 2 * gid + 1])
		if k < 258 || k - 258 >= len(extra) { return "" }
		return extra[k - 258]
	}

	// the character map: format 12 (whole Unicode) when there is one, else format 4
	sub := -1
	format := 0
	for i in 0 ..< be16(data, cmap + 2) {
		at := cmap + 4 + 8 * i
		off := cmap + be32(data, at + 4)
		f := be16(data, off)
		if f == 12 || (f == 4 && format != 12) { sub, format = off, f }
	}
	if sub < 0 { return nil, "no format 4 or 12 character map" }
	seen := make(map[string]bool, context.temp_allocator)
	out := make([dynamic]Lucide_Icon, context.temp_allocator)
	add :: proc(out: ^[dynamic]Lucide_Icon, seen: ^map[string]bool, name: string, code: rune) {
		if name == "" || name == ".notdef" || code < 0xe000 || seen[name] { return }
		seen[name] = true
		append(out, Lucide_Icon{name, code})
	}
	if format == 12 {
		for g in 0 ..< be32(data, sub + 12) {
			at := sub + 16 + 12 * g
			first, last, gid := be32(data, at), be32(data, at + 4), be32(data, at + 8)
			for c in first ..= last { add(&out, &seen, name_of(data, index_at, gid + (c - first), extra[:]), rune(c)) }
		}
	} else {
		segs := be16(data, sub + 6) / 2
		ends := sub + 14
		starts := ends + 2 * segs + 2
		deltas := starts + 2 * segs
		ranges := deltas + 2 * segs
		for s in 0 ..< segs {
			first, last := be16(data, starts + 2 * s), be16(data, ends + 2 * s)
			delta, range := be16(data, deltas + 2 * s), be16(data, ranges + 2 * s)
			if first == 0xffff { continue }
			for c in first ..= last {
				gid: int
				if range == 0 {
					gid = (c + delta) & 0xffff
				} else {
					at := ranges + 2 * s + range + 2 * (c - first)
					gid = be16(data, at)
					if gid != 0 { gid = (gid + delta) & 0xffff }
				}
				if gid != 0 { add(&out, &seen, name_of(data, index_at, gid, extra[:]), rune(c)) }
			}
		}
	}
	slice.sort_by(out[:], proc(x, y: Lucide_Icon) -> bool { return x.name < y.name })
	return out[:], ""
}

// The Odin source of the icons: a constant each, UPPER_SNAKE of the glyph's name.
lucide_source :: proc(icons: []Lucide_Icon) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `// The Lucide icons (lucide.dev, ISC licence: LICENSE.txt beside this file), as a font: DATA is its face (font.load_embedded),
// and each constant one icon's character in it, named as the font names its glyph. A program draws an icon as text in
// that face. One set for every program of the toolkit.
//
// -define:LUCIDE_SUBSET=<absolute path>: DATA is that font instead, the icons the program uses (toolbox.lucide_subset,
// Feature.Lucide_Subset: 900 KB less). A constant whose icon it does not hold draws nothing.
//
// Generated from lucide.ttf by `+"`odin run tools/tk -- gen_lucide`"+`: do not edit; a newer font, then that command again.
package tk_lucide

LUCIDE_SUBSET :: #config(LUCIDE_SUBSET, "")

when LUCIDE_SUBSET != "" {
	DATA :: #load(LUCIDE_SUBSET)
} else {
	DATA :: #load("lucide.ttf")
}

`)
	width := 0
	for ic in icons { width = max(width, len(ic.name)) }
	for ic in icons {
		upper := ascii.upper(ic.name)
		constant, _ := strings.replace_all(upper, "-", "_", context.temp_allocator)
		if len(constant) > 0 && constant[0] >= '0' && constant[0] <= '9' { constant = fmt.tprintf("N%s", constant) }
		fmt.sbprintf(&b, "%-*s :: \"\\u%04x\"   // %s\n", width, constant, int(ic.code), ic.name)
	}
	return strings.to_string(b)
}
