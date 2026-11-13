package ui

import "core:fmt"
import "core:strings"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:time"
import "../base"
import "../draw"
import "../font"
import "../platform"

// The state selected by the last `begin_build` (or `init`, `use`). Public procs operate on it (like raddebugger's `ui_state`), through `gs`.
@(private, thread_local) current: ^State   // (of this thread: several apps of a process build their interfaces on threads of their own)

NO_STATE_MESSAGE :: "ui: no begin_build on this thread"

// The thread's current state. A public proc called on a thread where no begin_build (nor init, use) selected one stops here, saying so,
// instead of crashing further on a nil state: one branch.
@(private)
gs :: #force_inline proc() -> ^State {
	if current == nil { panic(NO_STATE_MESSAGE) }
	return current
}

// The process's clock: the first init starts it, from any thread (atomic), and no later State restarts it.
@(private) tick_origin: time.Tick

init :: proc(s: ^State, fonts: ^font.State, theme: ^Theme) {
	// the state is current from here: an app may read it (scale, font_size, focus...) before its first build, e.g.
	// routing the input of its first frame
	use(s)
	s.fonts = fonts
	s.theme = theme
	s.zoom = 1
	s.layout_warnings = ODIN_DEBUG
	s.scale = 1
	s.toast_pos = .Top_Right
	s.caption_names = WINDOW_BUTTON_NAMES
	s.rounding = 1
	s.density = 1
	set_feel(s, FEEL_DEFAULT)
	s.sb_owner = make(map[Key]Key)
	_ = virtual.arena_init_growing(&s.arena)
	s.boxes = make(map[Key]^Box)
	s.anims = make(map[Key]Animation)
	s.timers = make(map[Key]Timer)
	s.tag_sets = make(map[Key][]string)
	s.qr_codes = make(map[Key]Qr_Cached)
	s.color_memo = make(map[[2]u64]Color)
	s.wrap_cache = make(map[Wrap_Key]Wrap_Entry)
	s.trunc_cache = make(map[Trunc_Key]Trunc_Entry)
	post_init(s)
	_, _ = sync.atomic_compare_exchange_strong(&tick_origin._nsec, 0, time.tick_now()._nsec)
}

// Makes s the state the public procs operate on (a program with several windows, one state each, goes back to a window's
// state after building or drawing another's: begin_build, draw_tree and init select the state they are given). The state
// is the caller's and stays selected until `destroy` forgets it, wherever it lives (rawptr: kept on purpose).
use :: proc(s: ^State) { current = (^State)(rawptr(s)) }

// Frees everything `init` and the builds allocated (the fonts and the theme are the caller's).
destroy :: proc(s: ^State) {
	box_edits_clear(s)
	delete(s.edits)
	draw.damage_memory_destroy(&s.damage)
	task_box_shut(s)  // (first: a task that ends from now on posts nothing to this State)
	post_destroy(s)   // (then: the threads still posting get false from now on)
	for _, b in s.boxes { free(b) }
	for b in s.free_boxes { free(b) }
	delete(s.boxes)
	delete(s.free_boxes)
	delete(s.anims)
	delete(s.wheel_rest)
	delete(s.timers)
	press_data_destroy(s)
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
	delete(s.tag_bases)
	delete(s.events.list)
	delete(s.events.consumed)
	delete(s.typed)
	delete(s.paste.text)
	delete(s.focus_order)
	delete(s.popup_stack)
	delete(s.modal_stack)
	delete(s.modals_open)
	delete(s.modals_built)
	delete(s.list_stack)
	menus_destroy(s)
	platform.chrome_regions_destroy(&s.chrome)
	wrap_cache_destroy(s)
	delete(s.trunc_cache)
	rich_cache_destroy(s)
	for _, m in s.layout_warned { delete(m) }
	delete(s.layout_warned)
	delete(s.lazy_heights)
	delete(s.lazy_columns)
	qr_destroy(s)
	delete(s.lazy_frame)
	find_destroy(s)
	selection_destroy(s)
	a11y_destroy(s)
	delete(s.mouse_events)
	delete(s.last_events)
	virtual.arena_destroy(&s.arena)
	if current == s { current = nil }
	if build_of == s { build_of = nil }   // (destroyed in the middle of a build: there is none to end)
	s^ = {}
}

frame_allocator :: proc() -> mem.Allocator { return virtual.arena_allocator(&gs().arena) }

// The toolkit's clock (ms): the system's, or the one the current state was given (set_clock).
now_ms :: proc() -> f64 { return current != nil ? clock_ms(current) : real_ms() }

// The state's time goes by `clock` (ms, above 0), which its owner moves: every delay of the interface (caret blink, double
// clicks, timers, toasts, tooltips, a scroll bar that hides) and every wake (wake_in_ms, wake_due) follows it. nil: the system's
// clock. A test or a replay is then deterministic, and waits for no time.
set_clock :: proc(s: ^State, clock: ^f64) { s.clock = clock }

