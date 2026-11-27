package debug_test

import "core:fmt"
import "core:testing"
import "gt:debug"
import "gt:testkit/session"
import "gt:ui"

// socle's Apply panel, call for call: watches, a section of watches, a section with a toggle, two watches and two acts,
// then an act after the sections.
Apply :: struct {
	stage:   enum { Idle, Preparing },
	back:    bool,
	summary: string,
	failure: string,
	built:   string,
	doing:   string,
	open:    bool,
	kept:    int,
	said:    u64,
	adds:    int,
}

APPLY_ROWS :: [?]string{"Apply/stage", "Apply/back to a version", "Apply/summary", "Apply/failure", "Apply/Progress/built",
	"Apply/Progress/downloaded", "Apply/Progress/bytes", "Apply/Progress/doing", "Apply/Log/open", "Apply/Log/lines kept",
	"Apply/Log/lines said"}
APPLY_WATCHES :: [?]string{"Apply/stage", "Apply/back to a version", "Apply/failure", "Apply/Progress/built",
	"Apply/Progress/downloaded", "Apply/Progress/bytes", "Apply/Progress/doing", "Apply/Log/lines kept", "Apply/Log/lines said"}
APPLY_ACTS :: [?]string{"Apply/Log/Add lines", "Apply/Log/Clear", "Apply/Fail the build"}

apply_debug :: proc(a: ^Apply) {
	debug.watch("stage", a.stage)
	debug.watch("back to a version", a.back)
	debug.watch("summary", a.summary)
	debug.watch("failure", a.failure)
	if debug.section("Progress") {
		debug.watch("built", a.built)
		debug.watch("downloaded", fmt.tprintf("%d of %d", 0, 3))
		debug.watch("bytes", fmt.tprintf("%d of %d", 0, 0))
		debug.watch("doing", a.doing)
	}
	if debug.section("Log") {
		debug.toggle("open", &a.open)
		debug.watch("lines kept", a.kept)
		debug.watch("lines said", a.said)
		if debug.act("Add lines") { a.adds += 1 }
		if debug.act("Clear") { a.kept = 0 }
	}
	if debug.act("Fail the build") { a.failure = "simulated by the debug panel" }
}

@(private = "file")
blank :: proc(s: ^session.Session) {}

// In a panel with a section that holds a toggle, two watches and two acts, then an act after it, no two rows overlap,
// the acts start where the labels of their depth start, a toggle's mark ends where the watches' words end (a row's
// value at its end), and every watch shows its value (a dark theme, at 3x).
@(test)
a_panel_of_rows_and_acts_lays_out :: proc(t: ^testing.T) {
	a := Apply{built = "0 of 2", doing = "nothing", failure = "simulated by the debug panel", kept = 1500, said = 4500}
	s := session.start(t, {size = {1200, 2100}, dpi_scale = 3, build = blank, palette = ui.palette_of("Midnight")})
	debug.panel(s.state, "Apply", apply_debug, &a)
	debug.open(s.state)
	testing.expect(t, debug.show_panel(s.state, "Apply"))
	session.wait_box(s, debug.box_name("Apply/Fail the build", "act"))
	session.frames(s, 3)
	session.save_png(s, "apply_panel.png")

	// every row and every act, top to bottom: none overlaps the next
	rects := make([dynamic]ui.Rect, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for path in APPLY_ROWS {
		b := session.get(s, debug.box_name(path, "row"))
		append(&rects, b.rect)
		append(&names, path)
	}
	for path in APPLY_ACTS {
		b := session.get(s, debug.box_name(path, "act"))
		testing.expectf(t, b.rect.max.y - b.rect.min.y > 4, "%s has a height: %v", path, b.rect)
		if path == "Apply/Log/Clear" { continue }   // (beside Add lines, on its row)
		append(&rects, b.rect)
		append(&names, path)
	}
	for i in 1 ..< len(rects) {
		above, below := rects[i - 1], rects[i]
		testing.expectf(t, below.min.y >= above.max.y - 0.5, "%s (%v) overlaps %s (%v)", names[i], below, names[i - 1], above)
	}
	add := session.get(s, debug.box_name("Apply/Log/Add lines", "act"))
	clear := session.get(s, debug.box_name("Apply/Log/Clear", "act"))
	testing.expectf(t, clear.rect.min.x >= add.rect.max.x && abs(clear.rect.min.y - add.rect.min.y) < 0.5, "Clear beside Add lines: %v, %v", clear.rect, add.rect)

	// an act starts where the text of the labels of its depth starts
	text_x :: proc(s: ^session.Session, path: string) -> f32 {
		label := session.get(s, "label", within = session.get(s, debug.box_name(path, "row")))
		return label.rect.min.x + label.text_pad
	}
	inside, outside := text_x(s, "Apply/Log/open"), text_x(s, "Apply/failure")
	testing.expectf(t, abs(add.rect.min.x - inside) < 1, "Add lines at %.1f, the section's labels at %.1f", add.rect.min.x, inside)
	fail := session.get(s, debug.box_name("Apply/Fail the build", "act"))
	testing.expectf(t, abs(fail.rect.min.x - outside) < 1, "Fail the build at %.1f, the panel's labels at %.1f", fail.rect.min.x, outside)

	// a toggle's mark is a row's value: it ends where every watch's words end, centred on its row
	mark := session.get(s, debug.box_name("Apply/Log/open", "check"))
	open_row := session.get(s, debug.box_name("Apply/Log/open", "row"))
	for path in APPLY_WATCHES {
		v := session.get(s, debug.box_name(path, "watch"))
		words_end := v.rect.min.x + (v.rect.max.x - v.rect.min.x) - v.text_pad
		testing.expectf(t, abs(mark.rect.max.x - words_end) < 1, "the toggle's mark ends at %.1f, %s's words at %.1f", mark.rect.max.x, path, words_end)
	}
	mid, row_mid := (mark.rect.min.y + mark.rect.max.y) * 0.5, (open_row.rect.min.y + open_row.rect.max.y) * 0.5
	testing.expectf(t, abs(mid - row_mid) < 1, "the mark centred on its row: %.1f, the row's middle %.1f", mid, row_mid)

	// every watch shows its value: its words in the window, inked
	img := session.capture(s)
	for path in APPLY_WATCHES {
		v := session.get(s, debug.box_name(path, "watch"))
		r := v.rect
		testing.expectf(t, r.max.x - r.min.x > 4 && r.min.x >= 0 && r.max.x <= f32(img.width), "%s: its value's box %v is in the window", path, r)
		ground := session.pixel(img, int(r.min.x) + 1, int(r.min.y) + 1)
		inked := session.count_other(img, {int(r.min.x), int(r.min.y)}, {int(r.max.x), int(r.max.y)}, ground, tolerance = 40)
		testing.expectf(t, inked > 20, "%s: its value %q is drawn (%d pixels inked)", path, v.text, inked)
	}
}
