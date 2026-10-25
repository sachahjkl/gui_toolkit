// COLR tables made by hand to be hostile: graphs that ask for too much memory or too much work, and graphs the routing
// to Direct2D (font.colr_nests_glyph) must not take for harmless. The tables are built here, byte by byte.
package colr_test

import "core:testing"
import "core:time"
import "../../font"

Tbl :: [dynamic]u8

put8 :: proc(b: ^Tbl, v: int) { append(b, u8(v)) }
put16 :: proc(b: ^Tbl, v: int) { append(b, u8(v >> 8), u8(v)) }
put24 :: proc(b: ^Tbl, v: int) { append(b, u8(v >> 16), u8(v >> 8), u8(v)) }
put32 :: proc(b: ^Tbl, v: int) { append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }

patch32 :: proc(b: ^Tbl, at, v: int) {
	b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

// A COLR version 1 header (34 bytes) with no v0 records; the offsets of the three lists are patched in later.
header :: proc(b: ^Tbl) {
	put16(b, 1); put16(b, 0); put32(b, 0); put32(b, 0); put16(b, 0)
	for _ in 0 ..< 5 { put32(b, 0) }
}

BASE_LIST_AT :: 14
LAYER_LIST_AT :: 18
CLIP_LIST_AT :: 22

// A ClipList with one box for glyph 1: 0 0 side side.
clip_box :: proc(b: ^Tbl, side: int) {
	patch32(b, CLIP_LIST_AT, len(b))
	put8(b, 1); put32(b, 1); put16(b, 1); put16(b, 1); put24(b, 12)
	put8(b, 1); put16(b, 0); put16(b, 0); put16(b, side); put16(b, side)
}

paint_solid :: proc(b: ^Tbl) { put8(b, 2); put16(b, 0); put16(b, 0x4000) }

no_outline :: proc(user: rawptr, gid: u16) -> ^font.Outline { return nil }

// Glyph 1: `depth` PaintComposite inside one another (each one's backdrop is the next), all sources the same PaintSolid, with a clip box.
composite_chain :: proc(depth, side: int) -> Tbl {
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, 1); put16(&b, 1); put32(&b, 10)
	for i in 0 ..< depth {
		put8(&b, 32); put24(&b, 8 * (depth - i)); put8(&b, 3); put24(&b, 8)
	}
	paint_solid(&b)
	clip_box(&b, side)
	return b
}

// The memory of a chain of composites is bounded: a glyph with many levels is refused (and nothing is allocated for them all).
@(test)
nested_composites_are_bounded :: proc(t: ^testing.T) {
	SIDE :: 500
	for depth in ([?]int{3, 8, 9, 40, 95}) {
		b := composite_chain(depth, SIDE)
		defer delete(b)
		c := font.colr_open(b[:], nil)
		testing.expect(t, c != nil)
		_, ok := font.colr_render({colr = c, upem = SIDE, outline = no_outline}, 1, {size = SIDE, samples = 2}, context.temp_allocator)
		testing.expectf(t, ok == (depth <= font.COLR_MAX_COMPOSITES), "%d levels: drawn %v", depth, ok)
		font.colr_destroy(c)
	}
	// a composite whose backdrop is itself (offset 0) is a cycle: refused
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, 1); put16(&b, 1); put32(&b, 10)
	put8(&b, 32); put24(&b, 8); put8(&b, 3); put24(&b, 0)
	paint_solid(&b)
	clip_box(&b, SIDE)
	defer delete(b)
	c := font.colr_open(b[:], nil)
	_, ok := font.colr_render({colr = c, upem = SIDE, outline = no_outline}, 1, {size = SIDE, samples = 2}, context.temp_allocator)
	testing.expect(t, !ok)
	font.colr_destroy(c)
}

