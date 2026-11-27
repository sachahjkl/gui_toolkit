package ui

import "core:fmt"
import "core:math"
import "../draw"
import "../platform"

_ :: fmt   // used by the UI_PROBE debug output only

// Input is resolved once per frame, in begin_build, against LAST frame's layout (the tree is still intact at that
// point): hot / active / pressed / clicked keys are plain lookups afterwards, so `signal` is just a comparison.

// Presses this close count as a double click (widgets' signal, words of selected text).
@(private) DOUBLE_CLICK_MS :: 450
// How far apart (logical pixels) the presses of a double or triple click may be: the same for a box's click and a text's.
@(private) MULTI_CLICK_SLOP_PX :: 4
WHEEL_LINE_PX :: 100.0 / 3   // a line of the wheel, in logical px: a browser's (a notch of three lines is 100 px), so a page scrolls here as there
@(private) HOT_ANCESTORS_MAX :: 64                // ancestors of the hot box that count as hot within (hot_within, .Hot_Within)

// What a notch of the wheel moves box `b` along `axis`, in px: the lines the system says (characters across), each WHEEL_LINE_PX at the
// window's scale; a page of the box less a line, where the system says a page. Every view scrolls by this, the text fields too.
wheel_step :: proc(b: ^Box, axis: Axis = .Y) -> f32 { return wheel_step_turned(b, axis, axis) }

// wheel_step of a wheel that turns along `from` (its own setting: the vertical wheel's lines, or the sideways one's) moving
// the box along `along` (a strip of one axis turns every wheel along it; its page is the box's length that way).
@(private)
wheel_step_turned :: proc(b: ^Box, from, along: Axis) -> f32 {
	sc := max(gs().scale, 0.01)
	line := WHEEL_LINE_PX * sc
	n := platform.wheel_lines(from == .X)
	if n > 0 { return math.round(n * line) }   // (whole pixels: where a view stops is where a pixel is)
	page := along == .X ? b.rect.max.x - b.rect.min.x : b.rect.max.y - b.rect.min.y
	return math.round(max(page - line, line))
}