@(private) real_ms :: proc() -> f64 { return time.duration_milliseconds(time.tick_since({sync.atomic_load(&tick_origin._nsec)})) }
@(private) clock_ms :: proc(s: ^State) -> f64 { return s.clock != nil ? s.clock^ : real_ms() }

Build_Params :: struct {
	window_size:    Vec2,
	events:         []platform.Event,
	dt:             f32,       // seconds since the previous frame
	animations:     bool,      // false = every transition jumps to its end value
	smooth_scroll:  Smooth_Scroll,   // whether scrolling glides (Follow: as `animations` says)
	dpi_scale:      f32,       // OS scale (dpi / 96); 0 is treated as 1
	base:           Style,     // root style in LOGICAL pixels: font_size, text_pad, radius and pixel sizes are multiplied by dpi_scale * zoom
	disable_zoom:   bool,      // true: ignore Ctrl+wheel and Ctrl +/-/0
	// A paste reads `clipboard_get`, a program's own clipboard (in memory: a test's); nil: the window's, asked without
	// waiting (paste.odin). Either answers in a later build. `clipboard_set` is what a copy writes (window_clipboard_set:
	// the window's).
	clipboard_get:  proc() -> string,
	clipboard_set:  proc(text: string),
	window:         ^platform.Window,   // optional: with an integrated title bar, gets its regions after each build;
	                                    // the clipboard a paste asks when clipboard_get is nil
	frame_ms:       f64,                // optional: the frame's time in ms (a display clock: when it will be shown);
	                                    // scroll animations are sampled on it. 0: now_ms()
	time_ms:        f64,                // optional: the build's clock in ms (caret blink, double clicks, timers, toasts,
	                                    // hover delays). 0: the state's clock (set_clock, else the system's)
	inactive:       bool,               // the window is not the one the user is in (an application with several windows):
	                                    // the caret of a focused text field is not drawn and does not blink (inactive())
}

// Build_Params.clipboard_set of the system's clipboard, for the window of the build being made (Build_Params.window):
// what a program would otherwise keep a global for, the procedure taking no argument.
window_clipboard_set :: proc(text: string) {
	if current != nil && current.window != nil { platform.set_clipboard(current.window, text) }
}

// The state whose build is open on this thread (between begin_build and the end of end_build), nil when none is.
@(private, thread_local) build_of: ^State

// True between begin_build and end_build. An app whose window procedure makes frames (platform: on_frame, inside a
// loop of the system) asks this before building one: a build begun inside another empties its parent stack, frees its
// frame arena and selects another state under it.
building :: proc() -> bool { return build_of != nil }

// The state whose build is open on this thread (nil outside a build): what a widget that works on other threads keeps,
// to post to it (ui.post) when its work ends.
current_state :: proc() -> ^State { return build_of }

// The time of what a call does: the open build's clock (Build_Params.time_ms), else the state's. What a build compares with
// its own time (an edit, a toast) takes this.
@(private)
build_now_ms :: proc() -> f64 { return build_of != nil && build_of == current ? current.time_ms : now_ms() }

// The window being built is not the one the user is in (Build_Params.inactive): a widget that shows a caret or a focus
// highlight that only the user's window shows reads this.
inactive :: proc() -> bool { return current != nil && current.inactive }