// The surfaces a glyph keeps alive at once are limited in bytes, whatever its size: a glyph whose surfaces do not fit is
// refused instead of asking the system for the memory.
@(test)
surfaces_are_limited_in_bytes :: proc(t: ^testing.T) {
	SIDE :: 500   // a surface is 502 x 502 x 16 bytes: 3.85 MiB. Two levels of composites keep the canvas, 2 backdrops and 1 source alive: 4 surfaces
	b := composite_chain(2, SIDE)
	defer delete(b)
	c := font.colr_open(b[:], nil)
	defer font.colr_destroy(c)
	src := font.Colr_Source{colr = c, upem = SIDE, outline = no_outline}
	_, ok := font.colr_render(src, 1, {size = SIDE, samples = 2}, context.temp_allocator)
	testing.expect(t, ok)
	_, ok = font.colr_render(src, 1, {size = SIDE, samples = 2, surface_limit = 16 << 20}, context.temp_allocator)
	testing.expect(t, ok)
	_, ok = font.colr_render(src, 1, {size = SIDE, samples = 2, surface_limit = 14 << 20}, context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = font.colr_render(src, 1, {size = SIDE, samples = 2, surface_limit = 2 << 20}, context.temp_allocator)
	testing.expect(t, !ok)
}

// 255 x 255 fills of the whole canvas inside 65 536 paints: the node budget lets it through, the work allowance does not.
work_bomb :: proc(side: int) -> Tbl {
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, 1); put16(&b, 1); put32(&b, 10 + 4 + 510 * 4)   // the root paint comes after the layer list
	// layer list: 255 layers that are X, 255 that are S; offsets from the list
	patch32(&b, LAYER_LIST_AT, len(b))
	list := len(b)
	x, s := list + 4 + 510 * 4 + 6, list + 4 + 510 * 4 + 12
	put32(&b, 510)
	for _ in 0 ..< 255 { put32(&b, x - list) }
	for _ in 0 ..< 255 { put32(&b, s - list) }
	// root: 255 layers from 0; X: 255 layers from 255; S: a solid
	put8(&b, 1); put8(&b, 255); put32(&b, 0)
	put8(&b, 1); put8(&b, 255); put32(&b, 255)
	paint_solid(&b)
	clip_box(&b, side)
	return b
}

@(test)
paint_work_is_bounded :: proc(t: ^testing.T) {
	SIDE :: 128
	b := work_bomb(SIDE)
	defer delete(b)
	c := font.colr_open(b[:], nil)
	testing.expect(t, c != nil)
	defer font.colr_destroy(c)
	start := time.now()
	_, ok := font.colr_render({colr = c, upem = SIDE, outline = no_outline}, 1, {size = SIDE, samples = 2}, context.temp_allocator)
	took := time.duration_milliseconds(time.since(start))
	testing.expectf(t, !ok, "a glyph of 65 000 full-canvas fills was drawn (%.0f ms)", took)
	testing.expectf(t, took < 1000, "%.0f ms", took)
}

// ---- routing: what is not read to its end is not given to Direct2D ----

// Glyphs 1 .. count, each one a PaintColrGlyph of the next; the last one a PaintGlyph inside a PaintGlyph.
colr_glyph_chain :: proc(count: int) -> Tbl {
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, count)
	for i in 1 ..= count { put16(&b, i); put32(&b, 4 + 6 * count + 3 * (i - 1)) }
	for i in 1 ..< count { put8(&b, 11); put16(&b, i + 1) }
	put8(&b, 10); put24(&b, 6); put16(&b, 1)
	put8(&b, 10); put24(&b, 6); put16(&b, 1)
	paint_solid(&b)
	return b
}

@(test)
long_colr_glyph_chains_are_nested :: proc(t: ^testing.T) {
	for count in ([?]int{2, 10, 17, 30, 90}) {
		b := colr_glyph_chain(count)
		defer delete(b)
		c := font.colr_open(b[:], nil)
		testing.expect(t, c != nil)
		testing.expectf(t, font.colr_nests_glyph(c, 1), "%d glyphs chained", count)
		font.colr_destroy(c)
	}
}

// A first layer whose offset leaves the table must not hide a nested paint in the layers after it.
@(test)
unreadable_layer_does_not_hide_nesting :: proc(t: ^testing.T) {
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, 1); put16(&b, 1); put32(&b, 10 + 12)   // the root paint comes after the layer list (4 + 2 x 4 bytes)
	patch32(&b, LAYER_LIST_AT, len(b))
	put32(&b, 2)
	put32(&b, 0xFFFFFF)       // layer 0: outside the table
	put32(&b, 6 + 12)         // layer 1: the outer PaintGlyph, 6 bytes after the root paint at list + 12
	put8(&b, 1); put8(&b, 2); put32(&b, 0)   // root: layers 0 and 1
	put8(&b, 10); put24(&b, 6); put16(&b, 1)   // PaintGlyph ...
	put8(&b, 10); put24(&b, 6); put16(&b, 1)   // ... of a PaintGlyph
	paint_solid(&b)
	defer delete(b)
	c := font.colr_open(b[:], nil)
	testing.expect(t, c != nil)
	testing.expect(t, font.colr_nests_glyph(c, 1))
	font.colr_destroy(c)
}

