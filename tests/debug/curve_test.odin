// The curve editor (src/md/features/curve-editor.md): a curve's values at its keys, between them for each interpolation,
// before the first and after the last; the program's clock; a key dragged (Shift, Ctrl), a handle dragged (aligned,
// broken), a key added and deleted, a box selection, undo, the playhead scrubbed, the view zoomed; Print parsed back to
// the same curve; the tools' list and set, in the process and over the devtools protocol; the easing editor.
//   odin run tools/run_tests -- debug
package debug_test

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:odin/ast"
import "core:odin/parser"
import "core:strconv"
import "core:strings"
import "core:testing"
import "gt:debug"
import "gt:devtools"
import "gt:platform"
import "gt:testkit/session"
import "gt:ui"

////////////////////////////////
// The model

@(private = "file")
key :: proc(time, value: f32, interp := debug.Curve_Interp.Bezier, in_handle := [2]f32{}, out_handle := [2]f32{}) -> debug.Curve_Key {
	return {time = time, value = value, interp = interp, in_handle = in_handle, out_handle = out_handle}
}

@(private = "file")
curve_of :: proc(keys: ..debug.Curve_Key) -> (c: debug.Curve) {
	for k in keys { debug.curve_insert(&c, k) }
	return
}

@(private = "file")
near :: proc(a, b: f32, eps: f32 = 1e-4) -> bool { return abs(a - b) <= eps }

@(test)
a_curve_is_worth_its_keys :: proc(t: ^testing.T) {
	empty: debug.Curve
	testing.expect_value(t, debug.curve_eval(empty, 3), 0)
	one := curve_of(key(1, 7))
	testing.expect_value(t, debug.curve_eval(one, -5), 7)
	testing.expect_value(t, debug.curve_eval(one, 5), 7)
	c := curve_of(key(0, 1, .Linear), key(1, 3, .Constant), key(2, -1), key(3, 5))
	// at its keys; before the first, after the last
	for k in c.keys[:c.count] { testing.expectf(t, debug.curve_eval(c, k.time) == k.value, "at %v: %v", k.time, debug.curve_eval(c, k.time)) }
	testing.expect_value(t, debug.curve_eval(c, -10), 1)
	testing.expect_value(t, debug.curve_eval(c, 10), 5)
	testing.expect_value(t, debug.curve_eval(c, f32(math.nan_f32())), 1)
	// linear: straight; constant: held
	testing.expect(t, near(debug.curve_eval(c, 0.25), 1.5))
	testing.expect_value(t, debug.curve_eval(c, 1.5), 3)
	testing.expect_value(t, debug.curve_eval(c, 1.999), 3)
	// a Bézier with no handles: an ease in and out, its middle half-way
	testing.expect(t, near(debug.curve_eval(c, 2.5), 2))
	testing.expect(t, debug.curve_eval(c, 2.1) < -1 + 6 * 0.1, "slow at its start")
	// a Bézier with handles over a unit segment is CSS's cubic-bezier of the same points
	b := ui.Cubic_Bezier{0.3, 0.9, 0.6, 1.2}
	unit := curve_of(key(0, 0, out_handle = {b.x1, b.y1}), key(1, 1, in_handle = {b.x2 - 1, b.y2 - 1}))
	for p in ([]f32{0.1, 0.25, 0.5, 0.75, 0.9}) {
		testing.expectf(t, near(debug.curve_eval(unit, p), ui.cubic_bezier_at(b, p), 1e-3), "at %v: %v, css %v", p, debug.curve_eval(unit, p), ui.cubic_bezier_at(b, p))
	}
	// a handle longer than its segment: shortened, a time has one value, no NaN
	long := curve_of(key(0, 0, out_handle = {5, 10}), key(1, 1, in_handle = {-5, 0}))
	last := f32(-1e9)
	for i in 0 ..= 20 {
		v := debug.curve_eval(long, f32(i) / 20)
		testing.expectf(t, !math.is_nan(v), "a value at %d", i)
		last = v
	}
	testing.expect(t, near(last, 1))
	// many keys: the binary search finds the segment
	many: debug.Curve
	for i in 0 ..< debug.CURVE_KEYS_MAX { debug.curve_insert(&many, key(f32(i), f32(i * i), .Linear)) }
	testing.expect_value(t, debug.curve_insert(&many, key(99, 0)), -1)
	for i in 0 ..< debug.CURVE_KEYS_MAX - 1 {
		want := (f32(i * i) + f32((i + 1) * (i + 1))) / 2
		testing.expectf(t, near(debug.curve_eval(many, f32(i) + 0.5), want, 1e-2), "between %d and %d", i, i + 1)
	}
	// several channels
	v := debug.curves_eval([2]debug.Curve{one, c}, 0.25)
	testing.expect(t, v[0] == 7 && near(v[1], 1.5))
	testing.expect_value(t, debug.curves_span([]debug.Curve{one, c, empty}), [2]f32{0, 3})
}

