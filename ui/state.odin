package ui

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:time"
import "../font"
import "../platform"

// The state selected by the last `begin_build`. Public procs operate on it (like raddebugger's `ui_state`).
@(private) g: ^State

@(private) tick_origin: time.Tick

init :: proc(s: ^State, fonts: ^font.State, theme: ^Theme) {
	// the state is current from here: an app may read it (scale, font_size, focus...) before its first build, e.g.
	// routing the input of its first frame
	g = s
	s.fonts = fonts
	s.theme = theme
	s.zoom = 1
	s.scale = 1
	s.toast_pos = .Top_Right
	s.rounding = 1
	s.density = 1
	s.sb_owner = make(map[Key]Key)
	_ = virtual.arena_init_growing(&s.arena)
	s.boxes = make(map[Key]^Box)
	s.anims = make(map[Key]Animation)
	s.timers = make(map[Key]Timer)
	s.tag_sets = make(map[Key][]string)
	s.color_memo = make(map[[2]u64]Color)
	s.wrap_cache = make(map[Wrap_Key]Wrap_Entry)
	tick_origin = time.tick_now()
}

// Frees everything `init` and the builds allocated (the fonts and the theme are the caller's).
destroy :: proc(s: ^State) {
	for _, b in s.boxes { free(b) }
	for b in s.free_boxes { free(b) }
	delete(s.boxes)
	delete(s.free_boxes)
	delete(s.anims)
	delete(s.timers)
	delete(s.tag_sets)
	delete(s.color_memo)
	delete(s.sb_owner)
	delete(s.bar_keys)
	delete(s.bar_keys_prev)
	delete(s.parent_stack)
	delete(s.style_stack)
	delete(s.tag_stack)
	delete(s.disabled_stack)
	delete(s.tab_stops_off)
	delete(s.tag_marks)
	delete(s.tag_keys)
	delete(s.events.list)
	delete(s.events.consumed)
	delete(s.typed)
	delete(s.focus_order)
	delete(s.popup_stack)
	delete(s.list_stack)
	menus_destroy(s)
	platform.chrome_regions_destroy(&s.chrome)
	wrap_cache_destroy(s)
	virtual.arena_destroy(&s.arena)
	if g == s { g = nil }
	s^ = {}
}

frame_allocator :: proc() -> mem.Allocator { return virtual.arena_allocator(&g.arena) }

now_ms :: proc() -> f64 { return time.duration_milliseconds(time.tick_since(tick_origin)) }

Build_Params :: struct {
	window_size:    Vec2,
	events:         []platform.Event,
	dt:             f32,       // seconds since the previous frame
	animations:     bool,      // false = every transition jumps to its end value
	dpi_scale:      f32,       // OS scale (dpi / 96); 0 is treated as 1
	base:           Style,     // root style in LOGICAL pixels: font_size, text_pad, radius and pixel sizes are multiplied by dpi_scale * zoom
	disable_zoom:   bool,      // true: ignore Ctrl+wheel and Ctrl +/-/0
	clipboard_get:  proc() -> string,
	clipboard_set:  proc(text: string),
	window:         ^platform.Window,   // optional: with an integrated title bar, gets its regions after each build
	frame_ms:       f64,                // optional: the frame's time in ms (a display clock: when it will be shown);
	                                    // scroll animations are sampled on it. 0: now_ms()
}

