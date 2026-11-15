// ui.stepper: what each state draws, the progress said to a screen reader, the clocks of the marks (settled on first
// sight, run by dt, at once with animations off), the frames asked for, and the layout in every direction.
//   odin run tools/run_tests -- stepper
package stepper_test

import "core:fmt"
import "core:testing"
import "gt:font"
import "gt:ui"

WINDOW :: [2]f32{400, 300}
WIDTH :: 400        // the stepper's
STEPS :: 4
DT :: f32(1.0 / 60)
EPS :: 0.001

@(test)
each_state_draws_its_look :: proc(t: ^testing.T) {
	pending := ui.stepper_look(.Pending, 1, 0)
	testing.expect(t, pending.ring && !pending.arc && pending.disc == 0 && pending.mark == .None)
	testing.expect_value(t, ui.stepper_look(.Pending, 1, 0, numbers = true).mark, ui.Stepper_Mark.Number)
	active := ui.stepper_look(.Active, 1, 0)
	testing.expect(t, active.ring && active.arc && active.disc == 0 && active.mark == .None)
	done := ui.stepper_look(.Done, 1, 1)
	testing.expect(t, !done.ring && done.disc == 1 && done.mark == .Check && done.drawn == 1 && done.fill == 1)
	failed := ui.stepper_look(.Failed, 1, 1)
	testing.expect(t, failed.disc == 1 && failed.mark == .Cross && failed.drawn == 1)
	testing.expect_value(t, failed.fill, 0)   // (only a done step fills the connector after it)
	skipped := ui.stepper_look(.Skipped, 1, 1)
	testing.expect(t, skipped.ring && skipped.disc == 0 && skipped.mark == .Dash && skipped.fill == 0)
}

@(test)
a_mark_pops_then_draws_its_stroke :: proc(t: ^testing.T) {
	start := ui.stepper_look(.Done, 0, 0)
	testing.expect(t, start.disc == 0 && start.drawn == 0 && start.fill == 0, "nothing at the start")
	early := ui.stepper_look(.Done, 0.2, 0.2)
	testing.expect(t, early.disc > 0 && early.drawn == 0, "the disc pops before the stroke starts")
	over: f32
	for k in 0 ..= 100 { over = max(over, ui.stepper_look(.Done, f32(k) / 100, 0).disc) }
	testing.expect(t, over > 1 && over < 1.1, "the pop overshoots a little")
	late := ui.stepper_look(.Done, 0.7, 0.7)
	testing.expect(t, late.drawn > 0 && late.drawn < 1 && late.disc == 1)
}

@(test)
the_progress_is_said :: proc(t: ^testing.T) {
	steps := []ui.Stepper_Step{{label = "Unpack", state = .Done}, {label = "Install", state = .Active}, {label = "Check"}, {label = "Clean", state = .Skipped}}
	p := ui.stepper_progress(steps)
	testing.expect_value(t, p.total, 4)
	testing.expect_value(t, p.finished, 2)
	testing.expect_value(t, p.current, 1)
	testing.expect(t, p.busy)
	testing.expect_value(t, ui.stepper_fraction(p), 0.5)
	testing.expect_value(t, ui.stepper_spoken(steps), "Step 2 of 4: Install, in progress")

	// no step under way: a failed one is the one said, before a pending one
	steps[1].state = .Pending
	steps[2].state = .Failed
	testing.expect_value(t, ui.stepper_spoken(steps), "Step 3 of 4: Check, failed")
	steps[2].state = .Pending
	testing.expect_value(t, ui.stepper_spoken(steps), "Step 2 of 4: Install, waiting")
	for &st in steps { st.state = .Done }
	testing.expect_value(t, ui.stepper_spoken(steps), "Every step is done")
	testing.expect_value(t, ui.stepper_progress(steps).current, -1)
	testing.expect_value(t, ui.stepper_spoken(nil), "")
}

@(test)
a_screen_reader_hears_one_progress_indicator :: proc(t: ^testing.T) {
	f := fx_new(t)
	if f == nil { return }
	defer fx_destroy(f)
	f.steps = {{label = "Unpack", state = .Done}, {label = "Install", state = .Active}, {label = "Check"}, {label = "Clean"}}
	r := frame(f)
	a := r.box.a11y
	if !testing.expect(t, a != nil) { return }
	testing.expect_value(t, a.role, ui.A11y_Role.Progress_Indicator)
	testing.expect_value(t, a.value, "Step 2 of 4: Install, in progress")
	testing.expect_value(t, a.numeric.? or_else -1, 25)
	testing.expect(t, a.busy)
	testing.expect(t, a.no_children.? or_else false, "its words are not read again")
}

