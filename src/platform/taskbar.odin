package platform

// A window's taskbar button (src/md/features/taskbar.md): a progress, a count and attention, one call per part. Each call
// sets one part of Window.taskbar; a call that changes nothing does nothing and answers false. The backends read the whole
// state when they apply it (taskbar_windows.odin, taskbar_linux.odin, taskbar_other.odin), so the state is never kept
// twice.
//
//   platform.taskbar_progress(w, .Normal, 0.4)
//   ui.taskbar_badge(w, 3, "3 sessions are waiting for you")
//   platform.taskbar_attention(w, true)

import "core:fmt"
import "core:math"
import "core:strings"
import "../ascii"
import "../dbus"
import i18n "../i18n"

// The state of a progress on the button. Windows draws each one (normal green, paused yellow, error red, indeterminate
// a moving band); Linux docks show Normal, Paused and Error as one bar and Indeterminate not at all.
Taskbar_Progress :: enum u8 { None, Normal, Paused, Error, Indeterminate }

// The steps of a progress's fraction: a fraction is kept in thousandths, so a progress told at each byte calls the system
// at most this many times.
TASKBAR_STEPS :: 1000

// The disc of a count when the program gives no colour: the red of Windows' own badges.
TASKBAR_BADGE_RED :: u32(0xC42B1C)

// What a window shows on its button (Window.taskbar; taskbar_state).
Taskbar_State :: struct {
	progress:  Taskbar_Progress,
	done:      int,      // the fraction in TASKBAR_STEPS; 0 unless the progress is Normal, Paused or Error
	count:     int,      // 0: no count
	words:     string,   // what a screen reader says of the count (owned); "" until a count is given
	accent:    u32,      // the count's disc, 0xRRGGBB
	attention: bool,
	flashes:   int,      // Windows: how many flashes the attention asked (0: until the window is active)
}

// The parts of the state a backend applies.
@(private) Taskbar_Part :: enum u8 { Progress, Badge, Attention }
@(private) Taskbar_Parts :: bit_set[Taskbar_Part; u8]

// Shows a progress on the window's button. `fraction` (0 to 1) counts for Normal, Paused and Error. False when the button
// already showed it: nothing was asked of the system.
taskbar_progress :: proc(w: ^Window, state: Taskbar_Progress, fraction: f32 = 0) -> (changed: bool) {
	if w == nil { return false }
	taskbar_progress_step(&w.taskbar, state, fraction) or_return
	taskbar_apply(w, {.Progress})
	return true
}

// Shows `count` on the window's button (0 takes it away). `words` is what a screen reader says of it ("3 sessions are
// waiting for you"; "": the toolkit's "3 waiting"). `accent`: the disc's colour where the toolkit draws it (Windows);
// ui.taskbar_badge gives the theme's. False when the button already showed it.
taskbar_badge :: proc(w: ^Window, count: int, words := "", accent := TASKBAR_BADGE_RED) -> (changed: bool) {
	if w == nil { return false }
	taskbar_badge_step(&w.taskbar, count, words, accent) or_return
	taskbar_apply(w, {.Badge})
	return true
}

// Asks the person to look at the window (on), or stops asking (off). It ends by itself when the window becomes active.
// `flashes` (Windows): flash that many times, then keep the button lit; 0 flashes until the window is active. False when
// nothing changed, or when the window is active already: there is nothing to draw the eyes to.
taskbar_attention :: proc(w: ^Window, on: bool, flashes := 0) -> (changed: bool) {
	if w == nil { return false }
	taskbar_attention_step(&w.taskbar, on, flashes, w.active) or_return
	taskbar_apply(w, {.Attention})
	return true
}

// Tests: an offscreen window's taskbar calls go out as a shown window's do (Linux: the launcher entry on the thread's
// session bus). Off by default: a program's tests that call ui.taskbar_badge at each build would put their count in the
// developer's own dock. Windows: an offscreen window has no button either way.
taskbar_offscreen_entry :: proc(w: ^Window, on: bool) {
	if w != nil && w.offscreen { w.taskbar_offscreen_entry = on }
}