begin_build :: proc(s: ^State, p: Build_Params) {
	g = s
	s.build_index += 1
	virtual.arena_free_all(&s.arena)
	clear(&s.parent_stack); clear(&s.style_stack); clear(&s.tag_stack); clear(&s.tag_marks); clear(&s.tag_keys)
	clear(&s.tag_sets); clear(&s.color_memo)
	clear(&s.disabled_stack); s.disabled_depth = 0
	clear(&s.tab_stops_off); s.tab_skip = 0
	clear(&s.focus_order)
	s.trap_depth = 0
	s.modal_prev, s.modal_now = s.modal_now, 0
	s.bar_keys, s.bar_keys_prev = s.bar_keys_prev, s.bar_keys
	clear(&s.bar_keys)
	s.has_next = false
	s.next_mod = {}
	s.window_size = p.window_size
	s.dt = p.dt
	s.anim_rate = p.animations ? 1 : 0
	s.anim_busy = false
	s.wake_ms = 0
	s.boxes_built = 0
	s.time_ms = now_ms()
	s.frame_ms = p.frame_ms > 0 ? p.frame_ms : s.time_ms
	s.clipboard_get = p.clipboard_get
	s.clipboard_set = p.clipboard_set
	s.cursor_request = .Arrow
	s.window = p.window
	s.caption_keys = {}
	s.caption_built = false

	process_events(s, p.events, !p.disable_zoom)
	menu_capture_keys(s, p.events)
	s.scale = (p.dpi_scale > 0 ? p.dpi_scale : 1) * s.zoom

	// root: fills the window
	base := p.base
	base.font_size = math.round(base.font_size * s.scale)
	base.text_pad = math.round(base.text_pad * s.scale)
	base.radius = math.round(base.radius * s.scale)
	for &sz in base.pref { if sz.kind == .Pixels || sz.kind == .Text { sz.value = math.round(sz.value * s.scale) } }
	append(&s.style_stack, base)
	key := key_from_string(0, "root")
	root := touch_box(s, key)
	root.flags = {}
	root.pref = {.X = px(p.window_size.x), .Y = px(p.window_size.y)}
	root.layout_axis = .Y
	root.text = ""
	root.rect = {{0, 0}, p.window_size}
	root.size = p.window_size
	s.root = root
	append(&s.parent_stack, root)
	push_tags_key(s)
}

end_build :: proc() {
	s := g
	pop(&s.parent_stack)
	assert(len(s.parent_stack) == 0, "ui: unbalanced parent push/pop")
	assert(len(s.tag_marks) == 0, "ui: unbalanced tags push/pop")
	assert(len(s.popup_stack) == 0, "ui: unbalanced popup scopes")
	assert(len(s.style_stack) == 1, "ui: unbalanced style push/pop")
	assert(len(s.disabled_stack) == 0, "ui: unbalanced disabled scopes")
	assert(len(s.tab_stops_off) == 0, "ui: unbalanced tab_stops scopes")

	layout(s)
	// the title bar's regions: for the window when its title bar is integrated, for chrome_regions in any case
	if s.caption_built || s.caption_keys != {} {
		chrome_collect(s)
	} else if s.window != nil && platform.is_integrated_title(s.window) && len(s.chrome.caption) > 0 {
		chrome_collect(s)   // none any more (full screen bars hidden...): the window forgets the last ones
	}
	wrap_cache_trim(s)
	menu_prune(s)
	handle_tab_navigation(s)
	update_animations(s)

	// drop boxes and animations that were not touched this build
	dead := make([dynamic]Key, context.temp_allocator)
	for k, b in s.boxes { if b.last_build != s.build_index { append(&dead, k) } }
	for k in dead {
		append(&s.free_boxes, s.boxes[k])
		delete_key(&s.boxes, k)
	}
	clear(&dead)
	for k, a in s.anims { if a.last_build + 1 < s.build_index { append(&dead, k) } }
	for k in dead { delete_key(&s.anims, k) }

	// per-frame input state is consumed
	s.scroll_delta = {}
	for b in platform.Mouse_Button {
		s.pressed_key[b] = 0
		s.pressed_any[b] = false
		s.released_key[b] = 0
		s.clicked_key[b] = 0
	}
	s.double_key = 0
}

// True while something is still animating or a timed wake is wanted: the app loop should keep rendering.
needs_frame :: proc(s: ^State) -> bool { return s.anim_busy }
wake_ms :: proc(s: ^State) -> int { return s.wake_ms }
cursor :: proc(s: ^State) -> platform.Cursor { return s.cursor_request }
boxes_built :: proc(s: ^State) -> int { return s.boxes_built }