@(private)
process_events :: proc(s: ^State, events: []platform.Event, zoom_keys, left_window: bool) {
	left := left_window
	clear(&s.events.list)
	clear(&s.events.consumed)
	clear(&s.typed)
	s.typed_mods = {}
	s.bar.alt_tapped = false
	clear(&s.mouse_events)
	clear(&s.pointer_samples)
	s.mouse_moved = false

	for e in events {
		pointer_device_follow(s, e)
		#partial switch e.kind {
		case .Mouse_Move:
			pointer_sample_add(s, e)
			if e.pos != s.mouse { s.mouse_moved = true }
			s.mouse = e.pos
			s.mouse_valid = true
		case .Mouse_Leave:
			s.mouse_valid = false
			// (a window manager's Alt+drag takes the pointer away: the Alt let go after it is no tap)
			s.bar.alt_alone = false
		case .Mouse_Press:
			s.bar.alt_alone = false
			s.mouse = e.pos
			s.mouse_valid = true
			// the click that ends a latched autoscroll does nothing else
			if !s.auto_off && autoscroll_click(&s.auto) { continue }
			append(&s.mouse_events, e)
			pointer_sample_add(s, e)
			s.mods = e.mods
			hot := hit_test(s, e.pos)
			when #config(UI_PROBE, false) {
				hb := s.boxes[hot] if hot != 0 else nil
				fmt.eprintf("press pos=(%.0f,%.0f) hit=%v rect=%v text=%q\n", e.pos.x, e.pos.y, hot, hb != nil ? hb.rect : Rect{}, hb != nil ? hb.text : "")
			}
			s.active_key[e.button] = hot
			s.press_serial[e.button] += 1
			s.press_pos[e.button] = e.pos
			s.pressed_key[e.button] = hot
			s.pressed_any[e.button] = true
			s.buttons_down += {e.button}
			if e.button == .Right { s.caption_right_down = hot == 0 && on_empty_caption(s, e.pos) }
			if e.button == .Left { scrollbar_press(s, hot, e.pos) }
			if e.button == .Left {
				// (two presses at the two ends of a wide box are two clicks, not a double one)
				near := abs(e.pos.x - s.last_click_pos.x) < MULTI_CLICK_SLOP_PX * s.scale && abs(e.pos.y - s.last_click_pos.y) < MULTI_CLICK_SLOP_PX * s.scale
				if hot != 0 && hot == s.last_click_key && s.time_ms - s.last_click_ms < DOUBLE_CLICK_MS && near {
					s.double_key = hot
					s.last_click_key = 0
					s.press_double = true
				} else {
					s.press_double = false
					s.last_click_key = hot
					s.last_click_ms = s.time_ms
					s.last_click_pos = e.pos
				}
				// keyboard focus follows the click (not into an open menu: what opened it has the keyboard when it closes;
				// but a field of a menu, a panel's search, takes it: its keys are its own, overlay_capture_keys)
				b := s.boxes[hot] if hot != 0 else nil
				if !menu_holds(s, hot) || (b != nil && .Text_Input in b.flags) {
					s.focus_key = (b != nil && .Focusable in b.flags) ? hot : 0
					s.focus_visible = false
				}
			}
		case .Mouse_Release:
			append(&s.mouse_events, e)
			pointer_sample_add(s, e)
			s.mouse = e.pos
			s.mods = e.mods
			hot := hit_test(s, e.pos)
			s.released_key[e.button] = s.active_key[e.button]
			if !e.lost && s.active_key[e.button] != 0 && s.active_key[e.button] == hot { s.clicked_key[e.button] = hot }
			if e.button == .Right && s.caption_right_down {
				s.caption_right_down = false
				if !e.lost && hot == 0 && on_empty_caption(s, e.pos) { s.caption_clicked, s.caption_click_at = true, e.pos }
			}
			s.active_key[e.button] = 0
			s.buttons_down -= {e.button}
		case .Scroll:
			s.bar.alt_alone = false
			s.mouse = e.pos
			s.mouse_valid = true   // (the wheel is where its event says: a first notch with no move before it scrolls too)
			s.mods = e.mods        // (what a wheel steps by: line_edit_num_step)
			if zoom_keys && .Ctrl in e.mods && !ctrl_wheel_taken(s, e.pos, e.delta) {
				// Ctrl+wheel zooms (wheel up = delta.y < 0 = bigger) instead of scrolling: the zone under the pointer, else the window
				if z := zoom_zone_at(s, e.pos); z != nil {
					zoom_zone_act(s, z, .In, -e.delta.y)
				} else {
					s.zoom = clamp(s.zoom * math.pow(s.feel.zoom_step, -e.delta.y), ZOOM_MIN, ZOOM_MAX)
				}
			} else {
				s.scroll_delta += e.delta
				// (Ctrl with fingers is Windows' pinch: a zoom, no swipe)
				if e.scroll_source == .Finger && .Ctrl not_in e.mods { s.swipe_delta += e.delta }
			}
			if e.scroll_end { s.swipe_end = true }
		case .Text:
			append(&s.typed, e.text)
		case .Key_Release:
			s.mods = e.mods
			s.keys_held -= {e.key}
			// (Alt pressed and let go with nothing between: the menu bar's key, menu_bar.odin)
			// (a release the system makes as the focus leaves, Alt+Tab's, is no tap: the window is inactive by then)
			if e.key == .Alt && s.bar.alt_alone && (s.window == nil || s.window.active) { s.bar.alt_tapped = true }
			s.bar.alt_alone = false
		case .Activate:
			// (the window lost or took the keyboard: an Alt held across it was for another window, Alt+Tab's)
			s.bar.alt_alone, s.bar.alt_tapped = false, false
			if s.window != nil && !s.window.active { left = true }
		case .Frame_Press:
			left = true
		case .Key_Press:
			s.mods = e.mods
			s.typed_mods += e.mods
			if e.key != .None { s.keys_held += {e.key} }
			// (Windows repeats a held Alt: a repeat keeps what came between, a click or a key)
			if !(e.repeat && e.key == .Alt) { s.bar.alt_alone = e.key == .Alt && e.mods - {.Alt} == {} }
			if act := zoom_key_action(e.key, e.mods); zoom_keys && act != .None {
				// the zone that holds the keyboard focus, else the window (zoom-zones.md)
				if z := zoom_zone_of_focus(s); z != nil {
					zoom_zone_act(s, z, act)
				} else {
					switch act {
					case .In:    s.zoom = clamp(s.zoom * s.feel.zoom_step, ZOOM_MIN, ZOOM_MAX)
					case .Out:   s.zoom = clamp(s.zoom / s.feel.zoom_step, ZOOM_MIN, ZOOM_MAX)
					case .Reset: s.zoom = 1
					case .None:
					}
				}
				continue
			}
			append(&s.events.list, e)
			append(&s.events.consumed, false)
		case:
		}
	}
	if left { window_left(s) }
	press_data_sweep(s)

	// hot box: the topmost clickable box under the mouse; while a button is held, only the pressed box can be hot
	hit: Key
	if s.mouse_valid { hit = hit_test(s, s.mouse) }
	active := s.active_key[.Left]
	s.hot_key = (active == 0 || hit == active) ? hit : 0
	s.front_key = s.mouse_valid && s.root != nil ? front_test_box(s.root, s.mouse, s.root.rect) : 0
	scrollbar_drag(s)
	s.scroll_key = (s.scroll_delta != {} && s.mouse_valid) ? wheel_latched(s, scroll_hit_test(s, s.mouse, scroll_view_delta(s))) : 0
	if s.hot_key != s.hover_key { s.hover_key = s.hot_key; s.hover_since_ms = s.time_ms }
	autoscroll_handle_input(s)   // middle-click autoscroll (autoscroll_region.odin): after hit tests, may swallow clicks
}