@(test)
keys_are_inserted_sorted_removed_and_smoothed :: proc(t: ^testing.T) {
	c := curve_of(key(2, 0), key(0, 0), key(1, 4))
	testing.expect_value(t, c.count, 3)
	testing.expect(t, c.keys[0].time == 0 && c.keys[1].time == 1 && c.keys[2].time == 2)
	debug.curve_smooth(&c, 1)
	testing.expect_value(t, c.keys[1].in_handle, [2]f32{-1.0 / 3, 0})   // (its neighbours at one height: flat)
	c.keys[2].value = 6
	debug.curve_smooth(&c, 1)
	testing.expect(t, near(c.keys[1].out_handle.y / c.keys[1].out_handle.x, 3), "the neighbours' slope")
	debug.curve_remove(&c, 0)
	testing.expect_value(t, c.count, 2)
	testing.expect_value(t, c.keys[0].time, 1)
}

@(test)
the_program_s_clock_loops_or_stops :: proc(t: ^testing.T) {
	p: debug.Playback
	testing.expect(t, near(debug.playback_step(&p, 0.5, {0, 2}), 0.5), "a zero speed is 1")
	testing.expect(t, near(debug.playback_step(&p, 2, {0, 2}), 0.5), "it loops")
	p.speed = 2
	testing.expect(t, near(debug.playback_step(&p, 0.25, {0, 2}), 1))
	p.paused = true
	testing.expect(t, near(debug.playback_step(&p, 1, {0, 2}), 1))
	p = {once = true, time = 1.5}
	testing.expect_value(t, debug.playback_step(&p, 3, {0, 2}), 2)
	p = {speed = -1}
	testing.expect(t, near(debug.playback_step(&p, 0.5, {0, 2}), 1.5), "backwards, it loops too")
}

@(test)
the_easings_are_the_toolkit_s :: proc(t: ^testing.T) {
	for p in ([]f32{0, 0.1, 0.3, 0.5, 0.8, 1}) {
		testing.expect(t, near(ui.cubic_bezier_at(ui.ease_bezier(.Linear), p), p, 1e-4))
		testing.expect(t, near(ui.cubic_bezier_at(ui.ease_bezier(.Emphasized), p), ui.ease_at(.Emphasized, p), 1e-5))
		// (CSS's approximations: near the toolkit's polynomials)
		testing.expectf(t, near(ui.cubic_bezier_at(ui.ease_bezier(.Out), p), ui.ease_at(.Out, p), 0.03), "Out at %v", p)
		testing.expectf(t, near(ui.cubic_bezier_at(ui.ease_bezier(.In_Out), p), ui.ease_at(.In_Out, p), 0.03), "In_Out at %v", p)
		testing.expectf(t, near(ui.cubic_bezier_at(ui.ease_bezier(.Sine), p), ui.ease_at(.Sine, p), 0.03), "Sine at %v", p)
	}
}

////////////////////////////////
// Print, parsed back by Odin's own parser

@(private = "file")
odin_value :: proc(e: ^ast.Expr) -> (v: f32, ok: bool) {
	#partial switch x in e.derived_expr {
	case ^ast.Basic_Lit:
		f, fok := strconv.parse_f32(x.tok.text)
		return f, fok
	case ^ast.Unary_Expr:
		f, fok := odin_value(x.expr)
		return x.op.text == "-" ? -f : f, fok
	case ^ast.Paren_Expr:
		return odin_value(x.expr)
	}
	return
}

@(private = "file")
odin_pair :: proc(e: ^ast.Expr) -> (p: [2]f32, ok: bool) {
	lit := e.derived_expr.(^ast.Comp_Lit) or_return
	if len(lit.elems) != 2 { return }
	p.x = odin_value(lit.elems[0]) or_return
	p.y = odin_value(lit.elems[1]) or_return
	return p, true
}