// Density: row heights and vertical gaps are multiplied by it (text keeps its size). Built-in widgets and
// vertical spacers follow it; use `dense` for your own row heights.
DENSITY_COMPACT :: 0.78
density :: proc(s: ^State) -> f32 { return s.density }
set_density :: proc(s: ^State, d: f32) { s.density = clamp(d, 0.6, 1.2) }
dense :: proc(v: f32) -> f32 { return math.round(v * g.density) }

ZOOM_MIN :: 0.5
ZOOM_MAX :: 3.0
ZOOM_STEP :: 1.1

zoom :: proc(s: ^State) -> f32 { return s.zoom }
set_zoom :: proc(s: ^State, z: f32) { s.zoom = clamp(z, ZOOM_MIN, ZOOM_MAX) }
// dpi scale * zoom: multiply your own pixel constants by this (ui.font_size() and the base style already include it)
scale :: proc() -> f32 { return g.scale }

////////////////////////////////
// Boxes

@(private)
touch_box :: proc(s: ^State, key: Key) -> ^Box {
	b, found := s.boxes[key]
	if !found {
		if len(s.free_boxes) > 0 { b = pop(&s.free_boxes); b^ = {} } else { b = new(Box) }
		b.key = key
		b.first_build = s.build_index
		s.boxes[key] = b
	}
	b.first, b.last, b.next, b.prev, b.parent = nil, nil, nil, nil, nil
	b.child_count = 0
	b.last_build = s.build_index
	return b
}

box_from_key :: proc(key: Key) -> ^Box {
	if b, ok := g.boxes[key]; ok { return b }
	return nil
}

parent_box :: proc() -> ^Box { return g.parent_stack[len(g.parent_stack) - 1] }

top_style :: proc() -> ^Style { return &g.style_stack[len(g.style_stack) - 1] }

font_size :: proc() -> f32 { return top_style().font_size }

