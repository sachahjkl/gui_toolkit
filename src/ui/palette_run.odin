package ui

// The palette's run mode (src/md/features/everything-palette.md, "Layer 2, as built"): Enter on an item that runs
// unfolds its control under its row (a setting's value) or its form (a command's arguments); a change is written at
// once, Enter keeps it, Escape puts back the value of before. The palette owns the levels and the keys; a runner
// (Palette_Runner: prefs_page's, which has the control table) owns the values.
//
//   Closed ──Enter on an item that runs──▶ Control ──Enter: kept / Escape: put back──▶ Closed
//   Closed ──Enter on a command with arguments──▶ Form at 0 ──Enter──▶ … at n − 1 ──Enter──▶ the choice (closed)
//   Form at n ──Escape──▶ Form at n − 1; at 0 ──Escape──▶ Closed
//   palette_open_form ──▶ Form at 0, no list under it: Escape at 0 or its item gone ──▶ the palette closed
//   any level ──a close the palette did not ask──▶ closed, as Escape at each level; its item gone ──▶ Closed, nothing put back
//
// Every write is made in palette_chosen, at the top of the program's next build: the palette's view is built after the
// program's content, and a value written there would show in the palette a frame before the page.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"

Palette_Run_Level :: enum u8 { Closed, Control, Form }

// The keys the palette reads for the control before its field: a move in a list or a step of a number (Down +1, Up −1,
// Page Down and Page Up a page of `page_rows`), and Enter (the control writes the row it has selected before it is
// kept).
Palette_Run_Keys :: struct {
	step:  int,
	page:  bool,
	enter: bool,
	tab:   bool,   // Tab: the control completes the field's text (a path: palette_run_set_text)
}

// What runs an item's run mode: its values and its controls. The settings source's and the commands' forms are
// prefs_page's (palette_settings_add, palette_forms_use).
Palette_Runner :: struct {
	// opens item `run.id`'s run mode: notes the value Escape puts back, makes its control's state (`run.state`). Its
	// steps: 1 a value, n a form's arguments; 0: it has none, Enter chooses it
	open:   proc(p: ^Command_Palette, run: ^Palette_Run) -> int,
	// the field's text when step `run.arg` opens (temp), and whether it is the value's text (else the control's filter)
	text:   proc(p: ^Command_Palette, run: ^Palette_Run) -> (text: string, value: bool),
	// builds the control of step `run.arg` under its row, `height` high: `query` the field's text, `keys` read before
	// the field. A value to write (temp): the palette writes it in palette_chosen
	build:  proc(p: ^Command_Palette, run: ^Palette_Run, query: string, keys: Palette_Run_Keys, height: f32) -> Maybe(string),
	// writes step `run.arg`'s value from its text: "" done, else why not (temp)
	write:  proc(p: ^Command_Palette, run: ^Palette_Run, text: string) -> string,
	// Escape on a value: the value of before, unless another path wrote it since the run mode's last write
	undo:   proc(p: ^Command_Palette, run: ^Palette_Run),
	// a form's values, in its arguments' order, as the settings file writes them (`allocator`)
	values: proc(p: ^Command_Palette, run: ^Palette_Run, allocator: runtime.Allocator) -> []string,
	// the run mode closed: lets go of what `open` made
	close:  proc(p: ^Command_Palette, run: ^Palette_Run),
	user:   rawptr,
}

// The run mode of a palette: its level, its item (by source and id: the row drawn is the one that runs), the step of a
// form, the field's text it opened with, and what the view asked that palette_chosen makes.
Palette_Run :: struct {
	level:      Palette_Run_Level,
	source:     ^Palette_Source,
	runner:     ^Palette_Runner,
	id:         string,   // (owned)
	title:      string,   // (owned) its row's
	icon:       string,   // (owned)
	arg, args:  int,      // the step shown, the steps (a value: 0 of 1)
	opened:     string,   // (owned) the field's text when the step opened
	value:      bool,     // the field holds the value's text, else the control's filter
	error:      string,   // (owned) why the last write was refused ("": none)
	query:      string,   // (owned) the field's text before the run mode: put back when it closes
	generation: u64,      // the palette's generation its item was last found at
	// opened by palette_open_form: no list under it, so leaving the first step closes the palette
	direct:     bool,
	state:      rawptr,   // the runner's, for this run
	// asked by the view, made by palette_chosen
	due_write:  string,   // (owned)
	has_write:  bool,
	due:        Palette_Run_Due,
}

@(private)
Palette_Run_Due :: enum u8 { None, Keep, Back, Gone }   // Gone: its item left its source's answer

// The run mode's level, for a test or a program's own hint.
palette_run_level :: proc(p: ^Command_Palette) -> Palette_Run_Level { return p.run.level }