// A curve's literal as Odin parses it: §Curve{count = n, keys = {i = {field = value, ...}}}§ or the same without a type.
@(private = "file")
odin_curve :: proc(e: ^ast.Expr) -> (c: debug.Curve, ok: bool) {
	lit := e.derived_expr.(^ast.Comp_Lit) or_return
	for f in lit.elems {
		fv := f.derived_expr.(^ast.Field_Value) or_return
		name := fv.field.derived_expr.(^ast.Ident) or_return
		switch name.name {
		case "count":
			n := odin_value(fv.value) or_return
			c.count = int(n)
		case "keys":
			keys := fv.value.derived_expr.(^ast.Comp_Lit) or_return
			for ke in keys.elems {
				kv := ke.derived_expr.(^ast.Field_Value) or_return
				i := odin_value(kv.field) or_return
				k := &c.keys[int(i)]
				body := kv.value.derived_expr.(^ast.Comp_Lit) or_return
				for kf in body.elems {
					kfv := kf.derived_expr.(^ast.Field_Value) or_return
					kn := kfv.field.derived_expr.(^ast.Ident) or_return
					switch kn.name {
					case "time":       k.time = odin_value(kfv.value) or_return
					case "value":      k.value = odin_value(kfv.value) or_return
					case "in_handle":  k.in_handle = odin_pair(kfv.value) or_return
					case "out_handle": k.out_handle = odin_pair(kfv.value) or_return
					case "broken":     k.broken = (kfv.value.derived_expr.(^ast.Ident) or_return).name == "true"
					case "interp":
						sel := kfv.value.derived_expr.(^ast.Implicit_Selector_Expr) or_return
						switch sel.field.name {
						case "Bezier":   k.interp = .Bezier
						case "Linear":   k.interp = .Linear
						case "Constant": k.interp = .Constant
						case: return
						}
					case: return
					}
				}
			}
		case: return
		}
	}
	return c, true
}

// Odin's parser reads §text§ as the value of a constant: the expression, or false when it is no Odin.
@(private = "file")
odin_parse :: proc(text: string) -> (e: ^ast.Expr, ok: bool) {
	context.allocator = context.temp_allocator
	file := new(ast.File)
	file.src = fmt.tprintf("package p\nX :: %s\n", text)
	file.fullpath = "print.odin"
	p := parser.default_parser()
	if !parser.parse_file(&p, file) || p.error_count > 0 || len(file.decls) != 1 { return }
	decl := file.decls[0].derived_stmt.(^ast.Value_Decl) or_return
	if len(decl.values) != 1 { return }
	return decl.values[0], true
}

@(test)
print_parses_back_to_the_same_curve :: proc(t: ^testing.T) {
	c := curve_of(key(0, 0, out_handle = {0.25, 10}), key(0.7, 18.5, .Linear, in_handle = {-0.2, -1.125}), key(1.3, -6, .Constant), key(2, 0.1, in_handle = {-0.25, 0}))
	c.keys[0].broken = true
	text := debug.curve_text(c)
	testing.expect(t, strings.has_prefix(text, "debug.Curve{count = 4, keys = {0 = {time = 0, value = 0, out_handle = {0.25, 10}, broken = true}"), text)
	e, ok := odin_parse(text)
	if !testing.expectf(t, ok, "Odin parses %s", text) { return }
	back, bok := odin_curve(e)
	testing.expect(t, bok)
	testing.expect_value(t, back, c)
	// several channels, and a curve inside a program's struct
	cs := [2]debug.Curve{c, curve_of(key(1, 2))}
	e, ok = odin_parse(debug.curves_text(cs[:]))
	if !testing.expect(t, ok) { return }
	lit := e.derived_expr.(^ast.Comp_Lit)
	testing.expect_value(t, len(lit.elems), 2)
	for i in 0 ..< 2 {
		x, xok := odin_curve(lit.elems[i])
		testing.expect(t, xok && x == cs[i])
	}
	Holder :: struct { speed: f32, path: debug.Curve }
	testing.expect_value(t, debug.odin_text(Holder{speed = 2, path = curve_of(key(0, 1))}), "Holder{speed = 2, path = {count = 1, keys = {0 = {time = 0, value = 1}}}}")
}

////////////////////////////////
// The editor

Anim :: struct {
	hover: debug.Curve,
	sway:  [3]debug.Curve,
	land:  ui.Cubic_Bezier,
	play:  debug.Playback,
	runs:  int,
}

