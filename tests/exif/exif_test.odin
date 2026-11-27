package exif_test

// gt:exif (moved from galerie with its tests): what a camera writes is read, damage reads as none, the orientation is
// written without touching a pixel, the embedded thumbnail is found; a fuzz test with a fixed seed.

import "core:math/rand"
import "core:testing"
import exif "gt:exif"
import image "gt:image"

// A small JPEG of the toolkit's encoder: it writes no metadata.
@(private = "file")
plain_jpeg :: proc() -> []u8 {
	img := image.create(8, 4, {200, 30, 30, 255}, context.temp_allocator)
	return image.jpeg_encode(img, allocator = context.temp_allocator)
}

// A TIFF block, big-endian: IFD0 with Make, Orientation and the Exif and GPS pointers; the Exif IFD with the exposure,
// the f-number, the ISO and the date; the GPS IFD at 48°51'29.6" N, 2°17'40.2" E.
@(private = "file")
sample_tiff :: proc() -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	u16be :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v >> 8), u8(v)) }
	u32be :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }
	entry :: proc(b: ^[dynamic]u8, tag, type, count, value: int) { u16be(b, tag); u16be(b, type); u32be(b, count); u32be(b, value) }
	append(&b, 'M', 'M', 0, 42)
	u32be(&b, 8)
	// IFD0 at 8: 4 entries -> 2 + 48 + 4 = 54 bytes, ends at 62
	u16be(&b, 4)
	entry(&b, 0x010F, 2, 4, 'G' << 24 | 'T' << 16 | 'K' << 8)   // "GTK\0", inside the entry
	entry(&b, 0x0112, 3, 1, 6 << 16)
	entry(&b, 0x8769, 4, 1, 62)
	entry(&b, 0x8825, 4, 1, 62 + 54 + 8 + 8 + 20)
	u32be(&b, 0)
	// Exif IFD at 62: 4 entries (54 bytes), then its values: the exposure at 116, the f-number at 124, the date at 132
	u16be(&b, 4)
	entry(&b, 0x829A, 5, 1, 116)
	entry(&b, 0x829D, 5, 1, 124)
	entry(&b, 0x8827, 3, 1, 400 << 16)
	entry(&b, 0x9003, 2, 20, 132)
	u32be(&b, 0)
	u32be(&b, 1); u32be(&b, 250)
	u32be(&b, 28); u32be(&b, 10)
	for c in "2026:05:01 18:30:00" { append(&b, u8(c)) }
	append(&b, 0)
	// GPS IFD at 152: 4 entries (54 bytes), then the latitude at 206 and the longitude at 230
	u16be(&b, 4)
	entry(&b, 1, 2, 2, 'N' << 24)
	entry(&b, 2, 5, 3, 206)
	entry(&b, 3, 2, 2, 'E' << 24)
	entry(&b, 4, 5, 3, 230)
	u32be(&b, 0)
	for v in ([6]int{48, 1, 51, 1, 296, 10}) { u32be(&b, v) }
	for v in ([6]int{2, 1, 17, 1, 402, 10}) { u32be(&b, v) }
	return b[:]
}

// The TIFF block in a JPEG's APP1 segment, right after its start.
@(private = "file")
jpeg_with :: proc(tiff: []u8) -> []u8 {
	jpeg := plain_jpeg()
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..jpeg[:2])
	n := 2 + 6 + len(tiff)
	append(&out, 0xFF, 0xE1, u8(n >> 8), u8(n))
	append(&out, ..transmute([]u8)string(exif.EXIF_HEADER))
	append(&out, ..tiff)
	append(&out, ..jpeg[2:])
	return out[:]
}

@(test)
a_cameras_metadata_is_read :: proc(t: ^testing.T) {
	tiff := sample_tiff()
	testing.expect_value(t, len(tiff), 254)
	info := exif.read(jpeg_with(tiff), context.temp_allocator)
	testing.expect(t, info.found)
	testing.expect_value(t, info.make, "GTK")
	testing.expect_value(t, info.orientation, 6)
	testing.expect_value(t, info.exposure, [2]u32{1, 250})
	testing.expect_value(t, exif.exposure_words(info.exposure), "1/250 s")
	testing.expect(t, abs(info.f_number - 2.8) < 1e-9)
	testing.expect_value(t, info.iso, 400)
	testing.expect_value(t, info.taken, "2026:05:01 18:30:00")
	testing.expect(t, info.gps)
	testing.expect(t, abs(info.latitude - (48 + 51.0 / 60 + 29.6 / 3600)) < 1e-9)
	testing.expect(t, abs(info.longitude - (2 + 17.0 / 60 + 40.2 / 3600)) < 1e-9)
}

