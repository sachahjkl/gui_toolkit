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