anim_debug :: proc(a: ^Anim) {
	a.runs += 1
	debug.curve("hover", &a.hover, &a.play)
	debug.curves("sway", a.sway[:], &a.play)
	debug.easing("land", &a.land)
}

@(private = "file")
anim_start :: proc() -> Anim {
	a: Anim
	a.hover = curve_of(key(0, 0, out_handle = {0.3, 0}), key(1, 1, in_handle = {-0.3, 0}, out_handle = {0.3, 0}), key(2, 0, in_handle = {-0.3, 0}))
	a.sway[0] = curve_of(key(0, -1, .Linear), key(2, 1))
	a.land = ui.ease_bezier(.Out)
	a.play = {paused = true}
	return a
}

HOVER :: "Anim/hover"

@(private = "file")
open_anim :: proc(t: ^testing.T, a: ^Anim) -> ^session.Session {
	s := session.start(t, {size = {1000, 900}, build = proc(s: ^session.Session) { ui.label("The page###page") }})
	debug.panel(s.state, "Anim", anim_debug, a)
	debug.open(s.state)
	testing.expect(t, debug.show_panel(s.state, "Anim"))
	session.wait_box(s, debug.box_name(HOVER, "graph"))
	session.frames(s, 2)
	return s
}

// Where a point of the hover curve is on the screen, whole pixels.
@(private = "file")
at :: proc(s: ^session.Session, p: [2]f32, path := HOVER) -> [2]f32 {
	q, ok := debug.curve_screen(s.state, path, p)
	assert(ok)
	return {math.round(q.x), math.round(q.y)}
}

// A drag with modifiers held, as the system gives them: each event of the pointer says them.
@(private = "file")
drag_mods :: proc(s: ^session.Session, from, to: [2]f32, mods: platform.Modifiers, button := platform.Mouse_Button.Left) {
	session.move(s, from)
	s.buttons += {button}
	session.event(s, {kind = .Mouse_Press, button = button, pos = from, mods = mods})
	session.frame(s)
	for i in 1 ..= session.DRAG_STEPS {
		p := from + (to - from) * f32(i) / f32(session.DRAG_STEPS)
		s.pointer = p
		session.event(s, {kind = .Mouse_Move, pos = p, mods = mods})
		session.frame(s)
	}
	s.buttons -= {button}
	session.event(s, {kind = .Mouse_Release, button = button, pos = to, mods = mods})
	session.frames(s, 2)
}

@(test)
a_key_dragged_changes_the_program_s_curve :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	// (selected first: the key's row under the graph comes, and the panel's scroll bar with it)
	session.click_at(s, at(s, {1, 1}))
	from := at(s, {1, 1})
	to := from + {40, 25}
	session.drag(s, from, to)
	k := a.hover.keys[1]
	moved := at(s, {k.time, k.value})
	testing.expectf(t, abs(moved.x - to.x) <= 1 && abs(moved.y - to.y) <= 1, "the key under the pointer: %v, dropped at %v", moved, to)
	testing.expect(t, k.time > 1 && k.value < 1)
	testing.expect_value(t, a.hover.count, 3)
	// Shift: the main direction only
	from = moved
	drag_mods(s, from, from + {50, 12}, {.Shift})
	testing.expect_value(t, a.hover.keys[1].value, k.value)
	testing.expect(t, a.hover.keys[1].time > k.time)
	// Ctrl: on the grid
	from = at(s, {a.hover.keys[1].time, a.hover.keys[1].value})
	drag_mods(s, from, from + {-23, -17}, {.Ctrl})
	k = a.hover.keys[1]
	testing.expectf(t, near(k.time * 100, math.round(k.time * 100), 1e-2) && near(k.value * 100, math.round(k.value * 100), 1e-2), "on the grid: %v, %v", k.time, k.value)
	// undo goes back through the three drags, redo forward
	session.key(s, .Z, {.Ctrl}, repeat = 3)
	testing.expect_value(t, a.hover, anim_start().hover)
	session.key(s, .Z, {.Ctrl, .Shift})
	testing.expect(t, a.hover.keys[1].time > 1)
	// a key dragged past its neighbour is sorted, and stays the one selected
	from = at(s, {a.hover.keys[1].time, a.hover.keys[1].value})
	session.drag(s, from, at(s, {2.5, 0.5}))
	testing.expect(t, a.hover.keys[2].time > 2 && a.hover.keys[1].time == 2, "sorted")
	testing.expect(t, a.hover.keys[2].value > 0.3)
}