// What the window's button shows (its words valid until the next change).
taskbar_state :: proc(w: ^Window) -> Taskbar_State {
	return w == nil ? {} : w.taskbar
}

// The words a screen reader says of a count: the program's, else the toolkit's (temp memory).
taskbar_badge_words :: proc(s: Taskbar_State) -> string {
	if s.count <= 0 { return "" }
	if s.words != "" { return s.words }
	return fmt.tprintf(i18n.tr(s.count, "%d waiting", "%d waiting"), s.count)
}

@(private)
taskbar_progress_step :: proc(s: ^Taskbar_State, state: Taskbar_Progress, fraction: f32) -> (changed: bool) {
	done := 0
	#partial switch state {
	case .Normal, .Paused, .Error:
		f := math.is_nan(fraction) ? 0 : clamp(fraction, 0, 1)
		done = int(math.round(f * TASKBAR_STEPS))
	}
	if s.progress == state && s.done == done { return false }
	s.progress, s.done = state, done
	return true
}

@(private)
taskbar_badge_step :: proc(s: ^Taskbar_State, count: int, words: string, accent: u32) -> (changed: bool) {
	n := max(count, 0)
	said := n > 0 ? words : ""
	disc := accent & 0xFFFFFF
	if s.count == n && s.words == said && (n == 0 || s.accent == disc) { return false }
	delete(s.words)
	s.count, s.words, s.accent = n, strings.clone(said), disc
	return true
}

@(private)
taskbar_attention_step :: proc(s: ^Taskbar_State, on: bool, flashes: int, active: bool) -> (changed: bool) {
	if on && active { return false }
	times := on ? max(flashes, 0) : 0
	if s.attention == on && s.flashes == times { return false }
	s.attention, s.flashes = on, times
	return true
}

// The window became active: its attention is over (the backends' focus calls it).
@(private)
taskbar_focused :: proc(w: ^Window) {
	if !w.taskbar.attention { return }
	w.taskbar.attention, w.taskbar.flashes = false, 0
	taskbar_apply(w, {.Attention})
}

// The window is going: what it showed is taken away, its words freed.
@(private)
taskbar_end :: proc(w: ^Window) {
	taskbar_detach(w)
	delete(w.taskbar.words)
	w.taskbar = {}
}

////////////////////////////////
// The count's picture (Windows' overlay icon)

// A count as a picture `size` pixels square, RGBA with straight alpha: a disc in `accent` (0xRRGGBB) and the number in
// white or black, the one with the higher contrast on it. 1 to 99 are written, 100 and more are a plus sign. nil for 0.
// Pure: the backends and the tests call it.
taskbar_badge_pixels :: proc(count: int, size: int, accent: u32, allocator := context.allocator) -> []u8 {
	if count <= 0 || size <= 0 { return nil }
	out := make([]u8, size * size * 4, allocator)
	disc := [3]f32{f32(accent >> 16 & 0xFF), f32(accent >> 8 & 0xFF), f32(accent & 0xFF)}
	ink := taskbar_badge_ink(accent)
	inkf := [3]f32{f32(ink >> 16 & 0xFF), f32(ink >> 8 & 0xFF), f32(ink & 0xFF)}

	// the glyphs: their strokes in a box of 1 by 1, laid side by side and centred
	glyphs: [2]int
	n := 0
	switch {
	case count < 10:  glyphs[0], n = count, 1
	case count < 100: glyphs[0], glyphs[1], n = count / 10, count % 10, 2
	case:             glyphs[0], n = BADGE_PLUS, 1
	}
	s := f32(size)
	gh := s * (n == 1 ? BADGE_GLYPH_HEIGHT_ONE : BADGE_GLYPH_HEIGHT_TWO)
	gw := gh * BADGE_GLYPH_ASPECT
	if glyphs[0] == BADGE_PLUS { gw = gh }
	gap := gh * BADGE_GLYPH_GAP
	stroke := max(s * BADGE_STROKE, BADGE_STROKE_MIN_PX)
	total := f32(n) * gw + f32(n - 1) * gap
	x0, y0 := (s - total) / 2, (s - gh) / 2

	segments := make([dynamic][2][2]f32, 0, 16, context.temp_allocator)
	for g, i in glyphs[:n] {
		left := x0 + f32(i) * (gw + gap)
		for path in badge_glyphs[g] {
			for k in 0 ..< path.n - 1 {
				a := [2]f32{left + path.p[k].x * gw, y0 + path.p[k].y * gh}
				b := [2]f32{left + path.p[k + 1].x * gw, y0 + path.p[k + 1].y * gh}
				append(&segments, [2][2]f32{a, b})
			}
		}
	}

	r := s / 2
	for y in 0 ..< size {
		for x in 0 ..< size {
			p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			d := p - [2]f32{r, r}
			cover := clamp(r - math.sqrt(d.x * d.x + d.y * d.y) + 0.5, 0, 1)
			if cover <= 0 { continue }
			on: f32 = 0
			for seg in segments { on = max(on, clamp(stroke / 2 - segment_distance(p, seg[0], seg[1]) + 0.5, 0, 1)) }
			c := disc + (inkf - disc) * on
			at := (y * size + x) * 4
			out[at], out[at + 1], out[at + 2] = u8(math.round(c.r)), u8(math.round(c.g)), u8(math.round(c.b))
			out[at + 3] = u8(math.round(cover * 255))
		}
	}
	return out
}

