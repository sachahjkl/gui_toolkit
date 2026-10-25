package dragdrop_test

import "core:testing"
import "../../platform"

@(test)
custom_entries_round_trip :: proc(t: ^testing.T) {
	entries := []platform.Drag_Entry{{"application/x-app", "one"}, {"text/x-empty", ""}, {"a", "\x00\xff bytes"}}
	b := platform.drag_custom_encode(entries)
	defer delete(b)
	got, ok := platform.drag_custom_decode(b)
	defer { for e in got { delete(e.mime); delete(e.data) }; delete(got) }
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 3)
	for e, i in entries {
		testing.expect_value(t, got[i].mime, e.mime)
		testing.expect_value(t, got[i].data, e.data)
	}
	// truncated or lying lengths are refused, nothing leaks
	_, bad := platform.drag_custom_decode(b[:len(b) - 1])
	testing.expect(t, !bad)
	lie := []u8{0xff, 0xff, 0xff, 0x7f, 'x'}
	_, bad2 := platform.drag_custom_decode(lie)
	testing.expect(t, !bad2)
	empty, ok3 := platform.drag_custom_decode(nil)
	defer delete(empty)
	testing.expect(t, ok3 && len(empty) == 0)
}

@(test)
uri_lists :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.uri_list_first("# comment\r\n  \r\nhttps://a.example/x \r\nhttps://b.example/\r\n"), "https://a.example/x")
	testing.expect_value(t, platform.uri_list_first("https://only.example"), "https://only.example")
	testing.expect_value(t, platform.uri_list_first("#nothing\n\n"), "")
	testing.expect_value(t, platform.uri_list_first(""), "")
}

@(test)
html_format :: proc(t: ^testing.T) {
	frag := "<b>gras</b> é"
	h := platform.html_format_wrap(frag, "https://example.com/page")
	defer delete(h)
	testing.expect_value(t, platform.html_format_fragment(h), frag)
	// offsets missing or wrong: the comments, then the HTML after the header
	testing.expect_value(t, platform.html_format_fragment("Version:0.9\r\n<html><!--StartFragment-->x<!--EndFragment--></html>"), "x")
	testing.expect_value(t, platform.html_format_fragment("StartFragment:999999\r\nEndFragment:9999999\r\n<p>y</p>"), "StartFragment:999999\r\nEndFragment:9999999\r\n<p>y</p>")
	plain := platform.html_format_wrap("", "")
	defer delete(plain)
	testing.expect_value(t, platform.html_format_fragment(plain), "")
}

@(test)
effects :: proc(t: ^testing.T) {
	all := platform.Drop_Effects{.Copy, .Move, .Link}
	testing.expect_value(t, platform.drop_effect_for(all, {}), platform.Drop_Effect.Copy)
	testing.expect_value(t, platform.drop_effect_for(all, {.Shift}), platform.Drop_Effect.Move)
	testing.expect_value(t, platform.drop_effect_for(all, {.Ctrl}), platform.Drop_Effect.Copy)
	testing.expect_value(t, platform.drop_effect_for(all, {.Ctrl, .Shift}), platform.Drop_Effect.Link)
	testing.expect_value(t, platform.drop_effect_for(all, {.Alt}), platform.Drop_Effect.Link)
	testing.expect_value(t, platform.drop_effect_for({.Move}, {.Ctrl}), platform.Drop_Effect.Move)
	testing.expect_value(t, platform.drop_effect_for({.Link, .Move}, {}, .Copy), platform.Drop_Effect.Move)
	_, none := platform.drop_effect_for({}, {}).?
	testing.expect(t, !none)
}

@(test)
types_and_clone :: proc(t: ^testing.T) {
	d: platform.Drag_Data
	append(&d.files, "C:\\a.txt")
	d.text = "hello"
	d.url = "https://x.example/"
	d.html = "<i>h</i>"
	append(&d.custom, platform.Drag_Entry{"application/x-mine", "v"})
	c := platform.drag_data_clone(d)
	defer platform.drag_data_destroy(&c)
	delete(d.files)
	delete(d.custom)
	types := platform.drag_data_types(c)
	testing.expect_value(t, len(types), 5)
	testing.expect_value(t, types[0], "application/x-mine")
	testing.expect_value(t, types[1], "text/plain")
	testing.expect_value(t, types[2], "text/uri-list")
	testing.expect_value(t, types[3], "text/html")
	testing.expect_value(t, types[4], "Files")
	testing.expect(t, !platform.drag_data_empty(c))
	testing.expect(t, platform.drag_data_empty(platform.Drag_Data{}))
}

