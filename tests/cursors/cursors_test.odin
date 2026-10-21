// Cursors: the CSS keywords, where each cursor comes from (system or drawn), the drawn shapes, the resampling of
// custom images, and on a real (hidden) window: every cursor made, sizes and hotspots, the life of custom cursors.
//   odin test tests/cursors -vet -define:ODIN_TEST_THREADS=1
package cursors_test

import "core:testing"
import "../../platform"

@(test)
css_names :: proc(t: ^testing.T) {
	for c in platform.Cursor {
		name := platform.cursor_css_name(c)
		testing.expectf(t, name != "", "%v has a CSS name", c)
		back, ok := platform.cursor_from_css(name)
		testing.expectf(t, ok && back == c, "%q -> %v", name, back)
	}
	c, ok := platform.cursor_from_css("POINTER")
	testing.expect(t, ok && c == .Hand, "ASCII case-insensitive")
	c, ok = platform.cursor_from_css("-webkit-grab")
	testing.expect(t, ok && c == .Grab, "-webkit-grab")
	c, ok = platform.cursor_from_css("-webkit-zoom-out")
	testing.expect(t, ok && c == .Zoom_Out, "-webkit-zoom-out")
	_, ok = platform.cursor_from_css("auto")
	testing.expect(t, !ok, "auto is no cursor")
	_, ok = platform.cursor_from_css("-webkit-pointer")
	testing.expect(t, !ok, "only the legacy -webkit- names")
	_, ok = platform.cursor_from_css("hand")
	testing.expect(t, !ok, "IE's hand is not CSS")
}

// Which cursor is the system's and which is drawn (what Chromium does on Windows, the missing ones drawn).
@(test)
sources :: proc(t: ^testing.T) {
	drawn := bit_set[platform.Cursor]{.Context_Menu, .Cell, .Vertical_Text, .Alias, .Copy, .No_Drop, .Grab, .Grabbing, .Col_Resize, .Row_Resize, .Zoom_In, .Zoom_Out}
	for c in platform.Cursor {
		src := platform.cursor_source(c)
		switch {
		case c == .None: testing.expectf(t, src == .Hidden, "%v hidden", c)
		case c in drawn:
			testing.expectf(t, src == .Drawn, "%v drawn, got %v", c, src)
			testing.expectf(t, platform.cursor_has_shape(c), "%v has a shape", c)
		case:
			testing.expectf(t, src == .System, "%v from the system, got %v", c, src)
			testing.expectf(t, !platform.cursor_has_shape(c), "%v has no shape of its own", c)
		}
	}
	// (resource ids, not strings)
	idc :: proc(c: platform.Cursor) -> uintptr { id, _ := platform.cursor_system_id(c); return uintptr(rawptr(id)) }
	testing.expect(t, idc(.Progress) == 32650, "progress is IDC_APPSTARTING")
	testing.expect(t, idc(.Wait) == 32514, "wait is IDC_WAIT")
	testing.expect(t, idc(.Resize_NE) == 32643, "ne-resize is IDC_SIZENESW")
	testing.expect(t, idc(.Resize_SE) == 32642, "se-resize is IDC_SIZENWSE")
	testing.expect(t, idc(.All_Scroll) == 32646, "all-scroll is IDC_SIZEALL")
	testing.expect(t, idc(.Help) == 32651, "help is IDC_HELP")
	testing.expect(t, idc(.Hand) == 32649, "pointer is IDC_HAND")
}

