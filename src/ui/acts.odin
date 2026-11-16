package ui

// Act names and go to (src/md/features/everything-palette.md, "Layer 3, as built"). An element states the act name of
// what it acts on ("setting:appearance.theme", "command:save"); each window keeps the act names of its last frame. Go
// to shows the element that holds a name: its view comes forward, the box is scrolled into view, its first focusable
// box gets the focus, and it is lit once.
//
//   ui.act_name(ui.parent_box(), "setting:appearance.theme")   at its build, each build
//   ui.act_shown("setting:appearance.theme")                    a window of the program showed it in its last frame
//   ui.act_go("setting:appearance.theme")                       goes there now, or when a next build shows it

import "core:math"
import "../draw"

// How long go to lights the element it shows (ms), and the builds it waits for an element not shown yet (the settings
// opened by the same press come at the next build).
ACT_LIGHT_MS :: 1200
ACT_GO_BUILDS :: 30

// The box go to lights, and when it began (the state's clock, ms).
Act_Light :: struct {
	key:   Key,
	start: f64,
}

// States the act name of box `b`, at its build: the frame being built holds it. One insert per element built: no pass
// over data.
act_name :: proc(b: ^Box, name: string) {
	if b == nil || name == "" { return }
	s := gs()
	s.acts_next[act_hash(name)] = b.key
}

// Whether a window of the program (this one, and those its views are built in) showed `name` in its last frame.
act_shown :: proc(name: string) -> bool {
	if name == "" { return false }
	_, _, ok := act_find(act_hash(name))
	return ok
}

// Goes to the element of act name `name`: at the end of the build of the window that shows it, its box is scrolled
// into view, its first focusable box gets the focus, its view comes forward and it is lit once. Not shown yet, the
// wish waits ACT_GO_BUILDS builds for it. True when a window showed it in its last frame.
act_go :: proc(name: string) -> bool {
	if name == "" { return false }
	vs := views()
	vs.act_want, vs.act_want_builds = act_hash(name), ACT_GO_BUILDS
	_, _, ok := act_find(vs.act_want)
	return ok
}

// (FNV-1a, 64 bits: no string is kept per frame; two names of one hash in one program's windows are not expected)
@(private = "file")
act_hash :: proc(name: string) -> u64 {
	h := u64(0xcbf29ce484222325)
	for i in 0 ..< len(name) { h = (h ~ u64(name[i])) * 0x100000001b3 }
	return h == 0 ? 1 : h
}

// The window whose last frame holds the hash, and the box's key there.
@(private = "file")
act_find :: proc(h: u64) -> (s: ^State, key: Key, ok: bool) {
	here := gs()
	if k, has := here.acts[h]; has { return here, k, true }
	for st in views().states {
		if st == here { continue }
		if k, has := st.acts[h]; has { return st, k, true }
	}
	return nil, 0, false
}

// (end_build, after the layout) This frame's act names become the window's; a go to waited for, shown in this frame,
// is made: scrolled, focused, its view forward, lit.
@(private)
acts_end_build :: proc(s: ^State) {
	s.acts, s.acts_next = s.acts_next, s.acts
	vs := state_views(s)
	if s.act_light.key != 0 {
		if s.time_ms - s.act_light.start >= ACT_LIGHT_MS || s.act_light.key not_in s.boxes {
			s.act_light = {}
		} else if s.anim_rate > 0 {
			s.anim_busy = true
		} else {
			wake_within(s, int(ACT_LIGHT_MS - (s.time_ms - s.act_light.start)) + WAKE_MARGIN_MS)
		}
	}
	if vs == nil || vs.act_want == 0 { return }
	k, has := s.acts[vs.act_want]
	if !has {
		// (each window's build spends one: with several windows the wish is shorter, still several frames of each)
		vs.act_want_builds -= 1
		if vs.act_want_builds <= 0 { vs.act_want = 0 }
		s.anim_busy = true   // (the next build may show it: the settings the same press opened)
		return
	}
	vs.act_want = 0
	b := s.boxes[k] or_else nil
	if b == nil { return }
	scroll_into_view(b)
	if stop := view_first_stop(b); stop != 0 { s.focus_key = stop }
	act_view_raise(vs, s, b)
	s.act_light = {key = k, start = s.time_ms}
	s.anim_busy = true
}

// The view whose body holds `b` comes forward (a dialog on top, a panel's tab chosen, a window raised).
@(private = "file")
act_view_raise :: proc(vs: ^Views, s: ^State, b: ^Box) {
	for a := b; a != nil; a = a.parent {
		for r in vs.records {
			if r.machine.state == .Closed { continue }
			for root in r.roots {
				if root != 0 && root == a.key && view_state_of(r, view_shown_in(r.machine)) == s {
					view_apply(vs, r, {kind = .Open})
					return
				}
			}
		}
	}
}

// (draw_box) The light of go to over its box: a ring of the focus colour and a wash inside it, fading (still with the
// animations off, then gone).
@(private)
act_light_draw :: proc(s: ^State, dc: ^draw.Context, b: ^Box, radii: [4]f32) {
	t := f32((s.time_ms - s.act_light.start) / ACT_LIGHT_MS)
	if t < 0 || t >= 1 { return }
	a := s.anim_rate > 0 ? 1 - t * t : 1
	c := color_from_tags(s, b.tags_key, "focus border")
	wash := c
	wash.a *= 0.18 * a
	ring := c
	ring.a *= a
	// (around the box, not on it: a settings line or a button has no inset of its own, and a ring on its edge touched
	// its words; the light stands off by ACT_LIGHT_OUTSET ems, its corners rounded as a selection's)
	em := b.font_size > 0 ? b.font_size : 14 * s.scale
	out := math.round(em * ACT_LIGHT_OUTSET)
	r := Rect{b.rect.min - out, b.rect.max + out}
	round := max(radii[0], radii[1], radii[2], radii[3]) + out
	corners := [4]f32{round, round, round, round}
	draw.rect_corners(dc, r, colors4(wash), corners)
	draw.rect_corners(dc, r, colors4(ring), corners, max(2, math.round(2 * s.scale)))
}

// How far the light of go to stands off its box, in ems.
ACT_LIGHT_OUTSET :: 0.4