// The user left the window (Event.Activate, Event.Frame_Press, Build_Params.inactive): nothing they were doing there goes on without them. A
// button held has no release to come on every system (Windows makes one, X11 and Wayland do not), and no click is made of it.
@(private)
window_left :: proc(s: ^State) {
	for &k in s.active_key { k = 0 }
	s.buttons_down = {}
	s.caption_right_down = false
	s.mods = {}
	s.keys_held = {}
	if len(s.menus) > 0 { menu_pop_to(0) }
	autoscroll_cancel(&s.auto)
	selection_drag_end(s)
}

// Topmost Clickable box at `p`: later siblings draw on top, so walk them last to first.
@(private)
hit_test :: proc(s: ^State, p: Vec2) -> Key {
	if s.root == nil { return 0 }
	return hit_test_box(s.root, p, s.root.rect)
}

@(private)
hit_test_box :: proc(b: ^Box, p: Vec2, clip: Rect) -> Key {
	if !(p.x >= clip.min.x && p.x < clip.max.x && p.y >= clip.min.y && p.y < clip.max.y) { return 0 }
	if axis, on := scrollbar_under(b, p); on {
		k := scrollbar_key(b, axis)
		gs().sb_owner[k] = b.key
		return k
	}
	child_clip := clip
	if .Clip in b.flags {
		child_clip = Rect{{max(clip.min.x, b.rect.min.x), max(clip.min.y, b.rect.min.y)}, {min(clip.max.x, b.rect.max.x), min(clip.max.y, b.rect.max.y)}}
	}
	for c := b.last; c != nil; c = c.prev {
		if k := hit_test_box(c, p, child_clip); k != 0 { return k }
	}
	// (a cut text's ellipsis, over whatever holds it: text_reveal.odin)
	if b.ellipsis != {} && .Draw_Text in b.flags && .Disabled not_in b.flags && draw.rect_contains(b.ellipsis, p) {
		k := reveal_key(b)
		gs().reveal_owner[k] = b.key
		return k
	}
	if .Clickable in b.flags && .Disabled not_in b.flags && box_contains(b, p) { return b.key }
	return 0
}