@(test)
drawn_shapes :: proc(t: ^testing.T) {
	for c in platform.Cursor {
		if !platform.cursor_has_shape(c) { continue }
		for size in ([]int{32, 40, 48, 64, 96}) {
			for scheme in platform.Cursor_Scheme {
				img, ok := platform.cursor_draw(c, size, scheme)
				defer platform.cursor_image_destroy(&img)
				testing.expectf(t, ok && img.size == size && len(img.pixels) == size * size * 4, "%v at %d", c, size)
				if !ok { continue }
				white, black, opaque := 0, 0, 0
				lo, hi := [2]int{size, size}, [2]int{-1, -1}
				for y in 0 ..< size {
					for x in 0 ..< size {
						p := img.pixels[(y * size + x) * 4:][:4]
						if p[3] == 0 { continue }
						lo = {min(lo.x, x), min(lo.y, y)}
						hi = {max(hi.x, x), max(hi.y, y)}
						if p[3] < 250 { continue }
						opaque += 1
						if p[0] > 230 { white += 1 }
						if p[0] < 25 { black += 1 }
					}
				}
				testing.expectf(t, white > size / 2 && black > size / 2, "%v %d %v: both colours (%d white, %d black)", c, size, scheme, white, black)
				// the shape stays within the bitmap with room: nothing touches the right or bottom edge
				testing.expectf(t, hi.x < size - 1 && hi.y < size - 1, "%v %d: inside the bitmap (%v)", c, size, hi)
				// the hotspot is on the shape's bounding box (the arrow's tip, the center of the others)
				h := img.hot
				testing.expectf(t, h.x >= lo.x && h.y >= lo.y && h.x <= hi.x && h.y <= hi.y, "%v %d: hotspot %v in %v..%v", c, size, h, lo, hi)
				// corners are clear
				testing.expectf(t, img.pixels[(size * size - 1) * 4 + 3] == 0, "%v %d: clear corner", c, size)
				// the scheme is the fill: a light cursor is mostly white
				if scheme == .Light {
					testing.expectf(t, white > black || c == .No_Drop || c == .Vertical_Text || c == .Col_Resize || c == .Row_Resize, "%v %d: white fill", c, size)
				}
			}
		}
	}
	img, ok := platform.cursor_draw(.Arrow, 32)
	testing.expect(t, !ok && img.pixels == nil, "the arrow is the system's")
}

@(test)
hotspots :: proc(t: ^testing.T) {
	expect_hot :: proc(t: ^testing.T, c: platform.Cursor, size: int, want: [2]int) {
		img, _ := platform.cursor_draw(c, size)
		defer platform.cursor_image_destroy(&img)
		testing.expectf(t, img.hot == want, "%v at %d: hotspot %v, want %v", c, size, img.hot, want)
	}
	expect_hot(t, .Copy, 32, {1, 1})
	expect_hot(t, .Copy, 64, {2, 2})
	expect_hot(t, .Cell, 32, {14, 14})
	expect_hot(t, .Cell, 48, {21, 21})
	expect_hot(t, .Zoom_In, 32, {12, 12})
	expect_hot(t, .Grab, 32, {14, 15})
	// the hotspot of a centered cursor is on its fill
	for c in ([]platform.Cursor{.Cell, .Grab, .Grabbing, .Zoom_In, .Zoom_Out}) {
		img, _ := platform.cursor_draw(c, 48)
		defer platform.cursor_image_destroy(&img)
		testing.expectf(t, img.pixels[(img.hot.y * 48 + img.hot.x) * 4 + 3] > 200, "%v: the hotspot is on the cursor", c)
	}
}

@(test)
resample :: proc(t: ^testing.T) {
	// 2 x 2: red opaque, transparent, blue half, green opaque
	src := []u8{255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 128, 0, 255, 0, 255}
	same := platform.cursor_resample(src, 2, 2, 2, 2)
	defer delete(same)
	testing.expect(t, string(same) == string(src), "same size: a copy")
	up := platform.cursor_resample(src, 2, 2, 4, 4)
	defer delete(up)
	testing.expect(t, len(up) == 64, "4 x 4")
	testing.expect(t, up[0] == 255 && up[1] == 0 && up[3] == 255, "corner keeps its colour")
	// transparent pixels lend no colour (premultiplied): the pixel next to the transparent one stays pure red
	testing.expectf(t, up[4] == 255 && up[5] == 0 && up[6] == 0, "no dark fringe: %v", up[4:8])
	down := platform.cursor_resample(src, 2, 2, 1, 1)
	defer delete(down)
	// alpha: (255 + 0 + 128 + 255) / 4
	testing.expectf(t, abs(int(down[3]) - 160) <= 1, "mean alpha %d", down[3])
	big := make([]u8, 256 * 256 * 4)
	defer delete(big)
	for i := 0; i < len(big); i += 4 { big[i], big[i + 3] = 200, 255 }
	small := platform.cursor_resample(big, 256, 256, 32, 32)
	defer delete(small)
	testing.expect(t, small[0] == 200 && small[3] == 255 && small[len(small) - 1] == 255, "uniform stays uniform")
	testing.expect(t, platform.cursor_resample(src, 2, 2, 0, 4) == nil, "an empty target")
	testing.expect(t, platform.cursor_resample(src[:8], 2, 2, 4, 4) == nil, "too few pixels")
}