// White or black, the one with the higher contrast on `accent` (WCAG's relative luminance), as 0xRRGGBB.
taskbar_badge_ink :: proc(accent: u32) -> u32 {
	lin :: proc(c: u32) -> f32 {
		v := f32(c) / 255
		return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4)
	}
	l := 0.2126 * lin(accent >> 16 & 0xFF) + 0.7152 * lin(accent >> 8 & 0xFF) + 0.0722 * lin(accent & 0xFF)
	on_white := 1.05 / (l + 0.05)
	on_black := (l + 0.05) / 0.05
	return on_white >= on_black ? 0xFFFFFF : 0x000000
}

@(private = "file") BADGE_PLUS :: 10
@(private = "file") BADGE_GLYPH_HEIGHT_ONE :: 0.5    // of the picture: one digit
@(private = "file") BADGE_GLYPH_HEIGHT_TWO :: 0.42   // two digits, narrower so both fit in the disc
@(private = "file") BADGE_GLYPH_ASPECT :: 0.58
@(private = "file") BADGE_GLYPH_GAP :: 0.22          // of a glyph's height
@(private = "file") BADGE_STROKE :: 0.11             // of the picture
@(private = "file") BADGE_STROKE_MIN_PX :: 1.4       // a thinner stroke fades at 16 pixels

// A glyph's strokes in a box of 1 by 1 (y down): up to two polylines of up to six points. Rounded caps make the corners.
@(private = "file") Badge_Path :: struct { n: int, p: [6][2]f32 }
@(private = "file") Badge_Glyph :: [2]Badge_Path

// The digits 0 to 9, then the plus sign (BADGE_PLUS).
@(private = "file", rodata)
badge_glyphs := [11]Badge_Glyph{
	{{5, {{0, 0}, {1, 0}, {1, 1}, {0, 1}, {0, 0}, {}}}, {}},
	{{3, {{0.15, 0.22}, {0.55, 0}, {0.55, 1}, {}, {}, {}}}, {}},
	{{6, {{0, 0}, {1, 0}, {1, 0.5}, {0, 0.5}, {0, 1}, {1, 1}}}, {}},
	{{4, {{0, 0}, {1, 0}, {1, 1}, {0, 1}, {}, {}}}, {2, {{0.2, 0.5}, {1, 0.5}, {}, {}, {}, {}}}},
	{{3, {{0, 0}, {0, 0.55}, {1, 0.55}, {}, {}, {}}}, {2, {{0.8, 0.2}, {0.8, 1}, {}, {}, {}, {}}}},
	{{6, {{1, 0}, {0, 0}, {0, 0.5}, {1, 0.5}, {1, 1}, {0, 1}}}, {}},
	{{6, {{1, 0}, {0, 0}, {0, 1}, {1, 1}, {1, 0.5}, {0, 0.5}}}, {}},
	{{3, {{0, 0}, {1, 0}, {0.35, 1}, {}, {}, {}}}, {}},
	{{5, {{0, 0}, {1, 0}, {1, 1}, {0, 1}, {0, 0}, {}}}, {2, {{0, 0.5}, {1, 0.5}, {}, {}, {}, {}}}},
	{{6, {{1, 0.5}, {0, 0.5}, {0, 0}, {1, 0}, {1, 1}, {0, 1}}}, {}},
	{{2, {{0.5, 0.1}, {0.5, 0.9}, {}, {}, {}, {}}}, {2, {{0.1, 0.5}, {0.9, 0.5}, {}, {}, {}, {}}}},
}

