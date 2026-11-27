package tk_session

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../../platform"
import "../../ui"

// Input: the toolkit's own path (platform.inject_event, then poll_events), never the machine's mouse or keyboard. Each action
// returns once the frames it takes are made and what it caused shows in the next build: a press is seen in one build, its
// release in the next, what the application changed then shows in the one after.

// Frames after an input for what it caused to be built and laid out.
@(private) INPUT_FRAMES :: 2
// How many moves a drag makes when a test does not say.
DRAG_STEPS :: 8
// A click from another, for the double click to come: more than ui's double click delay.
SEPARATE_CLICK_MS :: 600

// An event as the system would give it, handled by the next frame.
event :: proc(s: ^Session, e: platform.Event) {
	ev := e
	ev.buttons = s.buttons
	ev.pointer = e.pointer
	platform.inject_event(s.win, ev)
}

////////////////////////////////
// The pointer. Points are client pixels; a box's middle is `center(box)`.

move :: proc(s: ^Session, at: [2]f32) {
	s.pointer = at
	event(s, {kind = .Mouse_Move, pos = at})
	frames(s, INPUT_FRAMES)
}

// A button goes down where the pointer is (`at`: after moving there).
press :: proc(s: ^Session, at: [2]f32, button := platform.Mouse_Button.Left) {
	if at != s.pointer { move(s, at) }
	s.buttons += {button}
	event(s, {kind = .Mouse_Press, button = button, pos = at})
	frames(s, INPUT_FRAMES)
}

release :: proc(s: ^Session, at: [2]f32, button := platform.Mouse_Button.Left) {
	if at != s.pointer { move(s, at) }
	s.buttons -= {button}
	event(s, {kind = .Mouse_Release, button = button, pos = at})
	frames(s, INPUT_FRAMES)
}

// A click at a point. `count` 2: a double click. With a Left button held across a move it would be a drag: this is one place.
// The pointer moves there first and frames are built, even when it was there: what is under it (the box in front, which
// context_take and the hover read) comes from the last frame, and a press with no move before it met an old one (the
// pointer left the window since, or the boxes under it moved).
click_at :: proc(s: ^Session, at: [2]f32, button := platform.Mouse_Button.Left, count := 1) {
	move(s, at)
	for _ in 0 ..< count {
		s.buttons += {button}
		event(s, {kind = .Mouse_Press, button = button, pos = at})
		frame(s)
		s.buttons -= {button}
		event(s, {kind = .Mouse_Release, button = button, pos = at})
		frame(s)
	}
	frames(s, INPUT_FRAMES)
}

// A click on the box with this name (the deepest clickable box around it, its middle). No such box ends the test.
click :: proc(s: ^Session, name: string, button := platform.Mouse_Button.Left, count := 1, loc := #caller_location) {
	click_at(s, center(acts_on(get(s, name, loc = loc))), button, count)
}

// A click on the box that shows this text.
click_text :: proc(s: ^Session, text: string, button := platform.Mouse_Button.Left, count := 1, loc := #caller_location) {
	b := find_text(s, text)
	if b == nil { failed(s, fmt.tprintf("no box shows %q", text), loc) }
	click_at(s, center(acts_on(b)), button, count)
}