begin_build :: proc(s: ^State, p: Build_Params) {
	base.interface_thread_mark()   // (from now on, a call of the toolkit that blocks on this thread is said: base.blocking)
	// (a frame made from a message pumped during a build: a loop of the system such as TrackPopupMenu, a modal dialog)
	assert(build_of == nil, "ui: begin_build inside another build")
	build_of = s
	use(s)
	s.build_index += 1
	s.build_start = real_ms()
	clear(&s.last_events)
	append(&s.last_events, ..p.events)
	s.metrics.lazy_built = 0
	selection_snapshot(s)
	// what the last build's boxes hold of its arena goes with it: a box looked up during this build has none
	for _, b in s.boxes { b.text, b.name, b.a11y, b.custom_user = "", "", nil, nil }
	virtual.arena_free_all(&s.arena)
	clear(&s.parent_stack); clear(&s.style_stack); clear(&s.tag_stack); clear(&s.tag_marks); clear(&s.tag_keys)
	clear(&s.tag_bases); s.tag_base = 0
	clear(&s.tag_sets); clear(&s.color_memo)
	clear(&s.disabled_stack); s.disabled_depth = 0
	clear(&s.tab_stops_off); s.tab_skip = 0
	clear(&s.focus_order)
	s.modals_open, s.modals_built = s.modals_built, s.modals_open
	clear(&s.modals_built)
	s.find.waiting = false
	s.bar_keys, s.bar_keys_prev = s.bar_keys_prev, s.bar_keys
	clear(&s.bar_keys)
	s.has_next = false
	s.next_mod = {}
	s.window_size = p.window_size
	s.dt = p.dt
	s.anim_rate = p.animations ? 1 : 0
	s.scroll_smooth = p.smooth_scroll == .On || (p.smooth_scroll == .Follow && p.animations)
	s.anim_busy = false
	s.wake_ms = 0
	s.menu_close_pending = false
	s.toast_area_set = false
	s.boxes_built = 0
	s.virtual_depth = 0
	s.time_ms = p.time_ms > 0 ? p.time_ms : clock_ms(s)
	left := p.inactive && !s.inactive
	s.inactive = p.inactive
	s.frame_ms = p.frame_ms > 0 ? p.frame_ms : s.time_ms
	if s.theme != nil && s.theme.serial != s.theme_serial {
		// another palette (not the first one): every colour cross-fades to it for a moment
		if s.theme_serial != 0 { s.fade_until_ms = s.time_ms + f64(s.feel.palette_fade_ms) }
		s.theme_serial = s.theme.serial
	}
	s.clipboard_get = p.clipboard_get
	s.clipboard_set = p.clipboard_set
	s.cursor_request = .Arrow
	s.window = p.window
	s.caption_keys = {}
	s.caption_built = false

	// calls posted from other threads change the app's data before the frame reads it (post.odin)
	post_begin_build(s, p.window)
	paste_begin_build(s, p.events)
	selection_begin(s)
	process_events(s, p.events, !p.disable_zoom, left)
	a11y_begin_build(s, p.window)   // (after the input: a click asked by a screen reader is this build's click)
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
	s := build_of
	assert(s != nil, "ui: end_build with no build open")
	use(s)   // (whatever was selected since: this is the build that ends)
	pop(&s.parent_stack)
	assert(len(s.parent_stack) == 0, "ui: unbalanced parent push/pop")
	assert(len(s.tag_marks) == 0, "ui: unbalanced tags push/pop")
	assert(len(s.popup_stack) == 0, "ui: unbalanced popup scopes")
	assert(len(s.style_stack) == 1, "ui: unbalanced style push/pop")
	assert(len(s.disabled_stack) == 0, "ui: unbalanced disabled scopes")
	assert(len(s.tab_stops_off) == 0, "ui: unbalanced tab_stops scopes")
	assert(len(s.modal_stack) == 0, "ui: unbalanced modal scopes")
	assert(len(s.list_stack) == 0, "ui: unbalanced list scopes")
	assert(len(s.menu_build) == 0, "ui: unbalanced menu scopes")

	menus_raise(s)
	if len(s.edits) > 0 { box_edits_apply(s) }
	t_layout := real_ms()
	s.metrics.build_ms = t_layout - s.build_start
	layout(s)
	lazy_settle(s)   // (the view stays on what it showed: before anything reads the rects)
	s.metrics.layout_ms = real_ms() - t_layout
	// the title bar's regions: for the window when its title bar is integrated, for chrome_regions in any case
	if s.caption_built || s.caption_keys != {} {
		chrome_collect(s)
	} else if len(s.chrome.caption) > 0 || s.chrome.buttons != {} {
		chrome_collect(s)   // none any more (full screen bars hidden...): the window forgets the last ones
	}
	wrap_cache_trim(s)
	trunc_cache_trim(s)
	rich_cache_trim(s)
	lazy_trim(s)
	qr_trim(s)
	menu_prune(s)
	boxes_gone(s)
	press_data_sweep(s)   // (a press whose box went: what it kept with it)
	paste_end_build(s)
	selection_update(s)
	modals_settle(s)
	handle_tab_navigation(s)
	find_collect(s)     // (the rects are final, with the scroll they were laid out at: update_animations moves it)
	update_animations(s)
	a11y_end_build(s)   // (after the focus moved and the rects are final)

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
	// timers nobody asked about for a long while (their widget is gone), and scrollbars of scroll boxes that are gone
	clear(&dead)
	for k, t in s.timers { if t.last_build + TIMER_KEEP_BUILDS < s.build_index { append(&dead, k) } }
	for k in dead { delete_key(&s.timers, k) }
	clear(&dead)
	for k, owner in s.sb_owner { if owner not_in s.boxes { append(&dead, k) } }
	for k in dead { delete_key(&s.sb_owner, k) }

	// per-frame input state is consumed
	s.scroll_delta = {}
	for b in platform.Mouse_Button {
		s.pressed_key[b] = 0
		s.pressed_any[b] = false
		s.released_key[b] = 0
		s.clicked_key[b] = 0
	}
	s.a11y.pressed = 0
	s.double_key = 0
	s.caption_clicked = false
	s.metrics.total_ms = real_ms() - s.build_start
	build_of = nil
}