@(test)
pointer_details :: proc(t: ^testing.T) {
	pen := platform.Pointer_Info{kind = .Pen, barrel = true}
	testing.expect_value(t, platform.pointer_buttons(pen, true), u16(3))
	testing.expect_value(t, platform.pointer_buttons(pen, false), u16(2))
	pen.eraser = true
	testing.expect_value(t, platform.pointer_buttons(pen, true), u16(34))
	finger := platform.Pointer_Info{kind = .Touch}
	testing.expect_value(t, platform.pointer_buttons(finger, true), u16(1))
	testing.expect_value(t, platform.pointer_pressure(nil, true), f32(0.5))
	testing.expect_value(t, platform.pointer_pressure(nil, false), f32(0))
	testing.expect_value(t, platform.pointer_pressure(f32(1.7), true), f32(1))
	s: platform.Pointer_State
	defer platform.pointer_state_destroy(&s)
	platform.pointer_state_down(&s, 7)
	platform.pointer_state_down(&s, 7)
	platform.pointer_state_down(&s, 9)
	testing.expect_value(t, len(s.down), 2)
	testing.expect(t, platform.pointer_state_up(&s, 7))
	testing.expect(t, !platform.pointer_state_up(&s, 7))
}

// The system's half: the data object a drag would carry goes through the window's own drop target (no mouse, the
// window never shown). Every format comes back, the events arrive in order at the point, the app's answer is kept.
@(test)
round_trip_through_the_system :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	w := platform.open_window("dragdrop test", {200, 150})
	if w == nil { return }
	defer platform.destroy_window(w)
	testing.expect(t, platform.drop_target_enable(w, true))
	defer platform.drop_target_enable(w, false)
	d: platform.Drag_Data
	append(&d.files, "C:\\Windows\\win.ini")
	append(&d.files, "C:\\dossier é\\deux.txt")
	d.text = "texte é"
	d.url = "https://example.com/a?b=c"
	d.html = "<p>para</p>"
	append(&d.custom, platform.Drag_Entry{"application/x-test", "payload"})
	defer { delete(d.files); delete(d.custom) }
	platform.drop_set_effect(w, .Copy)
	testing.expect(t, platform.drop_self_test(w, d, {20, 30}, {.Copy, .Link}))
	evs := platform.poll_events(w, false)
	kinds := make([dynamic]platform.Event_Kind, context.temp_allocator)
	for e in evs {
		#partial switch e.kind {
		case .Drop_Enter, .Drop_Over, .Drop:
			append(&kinds, e.kind)
			testing.expect_value(t, e.pos, [2]f32{20, 30})
			testing.expect_value(t, e.drop_allowed, platform.Drop_Effects{.Copy, .Link})
		}
	}
	testing.expect_value(t, len(kinds), 3)
	if len(kinds) == 3 {
		testing.expect_value(t, kinds[0], platform.Event_Kind.Drop_Enter)
		testing.expect_value(t, kinds[2], platform.Event_Kind.Drop)
	}
	got := platform.drop_data(w)
	testing.expect(t, got != nil)
	if got == nil { return }
	testing.expect_value(t, len(got.files), 2)
	if len(got.files) == 2 { testing.expect_value(t, got.files[1], "C:\\dossier é\\deux.txt") }
	testing.expect_value(t, got.text, "texte é")
	testing.expect_value(t, got.url, "https://example.com/a?b=c")
	testing.expect_value(t, got.url_title, "texte é")
	testing.expect_value(t, got.html, "<p>para</p>")
	testing.expect_value(t, len(got.custom), 1)
	if len(got.custom) == 1 { testing.expect_value(t, got.custom[0].data, "payload") }
	testing.expect(t, !platform.drop_active(w))
	platform.drop_data_release(w)
	testing.expect(t, platform.drag_data_empty(platform.drop_data(w)^))
}

@(test)
drag_images :: proc(t: ^testing.T) {
	px := []u8{255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 200}
	img := platform.Drag_Image{px, {2, 2}, {1, 1}}
	testing.expect(t, platform.drag_image_valid(img))
	testing.expect(t, !platform.drag_image_valid(platform.Drag_Image{px[:8], {2, 2}, {}}))
	half := platform.drag_image_fit(img, {100, 100})
	defer delete(half.rgba)
	testing.expect_value(t, half.size, [2]int{2, 2})   // fits: a copy
	platform.drag_image_fade(half, 0.5)
	testing.expect_value(t, half.rgba[3], u8(128))
	testing.expect_value(t, half.rgba[7], u8(64))
	testing.expect_value(t, px[3], u8(255))   // the original untouched
	one := platform.drag_image_fit(img, {1, 1})
	defer delete(one.rgba)
	testing.expect_value(t, one.size, [2]int{1, 1})
	testing.expect_value(t, one.offset, [2]int{0, 0})
	// average of the alphas; the colour weighted by alpha (the transparent blue pixel does not tint it)
	testing.expect_value(t, one.rgba[3], u8((255 + 128 + 0 + 200) / 4))
	testing.expect(t, one.rgba[2] < 40)
	testing.expect(t, !platform.drag_image_valid(platform.drag_image_fit(platform.Drag_Image{}, {4, 4})))
}