@(test)
with_animations_off_a_state_jumps :: proc(t: ^testing.T) {
	f := fx_new(t)
	if f == nil { return }
	defer fx_destroy(f)
	f.steps = {{label = "Unpack"}, {label = "Install"}, {label = "Check"}, {label = "Clean"}}
	frame(f)
	f.steps[0].state = .Done
	f.steps[1].state = .Failed
	r := frame(f)
	testing.expect(t, r.looks[0].disc == 1 && r.looks[0].drawn == 1 && r.looks[0].fill == 1, "done at once")
	testing.expect(t, r.looks[1].disc == 1 && r.looks[1].drawn == 1, "failed at once")
	testing.expect(t, !ui.needs_frame(&f.s), "no frame asked for")
	f.steps[2].state = .Active
	frame(f)
	testing.expect(t, !ui.needs_frame(&f.s), "a still arc asks for no frame")
}

@(test)
a_mark_runs_on_the_builds_clock :: proc(t: ^testing.T) {
	f := fx_new(t)
	if f == nil { return }
	defer fx_destroy(f)
	f.animations = true
	f.steps = {{label = "Unpack", state = .Done}, {label = "Install"}, {label = "Check"}, {label = "Clean"}}
	r := frame(f)
	testing.expect(t, r.looks[0].drawn == 1 && r.looks[0].fill == 1, "a node seen for the first time is settled")
	testing.expect(t, !ui.needs_frame(&f.s), "at rest: no frame")

	f.steps[1].state = .Done
	r = frame(f)
	testing.expect(t, r.looks[1].disc == 0 && r.looks[1].drawn == 0 && r.looks[1].fill == 0, "its first frame is its start")
	testing.expect(t, ui.needs_frame(&f.s), "it asks for frames while it moves")
	mark_s := f32(ui.STEPPER_MARK_MS) / 1000
	frames := int(mark_s / DT) + 1
	for _ in 0 ..< frames - 1 {
		r = frame(f)
		testing.expect(t, ui.needs_frame(&f.s))
	}
	r = frame(f)
	testing.expect(t, abs(r.looks[1].drawn - 1) < EPS && r.looks[1].disc == 1 && r.looks[1].fill == 1, "drawn whole at its time")
	frame(f)
	testing.expect(t, !ui.needs_frame(&f.s), "settled: no frame")

	// back to pending and done again: a new state, a new clock
	f.steps[1].state = .Pending
	frame(f)
	frame(f)
	f.steps[1].state = .Done
	r = frame(f)
	testing.expect_value(t, r.looks[1].drawn, 0)

	// an active step turns: it asks for frames as long as it is shown
	f.steps[2].state = .Active
	for _ in 0 ..< frames * 2 { frame(f) }
	testing.expect(t, ui.needs_frame(&f.s))
}

@(test)
a_horizontal_stepper_spaces_its_nodes_evenly :: proc(t: ^testing.T) {
	f := fx_new(t)
	if f == nil { return }
	defer fx_destroy(f)
	f.steps = {{label = "Unpack"}, {label = "A label far too long for its column, in many words, and averyveryverylongwordthatcannotwrap"}, {label = "Check"}, {label = "Clean", detail = "2 files"}}
	frame(f)
	r := frame(f)
	cell := f32(WIDTH) / STEPS
	nodes := nodes_of(r.box)
	if !testing.expect_value(t, len(nodes), STEPS) { return }
	for b, i in nodes {
		c := (b.rect.min.x + b.rect.max.x) * 0.5
		testing.expectf(t, abs(c - (f32(i) + 0.5) * cell) < 1, "node %d centred in its column: %v", i, c)
		testing.expect_value(t, b.rect.min.y, nodes[0].rect.min.y)
	}
	testing.expect(t, r.box.rect.max.x - r.box.rect.min.x <= WIDTH, "a long label does not widen it")

	// above: the nodes stay on one line under labels of different heights
	f.o.labels = .Above
	frame(f)
	r = frame(f)
	nodes = nodes_of(r.box)
	for b in nodes { testing.expect_value(t, b.rect.min.y, nodes[0].rect.min.y) }
	testing.expect(t, nodes[0].rect.min.y > r.box.rect.min.y, "under the words")

	// right to left: the first step is at the right
	f.o = {direction = .Left}
	frame(f)
	r = frame(f)
	nodes = nodes_of(r.box)
	testing.expect(t, nodes[0].rect.min.x < nodes[1].rect.min.x, "in the tree from left to right")
	first := node_of_step(r.box, 0)
	testing.expect(t, first != nil && first.rect.min.x > f32(WIDTH) * 0.75, "the first step at the right")
}