@(test)
a_handle_dragged_turns_the_other :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	session.click_at(s, at(s, {1, 1}))
	k := a.hover.keys[1]
	handle := at(s, {k.time + k.out_handle.x, k.value + k.out_handle.y})
	session.drag(s, handle, handle + {0, 30})
	k = a.hover.keys[1]
	testing.expect(t, k.out_handle.y < 0, "its handle down")
	testing.expectf(t, near(k.in_handle.y / k.in_handle.x, k.out_handle.y / k.out_handle.x), "aligned: %v %v", k.in_handle, k.out_handle)
	testing.expect(t, !k.broken)
	// Alt breaks them: the other stays
	in_before := k.in_handle
	handle = at(s, {k.time + k.out_handle.x, k.value + k.out_handle.y})
	drag_mods(s, handle, handle + {0, -45}, {.Alt})
	k = a.hover.keys[1]
	testing.expect(t, k.broken)
	testing.expect_value(t, k.in_handle, in_before)
	testing.expect(t, k.out_handle.y > 0)
	// held to its segment: never past the next key
	handle = at(s, {k.time + k.out_handle.x, k.value + k.out_handle.y})
	session.drag(s, handle, at(s, {3, k.value}))
	testing.expect(t, a.hover.keys[1].out_handle.x <= 1 + 1e-4)
}

@(test)
a_key_is_added_and_deleted :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	// a double click on nothing: a key there
	p := at(s, {1.5, 0.2})
	session.click_at(s, p, count = 2)
	testing.expect_value(t, a.hover.count, 4)
	k := a.hover.keys[2]
	testing.expectf(t, near(k.time, 1.5, 0.03) && near(k.value, 0.2, 0.03), "the key where clicked: %v", k)
	testing.expect(t, k.in_handle.x < 0 && k.out_handle.x > 0, "smooth handles")
	// Delete: the key selected goes
	session.key(s, .Delete)
	testing.expect_value(t, a.hover.count, 3)
	testing.expect_value(t, a.hover, anim_start().hover)
	// a box over two keys selects them: both go
	session.drag(s, at(s, {-0.1, 1.1}), at(s, {1.2, -0.1}))
	session.key(s, .Delete)
	testing.expect_value(t, a.hover.count, 1)
	testing.expect_value(t, a.hover.keys[0].time, 2)
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, a.hover.count, 3)
}

@(test)
the_view_zooms_pans_and_the_playhead_scrubs :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	k0, k2 := at(s, {0, 0}), at(s, {2, 0})
	session.wheel(s, at(s, {1, 0.5}), {0, -3})
	z0, z2 := at(s, {0, 0}), at(s, {2, 0})
	testing.expectf(t, z2.x - z0.x > (k2.x - k0.x) * 1.3, "zoomed in: %v px, was %v", z2.x - z0.x, k2.x - k0.x)
	// the middle button pans
	p := at(s, {1, 0.5})
	session.drag(s, p, p + {30, 10}, button = .Middle)
	q := at(s, {1, 0.5})
	testing.expectf(t, abs(q.x - p.x - 30) <= 1 && abs(q.y - p.y - 10) <= 1, "panned with the pointer: %v from %v", q, p)
	// F frames every key
	session.click(s, debug.box_name(HOVER, "graph"))
	session.key(s, .F)
	f0, f2 := at(s, {0, 0}), at(s, {2, 0})
	testing.expect(t, abs((f2.x - f0.x) - (k2.x - k0.x)) <= 1)
	// a drag along the time's ruler: the playhead
	g := session.get(s, debug.box_name(HOVER, "graph"))
	y := g.rect.max.y - 4
	session.drag(s, {at(s, {0.5, 0}).x, y}, {at(s, {1.5, 0}).x, y})
	testing.expectf(t, near(a.play.time, 1.5, 0.02), "the playhead at the pointer: %v", a.play.time)
	// the transport: play
	session.click(s, debug.box_name(HOVER, "play"))
	testing.expect(t, !a.play.paused)
}

