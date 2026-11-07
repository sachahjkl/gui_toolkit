package panes_test

// ui.press_data: what a gesture keeps lives as long as its press, and a new press starts from zero.

import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

@(private = "file")
Px :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	f:     font.Font_Id,
	show:  bool,
	got:   ^Grip,   // what the box's press kept this build
	other: ^int,
}

@(private = "file")
Grip :: struct { n: int }

@(private = "file") AT :: [2]f32{20, 20}
@(private = "file") AWAY :: [2]f32{300, 80}

@(private = "file")
build :: proc(p: ^Px, events: []platform.Event = nil) {
	ui.begin_build(&p.s, {window_size = {400, 100}, events = events, dt = 1.0 / 60, dpi_scale = 1, base = ui.Style{font = p.f, font_size = 15}})
	p.got, p.other = nil, nil
	if p.show {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(100), height = ui.px(40)})
		b := ui.build_box({.Clickable}, "###grip")
		_ = ui.signal(b)
		p.got = ui.press_data(Grip, b.key)
		p.other = ui.press_data(int, b.key)
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
start :: proc(p: ^Px) {
	font.init(&p.fonts)
	p.f, _ = font.load_embedded(&p.fonts, font.FALLBACK_UI_DATA)
	ui.apply_palette(&p.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&p.s, &p.fonts, &p.theme)
	p.show = true
	build(p)
	build(p)
}

@(private = "file")
stop :: proc(p: ^Px) {
	ui.destroy(&p.s)
	ui.theme_destroy(&p.theme)
	font.destroy(&p.fonts)
}

@(private = "file")
press :: proc(at: [2]f32) -> [2]platform.Event { return {{kind = .Mouse_Move, pos = at}, {kind = .Mouse_Press, pos = at, button = .Left}} }

@(test)
a_press_keeps_its_data_and_ends_with_it :: proc(t: ^testing.T) {
	p := new(Px)
	defer free(p)
	start(p)
	defer stop(p)
	testing.expect(t, p.got == nil, "no press, nothing kept")
	pr := press(AT)
	build(p, pr[:])
	if !testing.expect(t, p.got != nil, "the press has its data") { return }
	testing.expect_value(t, p.got.n, 0)
	p.got.n = 7
	p.other^ = 9   // (another type, on the same press)
	build(p, {{kind = .Mouse_Move, pos = AWAY}})
	testing.expect(t, p.got != nil && p.got.n == 7, "the same for as long as the press lasts, wherever the pointer goes")
	testing.expect(t, p.other != nil && p.other^ == 9, "each type its own")
	build(p, {{kind = .Mouse_Release, pos = AWAY, button = .Left}})
	testing.expect(t, p.got == nil, "the press ended: nothing")
	build(p, pr[:])
	testing.expect(t, p.got != nil && p.got.n == 0, "a new press starts from zero")
}

// Released and pressed again in one batch: the same box, another press.
@(test)
a_press_again_in_one_batch_is_another :: proc(t: ^testing.T) {
	p := new(Px)
	defer free(p)
	start(p)
	defer stop(p)
	pr := press(AT)
	build(p, pr[:])
	if !testing.expect(t, p.got != nil, "pressed") { return }
	p.got.n = 7
	build(p, {{kind = .Mouse_Release, pos = AT, button = .Left}, {kind = .Mouse_Press, pos = AT, button = .Left}})
	testing.expect(t, p.got != nil && p.got.n == 0, "another press, from zero")
}

// A press ends with its box, and when the user leaves the window: what it kept goes too.
@(test)
a_press_ends_with_its_box_and_with_the_window :: proc(t: ^testing.T) {
	p := new(Px)
	defer free(p)
	start(p)
	defer stop(p)
	pr := press(AT)
	build(p, pr[:])
	testing.expect(t, p.got != nil, "pressed")
	p.show = false
	build(p)
	p.show = true
	build(p)
	testing.expect(t, p.got == nil, "its box went: the press with it")
	build(p, pr[:])
	testing.expect(t, p.got != nil, "pressed")
	build(p, {{kind = .Frame_Press}})   // (a press on the window's frame: the user is elsewhere)
	testing.expect(t, p.got == nil, "the user left the window")
}

// ui.press_hand: the press goes on on another box with what it kept, and ends with the button as before; the first box holds nothing.
@(test)
a_press_handed_to_another_box_keeps_its_data :: proc(t: ^testing.T) {
	p := new(Px)
	defer free(p)
	start(p)
	defer stop(p)
	pr := press(AT)
	build(p, pr[:])
	if !testing.expect(t, p.got != nil, "the press has its data") { return }
	p.got.n = 5
	from := ui.key_from_string(p.s.root.key, "###grip")
	to := ui.key_from_string(p.s.root.key, "###elsewhere")
	ui.begin_build(&p.s, {window_size = {400, 100}, dt = 1.0 / 60, dpi_scale = 1, base = ui.Style{font = p.f, font_size = 15}})
	testing.expect(t, ui.press_hand(from, to), "a button holds the first box")
	got := ui.press_data(Grip, to)
	testing.expect(t, got != nil && got.n == 5, "what the press kept goes with it")
	testing.expect(t, ui.press_data(Grip, from) == nil, "the first box holds nothing now")
	testing.expect(t, !ui.press_hand(from, to), "nothing to hand twice")
	ui.end_build()
	free_all(context.temp_allocator)
}
