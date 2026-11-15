package scenarios_test

// A label whose text changes (ui.morph_label): its width is the new text's at once, what stays the same stays still,
// the rest flips and settles on the new text within MORPH_MS; with the animations off, the new text at once.

import "core:strings"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Morph_Run :: struct { text: string }

@(private = "file")
morph_build :: proc(s: ^session.Session) {
	r := (^Morph_Run)(s.user)
	ui.next({fixed_x = 10, fixed_y = 10, height = ui.px(24)})
	ui.morph_label(strings.concatenate({r.text, "###status"}, context.temp_allocator))
}

@(test)
a_morph_label_settles_on_its_new_text :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Morph_Run{text = "3 running · 12 sessions"}
	s := session.start(t, {size = {400, 60}, user = &r, build = morph_build, animations = true})
	session.frames(s, 2)
	testing.expect_value(t, session.get(s, "status").text, "3 running · 12 sessions")
	r.text = "0 running · 47 sessions"
	session.frame(s)
	b := session.get(s, "status")
	testing.expect(t, b.text != r.text, "it changes over a few frames, not at once")
	testing.expect(t, strings.has_suffix(b.text, " sessions") || strings.contains(b.text, " running "), "what stays the same stays")
	session.advance(s, ui.MORPH_MS + 50)
	session.frames(s, 2)
	testing.expect_value(t, session.get(s, "status").text, r.text)
}) }

@(test)
with_the_animations_off_the_text_changes_at_once :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Morph_Run{text = "connected a.example"}
	s := session.start(t, {size = {400, 60}, user = &r, build = morph_build, animations = false})
	session.frames(s, 2)
	r.text = "connected b.example"
	session.frame(s)
	testing.expect_value(t, session.get(s, "status").text, r.text)
}) }