@(test)
the_key_s_fields_edit_the_keys_selected :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	testing.expect(t, session.find(s, debug.box_name(HOVER, "key_value")) == nil, "no key row without a selection")
	session.click_at(s, at(s, {1, 1}))
	// (the field inside the row: a click on the row's middle reaches the window around it)
	session.click_at(s, session.center(session.get(s, "value", within = session.get(s, debug.box_name(HOVER, "key_value")))), count = 2)
	session.type_text(s, "0.5")
	session.key(s, .Return)
	testing.expect_value(t, a.hover.keys[1].value, 0.5)
	// its interpolation
	session.click(s, debug.box_name(HOVER, "interp"))
	session.click_text(s, "Constant")
	testing.expect_value(t, a.hover.keys[1].interp, debug.Curve_Interp.Constant)
	testing.expect_value(t, debug.curve_eval(a.hover, 1.5), 0.5)
	// a channel hidden takes no click
	letter, lok := debug.curve_channel_at(s.state, "Anim/sway", 0)
	testing.expect(t, lok)
	session.click_at(s, {math.round(letter.x), math.round(letter.y)})
	sway := a.sway[0]
	session.click_at(s, at(s, {0, -1}, "Anim/sway"))
	session.key(s, .Delete)
	testing.expect_value(t, a.sway[0], sway)
}

// The channels' letters are boxes of their own: a check box to a screen reader, its state the channel shown; Space on
// the letter focused toggles it, and a click.
@(test)
the_channel_letters_are_check_boxes :: proc(t: ^testing.T) {
	SWAY :: "Anim/sway"
	a := anim_start()
	s := open_anim(t, &a)
	toggled :: proc(s: ^session.Session) -> (platform.A11y_Toggled, bool) {
		b := session.find(s, debug.box_name(SWAY, "channel1"))
		if b == nil || b.a11y == nil || b.a11y.role != .Check_Box { return .Mixed, false }
		return b.a11y.toggled.?
	}
	on, ok := toggled(s)
	if !testing.expect(t, ok, "the letter y is a check box") { return }
	testing.expect_value(t, on, platform.A11y_Toggled.True)
	ui.set_focus(session.get(s, debug.box_name(SWAY, "channel1")).key)
	session.frame(s)
	session.key(s, .Space)
	session.frame(s)
	on, _ = toggled(s)
	testing.expect_value(t, on, platform.A11y_Toggled.False)
	p, pok := debug.curve_channel_at(s.state, SWAY, 1)
	testing.expect(t, pok)
	session.click_at(s, {math.round(p.x), math.round(p.y)})
	on, _ = toggled(s)
	testing.expect_value(t, on, platform.A11y_Toggled.True)
}

// Escape during a box selection ends it and changes no key: a band has no curves of its own at its start, and the
// last move's were put back.
@(test)
escape_in_a_box_selection_keeps_the_keys :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	session.click_at(s, at(s, {1, 1}))
	from := at(s, {1, 1})
	session.drag(s, from, from + {40, 25})
	moved := a.hover
	testing.expect(t, moved != anim_start().hover, "the key moved")
	band := at(s, {0.2, 0.9})
	session.press(s, band)
	session.move(s, band + {60, 40})
	session.frame(s)
	session.key(s, .Escape)
	session.release(s, band + {60, 40})
	session.frames(s, 2)
	testing.expect_value(t, a.hover, moved)
}

////////////////////////////////
// The tools

