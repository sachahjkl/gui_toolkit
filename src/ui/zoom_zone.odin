package ui

import "core:math"
import "core:strings"
import "../platform"
import store "../store"

// Zoom zones: an area with a zoom of its own, which the program applies to what it draws there; its zoom remembered by
// the thing the area shows (src/md/features/zoom-zones.md).

// A zoom this close to the default is the default: steps in and out come back near it, not to it, and the key must
// then be forgotten (it follows the default again).
@(private = "file") ZOOM_ZONE_SNAP :: 0.005

// The zooms of the things some zones show, by key (a session's id, a shell's): kept by the program for the run, and
// between runs when it gives a Store (zoom_memory_load). Several zones can share one: the same key in two of them is one zoom.
Zoom_Memory :: struct {
	kept:    store.Kept,   // the zooms by key; a key at the default is not kept
	default: f32,          // what a key never zoomed (or reset) follows: the program sets it (a preference's value); 0: 1
	min:     f32,          // the zooms' bounds; 0: the window's (ZOOM_MIN, ZOOM_MAX)
	max:     f32,
	serial:  u64,          // moves at each change of a zoom in it
}

// A zone, kept by the program between builds. With a memory and a key, its zoom is the memory's for that key; else
// it is its own (`zoom`).
Zoom_Zone :: struct {
	memory: ^Zoom_Memory,
	key:    string,   // what it shows (zoom_zone sets it; owned: zoom_zone_destroy)
	zoom:   f32,      // its own zoom, with no memory or no key; 0: the default (1 with no memory)
	min:    f32,      // its own bounds, over the memory's; 0: none of its own
	max:    f32,
	serial: u64,      // moves at each change of its zoom made through it (a key, the wheel, zoom_zone_set)
}

// What a zoom key does.
Zoom_Action :: enum u8 { None, In, Out, Reset }

// Marks the next box built as the zone `z`, showing `key` (a key that changes shows another thing, with that thing's
// zoom), and gives its zoom: the program scales what it draws there by it. The standard zoom keys act on the zone
// while the keyboard focus is inside it, Ctrl+wheel while the pointer is over it. For this build only; `z` must stay
// valid until the next begin_build.
zoom_zone :: proc(z: ^Zoom_Zone, key := "") -> f32 {
	if key != z.key {
		delete(z.key)
		z.key = strings.clone(key)
	}
	gs().next_zoom_zone = z
	return zoom_zone_value(z)
}

// The zone's zoom now: its key's in its memory, else the memory's default; or its own.
zoom_zone_value :: proc(z: ^Zoom_Zone) -> f32 {
	if m := z.memory; m != nil && z.key != "" { return f32(store.kept_of(&m.kept, z.key, f64(zoom_default(z)))) }
	return z.zoom > 0 ? z.zoom : zoom_default(z)
}

// Sets the zone's zoom, within its bounds; at the default, its key is forgotten (it follows the default).
zoom_zone_set :: proc(z: ^Zoom_Zone, zoom: f32) {
	lo, hi := zoom_bounds(z)
	d := zoom_default(z)
	v := clamp(zoom, lo, hi)
	if abs(v - d) < ZOOM_ZONE_SNAP { v = d }
	if m := z.memory; m != nil && z.key != "" {
		store.kept_set(&m.kept, z.key, f64(v), f64(d))
		m.serial += 1
	} else {
		z.zoom = v
	}
	z.serial += 1
}

// The zone's zoom times `factor` (a step: feel(s).zoom_step, or its inverse).
zoom_zone_by :: proc(z: ^Zoom_Zone, factor: f32) { zoom_zone_set(z, zoom_zone_value(z) * factor) }

// Forgets the zone's zoom: it follows the default again (Ctrl+0).
zoom_zone_reset :: proc(z: ^Zoom_Zone) {
	if m := z.memory; m != nil && z.key != "" {
		store.kept_forget(&m.kept, z.key)
		m.serial += 1
	} else {
		z.zoom = 0
	}
	z.serial += 1
}

// What the zone holds of its own (its key). Its memory is the program's.
zoom_zone_destroy :: proc(z: ^Zoom_Zone) {
	delete(z.key)
	z.key = ""
}

// The memory's zooms read from `file` (the program's Store, opened before), each within the memory's bounds; each
// change is written through it, on the Store's worker. Without it, the memory lives for the run.
zoom_memory_load :: proc(m: ^Zoom_Memory, file: ^store.Store) {
	lo := m.min > 0 ? m.min : ZOOM_MIN
	hi := m.max > 0 ? m.max : ZOOM_MAX
	store.kept_load(&m.kept, file, f64(lo), f64(hi))
}

