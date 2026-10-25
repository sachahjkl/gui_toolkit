// COLR tables made by hand to be hostile: graphs that ask for too much memory or too much work, and graphs the routing
// to Direct2D (font.colr_nests_glyph) must not take for harmless. The tables are built here, byte by byte.
package colr_test

import "core:testing"
import "core:thread"
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

// The interpreter draws without the atlas lock: several threads asking for color glyphs (some of them the same) get
// consistent, kept bitmaps, and a thread that only looks up a plain glyph is not held up behind the drawing.
@(test)
color_glyphs_from_several_threads :: proc(t: ^testing.T) {
	s: font.State
	st := font.DEFAULT_SETTINGS
	st.color_engine = .Builtin
	font.init(&s, st)
	defer font.destroy(&s)
	id, ok := font.load_embedded(&s, COLRV1)
	testing.expect(t, ok)
	cas := font.cascade(&s, {{font = id}}, nil, true)
	gids := make([dynamic]u16, context.temp_allocator)
	for r := rune(0xF0000); r < 0xF0A00 && len(gids) < 120; r += 1 {
		sh := font.shape(&s, cas, 48, utf8(r), {}, context.temp_allocator)
		if len(sh.glyphs) == 1 && sh.glyphs[0].id != 0 { append(&gids, sh.glyphs[0].id) }
	}
	testing.expect(t, len(gids) > 40)
	Work :: struct { s: ^font.State, id: font.Font_Id, gids: []u16, from: int, bad: int }
	work :: proc(w: ^Work) {
		user := rawptr(w)
		font.atlas_begin_frame(w.s, user)
		defer font.atlas_remove_user(w.s, user)
		for round in 0 ..< 3 {
			for i in w.from ..< len(w.gids) {
				a := font.glyph_image(w.s, w.id, w.gids[i], 40, round % 2)
				b := font.glyph_image(w.s, w.id, w.gids[i], 40, round % 2)
				if a != b { w.bad += 1 }
			}
		}
	}
	jobs: [3]Work
	threads: [3]^thread.Thread
	for i in 0 ..< 3 {
		jobs[i] = Work{s = &s, id = id, gids = gids[:], from = i * 5}
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], work)
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	for j in jobs { testing.expect_value(t, j.bad, 0) }
	drawn, _ := font.colr_counts(&s)
	testing.expect(t, drawn > 40)
}

// ---- GSUB ----

// A GSUB header (version 1.0, no script list) whose feature list is at 10; the lookup list offset is patched in later.
gsub_header :: proc(b: ^Tbl) {
	put16(b, 1); put16(b, 0); put16(b, 0); put16(b, 10); put16(b, 0)
}

patch16 :: proc(b: ^Tbl, at, v: int) { b[at], b[at + 1] = u8(v >> 8), u8(v) }

// 2500 'ccmp' records sharing one feature table of 24 000 lookup indices: 60 million entries if each record were followed.
@(test)
gsub_shared_feature_tables_are_bounded :: proc(t: ^testing.T) {
	b: Tbl
	defer delete(b)
	gsub_header(&b)
	put16(&b, 2500)
	for _ in 0 ..< 2500 { put8(&b, 'c'); put8(&b, 'c'); put8(&b, 'm'); put8(&b, 'p'); put16(&b, 2 + 2500 * 6) }
	put16(&b, 0); put16(&b, 24000)
	for i in 0 ..< 24000 { put16(&b, i) }
	patch16(&b, 8, len(b))
	put16(&b, 0)   // no lookups
	start := time.now()
	_, ok := font.gsub_ligate(b[:], {'c', 'c', 'm', 'p'}, {1, 2, 3, 4, 5}, context.temp_allocator)
	took := time.duration_milliseconds(time.since(start))
	testing.expect(t, !ok)
	testing.expectf(t, took < 200, "%.0f ms", took)
}

// 50 lookups of 200 subtables, all the same table: a ligature subtable whose coverage lists 1000 ranges the glyphs are not in.
@(test)
gsub_shared_subtables_are_bounded :: proc(t: ^testing.T) {
	b: Tbl
	defer delete(b)
	gsub_header(&b)
	put16(&b, 1)
	put8(&b, 'c'); put8(&b, 'c'); put8(&b, 'm'); put8(&b, 'p'); put16(&b, 8)
	put16(&b, 0); put16(&b, 50)
	for i in 0 ..< 50 { put16(&b, i) }
	list := len(b)
	patch16(&b, 8, list)
	put16(&b, 50)
	for _ in 0 ..< 50 { put16(&b, 2 + 50 * 2) }
	lookup := len(b)
	put16(&b, 4); put16(&b, 0); put16(&b, 200)
	for _ in 0 ..< 200 { put16(&b, 6 + 200 * 2) }
	sub := len(b)
	put16(&b, 1); put16(&b, 8); put16(&b, 1); put16(&b, 8 + 4 + 1000 * 6)
	put16(&b, 2); put16(&b, 1000)
	for i in 0 ..< 1000 { put16(&b, 100 + 2 * i); put16(&b, 100 + 2 * i); put16(&b, i) }
	put16(&b, 0)   // a ligature set with no ligature
	_, _ = lookup, sub
	start := time.now()
	_, ok := font.gsub_ligate(b[:], {'c', 'c', 'm', 'p'}, {1, 2, 3, 4, 5}, context.temp_allocator)
	took := time.duration_milliseconds(time.since(start))
	testing.expect(t, !ok)
	testing.expectf(t, took < 200, "%.0f ms", took)
}

// A table that is what it says it is still works: one lookup, one ligature (glyphs 1 2 3 -> 9).
@(test)
gsub_ligature_still_forms :: proc(t: ^testing.T) {
	b: Tbl
	defer delete(b)
	gsub_header(&b)
	put16(&b, 1)
	put8(&b, 'c'); put8(&b, 'c'); put8(&b, 'm'); put8(&b, 'p'); put16(&b, 8)
	put16(&b, 0); put16(&b, 1); put16(&b, 0)   // feature table: one lookup, index 0
	patch16(&b, 8, len(b))
	put16(&b, 1); put16(&b, 4)                 // lookup list: one lookup at +4
	put16(&b, 4); put16(&b, 0); put16(&b, 1); put16(&b, 8)   // type 4, one subtable at +8
	put16(&b, 1); put16(&b, 8); put16(&b, 1); put16(&b, 14)  // subtable: coverage at +8, one set at +14
	put16(&b, 1); put16(&b, 1); put16(&b, 1)                  // coverage format 1: glyph 1
	put16(&b, 1); put16(&b, 4)                                // ligature set: one ligature at +4
	put16(&b, 9); put16(&b, 3); put16(&b, 2); put16(&b, 3)    // -> glyph 9 from 1 2 3
	out, ok := font.gsub_ligate(b[:], {'c', 'c', 'm', 'p'}, {1, 2, 3, 4}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(out), 2)
	if len(out) == 2 { testing.expect(t, out[0] == 9 && out[1] == 4) }
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