// The pointer comes over the box with this name.
hover :: proc(s: ^Session, name: string, loc := #caller_location) { move(s, center(get(s, name, loc = loc))) }

// The pointer leaves the window.
leave :: proc(s: ^Session) {
	event(s, {kind = .Mouse_Leave})
	frames(s, INPUT_FRAMES)
}

// A press, moves, a release.
drag :: proc(s: ^Session, from, to: [2]f32, steps := DRAG_STEPS, button := platform.Mouse_Button.Left) {
	press(s, from, button)
	for i in 1 ..= steps {
		k := f32(i) / f32(steps)
		at := from + (to - from) * k
		s.pointer = at
		event(s, {kind = .Mouse_Move, pos = at})
		frame(s)
	}
	release(s, to, button)
}

// A pen, as the system gives it: its own event (Pointer_*, with its pressure 0..1), then the mouse's emulation of it
// (Mouse_*, `emulated`), at one place. A pen's pressure reaches the build as ui.pointer_pressure.
PEN_ID :: 2   // Pointer_Info.id of the session's pen (the mouse is 1)

@(private)
pen_event :: proc(s: ^Session, pointer: platform.Event_Kind, mouse: platform.Event_Kind, at: [2]f32, pressure: f32, contact: bool) {
	pi := platform.Pointer_Info{id = PEN_ID, kind = .Pen, primary = true, measured = true, pressure = contact ? pressure : 0}
	s.pointer = at
	event(s, {kind = pointer, pos = at, pointer = pi})
	event(s, {kind = mouse, button = .Left, pos = at, pointer = pi, emulated = true})
}

// The pen's tip touches at `at`.
pen_press :: proc(s: ^Session, at: [2]f32, pressure: f32) {
	if at != s.pointer { pen_hover(s, at) }
	s.buttons += {.Left}
	pen_event(s, .Pointer_Down, .Mouse_Press, at, pressure, true)
	frames(s, INPUT_FRAMES)
}

// The pen moves to `at`: on the screen when its tip is down (a press before), above it else.
pen_move :: proc(s: ^Session, at: [2]f32, pressure: f32) {
	pen_event(s, .Pointer_Move, .Mouse_Move, at, pressure, .Left in s.buttons)
	frames(s, INPUT_FRAMES)
}

// The pen comes above `at`, its tip up.
pen_hover :: proc(s: ^Session, at: [2]f32) {
	pen_event(s, .Pointer_Move, .Mouse_Move, at, 0, false)
	frames(s, INPUT_FRAMES)
}

// The pen's tip lifts at `at` (its last move's place: a lift does not move it).
pen_release :: proc(s: ^Session, at: [2]f32) {
	s.buttons -= {.Left}
	pen_event(s, .Pointer_Up, .Mouse_Release, at, 0, false)
	frames(s, INPUT_FRAMES)
}

// A stroke of the pen: down at `from`, `steps` moves, up at `to`; the pressure goes from `pressure[0]` to
// `pressure[1]` along it, one move a frame.
pen_drag :: proc(s: ^Session, from, to: [2]f32, pressure := [2]f32{0.2, 0.9}, steps := DRAG_STEPS) {
	pen_press(s, from, pressure[0])
	for i in 1 ..= steps {
		k := f32(i) / f32(steps)
		pen_event(s, .Pointer_Move, .Mouse_Move, from + (to - from) * k, pressure[0] + (pressure[1] - pressure[0]) * k, true)
		frame(s)
	}
	pen_release(s, to)
}

// The wheel at a point: `notches` as Event.delta says (+y scrolls the content down).
wheel :: proc(s: ^Session, at: [2]f32, notches: [2]f32, mods: platform.Modifiers = {}) {
	if at != s.pointer { move(s, at) }
	event(s, {kind = .Scroll, pos = at, delta = notches, mods = mods})
	frames(s, INPUT_FRAMES)
}

// Fingers on a touchpad scroll at a point: `delta` in notches as Event.delta, its source .Finger (a wheel's is not).
// The next one within ui.SWIPE_PAUSE_MS is the same gesture: this one takes INPUT_FRAMES.
finger_scroll :: proc(s: ^Session, at: [2]f32, delta: [2]f32, mods: platform.Modifiers = {}) {
	if at != s.pointer { move(s, at) }
	event(s, {kind = .Scroll, pos = at, delta = delta, mods = mods, scroll_source = .Finger})
	frames(s, INPUT_FRAMES)
}

// The fingers leave the touchpad where the pointer is: the gesture ends (Wayland's axis_stop).
finger_lift :: proc(s: ^Session) {
	event(s, {kind = .Scroll, pos = s.pointer, scroll_source = .Finger, scroll_end = true})
	frames(s, INPUT_FRAMES)
}

////////////////////////////////
// The keyboard

// A key pressed and released.
key :: proc(s: ^Session, k: platform.Key, mods: platform.Modifiers = {}, repeat := 1) {
	for _ in 0 ..< repeat {
		event(s, {kind = .Key_Press, key = k, mods = mods})
		event(s, {kind = .Key_Release, key = k, mods = mods})
		frames(s, INPUT_FRAMES)
	}
}

// Text, as the keyboard's text input: one frame for all of it (a fast typist's burst), and then what it caused.
type_text :: proc(s: ^Session, text: string) {
	for r in text { event(s, {kind = .Text, text = r}) }
	frames(s, INPUT_FRAMES)
}

// Text, one character a frame, Enter and Tab as keys: for what reacts to each.
type_slowly :: proc(s: ^Session, text: string) {
	for r in text {
		switch r {
		case '\n': key(s, .Return)
		case '\t': key(s, .Tab)
		case:
			buf, n := utf8.encode_rune(r)
			type_text(s, string(buf[:n]))
		}
	}
}

////////////////////////////////
// The tree of boxes. Between frames: what the last build made.

// The box with this name (the part of its id after ###), nil when there is none. `index`: the nth of them, in the order of the tree.
// `within`: only under that box (a row of a page whose rows share their parts' names).
find :: proc(s: ^Session, name: string, index := 0, within: ^ui.Box = nil) -> ^ui.Box {
	return ui.box_find(s.state, name, "", index, within)
}

// The box that shows this text (letter case does not count), the outermost first of the tree. nil: none.
find_text :: proc(s: ^Session, text: string, index := 0) -> ^ui.Box {
	return ui.box_find(s.state, "", text, index)
}

// The box with this name (`within`: under that box): none ends the test.
get :: proc(s: ^Session, name: string, within: ^ui.Box = nil, loc := #caller_location) -> ^ui.Box {
	b := find(s, name, 0, within)
	if b == nil { failed(s, fmt.tprintf("no box is named %q", name), loc) }
	return b
}

// The box's middle, in client pixels, on whole pixels.
center :: proc(b: ^ui.Box) -> [2]f32 {
	return {math.round((b.rect.min.x + b.rect.max.x) * 0.5), math.round((b.rect.min.y + b.rect.max.y) * 0.5)}
}

// The box an action on `b` reaches: the deepest clickable box around it (a label's button), else itself.
acts_on :: proc(b: ^ui.Box) -> ^ui.Box {
	for a := b; a != nil; a = a.parent { if .Clickable in a.flags || .Text_Input in a.flags { return a } }
	return b
}

// The box that has the keyboard, nil when none has.
focused :: proc(s: ^Session) -> ^ui.Box {
	k := ui.focus_key_of(s.state)
	return k == 0 ? nil : ui.box_of(s.state, k)
}

// Its name ("" when none has the keyboard).
focused_name :: proc(s: ^Session, allocator := context.temp_allocator) -> string {
	b := focused(s)
	return b == nil ? "" : strings.clone(b.name, allocator)
}

// The box under the pointer.
hot_name :: proc(s: ^Session, allocator := context.temp_allocator) -> string {
	b := ui.box_of(s.state, ui.hot_key_of(s.state))
	return b == nil ? "" : strings.clone(b.name, allocator)
}

// The whole tree as text, one box a line: what a failure leaves.
tree_text :: proc(s: ^Session, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	write_tree(&sb, s.state, s.state.root, 0)
	return strings.to_string(sb)
}

@(private)
write_tree :: proc(sb: ^strings.Builder, state: ^ui.State, b: ^ui.Box, depth: int) {
	if b == nil || !ui.box_current(state, b) { return }
	for _ in 0 ..< depth { strings.write_string(sb, "  ") }
	fmt.sbprintf(sb, "%q %q [%.0f %.0f %.0f %.0f] %v\n", b.name, ui.box_text(b), b.rect.min.x, b.rect.min.y, b.rect.max.x, b.rect.max.y, b.flags)
	for c := b.first; c != nil; c = c.next { write_tree(sb, state, c, depth + 1) }
}