// True while something is still animating, or posted calls wait beyond the last build's budget: the app loop should
// keep rendering.
needs_frame :: proc(s: ^State) -> bool { return s.anim_busy || s.posts_more || s.lazy_more || s.find.waiting }
wake_ms :: proc(s: ^State) -> int { return s.wake_ms }

// wake_in_ms rounds up to whole milliseconds; wake_due counts a wake this close as due (a sleep rounds to whole ms).
@(private) WAKE_ROUND_UP_MS :: 0.999
@(private = "file") WAKE_DUE_SLACK_MS :: 0.5
// Added to a delay when asking for a wake: one that came a little early would wait again.
@(private) WAKE_MARGIN_MS :: 5

// The timed wake the last build asked for, measured from now: ms left until it is due (at least 1), 0 when none was
// asked. Use it as the loop's wait timeout: wake_ms counts from the build, and a loop woken early by a message (a
// program resizing the window sends WM_SIZING at every step) would otherwise wait the whole delay again.
wake_in_ms :: proc(s: ^State) -> int {
	if s.wake_ms == 0 { return 0 }
	return max(int(f64(s.wake_ms) - (clock_ms(s) - s.time_ms) + WAKE_ROUND_UP_MS), 1)
}

// Whether the timed wake the last build asked for is due now (a caret blink, a tooltip delay): a wake of the loop for
// anything else before it (a message) has no frame to make for the interface.
wake_due :: proc(s: ^State) -> bool { return s.wake_ms != 0 && clock_ms(s) - s.time_ms >= f64(s.wake_ms) - WAKE_DUE_SLACK_MS }

// Asks for a wake within `ms` milliseconds (the soonest of all the requests of a build stands: a caret blink and a tooltip
// delay both count).
wake_within :: proc(s: ^State, ms: int) { s.wake_ms = s.wake_ms == 0 ? ms : min(s.wake_ms, ms) }
cursor :: proc(s: ^State) -> platform.Cursor { return s.cursor_request }
boxes_built :: proc(s: ^State) -> int { return s.boxes_built }

// Density: row heights and vertical gaps are multiplied by it (text keeps its size). Built-in widgets and
// vertical spacers follow it; use `dense` for your own row heights.
DENSITY_COMPACT :: 0.78
DENSITY_MIN :: 0.6
DENSITY_MAX :: 1.2
density :: proc(s: ^State) -> f32 { return s.density }
set_density :: proc(s: ^State, d: f32) { s.density = clamp(d, DENSITY_MIN, DENSITY_MAX) }
dense :: proc(v: f32) -> f32 { return math.round(v * gs().density) }

// The interface's zoom stays within these; a step of it is Feel.zoom_step.
ZOOM_MIN :: 0.5
ZOOM_MAX :: 3.0

zoom :: proc(s: ^State) -> f32 { return s.zoom }
set_zoom :: proc(s: ^State, z: f32) { s.zoom = clamp(z, ZOOM_MIN, ZOOM_MAX) }
// dpi scale * zoom: multiply your own pixel constants by this (ui.font_size() and the base style already include it)
scale :: proc() -> f32 { return gs().scale }
// Same, for a given state (an app with several windows, or one drawing outside a build: the autoscroll marker).
scale_of :: proc(s: ^State) -> f32 { return s.scale }

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
	b.virtual = s.virtual_depth > 0
	return b
}

// A box of the last build that this one did not make. Not one never built: a focus may be given ahead of its box.
@(private)
box_gone :: proc(s: ^State, key: Key) -> bool {
	b := s.boxes[key] if key != 0 else nil
	return b != nil && b.last_build != s.build_index
}

// What holds a box by its key lets go of it here, once the build said which boxes stand (end_build): a press, the focus,
// a click that may become a double one, the link of a paragraph. A box of that key built later is another box.
@(private)
boxes_gone :: proc(s: ^State) {
	for &key, button in s.active_key {
		held := s.sb_owner[key] or_else key   // (a scroll bar is no box: its scroll box says)
		if !box_gone(s, held) { continue }
		if button == .Left { s.release_owed = key }
		key = 0
	}
	if b := s.boxes[s.release_owed] if s.release_owed != 0 else nil; b != nil && b.last_build == s.build_index { s.release_owed = 0 }
	// (a box of a virtual list or a lazy column has only left the built range: the focus waits for it there)
	if box_gone(s, s.focus_key) && !s.boxes[s.focus_key].virtual { s.focus_key = 0 }
	if box_gone(s, s.last_click_key) { s.last_click_key = 0 }
	if len(s.rich_link) == 0 { return }
	dead := make([dynamic]Key, context.temp_allocator)
	for k in s.rich_link { if k not_in s.boxes || box_gone(s, k) { append(&dead, k) } }
	for k in dead { delete_key(&s.rich_link, k) }
}