// The topmost box at `p` that is something on the screen: it draws a surface or takes a click. A box only of layout, or of text
// over a surface, is not one: what is under it shows.
@(private)
front_test_box :: proc(b: ^Box, p: Vec2, clip: Rect) -> Key {
	if !(p.x >= clip.min.x && p.x < clip.max.x && p.y >= clip.min.y && p.y < clip.max.y) { return 0 }
	child_clip := clip
	if .Clip in b.flags {
		child_clip = Rect{{max(clip.min.x, b.rect.min.x), max(clip.min.y, b.rect.min.y)}, {min(clip.max.x, b.rect.max.x), min(clip.max.y, b.rect.max.y)}}
	}
	for c := b.last; c != nil; c = c.prev {
		if k := front_test_box(c, p, child_clip); k != 0 { return k }
	}
	solid := .Clickable in b.flags || .Draw_Background in b.flags || .Plate in b.flags
	if solid && box_contains(b, p) { return b.key }
	return 0
}

// Whether the pointer is on `b` with nothing drawn over it there (the last build's layout): the surface in front at the pointer
// is `b`, a box in it, or one around it. A box under another one, which a later sibling covers (a message the conversation
// scrolls under its composer, a panel under a floating one), is not: what is in front takes a press, a right one included.
pointer_on :: proc(b: ^Box) -> bool {
	s := gs()
	if b == nil || !s.mouse_valid || !box_contains(b, s.mouse) { return false }
	front := box_from_key(s.front_key)
	if front == nil { return true }   // (nothing drawn there: no other box covers it)
	for x := front; x != nil; x = x.parent { if x == b { return true } }
	for x := b.parent; x != nil; x = x.parent { if x == front { return true } }
	return false
}

// The box a press at `p` (window pixels) acts on, by the last layout: the topmost clickable box there, enabled, within
// its clips. nil: none, or a scroll bar (it has no box). A program reads it at an event's own position (each
// event of a batch), not only at the pointer's last one (hot_key). (`box_at` finds a box by its ids.)
hit_box_at :: proc(p: Vec2) -> ^Box {
	s := gs()
	if s.root == nil { return nil }
	return box_from_key(hit_test(s, p))
}

// pointer_on at `p` (an event's own position) instead of the pointer's: whether `p` is on `b` with nothing drawn over it
// there, by the last layout.
pointer_on_at :: proc(b: ^Box, p: Vec2) -> bool {
	s := gs()
	if b == nil || s.root == nil || !box_contains(b, p) { return false }
	front := box_from_key(front_test_box(s.root, p, s.root.rect))
	if front == nil { return true }
	for x := front; x != nil; x = x.parent { if x == b { return true } }
	for x := b.parent; x != nil; x = x.parent { if x == front { return true } }
	return false
}

// Whether `p` is on the box's shape: its rect, or the trapezoid `slant` makes of it.
box_contains :: proc(b: ^Box, p: Vec2) -> bool {
	if b.hit_outset > 0 { return draw.rect_contains(Rect{b.rect.min - b.hit_outset, b.rect.max + b.hit_outset}, p) }
	if b.slant == {} { return draw.rect_contains(b.rect, p) }
	return platform.slanted_contains({b.rect.min, b.rect.max, b.slant}, p)
}

// The wheel as a view scrolls by it: Shift turns an up-and-down wheel sideways, as in a browser. (The raw delta stays what a
// box that scrolls itself is told: a number field steps further with Shift.)
@(private)
scroll_view_delta :: proc(s: ^State) -> Vec2 {
	d := s.scroll_delta
	if .Shift in s.mods && d.x == 0 { return {d.y, 0} }
	return d
}

// A wheel that turns on with no rest of this long scrolls the view it scrolled.
WHEEL_LATCH_MS :: 350

