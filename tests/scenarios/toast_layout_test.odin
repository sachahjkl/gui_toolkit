package scenarios_test

// A toast is as tall as its words: a long text goes on to the next lines inside it, a title stays on its line, and the toasts
// of a stack do not cover one another.

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file")
LONG_BODY :: "Permission: bash git push origin release/0.44.0 --force-with-lease, then the tag and the release notes"

@(private = "file")
Toasts :: struct { fired: bool }

@(test)
a_toast_is_as_tall_as_its_words :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Toasts
	s := session.start(t, {size = {900, 500}, user = &r, build = proc(s: ^session.Session) {
		r := (^Toasts)(s.user)
		if !r.fired {
			r.fired = true
			ui.toast(.Info, "Saved")
			ui.toast_titled(.Warn, "Session 12 about the project's frame pacing and its very long title that goes on", LONG_BODY)
		}
		ui.toasts_build()
	}})
	session.frames(s, 30)
	boxes := make([dynamic]^ui.Box, context.temp_allocator)
	for &x in s.state.toasts {
		if !x.alive { continue }
		b := session.find(s, fmt.tprintf("toast_%d", x.serial))
		if testing.expect(t, b != nil, "the toast's box") { append(&boxes, b) }
	}
	if !testing.expect_value(t, len(boxes), 2) { return }
	em := ui.font_size()
	short, long := boxes[0], boxes[1]
	if s.state.toasts[0].title_len > 0 { short, long = long, short }   // (the slots' order is not the stack's)
	sh := short.rect.max.y - short.rect.min.y
	lh := long.rect.max.y - long.rect.min.y
	testing.expectf(t, abs(sh - em * 3) < 1, "one line: the least height (%v)", sh)
	testing.expectf(t, lh > sh + em, "a title and a text on lines: taller (%v against %v)", lh, sh)
	for i := 0; session.find(s, "words", i) != nil; i += 1 {
		w := session.find(s, "words", i)
		p := w.parent
		testing.expectf(t, w.rect.max.y <= p.rect.max.y + 0.5 && w.rect.min.y >= p.rect.min.y - 0.5, "its words inside it: %v in %v", w.rect, p.rect)
	}
	title := session.find(s, "title")
	testing.expect(t, title != nil && title.rect.max.y - title.rect.min.y < em * 2, "the title on one line")
	a, b := short.rect, long.rect
	testing.expect(t, a.max.y <= b.min.y + 0.5 || b.max.y <= a.min.y + 0.5, "one does not cover the other")
	session.save_png(s, "toasts.png")
}) }

// A toast's title is the bold of the family the program gave (ui.set_family: an embedded font's own bold), not a bold
// simulated from the regular face: its strokes thickened by an algorithm, the bar of an e lost its join at small sizes.
// (The monospaced face stands for the family's bold here: one that is not simulated, and not the regular.)
@(test)
a_toast_title_is_the_familys_bold :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Titled :: struct { fired: bool }
	r: Titled
	s := session.start(t, {size = {900, 400}, user = &r, build = proc(s: ^session.Session) {
		r := (^Titled)(s.user)
		ui.set_family(s.state, ui.top_style().font, s.state.mono_font, 0, 0)
		if !r.fired {
			r.fired = true
			ui.toast_titled(.Warn, "Custom ShojiWM Desktop", "Permission: shell rm -rf /tmp/x")
		}
		ui.toasts_build()
		ui.section_header("###sec", "Memory", "a note", "", {1, 0, 0, 1})
	}})
	session.frames(s, 3)
	title := session.find(s, "title")
	if !testing.expect(t, title != nil, "the toast's title") { return }
	testing.expect_value(t, title.font, s.state.mono_font)
	sec := session.find(s, "sec")
	if !testing.expect(t, sec != nil && sec.first != nil, "the section's header") { return }
	name := sec.first.next.next   // (its stripe, a space, then its name)
	testing.expect(t, name != nil && name.font == s.state.mono_font, "the section's name in the family's bold")
}) }