// The item the run mode is open on (ok false: none) and the step of its form.
palette_run_item :: proc(p: ^Command_Palette) -> (src: ^Palette_Source, id: string, arg: int, ok: bool) {
	if p.run.level == .Closed { return nil, "", 0, false }
	return p.run.source, p.run.id, p.run.arg, true
}

// Why the run mode's last write was refused ("": it was not).
palette_run_error :: proc(p: ^Command_Palette) -> string { return p.run.error }

// Opens the run mode of item `it` of `src` (Enter on it). False: its runner has no step for it (Enter chooses it).
@(private)
palette_run_open :: proc(p: ^Command_Palette, src: ^Palette_Source, it: Palette_Item) -> bool {
	r := src.runner
	if r == nil || r.open == nil { return false }
	run := &p.run
	palette_run_strings_free(run)
	run^ = {source = src, runner = r, id = strings.clone(it.id), title = strings.clone(it.title), icon = strings.clone(it.icon), generation = p.generation}
	n := r.open(p, run)
	if n <= 0 {
		if r.close != nil { r.close(p, run) }
		palette_run_strings_free(run)
		run^ = {}
		return false
	}
	run.args = n
	run.level = n > 1 || src == &p.commands.source ? .Form : .Control
	run.query = strings.clone(line_edit_string(&p.field))
	palette_run_step_text(p)
	return true
}

// Opens the palette over the window being built straight on command `id`'s form, at its first argument: a button that
// sets what a command sets (a model) opens its form, and the program keeps no chooser of its own. There is no list it
// came from: Escape at the first argument closes the palette. False, the palette left as it was: the commands source
// has no such command, it takes no argument, it cannot act now (`disabled`), or no forms runner is installed
// (prefs_page.palette_forms_use).
palette_open_form :: proc(p: ^Command_Palette, id: string) -> bool {
	c := &p.commands
	i, ok := c.index[id]
	if !ok || i >= len(c.table) || len(c.table[i].arguments) == 0 || c.source.runner == nil { return false }
	if i < len(c.disabled) && c.disabled[i] { return false }
	// (a run open on another item ends as a close the palette did not ask: its value of before put back)
	palette_run_close(p, true)
	palette_open(p)
	label, _, _ := command_shown(c.table[i])
	if !palette_run_open(p, &c.source, Palette_Item{id = id, title = label, icon = c.table[i].icon}) {
		palette_close(p)
		return false
	}
	p.run.direct = true
	return true
}

// The run mode left from its first step (Escape, its item gone): the list it came from, or, opened by
// palette_open_form, the palette closed.
@(private = "file")
palette_run_leave :: proc(p: ^Command_Palette, undo: bool) {
	if p.run.direct { palette_close(p); return }
	palette_run_close(p, undo)
}

// The field takes the text of the step shown (its value's, or empty for a filter), and the keyboard.
@(private = "file")
palette_run_step_text :: proc(p: ^Command_Palette) {
	run := &p.run
	text, value := "", false
	if run.runner.text != nil { text, value = run.runner.text(p, run) }
	delete(run.opened)
	run.opened, run.value = strings.clone(text), value
	delete(run.error)
	run.error = ""
	line_edit_set(&p.field, text)
	p.fresh = true
}

// Closes the run mode: `undo`, the value of before is put back first (Escape, a close the palette did not ask). The
// field gets the query back; the list is where it was.
@(private)
palette_run_close :: proc(p: ^Command_Palette, undo: bool) {
	run := &p.run
	if run.level == .Closed { return }
	if undo && run.level == .Control && run.runner.undo != nil { run.runner.undo(p, run) }
	if run.runner.close != nil { run.runner.close(p, run) }
	query := strings.clone(run.query, context.temp_allocator)
	palette_run_strings_free(run)
	run^ = {}
	line_edit_set(&p.field, query)
	p.fresh, p.reveal = true, true
}

@(private)
palette_run_strings_free :: proc(run: ^Palette_Run) {
	delete(run.id); delete(run.title); delete(run.icon); delete(run.opened); delete(run.error); delete(run.query)
	delete(run.due_write)
	run.id, run.title, run.icon, run.opened, run.error, run.query, run.due_write = "", "", "", "", "", "", ""
}