// Builds a box under the current parent. `id` follows the id-string rules in key.odin ("" = anonymous, keyed by position).
build_box :: proc(flags: Box_Flags, id: string = "") -> ^Box {
	s := g
	parent := parent_box()
	key: Key
	if id == "" { key = key_from_u64(parent.key, u64(parent.child_count) + 0x9e3779b97f4a7c15) } else { key = key_from_string(parent.key, id) }
	// two siblings with the same id would share state: keep going until the key is free for this build
	for {
		if existing, ok := s.boxes[key]; ok && existing.last_build == s.build_index {
			key = key_from_u64(key, 0xdeadbeef)
		} else { break }
	}
	b := touch_box(s, key)
	s.boxes_built += 1

	st := top_style()^
	mod := s.next_mod
	has_mod := s.has_next
	s.has_next = false
	s.next_mod = {}
	axis := Axis.Y
	cross := Cross_Align.Start
	fixed: [2]Maybe(f32)
	if has_mod {
		apply_mod(&st, mod)
		if v, ok := mod.axis.?; ok { axis = v }
		if v, ok := mod.cross.?; ok { cross = v }
		fixed = {mod.fixed_x, mod.fixed_y}
	}

	b.flags = flags + st.extra_flags
	if s.disabled_depth > 0 { b.flags += {.Disabled} }
	if .Window_Caption in b.flags { s.caption_built = true }
	if .Disabled in b.flags && s.focus_key == b.key { s.focus_key = 0 }
	b.name = ""
	if id != "" { b.name = fmt.aprint(hash_part(id), allocator = frame_allocator()) }
	b.pref = st.pref
	b.layout_axis = axis
	b.cross = cross
	b.gap = {}
	if has_mod { if v, ok := mod.gap.?; ok { b.gap = v } }
	b.font = st.font
	b.font_size = st.font_size
	b.text_pad = st.text_pad
	b.text_align = st.text_align
	b.radius = st.radius
	b.transparency = st.transparency
	b.squish = st.squish
	b.cursor = st.cursor
	b.custom = nil
	b.custom_user = nil
	if v, ok := fixed[0].?; ok { b.flags += {.Floating_X}; b.fixed_pos.x = v }
	if v, ok := fixed[1].?; ok { b.flags += {.Floating_Y}; b.fixed_pos.y = v }
	if v, ok := mod.fixed_w.?; ok && has_mod { b.pref[.X] = px(v) }
	if v, ok := mod.fixed_h.?; ok && has_mod { b.pref[.Y] = px(v) }
	if .Clickable in b.flags && b.cursor == .Arrow && !has_mod { b.cursor = .Hand }
	if has_mod { if v, ok := mod.cursor.?; ok { b.cursor = v } }

	// text
	b.text = ""
	b.text_dim = {}
	disp := display_part(id)
	if disp != "" {
		b.text = fmt.aprint(disp, allocator = frame_allocator())
		m := font.metrics(s.fonts, b.font, b.font_size)
		b.text_dim = {font.text_width(s.fonts, b.font, b.font_size, b.text), m.line_height}
	}

	// colors: theme targets (or explicit overrides), animated toward the targets
	b.tags_key = current_tags_key(s)
	b.target_bg = color("background")
	b.target_border = color("border")
	b.target_text = color("text")
	if has_mod {
		if c, ok := mod.bg.?; ok { b.target_bg = c }
		if c, ok := mod.border.?; ok { b.target_border = c }
		if c, ok := mod.fg.?; ok { b.target_text = c }
	}
	if .Disabled in b.flags {
		// neutral look: an accent or danger fill would keep its colour while its text faded away
		plain := []string{"button"}
		if b.target_bg.a > 0.01 { b.target_bg = theme_lookup(s.theme, plain, "background") }
		if b.target_border.a > 0.01 { b.target_border = theme_lookup(s.theme, plain, "border") }
		b.target_text = theme_lookup(s.theme, nil, "weak text")
	}
	if b.first_build == s.build_index || s.anim_rate == 0 {
		b.bg, b.border, b.text_color = b.target_bg, b.target_border, b.target_text
	} else {
		rate := f32(1 - math.pow(2, -60 * f64(s.dt)))
		busy := false
		approach :: proc(cur: ^Color, target: Color, rate: f32, busy: ^bool) {
			d: f32
			for i in 0 ..< 4 { d = max(d, abs(target[i] - cur[i])) }
			if d < 0.002 { cur^ = target; return }
			cur^ += (target - cur^) * rate
			busy^ = true
		}
		approach(&b.bg, b.target_bg, rate, &busy)
		approach(&b.border, b.target_border, rate, &busy)
		approach(&b.text_color, b.target_text, rate, &busy)
		if busy { s.anim_busy = true }
	}

	if .Focusable in b.flags && .Disabled not_in b.flags && s.tab_skip == 0 {
		append(&s.focus_order, Focus_Entry{key = b.key, trapped = s.trap_depth > 0})
	}

	// link into the parent
	b.parent = parent
	if parent.last != nil { parent.last.next = b; b.prev = parent.last } else { parent.first = b }
	parent.last = b
	parent.child_count += 1
	return b
}

@(private)
apply_mod :: proc(st: ^Style, m: Style_Mod) {
	if v, ok := m.width.?; ok { st.pref[.X] = v }
	if v, ok := m.height.?; ok { st.pref[.Y] = v }
	if v, ok := m.font.?; ok { st.font = v }
	if v, ok := m.font_size.?; ok { st.font_size = v }
	if v, ok := m.text_pad.?; ok { st.text_pad = v }
	if v, ok := m.text_align.?; ok { st.text_align = v }
	if v, ok := m.radius.?; ok { st.radius = v }
	if v, ok := m.transparency.?; ok { st.transparency = v }
	if v, ok := m.squish.?; ok { st.squish = v }
	st.extra_flags += m.flags
}

