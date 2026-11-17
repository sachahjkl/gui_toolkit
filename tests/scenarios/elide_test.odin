package scenarios_test

// A text cut to a width (ui.elide): whole when it fits, else the most of it that fits with its ellipsis, at its end or
// in its middle, between clusters, without the spaces beside the cut.

import "core:strings"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Elide_Check :: struct { t: ^testing.T, done: bool }

@(private = "file") ELIDE_NAME :: "report-2026-11-17-the-quarterly-numbers-final.pdf"

// (the checks run inside a build: elide reads the window's fonts and its cache)
@(private = "file")
elide_build :: proc(s: ^session.Session) {
	r := (^Elide_Check)(s.user)
	if r.done { return }
	r.done = true
	t := r.t
	st := ui.top_style()
	f, size := st.font, st.font_size
	width := ui.text_width
	full := width(f, size, ELIDE_NAME)

	// fits: the same string, not a copy
	name := ELIDE_NAME
	whole := ui.elide(f, size, name, full + 1)
	testing.expect(t, raw_data(whole) == raw_data(name) && len(whole) == len(name), "a text that fits is returned as it is")

	// the end: a prefix and the ellipsis, within the width, and one character more would not fit
	room := full * 0.5
	end := ui.elide(f, size, ELIDE_NAME, room)
	testing.expectf(t, strings.has_suffix(end, ui.ELLIPSIS), "cut at its end: %q", end)
	kept := end[:len(end) - len(ui.ELLIPSIS)]
	testing.expectf(t, strings.has_prefix(ELIDE_NAME, kept), "its start kept: %q", end)
	testing.expectf(t, width(f, size, end) <= room, "within the width: %v of %v", width(f, size, end), room)
	more := strings.concatenate({name[:len(kept) + 1], ui.ELLIPSIS}, context.temp_allocator)
	testing.expectf(t, width(f, size, more) > room, "the most that fits: %q would too", more)
	testing.expect_value(t, ui.elide(f, size, ELIDE_NAME, room), end)   // (asked again: the cache's cut)

	// the middle: its start and its end, the name's extension kept
	mid := ui.elide(f, size, ELIDE_NAME, room, .Middle)
	i := strings.index(mid, ui.ELLIPSIS)
	testing.expectf(t, i > 0 && strings.has_prefix(ELIDE_NAME, mid[:i]), "its start kept: %q", mid)
	testing.expectf(t, strings.has_suffix(mid, ".pdf") && strings.has_suffix(ELIDE_NAME, mid[i + len(ui.ELLIPSIS):]), "its end kept: %q", mid)
	testing.expectf(t, width(f, size, mid) <= room, "within the width: %v of %v", width(f, size, mid), room)

	// narrower than the ellipsis: nothing
	testing.expect_value(t, ui.elide(f, size, ELIDE_NAME, width(f, size, ui.ELLIPSIS) * 0.5), "")

	// the space before the cut goes
	words :: "aaaa bbbb"
	testing.expect_value(t, ui.elide(f, size, words, width(f, size, "aaaa " + ui.ELLIPSIS)), "aaaa" + ui.ELLIPSIS)

	// never inside a cluster: "e" and its combining acute accent stay together
	accents :: "éééééééé"
	for k in 1 ..< 8 {
		cut := ui.elide(f, size, accents, width(f, size, accents) * f32(k) / 8)
		if cut == "" { continue }
		testing.expectf(t, (len(cut) - len(ui.ELLIPSIS)) % len("é") == 0, "a whole cluster kept: %q", cut)
	}
}

@(test)
elide_cuts_to_the_width :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := new(Elide_Check, context.temp_allocator)
	r.t = t
	s := session.start(t, {size = {600, 300}, no_renderer = true, user = r, build = elide_build})
	session.frames(s, 1)
	testing.expect(t, r.done, "the build ran")
}) }