@(test)
the_tools_list_and_set_a_curve :: proc(t: ^testing.T) {
	a := anim_start()
	s := session.start(t, {size = {1000, 700}, build = proc(s: ^session.Session) { ui.label("The page###page") }})
	debug.panel(s.state, "Anim", anim_debug, &a)
	sb := strings.builder_make(context.temp_allocator)
	debug.list(s.state, &sb)
	listed := strings.to_string(sb)
	testing.expect(t, strings.contains(listed, `"path":"Anim/hover","kind":"curve","value":[[{"time":0,"value":0,"in_handle":[0,0],"out_handle":[0.3,0],"interp":"bezier","broken":false},`), listed)
	testing.expect(t, strings.contains(listed, `"channels":"xyz"`), listed)
	testing.expect(t, strings.contains(listed, `"path":"Anim/land","kind":"easing","value":[0.33,1,0.68,1]`), listed)
	// what is listed, set back: the same curve
	parsed, err := json.parse_string(listed, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	before := a
	for p in parsed.(json.Object)["panels"].(json.Array) {
		for it in p.(json.Object)["items"].(json.Array) {
			o := it.(json.Object)
			if o["kind"].(json.String) != "curve" { continue }
			text, _ := json.marshal(o["value"], allocator = context.temp_allocator)
			testing.expect_value(t, debug.set(s.state, o["path"].(json.String), string(text)), "")
		}
	}
	testing.expect_value(t, a.hover, before.hover)
	testing.expect_value(t, a.sway, before.sway)
	// one channel's keys alone, unsorted; a key's missing fields are its zero
	testing.expect_value(t, debug.set(s.state, HOVER, `[{"time":2,"value":1},{"time":0,"value":3,"interp":"linear"}]`), "")
	testing.expect_value(t, a.hover.count, 2)
	testing.expect_value(t, a.hover.keys[0], debug.Curve_Key{time = 0, value = 3, interp = .Linear})
	testing.expect(t, near(debug.curve_eval(a.hover, 1), 2))
	// refused, and the curve kept
	too_many := strings.builder_make(context.temp_allocator)
	strings.write_byte(&too_many, '[')
	for i in 0 ..= debug.CURVE_KEYS_MAX { fmt.sbprintf(&too_many, "%s{{\"time\":%d}}", i > 0 ? "," : "", i) }
	strings.write_byte(&too_many, ']')
	for bad in ([]string{"3", `[[{"time":0}],[]]`, `[{"time":"a"}]`, `[{"interp":"cubic"}]`, `[{"time":1e999}]`, `[{"time":NaN}]`, `[{"value":Infinity}]`, `[{"out_handle":[1,NaN]}]`, strings.to_string(too_many)}) {
		testing.expectf(t, debug.set(s.state, HOVER, bad) != "", "%s refused", bad)
	}
	testing.expect(t, strings.contains(debug.set(s.state, HOVER, strings.to_string(too_many)), "32 keys at most"))
	// one set of names, Print's: another field is refused, named
	testing.expect(t, strings.contains(debug.set(s.state, HOVER, `[{"time":0,"in":[-1,0]}]`), `no key field "in"`))
	testing.expect(t, strings.contains(debug.set(s.state, HOVER, `[{"broken":1}]`), "broken"))
	testing.expect(t, strings.contains(debug.set(s.state, HOVER, `[{"interp":3}]`), "interp"))
	testing.expect_value(t, debug.set(s.state, HOVER, `[{"time":0,"value":1,"out_handle":[0.5,0]},{"time":1,"value":2,"in_handle":[-0.5,0]}]`), "")
	testing.expect_value(t, a.hover.keys[0].out_handle, [2]f32{0.5, 0})
	testing.expect_value(t, a.hover.count, 2)
	testing.expect(t, strings.contains(debug.set(s.state, "Anim/sway", `[[],[]]`), "3 channels"))
	// an easing: four numbers, or a preset by name
	testing.expect_value(t, debug.set(s.state, "Anim/land", "emphasized"), "")
	testing.expect_value(t, a.land, ui.ease_bezier(.Emphasized))
	testing.expect_value(t, debug.set(s.state, "Anim/land", "0.1, 0.2, 1.5, 0.4"), "")
	testing.expect_value(t, a.land, ui.Cubic_Bezier{0.1, 0.2, 1, 0.4})
}

@(test)
a_curve_round_trips_over_the_devtools_protocol :: proc(t: ^testing.T) {
	a := anim_start()
	s := session.start(t, {size = {1000, 700}, build = proc(s: ^session.Session) { ui.label("The page###page") }})
	debug.panel(s.state, "Anim", anim_debug, &a)
	srv := devtools.start_local(s.win, "curve")
	defer devtools.stop(srv)
	c := devtools.local_connect(srv)
	defer devtools.local_close(c)
	ask :: proc(s: ^session.Session, srv: ^devtools.Server, c: devtools.Local_Client, id: int, method, params: string) -> string {
		devtools.local_send(c, fmt.tprintf(`{{"id":%d,"method":%q,"params":%s}}`, id, method, params))
		for _ in 0 ..< 10 {
			devtools.service(srv, s.state, nil)
			for m in devtools.local_take(c, context.temp_allocator) {
				if strings.contains(m, fmt.tprintf(`"id":%d,`, id)) || strings.contains(m, fmt.tprintf(`"id":%d}}`, id)) { return m }
			}
			session.frame(s)
		}
		return ""
	}
	listed := ask(s, srv, c, 1, "Toolkit.debugPanels", "{}")
	testing.expect(t, strings.contains(listed, `"kind":"curve"`), listed)
	reply := ask(s, srv, c, 2, "Toolkit.debugSet", `{"path":"Anim/sway","value":[[{"time":0,"value":1},{"time":1,"value":2,"out_handle":[0.2,0.5],"broken":true}],[],[{"time":3,"value":-1,"interp":"constant"}]]}`)
	testing.expect(t, strings.contains(reply, `"result":{}`), reply)
	testing.expect_value(t, a.sway[0].count, 2)
	testing.expect_value(t, a.sway[0].keys[1], debug.Curve_Key{time = 1, value = 2, out_handle = {0.2, 0.5}, broken = true})
	testing.expect_value(t, a.sway[1].count, 0)
	testing.expect_value(t, a.sway[2].keys[0].interp, debug.Curve_Interp.Constant)
	reply = ask(s, srv, c, 3, "Toolkit.debugSet", `{"path":"Anim/hover","value":[{"time":0,"value":5}]}`)
	testing.expect(t, strings.contains(reply, `"result":{}`), reply)
	testing.expect_value(t, debug.curve_eval(a.hover, 9), 5)
}

@(test)
the_easing_s_handle_is_dragged :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	g := session.get(s, debug.box_name("Anim/land", "graph"))
	r := g.rect
	// (the square shows -0.35 .. 1.35 both ways)
	to_px :: proc(r: ui.Rect, p: [2]f32) -> [2]f32 {
		k := (p - {-0.35, -0.35}) / 1.7
		return {math.round(r.min.x + k.x * (r.max.x - r.min.x)), math.round(r.max.y - k.y * (r.max.y - r.min.y))}
	}
	from := to_px(r, {a.land.x1, a.land.y1})
	session.drag(s, from, to_px(r, {0.5, 0.25}))
	testing.expectf(t, near(a.land.x1, 0.5, 0.03) && near(a.land.y1, 0.25, 0.03), "the first handle where it was dropped: %v", a.land)
	testing.expect_value(t, a.land.x2, ui.ease_bezier(.Out).x2)
	// a preset
	session.click(s, debug.box_name("Anim/land", "preset"))
	session.click_text(s, "Linear")
	testing.expect_value(t, a.land, ui.ease_bezier(.Linear))
	// the presets as words ("In out", not In_Out); a tool names one either way
	session.click(s, debug.box_name("Anim/land", "preset"))
	testing.expect(t, session.find_text(s, "In out") != nil, "a preset in words")
	testing.expect(t, session.find_text(s, "In_Out") == nil, "no name of the code")
	session.click_text(s, "In out")
	testing.expect_value(t, a.land, ui.ease_bezier(.In_Out))
	testing.expect_value(t, debug.set(s.state, "Anim/land", "sine"), "")
	testing.expect_value(t, debug.set(s.state, "Anim/land", "in out"), "")
	testing.expect_value(t, debug.set(s.state, "Anim/land", "In_Out"), "")
	// no Tab stop: its numbers are the keyboard's way
	testing.expect(t, .Focusable not_in session.get(s, debug.box_name("Anim/land", "graph")).flags)
}