// Paints that share their parts: 2^30 visits would be needed to know. It is not known, so it is not left to Direct2D.
@(test)
exhausted_budget_is_nested :: proc(t: ^testing.T) {
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, 1); put16(&b, 1); put32(&b, 10)
	DEPTH :: 30
	for _ in 0 ..< DEPTH {   // each composite's source and backdrop are the next composite
		put8(&b, 32); put24(&b, 8); put8(&b, 3); put24(&b, 8)
	}
	paint_solid(&b)
	defer delete(b)
	c := font.colr_open(b[:], nil)
	testing.expect(t, c != nil)
	testing.expect(t, font.colr_nests_glyph(c, 1))
	font.colr_destroy(c)
}

// A base glyph record whose paint offset leaves the table: the glyph has a (broken) color description, so it is not
// taken for a glyph without one, which Direct2D would draw.
@(test)
base_record_outside_table_is_a_graph :: proc(t: ^testing.T) {
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, 1); put16(&b, 1); put32(&b, 0x00FFFFFF)
	defer delete(b)
	c := font.colr_open(b[:], nil)
	testing.expect(t, c != nil)
	testing.expect(t, font.colr_has_glyph(c, 1))
	testing.expect(t, font.colr_nests_glyph(c, 1))
	_, ok := font.colr_render({colr = c, upem = 1000, outline = no_outline}, 1, {size = 32, samples = 2}, context.temp_allocator)
	testing.expect(t, !ok)
	font.colr_destroy(c)
}

// A version 0 header with no records may carry any offsets; a base glyph list that does not fit is a table not to trust.
@(test)
header_checks :: proc(t: ^testing.T) {
	b: Tbl
	header(&b)
	patch32(&b, BASE_LIST_AT, len(b))
	put32(&b, 1); put16(&b, 1); put32(&b, 10)
	paint_solid(&b)
	defer delete(b)
	patch32(&b, 4, 0x7FFFFFF0)    // BaseGlyphRecordsOffset, no records
	patch32(&b, 8, 0x7FFFFFF0)    // LayerRecordsOffset, no records
	c := font.colr_open(b[:], nil)
	testing.expect(t, c != nil)
	font.colr_destroy(c)
	patch32(&b, BASE_LIST_AT, len(b) + 100)   // a base glyph list past the end
	c = font.colr_open(b[:], nil)
	testing.expect(t, c == nil)
	font.colr_destroy(c)
	patch32(&b, BASE_LIST_AT, 34)
	b[34], b[35], b[36], b[37] = 0, 0, 0xFF, 0xFF   // 65 535 records of 6 bytes in a table of 60
	c = font.colr_open(b[:], nil)
	testing.expect(t, c == nil)
}

@(test)
dump_survives_hostile_graphs :: proc(t: ^testing.T) {
	b := composite_chain(18, 100)
	defer delete(b)
	// every composite's source and backdrop are the next composite: 2^18 lines (and 2^40 for a longer chain) if the listing were not bounded
	for i in 0 ..< 18 {
		o := 34 + 10 + 8 * i
		b[o + 1], b[o + 2], b[o + 3] = 0, 0, 8
	}
	c := font.colr_open(b[:], nil)
	testing.expect(t, c != nil)
	defer font.colr_destroy(c)
	s := font.colr_dump(c, 1, context.temp_allocator)
	testing.expect(t, len(s) > 0 && len(s) < 1 << 20)
	// a base record outside the table
	b2: Tbl
	header(&b2)
	patch32(&b2, BASE_LIST_AT, len(b2))
	put32(&b2, 1); put16(&b2, 1); put32(&b2, 0x00FFFFFF)
	defer delete(b2)
	c2 := font.colr_open(b2[:], nil)
	defer font.colr_destroy(c2)
	s = font.colr_dump(c2, 1, context.temp_allocator)
	testing.expect(t, len(s) > 0)
}