box_from_key :: proc(key: Key) -> ^Box {
	if b, ok := gs().boxes[key]; ok { return b }
	return nil
}

// The box of the last build at this path of ids from the root (each id as it was given to build_box, a scroll box or a
// row: "###chat", "###col", ...), nil when there is none. For tests and tools: a box found from outside a build.
box_at :: proc(ids: ..string) -> ^Box {
	if current == nil || current.root == nil { return nil }
	k := gs().root.key
	for id in ids { k = key_from_string(k, id) }
	return box_from_key(k)
}

parent_box :: proc() -> ^Box { return gs().parent_stack[len(gs().parent_stack) - 1] }

top_style :: proc() -> ^Style { return &gs().style_stack[len(gs().style_stack) - 1] }

font_size :: proc() -> f32 { return top_style().font_size }

// Mixed into a key that another box of this build already holds.
@(private = "file") KEY_SIBLING_SALT :: 0xdeadbeef
// A disabled box keeps a fill or a border this transparent as it is (a ghost button stays see-through).
@(private = "file") DISABLED_NEUTRAL_MIN_ALPHA :: 0.01
// A colour this close to its target (each channel) jumps there and the fade ends.
@(private = "file") COLOR_SETTLED_EPS :: 0.002

// Builds a box under the current parent. `id` follows the id-string rules in key.odin ("" = anonymous, keyed by position).
build_box :: proc(flags: Box_Flags, id: string = "") -> ^Box {
	s := gs()
	parent := parent_box()
	key: Key
	if id == "" { key = key_from_u64(parent.key, u64(parent.child_count) + HASH_GOLDEN_RATIO_64) } else { key = key_from_string(parent.key, id) }
	// two siblings with the same id would share state: keep going until the key is free for this build
	for {
		if existing, ok := s.boxes[key]; ok && existing.last_build == s.build_index {
			key = key_from_u64(key, KEY_SIBLING_SALT)
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
	selection_note(s, b)
	b.name = ""
	if id != "" { b.name = strings.clone(hash_part(id), frame_allocator()) }
	b.pref = st.pref
	b.layout_axis = axis
	b.cross = cross
	b.gap = {}
	if has_mod { if v, ok := mod.gap.?; ok { b.gap = v } }
	b.edge_fade = {}
	if has_mod { if v, ok := mod.edge_fade.?; ok { b.edge_fade = v } }
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
	b.measure_y = nil
	b.slant = {}
	b.hit_outset = 0
	b.a11y = nil
	if s.a11y.has_next {
		b.a11y = new_clone(s.a11y.next, frame_allocator())
		s.a11y.has_next = false
	}
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
		b.text = strings.clone(disp, frame_allocator())
		m := font.metrics(s.fonts, b.font, b.font_size)
		b.text_dim = {font.text_width(s.fonts, b.font, b.font_size, b.text), m.line_height}
	}

	// colors: theme targets (or explicit overrides), animated toward the targets
	b.tags_key = current_tags_key(s)
	b.target_bg = color("background")
	b.target_border = color("border")
	b.target_text = color("text")
	// under the pointer: "hot text" (the theme's "<tags> hot text" when it has one, else the plain text colour)
	if .Clickable in b.flags && s.hot_key == b.key && .Disabled not_in b.flags { b.target_text = color("hot text") }
	if has_mod {
		if c, ok := mod.bg.?; ok { b.target_bg = c }
		if c, ok := mod.border.?; ok { b.target_border = c }
		if c, ok := mod.fg.?; ok { b.target_text = c }
	}
	if .Disabled in b.flags {
		// neutral look: an accent or danger fill would keep its colour while its text faded away
		plain := []string{"button"}
		if b.target_bg.a > DISABLED_NEUTRAL_MIN_ALPHA { b.target_bg = theme_lookup(s.theme, plain, "background") }
		if b.target_border.a > DISABLED_NEUTRAL_MIN_ALPHA { b.target_border = theme_lookup(s.theme, plain, "border") }
		b.target_text = theme_lookup(s.theme, nil, "weak text")
	}
	// colours jump to their targets (states show at once), except while a palette change cross-fades or when the theme
	// asks for transitions
	fading := s.time_ms < s.fade_until_ms || (s.theme != nil && s.theme.transition_ms > 0)
	if b.first_build == s.build_index || s.anim_rate == 0 || !fading {
		b.bg, b.border, b.text_color = b.target_bg, b.target_border, b.target_text
	} else {
		rate := state_rate(s)
		busy := false
		approach :: proc(cur: ^Color, target: Color, rate: f32, busy: ^bool) {
			d: f32
			for i in 0 ..< 4 { d = max(d, abs(target[i] - cur[i])) }
			if d < COLOR_SETTLED_EPS { cur^ = target; return }
			cur^ += (target - cur^) * rate
			busy^ = true
		}
		approach(&b.bg, b.target_bg, rate, &busy)
		approach(&b.border, b.target_border, rate, &busy)
		approach(&b.text_color, b.target_text, rate, &busy)
		if busy { s.anim_busy = true }
	}

	if .Focusable in b.flags && .Disabled not_in b.flags && s.tab_skip == 0 {
		append(&s.focus_order, Focus_Entry{key = b.key, modal = len(s.modal_stack) > 0 ? s.modal_stack[len(s.modal_stack) - 1].order : 0})
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
	append(&gs().style_stack, st)
	return true
}

pop_style :: proc() { pop(&gs().style_stack) }

// Override the style for the next box only (also the only way to set `axis`, `fixed_*`, `bg`, `border`, `fg`).
next :: proc(m: Style_Mod) {
	gs().next_mod = m
	gs().has_next = true
}

// A widget that builds nothing this frame (a closed dialog, a skipped item): what `next` and `a11y` said was for its box,
// not for the one after it.
@(private)
next_drop :: proc(s: ^State) {
	s.has_next = false
	s.next_mod = {}
	s.a11y.has_next = false
}

@(deferred_none = pop_parent)
parent :: proc(b: ^Box) -> bool {
	append(&gs().parent_stack, b)
	return true
}

pop_parent :: proc() { pop(&gs().parent_stack) }

// `if tags("card", "accent") { ... }`: push theme tags for the block.
@(deferred_none = pop_tags)
tags :: proc(names: ..string) -> bool {
	push_tags(..names)
	return true
}

push_tags :: proc(names: ..string) {
	s := gs()
	append(&s.tag_marks, len(s.tag_stack))
	for n in names {
		append(&s.tag_stack, n)
		append(&s.tag_keys, key_from_string(len(s.tag_keys) > s.tag_base ? s.tag_keys[len(s.tag_keys) - 1] : 0, n))
	}
	push_tags_key(s)
}

// Tags that start afresh: what is built until pop_tags_isolated wears these alone, not the tags around it (a menu
// opened from inside a field is a menu, not a field's).
push_tags_isolated :: proc(names: ..string) {
	s := gs()
	append(&s.tag_bases, s.tag_base)
	s.tag_base = len(s.tag_stack)
	push_tags(..names)
}

pop_tags_isolated :: proc() {
	s := gs()
	pop_tags()
	s.tag_base = pop(&s.tag_bases)
}

pop_tags :: proc() {
	s := gs()
	mark := pop(&s.tag_marks)
	resize(&s.tag_stack, mark)
	resize(&s.tag_keys, mark)
}

@(private)
current_tags_key :: proc(s: ^State) -> Key {
	if len(s.tag_keys) <= s.tag_base { return 0 }
	k := s.tag_keys[len(s.tag_keys) - 1]
	if _, ok := s.tag_sets[k]; !ok {
		cp := make([]string, len(s.tag_stack) - s.tag_base, frame_allocator())
		copy(cp, s.tag_stack[s.tag_base:])
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
	push_disabled(cond)
	return true
}

@(private)
push_disabled :: proc(cond: bool) {
	append(&gs().disabled_stack, cond)
	if cond { gs().disabled_depth += 1 }
}

pop_disabled :: proc() {
	if pop(&gs().disabled_stack) { gs().disabled_depth -= 1 }
}

// `if tab_stops(false) { ... }`: the widgets built in the block are no Tab stops (Tab and the arrow keys skip them);
// they still take the focus when clicked or through set_focus. For rows of a list whose editors only the active row
// should offer, and the like. Scopes nest; `tab_stops(true)` changes nothing.
@(deferred_none = pop_tab_stops)
tab_stops :: proc(on: bool) -> bool {
	append(&gs().tab_stops_off, !on)
	if !on { gs().tab_skip += 1 }
	return true
}

pop_tab_stops :: proc() {
	if pop(&gs().tab_stops_off) { gs().tab_skip -= 1 }
}

// `if muted() { ... }`: secondary content, drawn with the theme's weak text colour. Still interactive (see `disabled`).
@(deferred_none = pop_tags)
muted :: proc() -> bool {
	push_tags("weak")
	return true
}

////////////////////////////////
// Animation helper

ANIM_RATE_DEFAULT :: 40
@(private = "file") ANIM_SETTLED_EPS :: 0.001

// Eases a persistent value toward `target`. `rate` is "halvings per second of distance" (higher = faster).
anim :: proc(key: Key, target: f32, rate: f32 = ANIM_RATE_DEFAULT, initial: Maybe(f32) = nil) -> f32 {
	s := gs()
	a, found := s.anims[key]
	if !found { a.value = initial.? or_else target }
	a.last_build = s.build_index
	if s.anim_rate == 0 {
		a.value = target
	} else {
		d := target - a.value
		if abs(d) < ANIM_SETTLED_EPS { a.value = target } else {
			a.value += d * f32(1 - math.pow(2, -f64(rate) * f64(s.dt)))
			s.anim_busy = true
		}
	}
	s.anims[key] = a
	return a.value
}

// Goes to `target` in `ms`, leaving and arriving gently (a smoothstep): for what the eye follows from end to end, where anim's first
// step, its largest, looks like a jolt. A new target sets off from where the value is, for the whole time. It asks for frames while it
// moves; 0 ms, or animations off: at once.
tween :: proc(key: Key, target: f32, ms: f32, initial: Maybe(f32) = nil) -> f32 {
	s := gs()
	a, found := s.anims[key]
	if !found {
		a.value = initial.? or_else target
		a.from, a.to = a.value, a.value
	}
	a.last_build = s.build_index
	if s.anim_rate == 0 || ms <= 0 {
		a.value, a.from, a.to = target, target, target
	} else if target != a.to {
		a.from, a.to, a.elapsed_s = a.value, target, 0   // (this frame is its start: the time since the last one is not part of it)
		s.anim_busy = true
	} else if a.value != a.to {
		a.elapsed_s += s.dt
		p := min(a.elapsed_s * 1000 / ms, 1)
		a.value = p >= 1 ? a.to : a.from + (a.to - a.from) * p * p * (3 - 2 * p)
		s.anim_busy = true
	}
	s.anims[key] = a
	return a.value
}

// Whether the window animates: false when the desktop asks for less motion (Build_Params.animations). A program's own
// motion (a row that flashes, a value that pulses) asks it first.
animations_on :: proc() -> bool { return gs().anim_rate != 0 }

// Asks for the next frame: a program's own animation, drawn from the clock (now_ms), is still moving.
keep_animating :: proc() { gs().anim_busy = true }

// The cross-fade's halvings per second; log2(20): the halvings that cover 95 % of the way.
@(private = "file") PALETTE_FADE_HALVINGS_PER_S :: 60
@(private = "file") TRANSITION_HALVINGS :: 4.32

// Per-frame approach rate of colours and state values: the theme's transition (about 95 % of the way in
// transition_ms), else the cross-fade of a palette change; 1 (at once) with animations off.
@(private)
state_rate :: proc(s: ^State) -> f32 {
	if s.anim_rate == 0 { return 1 }
	halvings: f64 = PALETTE_FADE_HALVINGS_PER_S
	if s.theme != nil && s.theme.transition_ms > 0 { halvings = TRANSITION_HALVINGS * 1000 / f64(s.theme.transition_ms) }
	return f32(1 - math.pow(2, -halvings * f64(s.dt)))
}

// A state value (hot_t, focus_t...) this close to its target jumps there.
@(private = "file") STATE_SETTLED_EPS :: 0.003

@(private)
update_animations :: proc(s: ^State) {
	// hover, press, focus and disabled: at once unless the theme asks for transitions
	rate: f32 = 1
	if s.theme != nil && s.theme.transition_ms > 0 { rate = state_rate(s) }
	step :: proc(cur: ^f32, target: f32, rate: f32, busy: ^bool) {
		d := target - cur^
		if abs(d) < STATE_SETTLED_EPS || rate >= 1 { cur^ = target; return }
		cur^ += d * rate
		busy^ = true
	}
	autoscroll_apply(s)   // middle-click autoscroll sets its box's view_target before the ease below (autoscroll_region.odin)
	// the hot box and its ancestors (for .Hot_Within boxes)
	chain: [HOT_ANCESTORS_MAX]Key
	n := 0
	if hb := s.boxes[s.hot_key] if s.hot_key != 0 else nil; hb != nil && hb.last_build == s.build_index {
		for p := hb; p != nil && n < len(chain); p = p.parent { chain[n] = p.key; n += 1 }
	}
	// the focused box and its ancestors (for .Focus_Within boxes)
	fchain: [HOT_ANCESTORS_MAX]Key
	fn := 0
	if fb := s.boxes[s.focus_key] if s.focus_key != 0 else nil; fb != nil && fb.last_build == s.build_index {
		for p := fb; p != nil && fn < len(fchain); p = p.parent { fchain[fn] = p.key; fn += 1 }
	}
	for _, b in s.boxes {
		if b.last_build != s.build_index { continue }
		hot: f32 = s.hot_key == b.key ? 1 : 0
		if .Hot_Within in b.flags && hot == 0 {
			for k in chain[:n] { if k == b.key { hot = 1; break } }
		}
		active: f32 = s.active_key[.Left] == b.key ? 1 : 0
		focus: f32 = s.focus_key == b.key ? 1 : 0
		if .Focus_Within in b.flags && focus == 0 {
			for k in fchain[:fn] { if k == b.key { focus = 1; break } }
		}
		disabled: f32 = .Disabled in b.flags ? 1 : 0
		step(&b.hot_t, hot, rate, &s.anim_busy)
		step(&b.active_t, active, rate, &s.anim_busy)
		step(&b.focus_t, focus, rate, &s.anim_busy)
		step(&b.disabled_t, disabled, rate, &s.anim_busy)
		if s.scrollbar_autohide && b.flags & {.View_Scroll_Y, .View_Scroll_X, .Scroll_Self} != {} { step(&b.bar_t, scrollbar_shown(s, b) ? 1 : 0, rate, &s.anim_busy) }

		// scrolling: the offset follows the (clamped) target (scroll_anim.odin)
		for axis in Axis {
			scroll_flag := axis == .X ? Box_Flag.View_Scroll_X : Box_Flag.View_Scroll_Y
			if scroll_flag not_in b.flags { continue }
			b.view_target[int(axis)] = clamp(b.view_target[int(axis)], 0, view_limit(b, axis))
			if b.view_target[int(axis)] != 0 { b.view_top_held[int(axis)] = false }   // (moved off the start since view_top)
			scroll_step(s, b, int(axis))
		}
	}
}

// Prints every box taller than `limit` px (id text, size, pref kinds): layout debugging aid.
debug_dump_tall :: proc(s: ^State, limit: f32) {
	use(s)
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
	s.tab_dir, s.tab_dir_next = s.tab_dir_next, 0
	handle_arrow_navigation(s)
	dir := 0
	// (the focus moves among the stops of the dialog on top: its keys, read at the end of the build, outside its scope)
	if key_press_any(.Tab) { dir = 1 } else if key_press_any(.Tab, {.Shift}) { dir = -1 }
	if dir == 0 || len(s.focus_order) == 0 { return }
	stops := focus_stops(s)
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
	stops := focus_stops(s)
	n := len(stops)
	if n == 0 { return }
	cur := -1
	for k, i in stops { if k == from { cur = i; break } }
	next: int
	if cur < 0 { next = dir > 0 ? 0 : n - 1 } else { next = (cur + (dir > 0 ? 1 : -1) + n) % n }
	s.focus_key = stops[next]
	s.focus_visible = true
	// (tab_direction speaks of the next build: one open now ends before it)
	if build_of == s { s.tab_dir_next = dir > 0 ? 1 : -1 } else { s.tab_dir = dir > 0 ? 1 : -1 }
}

// The dialog that has the keyboard: the last one built that has a Tab stop (0: the page).
@(private)
focus_modal :: proc(s: ^State) -> int {
	top := 0
	for e in s.focus_order { top = max(top, e.modal) }
	return top
}

// The Tab stops of the last build, in order: those of the dialog on top when there is one, else the others.
@(private)
focus_stops :: proc(s: ^State) -> [dynamic]Key {
	top := focus_modal(s)
	stops := make([dynamic]Key, 0, len(s.focus_order), context.temp_allocator)
	for e in s.focus_order { if e.modal == top { append(&stops, e.key) } }
	return stops
}

// How much a pixel across the arrow's direction counts against a stop, next to a pixel along it.
@(private = "file") ARROW_ACROSS_WEIGHT :: 4

@(private)
handle_arrow_navigation :: proc(s: ^State) -> bool {
	if s.focus_key == 0 || len(s.menus) > 0 || len(s.focus_order) == 0 { return false }
	cur := s.boxes[s.focus_key]
	if cur == nil || cur.last_build != s.build_index || .Text_Input in cur.flags { return false }
	dir: Vec2
	switch {
	case key_press_any(.Left):  dir = {-1, 0}
	case key_press_any(.Right): dir = {1, 0}
	case key_press_any(.Up):    dir = {0, -1}
	case key_press_any(.Down):  dir = {0, 1}
	case: return false
	}
	top := focus_modal(s)
	c0 := (cur.rect.min + cur.rect.max) * 0.5
	best: Key
	best_score := max(f32)
	for e in s.focus_order {
		if e.modal != top || e.key == cur.key { continue }
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
		score := along + across * ARROW_ACROSS_WEIGHT
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
		view_reveal_box(p, b, margin = b.font_size)
	}
}

// Hash part of the id of the focused box ("" if none): handy for tests and debugging. A box that has not been built yet
// in the build under way has none: its name lives in the arena of the build that made it, which is freed at the start of
// the next one.
focused_name :: proc() -> string {
	s := gs()
	if b, ok := s.boxes[s.focus_key]; ok && b.last_build == s.build_index { return b.name }
	return ""
}