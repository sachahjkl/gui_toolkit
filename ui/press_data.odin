package ui

import "core:mem"
import "../platform"

// What a gesture keeps for as long as its press lasts: the size a splitter had, the thumb a range slider took. It is the press's,
// not the widget's nor the State's: when the press ends, by whatever way (the button went up, its box went, the user left the
// window: boxes_gone, window_left), the state ends with it, and the next press starts from zero. A gesture that needs what an
// earlier press left (a double click told from two clicks) keeps that itself: drag_store does (panes.odin).
//
//   if p := ui.press_data(Grip_Press, b.key); p != nil {
//       if !p.taken { p^ = {from = size^, taken = true} }   // the first build of the press: what it starts from
//       if sig.dragging { size^ = p.from + sig.drag_delta.x }
//   }

@(private)
Press_Data_Key :: struct { key: Key, type: typeid }

@(private)
Press_Data :: struct {
	data:      rawptr,
	allocator: mem.Allocator,
	button:    platform.Mouse_Button,
	serial:    u64,
}

// The `T` of the press held on box `key`, zero when that press began; nil when no button holds `key`. Several types may share a
// press. The pointer holds until the press ends: ask again at each build rather than keep it.
press_data :: proc($T: typeid, key: Key) -> ^T {
	s := gs()
	if key == 0 { return nil }
	for k, button in s.active_key {
		if k != key { continue }
		pk := Press_Data_Key{key, T}
		if e, ok := s.press_kept[pk]; ok {
			if e.button == button && e.serial == s.press_serial[button] { return (^T)(e.data) }
			mem.free(e.data, e.allocator)   // (an earlier press of this box, not yet swept)
		}
		p := new(T)
		s.press_kept[pk] = {data = p, allocator = context.allocator, button = button, serial = s.press_serial[button]}
		return p
	}
	return nil
}

// What the presses that ended kept goes: after the input (a release, the user leaving) and after the build (boxes_gone).
@(private)
press_data_sweep :: proc(s: ^State) {
	if len(s.press_kept) == 0 { return }
	ended := make([dynamic]Press_Data_Key, context.temp_allocator)
	for pk, e in s.press_kept {
		if s.active_key[e.button] != pk.key || s.press_serial[e.button] != e.serial { append(&ended, pk) }
	}
	for pk in ended {
		mem.free(s.press_kept[pk].data, s.press_kept[pk].allocator)
		delete_key(&s.press_kept, pk)
	}
}

@(private)
press_data_destroy :: proc(s: ^State) {
	for _, e in s.press_kept { mem.free(e.data, e.allocator) }
	delete(s.press_kept)
}