@(private = "file")
segment_distance :: proc(p, a, b: [2]f32) -> f32 {
	ab, ap := b - a, p - a
	len2 := ab.x * ab.x + ab.y * ab.y
	t := len2 > 0 ? clamp((ap.x * ab.x + ap.y * ab.y) / len2, 0, 1) : 0
	d := ap - ab * t
	return math.sqrt(d.x * d.x + d.y * d.y)
}

////////////////////////////////
// Wayland's attention

// Whether the desktop named by XDG_CURRENT_DESKTOP (a list split by ':') marks a window that spends an activation token
// with no input serial, instead of focusing it: KDE (KWin), GNOME (Mutter) and sway. Elsewhere such a token can take the
// focus from the window the person types in, which is worse than no mark: no token is asked. Pure: tests.
wayland_attention_marks :: proc(current_desktop: string) -> bool {
	rest := current_desktop
	for name in strings.split_iterator(&rest, ":") {
		if ascii.equal_fold(name, "KDE") || ascii.equal_fold(name, "GNOME") || ascii.equal_fold(name, "sway") { return true }
	}
	return false
}

////////////////////////////////
// Linux's launcher entry (com.canonical.Unity.LauncherEntry), pure so that every system tests it

LAUNCHER_ENTRY_INTERFACE :: "com.canonical.Unity.LauncherEntry"
LAUNCHER_ENTRY_SIGNATURE :: "sa{sv}"

// The program's URI in the entry: its desktop file (application://<id>.desktop), temp memory.
launcher_entry_uri :: proc(app_id: string) -> string {
	return strings.concatenate({"application://", app_id, ".desktop"}, context.temp_allocator)
}

// The object path the entry's signal comes from: libunity's, a hash of the URI (docks match the interface, not the path).
launcher_entry_path :: proc(uri: string) -> string {
	h: u32 = 5381
	for c in transmute([]u8)uri { h = h * 33 + u32(c) }
	return fmt.tprintf("/com/canonical/unity/launcherentry/%d", h)
}

// The Update signal's body for `s`: the URI, then every property, so a dock that missed a signal is right at the next
// one. Paused and Error show as Normal (the entry has no state for them); Indeterminate shows no progress.
launcher_entry_body :: proc(uri: string, s: Taskbar_State, allocator := context.temp_allocator) -> []u8 {
	w := dbus.body_writer(allocator)
	dbus.w_string(&w, uri)
	l, at := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "count")
	dbus.w_signature(&w, "x")
	dbus.w_u64(&w, u64(i64(max(s.count, 0))))
	dbus.arg_dict_entry(&w, "count-visible")
	dbus.arg_variant_bool(&w, s.count > 0)
	shown := s.progress == .Normal || s.progress == .Paused || s.progress == .Error
	dbus.arg_dict_entry(&w, "progress")
	dbus.w_signature(&w, "d")
	dbus.w_f64(&w, shown ? f64(s.done) / TASKBAR_STEPS : 0)
	dbus.arg_dict_entry(&w, "progress-visible")
	dbus.arg_variant_bool(&w, shown)
	dbus.arg_dict_entry(&w, "urgent")
	dbus.arg_variant_bool(&w, s.attention)
	dbus.arg_dict_end(&w, l, at)
	return w.buf[:]
}