// A scroll in progress keeps its view. While the wheel turns on, a box inside that view that takes the wheel itself (an
// instrument's field, debug-panel.md) and slides under a still pointer does not take it: the view goes on scrolling. A
// wheel that starts after a rest goes where the pointer is, and a box that has the keyboard takes it at once: the person
// chose it.
@(private)
wheel_latched :: proc(s: ^State, hit: Key) -> Key {
	hit := hit
	l := s.boxes[s.wheel_latch] if s.wheel_latch != 0 else nil
	if l != nil && hit != 0 && hit != s.wheel_latch && hit != s.focus_key && s.time_ms - s.wheel_latch_ms < WHEEL_LATCH_MS && draw.rect_contains(l.rect, s.mouse) {
		if b := s.boxes[hit]; b != nil && .Scroll_Self in b.flags && is_descendant(b, l) { hit = s.wheel_latch }
	}
	hb := s.boxes[hit] if hit != 0 else nil
	if hb != nil && hb.flags & {.View_Scroll_X, .View_Scroll_Y} != {} {
		s.wheel_latch, s.wheel_latch_ms = hit, s.time_ms
	} else {
		s.wheel_latch = 0
	}
	return hit
}

// The box the wheel scrolls: the innermost under `p` that scrolls the way `d` goes (mostly sideways: .View_Scroll_X, else
// .View_Scroll_Y; .Scroll_Self takes both). A box that scrolls only sideways (a wide table) lets a vertical wheel through to
// the page around it. A strip (.Strip_Wheel) takes the wheel only while it overflows the way the wheel scrolls it, and
// never with Ctrl (the zoom's).
@(private)
scroll_hit_test :: proc(s: ^State, p: Vec2, d: Vec2) -> Key {
	if s.root == nil { return 0 }
	return scroll_hit_box(s.root, p, s.root.rect, abs(d.x) > abs(d.y), .Ctrl in s.mods, .Shift in s.mods)
}

@(private)
scroll_hit_box :: proc(b: ^Box, p: Vec2, clip: Rect, sideways, ctrl, shift: bool) -> Key {
	if !(p.x >= clip.min.x && p.x < clip.max.x && p.y >= clip.min.y && p.y < clip.max.y) { return 0 }
	child_clip := clip
	if .Clip in b.flags {
		child_clip = Rect{{max(clip.min.x, b.rect.min.x), max(clip.min.y, b.rect.min.y)}, {min(clip.max.x, b.rect.max.x), min(clip.max.y, b.rect.max.y)}}
	}
	for c := b.last; c != nil; c = c.prev {
		if k := scroll_hit_box(c, p, child_clip, sideways, ctrl, shift); k != 0 { return k }
	}
	takes: bool
	if .Strip_Wheel in b.flags {
		x, y := .View_Scroll_X in b.flags, .View_Scroll_Y in b.flags
		switch {
		case ctrl:   takes = false
		// (both axes: the wheel scrolls Y, Shift+wheel or a sideways touchpad X, as every page does)
		case x && y: takes = view_limit(b, sideways ? .X : .Y) > 0
		// (one axis: every wheel scrolls along it: over a row of tabs there is nothing to scroll up and down)
		case:        takes = view_limit(b, x ? .X : .Y) > 0
		}
	} else {
		takes = .Scroll_Self in b.flags || (sideways ? .View_Scroll_X in b.flags : .View_Scroll_Y in b.flags)
	}
	if shift && .Shift_Wheel_Free in b.flags { takes = false }
	if takes && draw.rect_contains(b.rect, p) { return b.key }
	return 0
}

// Whether the box the wheel at `p` goes to zooms with Ctrl+wheel itself (.Ctrl_Wheel): then the interface keeps its zoom.
// (A touchpad's pinch comes as Ctrl+wheel on Windows and in browsers: a canvas under it zooms, not the whole window.)
@(private)
ctrl_wheel_taken :: proc(s: ^State, p, d: Vec2) -> bool {
	k := scroll_hit_test(s, p, d)
	b := s.boxes[k] if k != 0 else nil
	return b != nil && .Ctrl_Wheel in b.flags
}

// Whether `key` is held now: pressed in this window and not released yet, by its own presses and releases (not by the
// modifiers' state, which a compositor may leave stale). A key pressed before the window had the keyboard is not held;
// none is once the user left the window. Ctrl, Shift and Alt are keys here: Ctrl held alone (a monitor that stops its
// refresh while it is, as Windows' Task Manager).
key_held :: proc(key: platform.Key) -> bool { return key in gs().keys_held }