////////////////////////////////
// Style, parent and tag scopes

// `if style({...}) { ... }`: override the style for the block.
@(deferred_none = pop_style)
style :: proc(m: Style_Mod) -> bool {
	st := top_style()^
	apply_mod(&st, m)
	if v, ok := m.cursor.?; ok { st.cursor = v }
	append(&g.style_stack, st)
	return true
}

pop_style :: proc() { pop(&g.style_stack) }

// Override the style for the next box only (also the only way to set `axis`, `fixed_*`, `bg`, `border`, `fg`).
next :: proc(m: Style_Mod) {
	g.next_mod = m
	g.has_next = true
}

@(deferred_none = pop_parent)
parent :: proc(b: ^Box) -> bool {
	append(&g.parent_stack, b)
	return true
}

pop_parent :: proc() { pop(&g.parent_stack) }

// `if tags("card", "accent") { ... }`: push theme tags for the block.
@(deferred_none = pop_tags)
tags :: proc(names: ..string) -> bool {
	push_tags(..names)
	return true
}

push_tags :: proc(names: ..string) {
	s := g
	append(&s.tag_marks, len(s.tag_stack))
	for n in names {
		append(&s.tag_stack, n)
		append(&s.tag_keys, key_from_string(len(s.tag_keys) > 0 ? s.tag_keys[len(s.tag_keys) - 1] : 0, n))
	}
	push_tags_key(s)
}

pop_tags :: proc() {
	s := g
	mark := pop(&s.tag_marks)
	resize(&s.tag_stack, mark)
	resize(&s.tag_keys, mark)
}

@(private)
current_tags_key :: proc(s: ^State) -> Key {
	if len(s.tag_keys) == 0 { return 0 }
	k := s.tag_keys[len(s.tag_keys) - 1]
	if _, ok := s.tag_sets[k]; !ok {
		cp := make([]string, len(s.tag_stack), frame_allocator())
		copy(cp, s.tag_stack[:])
		s.tag_sets[k] = cp
	}
	return k
}

@(private)
push_tags_key :: proc(s: ^State) { _ = current_tags_key(s) }

// `if disabled(!enabled) { ... }`: when `cond` is true, every box built in the block is disabled: no clicks,
// no hover, no keyboard focus, and it fades to a muted look. Scopes nest; `disabled(false)` changes nothing.
@(deferred_none = pop_disabled)
disabled :: proc(cond := true) -> bool {
	append(&g.disabled_stack, cond)
	if cond { g.disabled_depth += 1 }
	return true
}

pop_disabled :: proc() {
	if pop(&g.disabled_stack) { g.disabled_depth -= 1 }
}

// `if tab_stops(false) { ... }`: the widgets built in the block are no Tab stops (Tab and the arrow keys skip them);
// they still take the focus when clicked or through set_focus. For rows of a list whose editors only the active row
// should offer, and the like. Scopes nest; `tab_stops(true)` changes nothing.
@(deferred_none = pop_tab_stops)
tab_stops :: proc(on: bool) -> bool {
	append(&g.tab_stops_off, !on)
	if !on { g.tab_skip += 1 }
	return true
}

pop_tab_stops :: proc() {
	if pop(&g.tab_stops_off) { g.tab_skip -= 1 }
}

// `if muted() { ... }`: secondary content, drawn with the theme's weak text colour. Still interactive (see `disabled`).
@(deferred_none = pop_tags)
muted :: proc() -> bool {
	push_tags("weak")
	return true
}

////////////////////////////////
// Animation helper