@(test)
script_calls :: proc(t: ^testing.T) {
	a, b := platform.drag_script_calls(false, false, false)
	testing.expect(t, a == .None && b == .None)
	a, b = platform.drag_script_calls(false, true, false)
	testing.expect(t, a == .Enter && b == .None)
	a, b = platform.drag_script_calls(true, true, true)
	testing.expect(t, a == .Over && b == .Drop)
	a, b = platform.drag_script_calls(true, false, false)
	testing.expect(t, a == .Leave && b == .None)
	a, b = platform.drag_script_calls(false, false, true)
	testing.expect(t, a == .None && b == .Cancel)
}

@(test)
input_device_rules :: proc(t: ^testing.T) {
	acc, hover := platform.primary_pointer({mouse = true, touch_points = 10})
	testing.expect(t, acc == .Fine && hover)
	acc, hover = platform.primary_pointer({touch_points = 5})
	testing.expect(t, acc == .Coarse && !hover)
	acc, hover = platform.primary_pointer({})
	testing.expect(t, acc == .None && !hover)
	fine, coarse, any_hover := platform.any_pointer({mouse = true, touch_points = 2})
	testing.expect(t, fine && coarse && any_hover)
	fine, coarse, any_hover = platform.any_pointer({mouse = true})
	testing.expect(t, fine && !coarse && any_hover)
	d := platform.input_devices()
	testing.expect(t, d.touch_points >= 0 && platform.touch_max_points() == d.touch_points)
}

@(test)
touch_gestures :: proc(t: ^testing.T) {
	g: platform.Touch_Gesture
	platform.touch_gesture_init(&g)
	// a tap: down and up without moving past the slop
	platform.touch_gesture_down(&g, 1, {100, 100}, 0)
	testing.expect_value(t, platform.touch_gesture_move(&g, 1, {104, 103}, 10).kind, platform.Touch_Gesture_Kind.None)
	testing.expect_value(t, platform.touch_gesture_up(&g, 1, {104, 103}, 50).kind, platform.Touch_Gesture_Kind.Tap)
	testing.expect(t, !platform.touch_gesture_active(&g))
	// a pan: the content follows the finger, then a fling at the speed of the last 100 ms
	platform.touch_gesture_down(&g, 2, {100, 300}, 1000)
	e := platform.touch_gesture_move(&g, 2, {100, 280}, 1010)
	testing.expect(t, e.kind == .Pan && e.first && e.pan == {0, -20})
	e = platform.touch_gesture_move(&g, 2, {100, 260}, 1020)
	testing.expect(t, e.kind == .Pan && !e.first && e.pan == {0, -20})
	e = platform.touch_gesture_up(&g, 2, {100, 240}, 1030)
	testing.expect_value(t, e.kind, platform.Touch_Gesture_Kind.Fling)
	testing.expect(t, abs(e.velocity.y + 2000) < 1, "60 px in 30 ms")
	// a slow release: no fling
	platform.touch_gesture_down(&g, 3, {0, 0}, 2000)
	platform.touch_gesture_move(&g, 3, {0, 30}, 2010)
	platform.touch_gesture_move(&g, 3, {0, 31}, 2300)
	testing.expect_value(t, platform.touch_gesture_up(&g, 3, {0, 31}, 2500).kind, platform.Touch_Gesture_Kind.End)
	// a pinch: two fingers apart twice as far, about their middle
	platform.touch_gesture_down(&g, 4, {100, 100}, 3000)
	platform.touch_gesture_down(&g, 5, {200, 100}, 3005)
	e = platform.touch_gesture_move(&g, 5, {300, 100}, 3020)
	testing.expect(t, e.kind == .Pinch && abs(e.scale - 2) < 0.001 && e.pos == {200, 100} && e.pan == {50, 0})
	platform.touch_gesture_up(&g, 5, {300, 100}, 3030)
	e = platform.touch_gesture_move(&g, 4, {100, 120}, 3040)
	testing.expect(t, e.kind == .Pan && e.pan == {0, 20}, "one finger left: it pans on without a jump")
	platform.touch_gesture_up(&g, 4, {100, 120}, 3050)
	// a long press: still for long_press_ms
	platform.touch_gesture_down(&g, 6, {50, 50}, 4000)
	due, pending := platform.touch_gesture_long_press_due(&g)
	testing.expect(t, pending && due == 4500)
	testing.expect_value(t, platform.touch_gesture_tick(&g, 4400).kind, platform.Touch_Gesture_Kind.None)
	testing.expect_value(t, platform.touch_gesture_tick(&g, 4500).kind, platform.Touch_Gesture_Kind.Long_Press)
	testing.expect_value(t, platform.touch_gesture_tick(&g, 4600).kind, platform.Touch_Gesture_Kind.None)
	testing.expect_value(t, platform.touch_gesture_move(&g, 6, {90, 90}, 4700).kind, platform.Touch_Gesture_Kind.None)
	testing.expect_value(t, platform.touch_gesture_up(&g, 6, {90, 90}, 4800).kind, platform.Touch_Gesture_Kind.End)
	testing.expect_value(t, platform.touch_gesture_cancel(&g).kind, platform.Touch_Gesture_Kind.None)
	// the fling's glide
	dist, ms := platform.touch_fling({0, -2000}, 4)
	testing.expect(t, dist == {0, -500} && ms > 0)
}