// Consuming keyboard query: true once if a matching key press (exact modifiers) is pending. While a dialog is open, the
// keys are its own: code built outside it gets none (keys_behind_dialogs turns that off).
key_press :: proc(key: platform.Key, mods: platform.Modifiers = {}) -> bool {
	s := gs()
	if keys_held_by_dialog(s) || keys_held_from_view(s) { return false }
	return key_press_any(key, mods)
}

// Whether the code being built is a panel's or an internal window's body (State.view_keys_root) and the focus is not
// in it: its keys are the content's then (src/md/features/views.md, section 6.5).
@(private)
keys_held_from_view :: proc(s: ^State) -> bool {
	return s.view_keys_root != 0 && !view_focus_inside(s, s.view_keys_root)
}

// key_press wherever it is asked from (a dialog's own Escape, taken as its scope ends).
@(private)
key_press_any :: proc(key: platform.Key, mods: platform.Modifiers = {}) -> bool {
	s := gs()
	for e, i in s.events.list {
		if s.events.consumed[i] || e.key != key || e.mods != mods { continue }
		s.events.consumed[i] = true
		return true
	}
	return false
}

// The first key press of the frame not taken yet, taken (a recorder of shortcuts: whatever is pressed): a key Key
// names, or one by the character it types (Hotkey.char). Shift, Ctrl and Alt alone are not keys here: they come with the
// key they modify. ok = false: none.
key_take :: proc() -> (hk: platform.Hotkey, ok: bool) {
	s := gs()
	if keys_held_by_dialog(s) || keys_held_from_view(s) { return }
	for e, i in s.events.list {
		if s.events.consumed[i] || e.kind != .Key_Press || (e.key == .None && e.char == 0) { continue }
		if e.key == .Shift || e.key == .Ctrl || e.key == .Alt { continue }
		s.events.consumed[i] = true
		return {key = e.key, mods = e.mods, super = e.super, char = e.key == .None ? e.char : 0}, true
	}
	return
}

// Like key_press but does not consume (for global shortcuts that must not steal keys from a focused field).
key_pressed_peek :: proc(key: platform.Key, mods: platform.Modifiers = {}) -> bool {
	s := gs()
	if keys_held_by_dialog(s) { return false }
	for e, i in s.events.list { if !s.events.consumed[i] && e.key == key && e.mods == mods { return true } }
	return false
}

// Whether `b` takes this build's right press for its context menu: a right press came, the pointer is on `b` with nothing
// drawn over it (pointer_on: not a dialog's, not a panel floating over it), and nothing took it first. Call it after
// building what is in `b`: the innermost that asks keeps it, and a widget that opened its own menu on that press (a
// field's) keeps it too. For a block that is no button (a message, a card, an image): a clickable box has
// Signal.right_clicked. The program then opens its menu where the pointer is: menu_open(id, mouse_pos()).
context_take :: proc(b: ^Box) -> bool {
	s := gs()
	if !s.pressed_any[.Right] || s.context_taken == s.build_index || !pointer_on(b) { return false }
	for lv in s.menus { if lv.open_build == s.build_index { return false } }
	s.context_taken = s.build_index
	return true
}

mouse_pos :: proc() -> Vec2 { return gs().mouse }

// The device that moved the pointer last, as of this build: a mouse (`kind` .Mouse, id 1), else the pen or the finger
// with its pressure, tilt, eraser and barrel button (platform.Pointer_Info). Several moves in one frame: the last one's.
pointer_device :: proc() -> platform.Pointer_Info { return gs().pointer }

// The pressure of the pen or the finger on the screen, 0..1, as gt:ink's Sample.pressure takes it: 0 when it is
// unknown (a mouse, a device that does not measure it) or nothing is in contact.
pointer_pressure :: proc() -> f32 {
	p := gs().pointer
	return p.measured ? p.pressure : 0
}