Own :: struct { c: debug.Curve }

own_debug :: proc(o: ^Own) { debug.curve("c", &o.c) }

// Nothing that plays, nothing drawn: the easing's dot rests until the pointer is on its square or its curve changed, and
// then for one period; a curve editor with no Playback of the program's starts paused. A dot that always ran drew a
// frame after another while the row showed.
@(test)
the_editors_rest_when_nothing_plays :: proc(t: ^testing.T) {
	a := anim_start()
	s := open_anim(t, &a)
	session.wait_idle(s)
	g := session.get(s, debug.box_name("Anim/land", "graph"))
	session.move(s, session.center(g))
	session.frame(s)
	testing.expect(t, ui.needs_frame(s.state), "the pointer on the square runs the dot")
	session.move(s, {5, 5})
	session.wait_idle(s)
	testing.expect_value(t, debug.set(s.state, "Anim/land", "linear"), "")
	session.frame(s)
	testing.expect(t, ui.needs_frame(s.state), "a change runs the dot")
	session.wait_idle(s)

	o := Own{c = curve_of(key(0, 0), key(1, 1))}
	s2 := session.start(t, {size = {1000, 700}, build = proc(s: ^session.Session) { ui.label("The page###page") }})
	debug.panel(s2.state, "Own", own_debug, &o)
	debug.open(s2.state)
	testing.expect(t, debug.show_panel(s2.state, "Own"))
	session.wait_box(s2, debug.box_name("Own/c", "graph"))
	session.wait_idle(s2)
	session.click(s2, debug.box_name("Own/c", "play"))
	session.frame(s2)
	testing.expect(t, ui.needs_frame(s2.state), "played, its playhead asks for frames")
}