@(test)
a_png_and_a_webp_carry_it_too :: proc(t: ^testing.T) {
	tiff := sample_tiff()
	png := make([dynamic]u8, context.temp_allocator)
	append(&png, ..transmute([]u8)string("\x89PNG\r\n\x1a\n"))
	append(&png, 0, 0, 0, 13, 'I', 'H', 'D', 'R')
	for _ in 0 ..< 13 + 4 { append(&png, 0) }
	n := len(tiff)
	append(&png, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n), 'e', 'X', 'I', 'f')
	append(&png, ..tiff)
	append(&png, 0, 0, 0, 0)
	testing.expect_value(t, exif.read(png[:], context.temp_allocator).orientation, 6)

	webp := make([dynamic]u8, context.temp_allocator)
	append(&webp, 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B', 'P', 'E', 'X', 'I', 'F', u8(n), u8(n >> 8), 0, 0)
	append(&webp, ..tiff)
	testing.expect_value(t, exif.read(webp[:], context.temp_allocator).iso, 400)
}

@(test)
the_orientation_is_written_without_touching_a_pixel :: proc(t: ^testing.T) {
	plain := plain_jpeg()
	testing.expect_value(t, exif.read(plain).orientation, 0)
	turned, result := exif.set_orientation(plain, 6, context.temp_allocator)
	testing.expect_value(t, result, exif.Write_Result.Inserted)
	testing.expect_value(t, exif.read(turned, context.temp_allocator).orientation, 6)
	// (the scan, the pixels' bytes, is the same)
	testing.expect_value(t, len(turned) - len(plain), 36)
	again, result2 := exif.set_orientation(turned, 3, context.temp_allocator)
	testing.expect_value(t, result2, exif.Write_Result.Changed)
	testing.expect_value(t, len(again), len(turned))
	testing.expect_value(t, exif.read(again, context.temp_allocator).orientation, 3)
	img, _, ok := image.decode(again, context.temp_allocator)
	testing.expect(t, ok, "the file still decodes")
	testing.expect_value(t, img.width, 8)

	camera := jpeg_with(sample_tiff())
	back, result3 := exif.set_orientation(camera, 1, context.temp_allocator)
	testing.expect_value(t, result3, exif.Write_Result.Changed)
	info := exif.read(back, context.temp_allocator)
	testing.expect_value(t, info.orientation, 1)
	testing.expect_value(t, info.iso, 400)

	_, refused := exif.set_orientation(transmute([]u8)string("not a jpeg"), 6)
	testing.expect_value(t, refused, exif.Write_Result.Refused)
}

@(test)
turns_and_orientations_are_inverse :: proc(t: ^testing.T) {
	for o in 1 ..= 8 { testing.expect_value(t, exif.turn_orientation(exif.orientation_turn(o)), o) }
	testing.expect_value(t, exif.turn_orientation({1, false}), 6)
	testing.expect_value(t, exif.turn_orientation({-1, false}), 8)
}

@(test)
damaged_metadata_reads_as_none :: proc(t: ^testing.T) {
	tiff := sample_tiff()
	for cut in 0 ..< len(tiff) {
		info := exif.read_tiff(tiff[:cut], context.temp_allocator)
		_ = info
	}
	bad := make([]u8, len(tiff), context.temp_allocator)
	copy(bad, tiff)
	bad[8] = 0xFF   // (an entry count of 0xFF04: past ENTRIES_MAX)
	testing.expect_value(t, exif.read_tiff(bad, context.temp_allocator).orientation, 0)
}


// A header that stops before the scan (a damaged length) may hide a block of metadata: no second one is inserted.
// An orientation of more than one value holds an offset, not the value: it is not written over.
@(test)
a_doubtful_header_is_never_written :: proc(t: ^testing.T) {
	plain := plain_jpeg()
	broken := make([]u8, len(plain), context.temp_allocator)
	copy(broken, plain)
	broken[4], broken[5] = 0xFF, 0xFF   // (the first segment's length: past the file)
	_, result := exif.set_orientation(broken, 6, context.temp_allocator)
	testing.expect_value(t, result, exif.Write_Result.Refused)

	// (fill bytes before a marker are allowed: the walk goes on)
	filled := make([dynamic]u8, context.temp_allocator)
	append(&filled, ..plain[:2])
	append(&filled, 0xFF, 0xFF)
	append(&filled, ..plain[2:])
	_, result2 := exif.set_orientation(filled[:], 6, context.temp_allocator)
	testing.expect_value(t, result2, exif.Write_Result.Inserted)

	tiff := sample_tiff()
	tiff[10 + 12 + 7] = 3   // (IFD0's second entry, the orientation: a count of 3)
	_, result3 := exif.set_orientation(jpeg_with(tiff), 1, context.temp_allocator)
	testing.expect_value(t, result3, exif.Write_Result.Refused)
}

// The rounds of each fuzz test (more with -define:EXIF_FUZZ_ROUNDS=n, a fixed seed: a failure reproduces).
FUZZ_ROUNDS :: #config(EXIF_FUZZ_ROUNDS, 4000)
FUZZ_SEED :: 0x6a1e71e

