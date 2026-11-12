package ui

// A field that records a key combination (a program's global shortcut, a command's keys): a click, or Enter or Space
// while it has the keyboard, arms it; the next combination pressed with Ctrl, Shift, Alt or Super (Event.super) is its
// value. Escape gives the recording up, and so does the keyboard going elsewhere. Nothing is typed: a key Key does not
// name is taken by the character it types (platform.Hotkey.char: the French ù).
//
//   if ui.hotkey_field("###keys", &app.hotkey) { save(app.hotkey) }
//
// While one records, hotkey_recording() is true: a program that holds its shortcut as a global hotkey lets it go then
// (platform.hotkey_unregister), or the system would take the very keys being recorded. Tags used: "input" (the field),
// "weak" (the words while it records, and with no value).

import "core:fmt"
import "core:math"
import "../platform"

// The words of the field while it records, and when it has no value.
HOTKEY_FIELD_RECORDING :: "Press the keys…"
HOTKEY_FIELD_EMPTY     :: "Click, then press the keys"

hotkey_field :: proc(id: string, hk: ^platform.Hotkey) -> (changed: bool) {
	s := gs()
	em := font_size()
	key := key_from_string(parent_box().key, id)   // (the key build_box gives it: its state is known before it is built)
	recording := s.hotkey_recorder == key
	if recording && s.focus_key != key { s.hotkey_recorder, recording = 0, false }   // (the keyboard went elsewhere)
	if recording {
		if got, ok := key_take(); ok {
			switch {
			case got.key == .Escape && got.mods == {}:
				s.hotkey_recorder, recording = 0, false
			case platform.hotkey_complete(got):
				hk^ = got
				changed = true
				s.hotkey_recorder, recording = 0, false
			}   // (a key alone is no shortcut, Print Screen apart: the field waits for one)
		}
	}
	empty := hk.key == .None && hk.char == 0
	text := recording ? HOTKEY_FIELD_RECORDING : empty ? HOTKEY_FIELD_EMPTY : platform.hotkey_text(hk^)
	if !s.has_next || s.next_mod.height == nil { next({height = px(math.round(em * 2))}) }
	push_tags("input")
	if recording || empty { push_tags("weak") }
	b := build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Focus_Ring, .Sunken, .Draw_Text}, fmt.tprintf("%s%s", text, id_part(id)))
	if recording || empty { pop_tags() }
	pop_tags()
	a11y_default(b, {role = .Button, name = fmt.tprintf("Shortcut: %s", text)})
	// (a click, or Enter or Space while it has the keyboard, which signal takes as a click)
	if signal(b).clicked && !recording {
		s.hotkey_recorder = b.key
		set_focus(b.key)
		wake_within(s, 1)
	}
	return
}

// Whether a hotkey_field records now.
hotkey_recording :: proc() -> bool { return gs().hotkey_recorder != 0 }

// The part of an id that makes the key ("###keys" of "words###keys"), kept when the field writes its own words.
@(private = "file")
id_part :: proc(id: string) -> string {
	for i := 0; i + 3 <= len(id); i += 1 { if id[i:i + 3] == "###" { return id[i:] } }
	return fmt.tprintf("###%s", id)
}