// The pen's or the finger's own events say what it is; its emulated mouse events carry less and change nothing; the
// mouse's own make the mouse the device again.
@(private)
pointer_device_follow :: proc(s: ^State, e: platform.Event) {
	#partial switch e.kind {
	case .Pointer_Down, .Pointer_Move, .Pointer_Up:
		s.pointer = e.pointer
	case .Pointer_Cancel:
		// (Windows' cancel of a pointer the system no longer knows carries only its id)
		if e.pointer.id == s.pointer.id { s.pointer.pressure = 0 }
	case .Mouse_Move, .Mouse_Press, .Mouse_Release, .Scroll:
		if !e.emulated { s.pointer = MOUSE_DEVICE }
	}
}

// A move, a press or a release of this build, with the pen's pressure (0: unknown) and tilt as they were then: the
// pen's own events come before the mouse events the system makes of them.
@(private)
Pointer_Sample :: struct {
	event:    platform.Event,
	pressure: f32,
	tilt:     [2]f32,
}

@(private)
pointer_sample_add :: proc(s: ^State, e: platform.Event) {
	p := s.pointer
	append(&s.pointer_samples, Pointer_Sample{event = e, pressure = p.measured ? p.pressure : 0, tilt = p.tilt})
}

@(private) MOUSE_DEVICE :: platform.Pointer_Info{id = 1, kind = .Mouse, primary = true}
// A press of `button` happened in this frame, on anything or on nothing (a popup the app closes on a press outside it).
mouse_pressed :: proc(button := platform.Mouse_Button.Left) -> bool { return gs().pressed_any[button] }
hot_key :: proc() -> Key { return gs().hot_key }
// The wheel of this build went to the interface: to a box that scrolls under the pointer, or to an open menu's level
// (one that fits takes it too, and scrolls nothing). What the app draws under it gets none of it.
wheel_consumed :: proc() -> bool { return gs().scroll_key != 0 }

// The wheel of this build that no box took, in notches as platform.Event.delta (+y scrolls the content down), and the
// modifiers held with it: {} when a box took it (wheel_consumed). A program reads it for its own use of the wheel
// (Shift+wheel over a preview with shift_wheel_free: the next picture).
wheel_free :: proc() -> (delta: Vec2, mods: platform.Modifiers) {
	s := gs()
	if s.scroll_key != 0 || !s.mouse_valid { return }
	return s.scroll_delta, s.mods
}

// Is the pointer on box `key` or on a clickable box inside it (by the last frame's tree)? For a row that shows its
// buttons while the pointer is anywhere on it.
hot_within :: proc(key: Key) -> bool {
	s := gs()
	if s.hot_key == 0 || key == 0 { return false }
	hb := s.boxes[s.hot_key] if s.hot_key != 0 else nil
	for p, depth := hb, 0; p != nil && depth < HOT_ANCESTORS_MAX; p, depth = p.parent, depth + 1 {
		if p.key == key { return true }
		if p.last_build + 1 < s.build_index { break }
	}
	return false
}
active_key :: proc() -> Key { return gs().active_key[.Left] }
focus_key :: proc() -> Key { return gs().focus_key }
set_focus :: proc(k: Key) { gs().focus_key = k }

// The keyboard's own move of the focus to box `k` (a list's Up and Down): its ring shows, as after Tab, and its scroll
// boxes bring it into view by its last layout (`k` was built in the last build, or earlier in this one).
focus_by_keys :: proc(k: Key) {
	s := gs()
	s.focus_key, s.focus_visible = k, true
	scroll_focus_into_view(s)
}

// The focus is on the signal's box and the keyboard put it there (its ring shows): what shows on a hover shows then too,
// beside the box (`tooltip_beside(sig.box.rect)`).
keyboard_focused :: proc(sig: Signal) -> bool { return sig.focused && gs().focus_visible }

// Inside a build: the next field built in it (a line_edit, a number's value, a text_edit: a box that takes text) takes
// the keyboard, whatever keys its widget gives its boxes. A view focuses its field on its first build so:
// `if first { ui.focus_next_field() }; ui.number("width", &w)`.
focus_next_field :: proc() { gs().focus_field_next = true }