// `base` changed at a few random places: bytes flipped, set to an edge value, cut, doubled or dropped.
mutate :: proc(base: []u8, r: ^rand.Default_Random_State, allocator := context.allocator) -> []u8 {
	gen := rand.default_random_generator(r)
	b := make([dynamic]u8, 0, len(base) + 64, allocator)
	append(&b, ..base)
	edges := [?]u8{0, 1, 2, 3, 4, 5, 7, 8, 0x7F, 0x80, 0xFE, 0xFF}
	for _ in 0 ..< 1 + rand.int_max(8, gen) {
		if len(b) == 0 { append(&b, 0) }
		at := rand.int_max(len(b), gen)
		switch rand.int_max(6, gen) {
		case 0: b[at] ~= u8(1) << uint(rand.int_max(8, gen))
		case 1: b[at] = edges[rand.int_max(len(edges), gen)]
		case 2: b[at] = u8(rand.uint32(gen))
		case 3: resize(&b, at)
		case 4: inject_at(&b, at, u8(rand.uint32(gen)))
		case 5: ordered_remove(&b, at)
		}
	}
	return b[:]
}

// Damaged and crafted metadata never reads or writes outside its bytes (the bounds are checked in the tests: an
// access outside fails the test) and never takes more than the file holds.
@(test)
metadata_fuzz :: proc(t: ^testing.T) {
	r := rand.create(FUZZ_SEED)
	tiff := sample_tiff()
	seeds := [?][]u8{jpeg_with(tiff), plain_jpeg(), tiff, jpeg_with(tiff_with_thumbnail(plain_jpeg()))}
	for round in 0 ..< FUZZ_ROUNDS {
		free_all(context.temp_allocator)
		tiff = sample_tiff()
		seeds = {jpeg_with(tiff), plain_jpeg(), tiff, jpeg_with(tiff_with_thumbnail(plain_jpeg()))}
		data := mutate(seeds[round % len(seeds)], &r, context.temp_allocator)
		info := exif.read(data, context.temp_allocator)
		_ = exif.read_tiff(data, context.temp_allocator)
		testing.expect(t, info.orientation >= 0 && info.orientation <= 8)
		out, result := exif.set_orientation(data, 1 + round % 8, context.temp_allocator)
		switch result {
		case .Changed:  testing.expect_value(t, len(out), len(data))
		case .Inserted: testing.expect_value(t, len(out), len(data) + 36)
		case .Refused:  testing.expect(t, out == nil)
		}
		_ = exif.orientation_offset(data)
		o := exif.orientation(data)
		testing.expect(t, o >= 0 && o <= 8)
		if thumb := exif.thumbnail(data); thumb != nil {
			testing.expect(t, len(thumb) >= 4 && thumb[0] == 0xFF && thumb[1] == 0xD8)
		}
	}
}

// A TIFF block, little-endian, as a phone writes it: IFD0 with the orientation (8) and a link to IFD1, which says where
// the embedded JPEG is and its length; the JPEG after it.
@(private = "file")
tiff_with_thumbnail :: proc(jpeg: []u8) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	u16le :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v), u8(v >> 8)) }
	u32le :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }
	entry :: proc(b: ^[dynamic]u8, tag, type, count, value: int) { u16le(b, tag); u16le(b, type); u32le(b, count); u32le(b, value) }
	append(&b, 'I', 'I', 42, 0)
	u32le(&b, 8)
	// IFD0 at 8: one entry, 2 + 12 + 4 = 18 bytes, ends at 26
	u16le(&b, 1)
	entry(&b, 0x0112, 3, 1, 8)
	u32le(&b, 26)
	// IFD1 at 26: two entries, 2 + 24 + 4 = 30 bytes, ends at 56: the JPEG there
	u16le(&b, 2)
	entry(&b, 0x0201, 4, 1, 56)
	entry(&b, 0x0202, 4, 1, len(jpeg))
	u32le(&b, 0)
	append(&b, ..jpeg)
	return b[:]
}

@(test)
the_embedded_thumbnail_is_found :: proc(t: ^testing.T) {
	small := plain_jpeg()
	file := jpeg_with(tiff_with_thumbnail(small))
	thumb := exif.thumbnail(file)
	testing.expect_value(t, len(thumb), len(small))
	testing.expect(t, string(thumb) == string(small), "the embedded JPEG's bytes")
	img, _, ok := image.decode(thumb, context.temp_allocator)
	testing.expect(t, ok, "it decodes")
	testing.expect_value(t, img.width, 8)
	testing.expect_value(t, exif.orientation(file), 8)
	testing.expect_value(t, exif.read(file, context.temp_allocator).orientation, 8)
	// (none: a file without metadata, metadata without IFD1)
	testing.expect(t, exif.thumbnail(small) == nil)
	testing.expect(t, exif.thumbnail(jpeg_with(sample_tiff())) == nil)
	testing.expect_value(t, exif.orientation(jpeg_with(sample_tiff())), 6)
	testing.expect_value(t, exif.orientation(small), 0)
	// (a length past the block: refused, not cut)
	bad := tiff_with_thumbnail(small)
	bad[26 + 2 + 12 + 8] = 0xFF
	bad[26 + 2 + 12 + 9] = 0xFF
	testing.expect(t, exif.thumbnail(jpeg_with(bad)) == nil)
}