// (palette_chosen, at the top of the program's build) What the view asked: a value written, then Enter (kept: the next
// step, or the form's choice) or Escape (a step back, or the value of before).
@(private)
palette_run_due :: proc(p: ^Command_Palette) {
	run := &p.run
	if run.level == .Closed { return }
	r := run.runner
	if run.has_write {
		run.has_write = false
		err := r.write(p, run, run.due_write)
		delete(run.error)
		run.error = strings.clone(err)
		// (a value the control wrote: the field shows it, unless it is being typed)
		if err == "" && run.value && line_edit_string(&p.field) == run.opened {
			text, _ := r.text(p, run)
			delete(run.opened)
			run.opened = strings.clone(text)
			line_edit_set(&p.field, text)
		}
	}
	due := run.due
	run.due = .None
	switch due {
	case .None:
	case .Keep:
		if run.value {
			typed := line_edit_string(&p.field)
			if typed != run.opened {
				err := r.write(p, run, typed)
				if err != "" {
					delete(run.error)
					run.error = strings.clone(err)
					return
				}
			}
		}
		if run.level == .Control { palette_run_close(p, false); return }
		if run.arg + 1 < run.args {
			run.arg += 1
			palette_run_step_text(p)
			return
		}
		// (the form's last argument: the command chosen with its values, the palette closed)
		values: []string
		if r.values != nil { values = r.values(p, run, context.allocator) }
		src, id := run.source, strings.clone(run.id, context.temp_allocator)
		palette_run_close(p, false)
		palette_form_chosen(p, src, id, values)
	case .Back:
		if run.level == .Form && run.arg > 0 {
			run.arg -= 1
			palette_run_step_text(p)
			return
		}
		palette_run_leave(p, true)
	case .Gone:
		palette_run_leave(p, false)
	}
}

// The run mode's item gone from its source's answer (a table made again without it): closed, nothing put back. Looked
// for only when the answers changed (the palette's generation), never at each build.
@(private)
palette_run_follow :: proc(p: ^Command_Palette) {
	run := &p.run
	if run.level == .Closed || run.generation == p.generation { return }
	run.generation = p.generation
	i := palette_source_index(p, run.source)
	if i >= 0 {
		snap := p.states[i].snap
		if snap == nil { return }   // (read again: its answer comes)
		for it in snap.items { if it.id == run.id { return } }
	}
	// (opened by palette_open_form, the palette closes: made by palette_chosen, not inside the palette's own view)
	if run.direct {
		run.due = .Gone
		gs().anim_busy = true
		return
	}
	palette_run_close(p, false)
}

// (the view, in the run mode) Its keys, read before the field: Escape a step back, Enter keeps, the moves to the
// control.
@(private)
palette_run_keys :: proc(p: ^Command_Palette, page: int) -> (keys: Palette_Run_Keys) {
	run := &p.run
	if run.due == .Gone { return }   // (its item gone: no key acts on it any more)
	if !hotkey_recording() && key_press_any(.Escape) { run.due = .Back }
	if key_press_any(.Return) { run.due = .Keep; keys.enter = true }
	if key_press_any(.Down) { keys.step = 1 }
	if key_press_any(.Up) { keys.step = -1 }
	if key_press_any(.Page_Down) { keys.step, keys.page = page, true }
	if key_press_any(.Page_Up) { keys.step, keys.page = -page, true }
	if key_press_any(.Tab) { keys.tab = true }
	return
}

// The run mode's control asks what Enter does (a row of its sub-list clicked: a click is a choice): the step's value
// kept, then the list, the next argument or the form's choice, made by palette_chosen after the control's write.
palette_run_keep :: proc(p: ^Command_Palette) {
	run := &p.run
	if run.level == .Closed || run.due != .None { return }   // (its item gone, or a key that asked first, wins)
	run.due = .Keep
	gs().anim_busy = true
}

// The run mode's control puts `text` in the palette's field, the caret at its end (a path completed by Tab): from its
// build, as the person typing it would. The field's text is the step's value text or its filter, as before.
palette_run_set_text :: proc(p: ^Command_Palette, text: string) {
	if p.run.level == .Closed { return }
	line_edit_set(&p.field, text)
	gs().anim_busy = true
}

// (the view, in the run mode) Under the field: its row, why a value was refused, then the control in the room left.
@(private)
palette_run_build :: proc(p: ^Command_Palette, keys: Palette_Run_Keys, row_h, height: f32) {
	run := &p.run
	em := font_size()
	icons := run.icon != "" && gs().icon_font != 0
	next({width = fill(), height = px(row_h), axis = .X, cross = .Center, radius = em * shape_of(.Row)})
	if row(.Center, {.Draw_Background}, "###palette_run_row") {
		spacer(px(em * 0.7))
		if icons {
			next({width = px(em * 1.7), height = pct(1), font = gs().icon_font, font_size = em * 0.95, text_align = .Center, text_pad = 0})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", run.icon))
			spacer(px(em * 0.5))
		}
		next({width = fill(), height = pct(1), text_pad = 0})
		label(fmt.tprintf("%s###t", run.title))
		if run.args > 1 {
			if tags("weak") {
				next({width = text_size(), height = pct(1), text_pad = 0, font_size = em * 0.9})
				label(fmt.tprintf("%d / %d###n", run.arg + 1, run.args))
			}
		}
		spacer(px(em * 0.7))
	}
	used := row_h
	if run.error != "" {
		if tags("bad") {
			next({width = fill(), font_size = math.round(em * 0.86), text_pad = em * 0.7})
			paragraph(fmt.tprintf("%s###palette_run_error", run.error))
		}
		used += math.round(em * 1.6)
	}
	spacer(px(math.round(em * 0.3)))
	used += math.round(em * 0.3)
	query := line_edit_string(&p.field)
	if run.runner.build != nil {
		next({width = fill(), height = px(max(height - used, 0)), axis = .Y})
		if column(id = "###palette_run_control") {
			if v, ok := run.runner.build(p, run, query, keys, max(height - used, 0)).?; ok {
				delete(run.due_write)
				run.due_write, run.has_write = strings.clone(v), true
			}
		}
	}
	if run.has_write || run.due != .None { gs().anim_busy = true }   // (palette_chosen makes it at the next build)
}

