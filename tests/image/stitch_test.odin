package image_test

// image.Stitcher on synthetic screens: one tall page (a sticky header, rows that scroll, a footer) cut into screens at
// irregular steps is stitched back exactly; a screen too far from the one before is refused and the stitch goes on; a
// repeated screen is the end; max_height bounds the picture; repeated rows still align, and on a page whose every row
// repeats the largest overlap (the smallest move) is taken. The stitched pictures are made in context.allocator, so the
// test runner's tracker checks that the stitcher frees what it does not give.

import "core:slice"
import "core:testing"
import image "gt:image"

@(private = "file")
W :: 8
@(private = "file")
HEADER :: 20
@(private = "file")
FOOTER :: 10
@(private = "file")
VIEW :: 90   // the rows that scroll on one screen
@(private = "file")
PAGE :: 800
@(private = "file")
LAST :: PAGE - HEADER - FOOTER - VIEW   // the offset of the last screen

// The page: every row different (its number in red and green, the column in blue).
@(private = "file")
stitch_page :: proc() -> image.Image {
	img := image.create(W, PAGE, allocator = context.temp_allocator)
	for y in 0 ..< PAGE {
		for x in 0 ..< W {
			p := img.pixels[(y * W + x) * 4:][:4]
			p[0], p[1], p[2], p[3] = u8(y), u8(y >> 8), u8(x * 31), 255
		}
	}
	return img
}

// Row `y` of `img` all `c`.
@(private = "file")
row_fill :: proc(img: image.Image, y: int, c: image.Color) {
	image.fill_rect(img, {0, y, img.width, 1}, c)
}

@(private = "file")
rows_of :: proc(img: image.Image, from, count: int) -> []u8 {
	return img.pixels[from * img.width * 4:][:count * img.width * 4]
}

// The screen scrolled by `offset` rows: the header, VIEW rows of the middle from `offset`, the footer.
@(private = "file")
screen :: proc(page: image.Image, offset: int) -> image.Image {
	img := image.create(W, HEADER + VIEW + FOOTER, allocator = context.temp_allocator)
	copy(rows_of(img, 0, HEADER), rows_of(page, 0, HEADER))
	copy(rows_of(img, HEADER, VIEW), rows_of(page, HEADER + offset, VIEW))
	copy(rows_of(img, HEADER + VIEW, FOOTER), rows_of(page, PAGE - FOOTER, FOOTER))
	return img
}

// Screens from the top to the end of the page, the steps taken in turn; the offset of each.
@(private = "file")
screens :: proc(page: image.Image, steps: []int) -> (frames: []image.Image, offsets: []int) {
	f := make([dynamic]image.Image, context.temp_allocator)
	o := make([dynamic]int, context.temp_allocator)
	offset := 0
	for i := 0;; i += 1 {
		append(&f, screen(page, offset))
		append(&o, offset)
		if offset == LAST { break }
		offset = min(offset + steps[i % len(steps)], LAST)
	}
	return f[:], o[:]
}

// The page cut after `middle` rows that scroll, its footer below.
@(private = "file")
page_part :: proc(page: image.Image, middle: int) -> image.Image {
	img := image.create(W, HEADER + middle + FOOTER, allocator = context.temp_allocator)
	copy(rows_of(img, 0, HEADER + middle), rows_of(page, 0, HEADER + middle))
	copy(rows_of(img, HEADER + middle, FOOTER), rows_of(page, PAGE - FOOTER, FOOTER))
	return img
}

@(private = "file")
expect_same :: proc(t: ^testing.T, got, want: image.Image, what: string, loc := #caller_location) {
	if !testing.expectf(t, got.width == want.width && got.height == want.height, "%s: %d x %d, not %d x %d", what, got.width, got.height, want.width, want.height, loc = loc) { return }
	for y in 0 ..< want.height {
		if !slice.equal(rows_of(got, y, 1), rows_of(want, y, 1)) {
			testing.expectf(t, false, "%s: row %d differs", what, y, loc = loc)
			return
		}
	}
}

@(test)
stitch_rebuilds_the_page :: proc(t: ^testing.T) {
	page := stitch_page()
	steps := [?]int{37, 43, 61, 17, 70, 52, 74, 29}
	frames, offsets := screens(page, steps[:])

	s := image.stitch_begin()
	for frame, i in frames {
		moved, result := image.stitch_add(&s, frame)
		testing.expect_value(t, result, image.Stitch_Result.Added)
		testing.expect_value(t, moved, i == 0 ? HEADER + VIEW + FOOTER : offsets[i] - offsets[i - 1])
	}
	// the page did not move: its end
	moved, result := image.stitch_add(&s, frames[len(frames) - 1])
	testing.expect_value(t, result, image.Stitch_Result.Same)
	testing.expect_value(t, moved, 0)
	out, ok := image.stitch_end(&s)
	testing.expect(t, ok)
	expect_same(t, out, page, "incremental")
	image.destroy(&out)

	// the same frames at once, the last one twice: it stops there
	all := make([dynamic]image.Image, context.temp_allocator)
	append(&all, ..frames)
	append(&all, frames[len(frames) - 1])
	whole, used, whole_ok := image.stitch(all[:])
	testing.expect(t, whole_ok)
	testing.expect_value(t, used, len(frames))
	expect_same(t, whole, page, "at once")
	image.destroy(&whole)
}

