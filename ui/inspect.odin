package ui

import "../platform"

// What a tool reads of a box from outside a build (devtools, tests): its text as shown, plain or rich. Between end_build
// and the next begin_build (the frame memory it points into is freed then). Temp memory for a rich paragraph's text.
box_text :: proc(b: ^Box) -> string {
	if b == nil { return "" }
	if b.custom == rich_draw && b.custom_user != nil {
		return rich_text((^Rich_Draw)(b.custom_user).runs)
	}
	return b.text
}

// Whether the box was built by the last build (a box kept from an older one is about to go: its memory is not to be read).
box_current :: proc(s: ^State, b: ^Box) -> bool { return b != nil && b.last_build == s.build_index }

// The box with the focus, the one under the pointer (last build).
focus_key_of :: proc(s: ^State) -> Key { return s.focus_key }
hot_key_of :: proc(s: ^State) -> Key { return s.hot_key }

// What the last build cost (milliseconds), and the items of its lazy columns that were built. total_ms runs from
// begin_build to the end of end_build, the app's own code and the accessibility tree included.
Build_Metrics :: struct {
	build_ms, layout_ms, total_ms: f64,
	lazy_built:                    int,
}

build_metrics :: proc(s: ^State) -> Build_Metrics { return s.metrics }

// The input the last build took (until the next poll_events).
build_events :: proc(s: ^State) -> []platform.Event { return s.last_events }

// The box of a key, if the last build made it.
box_of :: proc(s: ^State, key: Key) -> ^Box {
	b := s.boxes[key] if key != 0 else nil
	return box_current(s, b) ? b : nil
}