@(test)
a_vertical_stepper_puts_its_words_beside :: proc(t: ^testing.T) {
	f := fx_new(t)
	if f == nil { return }
	defer fx_destroy(f)
	f.steps = {{label = "Unpack", detail = "a detail long enough to wrap onto more than one line in a narrow stepper"}, {label = "Install"}, {label = "Check"}}
	f.o = {direction = .Down}
	frame(f)
	r := frame(f)
	nodes := nodes_of(r.box)
	if !testing.expect_value(t, len(nodes), 3) { return }
	testing.expect(t, nodes[0].rect.min.x == r.box.rect.min.x, "after: the nodes at the left")
	for i in 1 ..< len(nodes) { testing.expect(t, nodes[i].rect.min.y > nodes[i - 1].rect.max.y, "top to bottom") }

	f.o = {direction = .Up, labels = .Before, compact = false}
	frame(f)
	r = frame(f)
	first := node_of_step(r.box, 0)
	last := node_of_step(r.box, 2)
	testing.expect(t, first != nil && last != nil && first.rect.min.y > last.rect.min.y, "bottom to top")
	testing.expect(t, abs(first.rect.max.x - r.box.rect.max.x) < 1, "before: the nodes at the right")

	f.o = {direction = .Down, compact = true}
	frame(f)
	r = frame(f)
	testing.expect(t, r.box.rect.max.y - r.box.rect.min.y < 3 * 15 * 3.5, "compact: no words")
}

// The fixture: a State with no window, the embedded face, a stepper WIDTH wide.
Fx :: struct {
	fonts:      font.State,
	theme:      ui.Theme,
	s:          ui.State,
	base:       font.Font_Id,
	steps:      []ui.Stepper_Step,   // (a literal of the test's frame)
	o:          ui.Stepper_Options,
	animations: bool,
	time_ms:    f64,
}

// (on the heap: the State keeps pointers to the fonts and the theme)
@(private = "file")
fx_new :: proc(t: ^testing.T) -> ^Fx {
	f := new(Fx)
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok) { font.destroy(&f.fonts); free(f); return nil }
	f.base = id
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.time_ms = 1000
	return f
}

@(private = "file")
fx_destroy :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
	free(f)
}

@(private = "file")
frame :: proc(f: ^Fx) -> (r: ui.Stepper_Result) {
	f.time_ms += f64(DT) * 1000
	ui.begin_build(&f.s, {
		window_size = WINDOW, dt = DT, time_ms = f.time_ms, animations = f.animations, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base, font_size = 15, text_pad = 6},
	})
	ui.next({width = ui.px(WIDTH)})
	r = ui.stepper("###steps", f.steps, f.o)
	ui.end_build()
	free_all(context.temp_allocator)
	return
}

// The nodes under `b`, in the order of the tree (from left to right, from top to bottom).
@(private = "file")
nodes_of :: proc(b: ^ui.Box) -> []^ui.Box {
	out := make([dynamic]^ui.Box, context.temp_allocator)
	walk :: proc(b: ^ui.Box, out: ^[dynamic]^ui.Box) {
		for c := b.first; c != nil; c = c.next {
			if c.name == "stepper_node" { append(out, c) }
			walk(c, out)
		}
	}
	walk(b, &out)
	return out[:]
}

// The node of step `i`: in its cell (horizontal) or its row (vertical), named by the step's index.
@(private = "file")
node_of_step :: proc(b: ^ui.Box, i: int) -> ^ui.Box {
	names := [2]string{"stepper_cell", "stepper_step"}
	find :: proc(b: ^ui.Box, name: string) -> ^ui.Box {
		for c := b.first; c != nil; c = c.next {
			if c.name == name { return c }
			if x := find(c, name); x != nil { return x }
		}
		return nil
	}
	for prefix in names {
		if cell := find(b, fmt.tprintf("%s%d", prefix, i)); cell != nil { return find(cell, "stepper_node") }
	}
	return nil
}