// Eases a persistent value toward `target`. `rate` is "halvings per second of distance" (higher = faster).
anim :: proc(key: Key, target: f32, rate: f32 = 40, initial: Maybe(f32) = nil) -> f32 {
	s := g
	a, found := s.anims[key]
	if !found { a.value = initial.? or_else target }
	a.last_build = s.build_index
	if s.anim_rate == 0 {
		a.value = target
	} else {
		d := target - a.value
		if abs(d) < 0.001 { a.value = target } else {
			a.value += d * f32(1 - math.pow(2, -f64(rate) * f64(s.dt)))
			s.anim_busy = true
		}
	}
	s.anims[key] = a
	return a.value
}

@(private)
update_animations :: proc(s: ^State) {
	rate := f32(1 - math.pow(2, -60 * f64(s.dt)))
	if s.anim_rate == 0 { rate = 1 }
	step :: proc(cur: ^f32, target: f32, rate: f32, busy: ^bool) {
		d := target - cur^
		if abs(d) < 0.003 { cur^ = target; return }
		cur^ += d * rate
		busy^ = true
	}
	for _, b in s.boxes {
		if b.last_build != s.build_index { continue }
		hot: f32 = s.hot_key == b.key ? 1 : 0
		active: f32 = s.active_key[.Left] == b.key ? 1 : 0
		focus: f32 = s.focus_key == b.key ? 1 : 0
		disabled: f32 = .Disabled in b.flags ? 1 : 0
		step(&b.hot_t, hot, rate, &s.anim_busy)
		step(&b.active_t, active, rate, &s.anim_busy)
		step(&b.focus_t, focus, rate, &s.anim_busy)
		step(&b.disabled_t, disabled, rate, &s.anim_busy)

		// scrolling: the offset follows the (clamped) target (scroll_anim.odin)
		for axis in Axis {
			scroll_flag := axis == .X ? Box_Flag.View_Scroll_X : Box_Flag.View_Scroll_Y
			if scroll_flag not_in b.flags { continue }
			limit := max(0, b.view_bounds[int(axis)] - b.size[int(axis)])
			b.view_target[int(axis)] = clamp(b.view_target[int(axis)], 0, limit)
			scroll_step(s, b, int(axis))
		}
	}
}

// Prints every box taller than `limit` px (id text, size, pref kinds): layout debugging aid.
debug_dump_tall :: proc(s: ^State, limit: f32) {
	g = s
	walk :: proc(b: ^Box, depth: int, limit: f32) {
		if b.size.y > limit {
			fmt.printf("%*s text=%q size=%.0fx%.0f pref=(%v %.1f, %v %.1f) children=%d axis=%v\n",
				depth * 2, "", b.text, b.size.x, b.size.y, b.pref[Axis.X].kind, b.pref[Axis.X].value, b.pref[Axis.Y].kind, b.pref[Axis.Y].value, b.child_count, b.layout_axis)
		}
		for c := b.first; c != nil; c = c.next { walk(c, depth + 1, limit) }
	}
	walk(s.root, 0, limit)
}
////////////////////////////////
// Keyboard focus navigation

// Tab / Shift+Tab move the focus through the Tab stops (boxes with .Focusable) in build order, wrapping around.
// While a modal is open only its own Tab stops take part. Runs after layout, so the newly focused box can be
// scrolled into view inside its scroll containers.
//
// Arrow keys move the focus spatially (to the nearest Tab stop in that direction) once a widget that does not use
// arrows itself has the focus; sliders, text fields and open menus consume their arrows before this runs.
@(private)
handle_tab_navigation :: proc(s: ^State) {
	s.tab_dir = 0
	if handle_arrow_navigation(s) { return }
	dir := 0
	if key_press(.Tab) { dir = 1 } else if key_press(.Tab, {.Shift}) { dir = -1 }
	if dir == 0 || len(s.focus_order) == 0 { return }
	trapped := false
	for e in s.focus_order { if e.trapped { trapped = true; break } }
	stops := make([dynamic]Key, 0, len(s.focus_order), context.temp_allocator)
	for e in s.focus_order { if e.trapped == trapped { append(&stops, e.key) } }
	if len(stops) == 0 { return }
	cur := -1
	for k, i in stops { if k == s.focus_key { cur = i; break } }
	next: int
	if cur < 0 { next = dir > 0 ? 0 : len(stops) - 1 } else { next = (cur + dir + len(stops)) % len(stops) }
	s.focus_key = stops[next]
	s.focus_visible = true
	s.tab_dir = dir
	scroll_focus_into_view(s)
}