// `key`'s zoom kept no longer: the thing is gone (a session deleted, a shell closed).
zoom_memory_forget :: proc(m: ^Zoom_Memory, key: string) {
	store.kept_forget(&m.kept, key)
	m.serial += 1
}

// The memory's zooms (its Store is the program's to close).
zoom_memory_destroy :: proc(m: ^Zoom_Memory) { store.kept_destroy(&m.kept) }

// What the key press `key` with `mods` does to a zoom: Ctrl without Alt, on =, -, 0 or the keypad's + and -, whatever
// Shift says. It holds every chord of ZOOM_IN_KEYS, ZOOM_OUT_KEYS and ZOOM_RESET_KEYS (Ctrl+Shift+= is Ctrl++ on AZERTY).
zoom_key_action :: proc(key: platform.Key, mods: platform.Modifiers) -> Zoom_Action {
	if .Ctrl not_in mods || .Alt in mods { return .None }
	#partial switch key {
	case .Equal, .Num_Add:       return .In
	case .Minus, .Num_Subtract:  return .Out
	case .N0:                    return .Reset
	}
	return .None
}

@(private = "file")
zoom_default :: proc(z: ^Zoom_Zone) -> f32 {
	if m := z.memory; m != nil && m.default > 0 { return m.default }
	return 1
}

@(private = "file")
zoom_bounds :: proc(z: ^Zoom_Zone) -> (lo, hi: f32) {
	m := z.memory
	lo = z.min > 0 ? z.min : (m != nil && m.min > 0 ? m.min : ZOOM_MIN)
	hi = z.max > 0 ? z.max : (m != nil && m.max > 0 ? m.max : ZOOM_MAX)
	return
}

// A zoom key or `notches` of Ctrl+wheel (up: positive) on the zone.
@(private)
zoom_zone_act :: proc(s: ^State, z: ^Zoom_Zone, act: Zoom_Action, notches: f32 = 1) {
	switch act {
	case .In:    zoom_zone_by(z, math.pow(s.feel.zoom_step, notches))
	case .Out:   zoom_zone_by(z, 1 / math.pow(s.feel.zoom_step, notches))
	case .Reset: zoom_zone_reset(z)
	case .None:
	}
	s.pointer_only = false   // (the zone's content changes: a whole build)
}

// The innermost zone that holds `b` (b, then its parents); b must be a box of the last build.
@(private)
zoom_zone_around :: proc(b: ^Box) -> ^Zoom_Zone {
	for x := b; x != nil; x = x.parent {
		if x.zoom_zone != nil { return x.zoom_zone }
	}
	return nil
}

// The zone the keys act on: the innermost around the box with the keyboard focus, if that box is in the last build.
@(private)
zoom_zone_of_focus :: proc(s: ^State) -> ^Zoom_Zone {
	b := s.boxes[s.focus_key] if s.focus_key != 0 else nil
	// (a box of an earlier build keeps the parents it had then: no walk from it)
	if b == nil || b.last_build + 1 != s.build_index { return nil }
	return zoom_zone_around(b)
}

// The zone Ctrl+wheel at `p` acts on: the innermost around the box drawn in front there, else around the deepest box
// there (a zone with nothing drawn in it but text).
@(private)
zoom_zone_at :: proc(s: ^State, p: Vec2) -> ^Zoom_Zone {
	if s.root == nil { return nil }
	if k := front_test_box(s.root, p, s.root.rect); k != 0 {
		if b := s.boxes[k]; b != nil { return zoom_zone_around(b) }
	}
	return zoom_zone_around(deepest_box_at(s.root, p, s.root.rect))
}

// The deepest box at `p` within its clips, the last siblings first (they are drawn over the earlier ones).
@(private = "file")
deepest_box_at :: proc(b: ^Box, p: Vec2, clip: Rect) -> ^Box {
	if !(p.x >= clip.min.x && p.x < clip.max.x && p.y >= clip.min.y && p.y < clip.max.y) { return nil }
	child_clip := clip
	if .Clip in b.flags {
		child_clip = Rect{{max(clip.min.x, b.rect.min.x), max(clip.min.y, b.rect.min.y)}, {min(clip.max.x, b.rect.max.x), min(clip.max.y, b.rect.max.y)}}
	}
	for c := b.last; c != nil; c = c.prev {
		// (a floating child can lie outside its parent: each child is tried)
		if d := deepest_box_at(c, p, child_clip); d != nil { return d }
	}
	return box_contains(b, p) ? b : nil
}