// The signal of a box (call after building it, usually through a widget).
signal :: proc(b: ^Box) -> (sig: Signal) {
	s := gs()
	sig.box = b
	sig.mouse = s.mouse - b.rect.min
	sig.mods = s.mods
	sig.focused = s.focus_key == b.key
	if .Disabled in b.flags { return }
	if .Clickable in b.flags {
		sig.hovering = s.hot_key == b.key
		sig.pressed = s.pressed_key[.Left] == b.key
		sig.pointer_pressed = sig.pressed && s.a11y.pressed != b.key
		sig.released = s.released_key[.Left] == b.key || s.release_owed == b.key
		sig.clicked = s.clicked_key[.Left] == b.key
		sig.pointer_clicked = sig.clicked && s.a11y.pressed != b.key
		// (the release can come frames after the press that made the double: the press notes it, the click reads it)
		sig.second_click = sig.pointer_clicked && s.press_double
		sig.double_clicked = s.double_key == b.key
		sig.right_clicked = s.clicked_key[.Right] == b.key
		sig.middle_clicked = s.clicked_key[.Middle] == b.key
		if s.active_key[.Left] == b.key {
			sig.dragging = true
			sig.drag_delta = s.mouse - s.press_pos[.Left]
		}
		if sig.hovering && b.cursor != .Arrow { s.cursor_request = b.cursor }
		// keyboard activation of the focused Tab stop (text inputs handle their own keys)
		// (not while a context menu is open: Enter / Space then belong to the menu)
		if sig.focused && .Focusable in b.flags && .Text_Input not_in b.flags && len(s.menus) == 0 {
			if key_press(.Return) || key_press(.Space) {
				sig.clicked, sig.pressed, sig.released = true, true, true
			}
		}
	}
	if .Scroll_Self in b.flags && s.scroll_key == b.key { sig.scrolled = s.scroll_delta }
	if (.View_Scroll_X in b.flags || .View_Scroll_Y in b.flags) && s.scroll_key == b.key {
		d := scroll_view_delta(s)
		if .Strip_Wheel in b.flags && (.View_Scroll_X in b.flags) != (.View_Scroll_Y in b.flags) {
			// (a strip on one axis: the wheel's main motion, whatever its way, goes along it, by the step of the wheel
			// that moved; on both axes, the wheel as on a page)
			to := .View_Scroll_X in b.flags ? Axis.X : Axis.Y
			from := abs(d.x) > abs(d.y) ? Axis.X : Axis.Y
			along := d[int(from)]
			b.view_target[int(to)] += along * wheel_step_turned(b, from, to)
			sig.scrolled[int(to)] = along
		} else {
			if .View_Scroll_X in b.flags { b.view_target.x += d.x * wheel_step(b, .X); sig.scrolled.x = d.x }
			if .View_Scroll_Y in b.flags { b.view_target.y += d.y * wheel_step(b, .Y); sig.scrolled.y = d.y }
		}
		// clamp against last frame's bounds; the animation pass re-clamps with fresh ones
		b.view_target = {clamp(b.view_target.x, 0, view_limit(b, .X)), clamp(b.view_target.y, 0, view_limit(b))}
	}
	return
}

// Whether a dialog holds the keys from the code asking: one is open (the last build's on top), and the code is not built
// inside it. A program reads its keys before it builds its dialogs: without this, Escape closed the window behind one.
@(private)
keys_held_by_dialog :: proc(s: ^State) -> bool {
	if s.keys_behind_dialogs || len(s.modals_open) == 0 { return false }
	top := s.modals_open[len(s.modals_open) - 1].panel
	for m in s.modal_stack { if m.panel == top { return false } }
	return true
}

// Keys reach code built outside an open dialog too (by default a dialog holds them: key_press, key_take and
// command_pressed give nothing elsewhere while it is open).
set_keys_behind_dialogs :: proc(s: ^State, on: bool) { s.keys_behind_dialogs = on }

// Whether a dialog is open now (the last build's): a program's own key handling may wait for it.
dialog_open :: proc() -> bool { return len(gs().modals_open) > 0 }