// A hidden window: every cursor is made, at the size of the system's, and custom cursors live and die.
@(test)
window_cursors :: proc(t: ^testing.T) {
	w := platform.open_window("cursors test", {200, 150})
	defer platform.destroy_window(w)
	px := platform.cursor_size_px(w)
	testing.expectf(t, px >= 16 && px <= 1024, "cursor size %d", px)
	for c in platform.Cursor {
		info := platform.cursor_info(w, c)
		testing.expectf(t, info.ok, "%v made", c)
		switch platform.cursor_source(c) {
		case .Hidden: testing.expect(t, info.handle == nil, "none: no cursor")
		case .System: testing.expectf(t, info.handle != nil, "%v loaded", c)
		case .Drawn:
			testing.expectf(t, info.size == {px, px}, "%v drawn at %d (got %v)", c, px, info.size)
			again := platform.cursor_info(w, c)
			testing.expectf(t, again.handle == info.handle, "%v made once", c)
		}
	}
	platform.set_cursor(w, .Grab)
	testing.expect(t, platform.shown_cursor(w) == platform.cursor_handle_of(w, .Grab), "set_cursor shows it")
	platform.set_cursor(w, .None)
	testing.expect(t, platform.shown_cursor(w) == nil, "none hides")

	// custom: a 24 x 16 image, hotspot (5, 3)
	img := make([]u8, 24 * 16 * 4)
	defer delete(img)
	for i := 0; i < len(img); i += 4 { img[i], img[i + 3] = 255, 255 }
	cc, err := platform.custom_cursor_create(w, img, {24, 16}, {5, 3}, key = 77)
	testing.expect(t, err == .None && cc != 0, "made")
	info := platform.custom_cursor_info(w, cc, 1)
	testing.expectf(t, info.ok && info.size == {24, 16} && info.hot == {5, 3}, "at 1x: %v", info)
	info = platform.custom_cursor_info(w, cc, 2)
	testing.expectf(t, info.ok && info.size == {48, 32} && info.hot == {10, 6}, "at 2x: %v", info)
	images, handles := platform.custom_cursor_stats(w)
	testing.expectf(t, images == 1 && handles == 2, "one image, two sizes (%d, %d)", images, handles)
	for s in ([]f32{1.25, 1.5, 1.75, 2.5, 3}) { _ = platform.custom_cursor_info(w, cc, s) }
	_, handles = platform.custom_cursor_stats(w)
	testing.expectf(t, handles == 4, "at most 4 sizes kept (%d)", handles)
	// shared by key
	cc2, err2 := platform.custom_cursor_create(w, nil, {0, 0}, {}, key = 77)
	testing.expect(t, err2 == .None && cc2 == cc, "same key: shared")
	platform.set_cursor_custom(w, cc, .Hand, 1)
	testing.expect(t, platform.shown_cursor(w) != platform.cursor_handle_of(w, .Hand) && platform.shown_cursor(w) != nil, "the image shows")
	platform.custom_cursor_release(w, cc)
	testing.expect(t, platform.custom_cursor_valid(w, cc), "one reference left")
	platform.custom_cursor_release(w, cc)
	testing.expect(t, !platform.custom_cursor_valid(w, cc), "gone with the last reference")
	testing.expect(t, platform.shown_cursor(w) == platform.cursor_handle_of(w, .Hand), "the fallback shows when it goes")
	images, handles = platform.custom_cursor_stats(w)
	testing.expect(t, images == 0 && handles == 0, "nothing left")
	platform.custom_cursor_release(w, cc)   // a stale handle does nothing
	// a reused slot gets a new generation: the old handle stays dead
	cc3, _ := platform.custom_cursor_create(w, img, {24, 16}, {100, -4})
	testing.expect(t, cc3 != cc && !platform.custom_cursor_valid(w, cc), "new generation")
	info = platform.custom_cursor_info(w, cc3, 1)
	testing.expectf(t, info.hot == {23, 0}, "hotspot clamped into the image: %v", info.hot)
	platform.set_cursor_custom(w, cc, .Copy, 1)
	testing.expect(t, platform.shown_cursor(w) == platform.cursor_handle_of(w, .Copy), "a dead custom cursor: the fallback")

	// limits
	big := make([]u8, 300 * 10 * 4)
	defer delete(big)
	_, e := platform.custom_cursor_create(w, big, {300, 10}, {})
	testing.expect(t, e == .Too_Large, "300 px: too large")
	cc4, e4 := platform.custom_cursor_create(w, big, {300, 10}, {}, density = 3)
	testing.expect(t, e4 == .None, "300 image px at 3x are 100 CSS px")
	platform.custom_cursor_release(w, cc4)
	_, e = platform.custom_cursor_create(w, big[:100], {300, 10}, {})
	testing.expect(t, e == .Bad_Size, "too few pixels")
	_, e = platform.custom_cursor_create(w, big, {0, 10}, {})
	testing.expect(t, e == .Bad_Size, "empty")
	// cc3 stays: destroy_window frees it
}