@(test)
stitch_refuses_frames_that_do_not_overlap :: proc(t: ^testing.T) {
	page := stitch_page()
	s := image.stitch_begin()
	_, first := image.stitch_add(&s, screen(page, 0))
	testing.expect_value(t, first, image.Stitch_Result.Added)
	// 10 rows in common, under the least overlap (16): refused, nothing changed
	moved, result := image.stitch_add(&s, screen(page, 80))
	testing.expect_value(t, result, image.Stitch_Result.No_Overlap)
	testing.expect_value(t, moved, 0)
	// a smaller step joins the first frame
	moved, result = image.stitch_add(&s, screen(page, 50))
	testing.expect_value(t, result, image.Stitch_Result.Added)
	testing.expect_value(t, moved, 50)
	out, ok := image.stitch_end(&s)
	testing.expect(t, ok)
	expect_same(t, out, page_part(page, 50 + VIEW), "after a refused frame")
	image.destroy(&out)

	// at once: a picture with a hole is no answer
	frames := []image.Image{screen(page, 0), screen(page, 80)}
	whole, _, whole_ok := image.stitch(frames)
	testing.expect(t, !whole_ok)
	testing.expect_value(t, len(whole.pixels), 0)

	// a frame of another size
	s = image.stitch_begin()
	image.stitch_add(&s, screen(page, 0))
	_, result = image.stitch_add(&s, image.create(W + 1, HEADER + VIEW + FOOTER, allocator = context.temp_allocator))
	testing.expect_value(t, result, image.Stitch_Result.Refused)
	one, one_ok := image.stitch_end(&s)
	testing.expect(t, one_ok)
	expect_same(t, one, screen(page, 0), "one frame")
	image.destroy(&one)

	// no frame
	s = image.stitch_begin()
	_, none_ok := image.stitch_end(&s)
	testing.expect(t, !none_ok)
}

@(test)
stitch_stops_at_the_max_height :: proc(t: ^testing.T) {
	page := stitch_page()
	steps := [?]int{37, 43, 61, 17, 70, 52, 74, 29}
	frames, _ := screens(page, steps[:])
	out, used, ok := image.stitch(frames, {max_height = 300})
	testing.expect(t, ok)
	testing.expect(t, used < len(frames))
	// the rows past the bound are cut; the footer still ends the picture
	expect_same(t, out, page_part(page, 300 - HEADER - FOOTER), "bounded")
	image.destroy(&out)

	// a first frame taller than the bound is cut, and the stitch is full
	s := image.stitch_begin({max_height = 50})
	moved, result := image.stitch_add(&s, frames[0])
	testing.expect_value(t, result, image.Stitch_Result.Full)
	testing.expect_value(t, moved, 50)
	_, result = image.stitch_add(&s, frames[1])
	testing.expect_value(t, result, image.Stitch_Result.Full)
	cut, _ := image.stitch_end(&s)
	testing.expect_value(t, cut.height, 50)
	image.destroy(&cut)
}

@(test)
stitch_aligns_repeated_rows :: proc(t: ^testing.T) {
	// a block of 40 equal rows and one of 12: with steps of 40 rows at most, every overlap is 50 rows or more, longer
	// than a block, so only the true alignment matches it
	page := stitch_page()
	for y in 300 ..< 340 { row_fill(page, y, image.WHITE) }
	for y in 500 ..< 512 { row_fill(page, y, image.BLACK) }
	steps := [?]int{23, 31, 40, 17, 38}
	frames, _ := screens(page, steps[:])
	out, used, ok := image.stitch(frames)
	testing.expect(t, ok)
	testing.expect_value(t, used, len(frames))
	expect_same(t, out, page, "repeated rows")
	image.destroy(&out)

	// every row repeats each 5 rows: a move of 12 and a move of 2 both match; the largest overlap wins
	periodic := stitch_page()
	for y in HEADER ..< PAGE - FOOTER {
		v := u8((y - HEADER) % 5 * 50)
		row_fill(periodic, y, {v, v, v, 255})
	}
	s := image.stitch_begin()
	image.stitch_add(&s, screen(periodic, 0))
	moved, result := image.stitch_add(&s, screen(periodic, 12))
	testing.expect_value(t, result, image.Stitch_Result.Added)
	testing.expect_value(t, moved, 2)
	end, _ := image.stitch_end(&s)
	image.destroy(&end)
}