// +1 / -1 when Tab / Shift+Tab moved the focus at the end of the last build (0 otherwise; valid during the next build):
// an app that hands the focus over to content of its own when a box takes it (a document view) knows from which side
// it came.
tab_direction :: proc(s: ^State) -> int { return s.tab_dir }

// Moves the focus as Tab (dir > 0) or Shift+Tab would, from `from` (0: from the start or the end). For an app whose
// own content passes the focus back to the toolkit's Tab order.
focus_step :: proc(s: ^State, from: Key, dir: int) {
	if len(s.focus_order) == 0 { return }
	cur := -1
	for e, i in s.focus_order { if e.key == from { cur = i; break } }
	n := len(s.focus_order)
	next: int
	if cur < 0 { next = dir > 0 ? 0 : n - 1 } else { next = (cur + (dir > 0 ? 1 : -1) + n) % n }
	s.focus_key = s.focus_order[next].key
	s.focus_visible = true
}

@(private)
handle_arrow_navigation :: proc(s: ^State) -> bool {
	if s.focus_key == 0 || len(s.menus) > 0 || len(s.focus_order) == 0 { return false }
	cur := s.boxes[s.focus_key]
	if cur == nil || cur.last_build != s.build_index || .Text_Input in cur.flags { return false }
	dir: Vec2
	switch {
	case key_press(.Left):  dir = {-1, 0}
	case key_press(.Right): dir = {1, 0}
	case key_press(.Up):    dir = {0, -1}
	case key_press(.Down):  dir = {0, 1}
	case: return false
	}
	trapped := false
	for e in s.focus_order { if e.trapped { trapped = true; break } }
	c0 := (cur.rect.min + cur.rect.max) * 0.5
	best: Key
	best_score := max(f32)
	for e in s.focus_order {
		if e.trapped != trapped || e.key == cur.key { continue }
		b := s.boxes[e.key]
		if b == nil { continue }
		c := (b.rect.min + b.rect.max) * 0.5
		d := c - c0
		along := d.x * dir.x + d.y * dir.y            // distance in the arrow direction
		if along <= 1 { continue }
		// distance across it; zero when the two boxes overlap on that axis (same row / same column)
		across: f32
		if dir.x != 0 {
			gap := max(b.rect.min.y - cur.rect.max.y, cur.rect.min.y - b.rect.max.y)
			across = max(gap, 0)
		} else {
			gap := max(b.rect.min.x - cur.rect.max.x, cur.rect.min.x - b.rect.max.x)
			across = max(gap, 0)
		}
		score := along + across * 4
		if score < best_score { best_score = score; best = e.key }
	}
	if best == 0 { return true }   // nothing that way: the key is still ours (do not scroll the page)
	s.focus_key = best
	s.focus_visible = true
	scroll_focus_into_view(s)
	return true
}

@(private)
scroll_focus_into_view :: proc(s: ^State) {
	b := s.boxes[s.focus_key]
	if b == nil { return }
	for p := b.parent; p != nil; p = p.parent {
		if .View_Scroll_Y not_in p.flags { continue }
		margin := b.font_size
		if b.rect.min.y < p.rect.min.y { p.view_target.y -= p.rect.min.y - b.rect.min.y + margin }
		if b.rect.max.y > p.rect.max.y { p.view_target.y += b.rect.max.y - p.rect.max.y + margin }
	}
}

// Hash part of the id of the focused box ("" if none): handy for tests and debugging.
focused_name :: proc() -> string {
	if b, ok := g.boxes[g.focus_key]; ok { return b.name }
	return ""
}