// (the hint row, in the run mode) Its keys: Enter keeps or goes on, Escape puts back or steps back.
@(private)
palette_run_hints :: proc(p: ^Command_Palette) -> string {
	run := &p.run
	enter := i18n.tr("Keep")
	escape := i18n.tr("Put back")
	if run.level == .Form {
		enter = run.arg + 1 < run.args ? i18n.tr("Next") : i18n.tr(run.source.enter != "" ? run.source.enter : "Run")
		escape = run.arg > 0 ? i18n.tr("Back") : i18n.tr("Cancel")
	}
	return fmt.tprintf("%s %s   %s %s", chord_text({.Return, {}}), enter, chord_text({.Escape, {}}), escape)
}

////////////////////////////////
// The sub-list: every closed list of the run mode

// A sub-list's state: the row selected, and whether it is brought into view at the next build.
Palette_Sublist :: struct {
	sel:    int,
	reveal: bool,
}

// The run mode's list of choices (a family, a theme, a closed list): `count` rows of one height (PALETTE_ROW_EM), only
// those in view built, `height` high. `step` moves the selection (the run mode's keys), which comes into view. `row`
// builds row `i`'s content inside its row box (the icon, the name, the mark). `moved`: the selection moved by `step`;
// `clicked`: the row clicked (-1: none), selected too; a runner keeps it as Enter would (palette_run_keep). The
// second click of a double one is no click: the first kept its row.
palette_sublist :: proc(id: string, st: ^Palette_Sublist, count: int, step: int, height: f32, row_build: proc(user: rawptr, i: int, selected: bool), user: rawptr) -> (moved: bool, clicked: int) {
	clicked = -1
	em := font_size()
	row_h := math.round(dense(em * PALETTE_ROW_EM))
	if count == 0 { return }
	if step != 0 {
		was := st.sel
		st.sel = clamp(st.sel + step, 0, count - 1)
		if abs(step) == 1 && was == st.sel { st.sel = step > 0 ? 0 : count - 1 }   // (a single step wraps, as the palette's)
		moved, st.reveal = st.sel != was, true
	}
	st.sel = clamp(st.sel, 0, count - 1)
	next({width = fill(), height = px(height)})
	if scroll_y(id) {
		lb := parent_box()
		view_h := lb.rect.max.y - lb.rect.min.y
		if st.reveal && view_h > row_h {
			top := f32(st.sel) * row_h
			lb.view_target.y = view_reveal_offset(lb.view_target.y, top, top + row_h, view_h)
			st.reveal = false
		}
		// (the rows in view and one more on each side; a view not laid out yet builds a screen's worth)
		shown := view_h > 0 ? view_h : height
		first := clamp(int(math.floor(lb.view_off.y / row_h)) - 1, 0, count)
		last := clamp(first + int(math.ceil(shown / row_h)) + 3, 0, count)
		if first > 0 { spacer(px(f32(first) * row_h)) }
		for i in first ..< last {
			sel := i == st.sel
			push_tags("menu_item", "nav")
			if sel { push_tags("selected") }
			next({width = fill(), height = px(row_h), axis = .X, cross = .Center, radius = em * shape_of(.Row)})
			flags := Box_Flags{.Clickable, .Draw_Hot_Effects, .Row}
			if sel { flags += {.Draw_Background, .Chosen} }
			rb := build_box(flags, fmt.tprintf("###sub_%d", i))
			a11y_default(rb, {role = .List_Box_Option, selected = sel, position = i + 1})
			// (the first click of a double one kept its row: the step after it is under the pointer now)
			if sig := signal(rb); sig.clicked && !sig.second_click { clicked = i }
			if parent(rb) { row_build(user, i, sel) }
			if sel { pop_tags() }
			pop_tags()
		}
		if last < count { spacer(px(f32(count - last) * row_h)) }
	}
	if clicked >= 0 { st.sel = clicked }
	return
}