// A drag the app starts that comes back over its own window while drag_start blocks: with drop_sync_set, the app is
// asked at once (enter, over, drop) before drag_start returns, and the effect it chose is the drag's. The drag image
// given goes to the system's helper, which holds it with its hot spot.
@(test)
own_drag_back_over_the_window :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	w := platform.open_window("dragdrop sync", {200, 150})
	if w == nil { return }
	defer platform.destroy_window(w)
	testing.expect(t, platform.drop_target_enable(w, true))
	defer platform.drop_target_enable(w, false)
	Seen :: struct { kinds: [dynamic]platform.Event_Kind, text: string }
	seen: Seen
	defer delete(seen.kinds)
	platform.drop_sync_set(w, proc(user: rawptr, w: ^platform.Window, ev: platform.Event) -> Maybe(platform.Drop_Effect) {
		s := (^Seen)(user)
		append(&s.kinds, ev.kind)
		if ev.kind == .Drop { s.text = platform.drop_data(w).text }
		return .Move
	}, &seen)
	defer platform.drop_sync_set(w, nil, nil)
	steps := []platform.Drag_Step{{pos = {-10, 40}}, {pos = {50, 40}}, {pos = {60, 45}}}
	testing.expect(t, platform.drag_script(w, steps))
	d: platform.Drag_Data
	d.text = "back"
	px := make([]u8, 8 * 6 * 4)
	defer delete(px)
	for i in 0 ..< 8 * 6 { px[i * 4 + 3] = 200 }
	effect, ok := platform.drag_start(w, d, {.Copy, .Move}, platform.Drag_Image{px, {8, 6}, {3, 2}})
	testing.expect(t, ok)
	testing.expect_value(t, effect, platform.Drop_Effect.Move)
	testing.expect_value(t, len(seen.kinds), 3)
	if len(seen.kinds) == 3 {
		testing.expect_value(t, seen.kinds[0], platform.Event_Kind.Drop_Enter)
		testing.expect_value(t, seen.kinds[1], platform.Event_Kind.Drop_Over)
		testing.expect_value(t, seen.kinds[2], platform.Event_Kind.Drop)
	}
	testing.expect_value(t, seen.text, "back")
	size, offset, held := platform.drag_image_held(w)
	testing.expect(t, held, "the system's helper took the picture")
	testing.expect_value(t, size, [2]int{8, 6})
	testing.expect_value(t, offset, [2]int{3, 2})
	// nothing was queued for the next poll: the app already handled it
	n := 0
	for e in platform.poll_events(w, false) { if e.kind >= .Drop_Enter { n += 1 } }
	testing.expect_value(t, n, 0)
	// without the handler, released outside the window: no effect
	platform.drop_sync_set(w, nil, nil)
	platform.drag_script(w, []platform.Drag_Step{{pos = {20, 20}}, {pos = {-5, -5}}})
	effect, ok = platform.drag_start(w, d, {.Copy})
	_, has := effect.?
	testing.expect(t, ok && !has)
	platform.drop_data_release(w)
}

@(test)
injected_drops :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	w := platform.open_window("dragdrop inject", {200, 150})
	if w == nil { return }
	defer platform.destroy_window(w)
	d: platform.Drag_Data
	d.text = "x"
	testing.expect(t, platform.drop_inject(w, .Drop_Enter, {5, 6}, &d))
	testing.expect(t, platform.drop_active(w))
	testing.expect(t, platform.drop_inject(w, .Drop_Leave, {}))
	testing.expect(t, !platform.drop_inject(w, .Mouse_Move, {}))
	evs := platform.poll_events(w, false)
	n := 0
	for e in evs { if e.kind == .Drop_Enter || e.kind == .Drop_Leave { n += 1 } }
	testing.expect_value(t, n, 2)
	testing.expect_value(t, platform.drop_data(w).text, "x")
	testing.expect(t, !platform.drop_active(w))
}
