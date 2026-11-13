package scenarios_test

// The colour picker (ui.color_picker) by what it is for: the square, the hue bar and the opacity bar give the colours under
// the pointer, the old colour takes it back, the keyboard moves each part, the text field reads every format and the format
// switch writes in it; the text of each format reads back as the colour it was written from (ui.color_parse, ui.color_text).

import "core:strings"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{500, 500}
// A colour read back from its text: within one step of 8 bits (oklch and hsl round their numbers).
@(private = "file") CHANNEL_NEAR :: 1.5 / 255.0
// A press a pixel or two into a part: its value there, to this much.
@(private = "file") PRESS_NEAR :: 0.03
// The keyboard's steps (ui pickers): Shift moves the square a tenth.
@(private = "file") SHIFT_STEP :: 0.1
// A drag this far past a part's edge (px).
@(private = "file") OUTSIDE :: 20

@(private = "file")
Run :: struct { cp: ui.Color_Pick, changed: int, text: string }

@(private = "file")
near :: proc(a, b: ui.Srgba, eps: f32 = CHANNEL_NEAR) -> bool {
	for k in 0 ..< 4 { if abs(a[k] - b[k]) > eps { return false } }
	return true
}

@(private = "file")
picker :: proc(t: ^testing.T, r: ^Run) -> ^session.Session {
	return session.start(t, {size = WINDOW, user = r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if ui.color_picker("###pick", &r.cp) {
			r.changed += 1
			delete(r.text)
			r.text = strings.clone(ui.color_pick_text(&r.cp))
		}
	}})
}

@(test)
the_colour_picker_gives_the_colour_under_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer { ui.color_pick_destroy(&r.cp); delete(r.text) }
	ui.color_pick_set(&r.cp, {1, 0, 0, 1}, {.Hex, false})
	s := picker(t, &r)

	sq := session.get(s, "square")
	session.drag(s, session.center(sq), {sq.rect.min.x - OUTSIDE, sq.rect.max.y + OUTSIDE})
	testing.expect_value(t, r.text, "#000000")   // the bottom left is black
	session.drag(s, session.center(sq), {sq.rect.max.x + OUTSIDE, sq.rect.min.y - OUTSIDE})
	testing.expect_value(t, r.text, "#ff0000")   // the top right (a drag past it stays on its edge): the hue in full

	hue := session.get(s, "hue")
	session.click_at(s, session.center(hue))
	testing.expectf(t, abs(r.cp.hue - 0.5) < PRESS_NEAR, "the middle of the hue bar is cyan: %v (%s)", r.cp.hue, r.text)
	alpha := session.get(s, "alpha")
	session.click_at(s, {alpha.rect.min.x + 1, session.center(alpha).y})
	testing.expectf(t, r.cp.alpha < PRESS_NEAR && len(r.text) == len("#rrggbbaa"), "the left of the opacity bar is transparent: %s", r.text)

	// the old colour takes it back
	session.click(s, "old")
	testing.expect_value(t, r.text, "#ff0000")

	// the keyboard: the square by a tenth with Shift, the hue by degrees
	session.click_at(s, session.center(sq))
	sat := r.cp.sat
	session.key(s, .Left, {.Shift})
	testing.expectf(t, abs(r.cp.sat - (sat - SHIFT_STEP)) < 0.001, "Shift+Left: a tenth less saturated: %v -> %v", sat, r.cp.sat)
	session.key(s, .Tab)   // (the old colour, then the hue bar)
	session.key(s, .Tab)
	h := r.cp.hue
	session.key(s, .Right, repeat = 3)
	testing.expectf(t, abs(r.cp.hue - (h + 3.0 / 360)) < 0.0001, "three degrees: %v -> %v", h, r.cp.hue)
}) }

@(test)
the_colour_picker_reads_and_writes_each_format :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer { ui.color_pick_destroy(&r.cp); delete(r.text) }
	ui.color_pick_set(&r.cp, {0, 0, 1, 1}, {.Hex, false})
	s := picker(t, &r)

	typed := [?]struct { text: string, want: ui.Srgba, format: ui.Color_Format } {
		{"rgb(10 20 30)", {10.0 / 255, 20.0 / 255, 30.0 / 255, 1}, .Rgb},
		{"rgba(255, 0, 0, 0.5)", {1, 0, 0, 0.5}, .Rgb},
		{"hsl(120deg 100% 25%)", {0, 0.5, 0, 1}, .Hsl},
		{"#ff000080", {1, 0, 0, 128.0 / 255}, .Hex},
		{"oklch(0.628 0.2577 29.23)", {1, 0, 0, 1}, .Oklch},
	}
	for c in typed {
		session.click(s, "text")
		session.key(s, .A, {.Ctrl})
		session.type_text(s, c.text)
		testing.expectf(t, near(ui.color_pick_rgba(&r.cp), c.want, 0.01), "%s is %v", c.text, ui.color_pick_rgba(&r.cp))
		testing.expect_value(t, r.cp.style.format, c.format)
		testing.expect_value(t, r.text, c.text)   // as typed
	}
	// the switch writes the colour in another format
	session.click(s, "seg2")
	testing.expect_value(t, r.cp.style.format, ui.Color_Format.Hsl)
	testing.expect(t, strings.has_prefix(r.text, "hsl("), r.text)
	back, _, ok := ui.color_parse(r.text)
	testing.expectf(t, ok && near(back, ui.color_pick_rgba(&r.cp)), "%s reads back as the colour", r.text)
	testing.expect_value(t, ui.field_string(&r.cp.field), r.text)
}) }

@(test)
colour_text_reads_back_in_every_style :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	colours := [?]ui.Srgba{{1, 0, 0, 1}, {0.2, 0.4, 0.6, 1}, {0.1, 0.9, 0.35, 0.5}, {0, 0, 0, 0}, {1, 1, 1, 1}, {0.5, 0.5, 0.5, 0.25}}
	for c in colours {
		for f in ui.Color_Format {
			for legacy in ([2]bool{false, true}) {
				text := ui.color_text(c, {f, legacy})
				back, style, ok := ui.color_parse(text)
				testing.expectf(t, ok, "%s parses", text)
				testing.expectf(t, near(back, c), "%s reads back as %v: %v", text, c, back)
				testing.expectf(t, style.format == f, "%s is %v", text, f)
			}
		}
	}
	// the short hex form where it is exact, the long one where it is not
	testing.expect_value(t, ui.color_text({1, 0, 0, 1}, {.Hex, true}), "#f00")
	testing.expect_value(t, ui.color_text({0.2, 0.4, 0.6, 1}, {.Hex, true}), "#369")
	testing.expect_value(t, ui.color_text({0.5, 0, 0, 1}, {.Hex, true}), "#800000")
	testing.expect_value(t, ui.color_text({1, 0, 0, 0.5}, {.Rgb, true}), "rgba(255, 0, 0, 0.5)")
	testing.expect_value(t, ui.color_text({1, 0, 0, 0.5}, {.Rgb, false}), "rgb(255 0 0 / 0.5)")
	testing.expect_value(t, ui.color_text({1, 0, 0, 1}, {.Hsl, false}), "hsl(0 100% 50%)")
	_, _, bad := ui.color_parse("rgb(1 2)")
	testing.expect(t, !bad, "two channels are not a colour")
	_, _, bad = ui.color_parse("#12345")
	testing.expect(t, !bad, "five digits are not a colour")
	turn, _, _ := ui.color_parse("hsl(0.5turn 100% 50%)")
	testing.expect(t, near(turn, {0, 1, 1, 1}), "half a turn is cyan")
}) }
