package fidget

// The four gallery pages. Everything is built from `ui` widgets; the only custom draw procs here are the
// physics arena, the spinner and the data-page column resizer.

import "core:fmt"
import "core:math"
import "core:strings"
import "../../draw"
import "../../ui"

seg_labels := [?]string{"Day", "Week", "Month"}
chip_labels := [?]string{"Alpha", "Beta", "Gamma", "Delta"}
lang_items := [?]string{"C", "C++", "Rust", "Zig", "Odin", "Go"}
sort_items := [?]string{"Name", "Date modified", "Size", "Type"}

reset_values :: proc(app: ^App) {
	app.sw = {true, false, true}
	app.chk = {true, false, false}
	app.radio_sel = 0
	app.slider = {64, 0.75, 21.5}
	app.range_lo, app.range_hi = 20, 70
	app.stepper = 5
	app.seg = 1
	app.chips = 0x5
	app.dd = {0, 1}
	app.rating = 3
	app.progress, app.progress_run = 0.35, false
	ui.field_set(&app.name, "Ada Lovelace")
	ui.field_set(&app.email, "ada@example.com")
	ui.field_set(&app.number, "42")
	ui.field_clear(&app.search)
	ui.field_clear(&app.tag_input)
	ui.field_clear(&app.bio)
	ui.field_clear(&app.filter)
	ui.area_set(&app.editor, "# Notes\n\nA multi-line editor from gui_toolkit:\n  - Enter keeps the indentation\n  - Ctrl+Z / Ctrl+Y undo and redo\n  - Up / Down keep the column\n  - Tab moves the focus (or indents, see below)\n")
	// every tag is heap-owned (removing one deletes its string)
	for t in app.tags { delete(t) }
	clear(&app.tags)
	for t in ([?]string{"ui", "odin", "fast"}) { append(&app.tags, strings.clone(t)) }
	app.agree = false
	app.gravity, app.bounce, app.repel, app.phys_run = 1, 0.72, true, true
	app.sort_col, app.sort_asc, app.selected_row = 0, true, -1
	app.order_key = max(u64)
	app.notes[0] = {{20, 18}, {210, 118}, "Notes", 0}
	app.notes[1] = {{150, 96}, {200, 112}, "Counter", 1}
	app.notes[2] = {{40, 170}, {220, 118}, "Mix", 2}
	app.note_order = {0, 1, 2}
}

////////////////////////////////
// Scrollable page frame

@(deferred_none = page_end)
page_begin :: proc(id: string) -> bool {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	sc := ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, id)
	_ = ui.signal(sc)
	ui.push_parent(sc)
	ui.spacer(ui.px(em))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	ui.push_parent(ui.build_box({}, "###page_row"))
	ui.spacer(ui.px(em * 1.3))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	ui.push_parent(ui.build_box({}, "###page_col"))
	return true
}

@(private)
page_end :: proc() {
	em := ui.font_size()
	ui.pop_parent()
	ui.spacer(ui.px(em * 1.3))
	ui.pop_parent()
	ui.spacer(ui.px(em * 0.5))
	ui.pop_parent()   // the scroll box pushed by scroll_y
}

// Two half-width columns inside a page.
@(deferred_none = ui.pop_parent)
half :: proc(id: string, frac: f32 = 0.5) -> bool {
	ui.next({width = ui.pct(frac), height = ui.children_sum(), axis = .Y})
	ui.push_parent(ui.build_box({}, id))
	return true
}

////////////////////////////////
// Controls page

page_controls :: proc(app: ^App) {
	em := ui.font_size()
	if page_begin("###pg_controls") {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(id = "###cols") {
			if half("###left") {
				if ui.card("Buttons", ICON_PLAY) {
					ui.spacer(ui.px(em * 0.3))
					if ui.flow({em * 0.5, em * 0.5}, "###btnrow") {
						if ui.tags("accent_button") {
							if ui.button_icon("###b_primary", ICON_PLAY, "Primary").clicked { ui.toast(.Good, "Primary clicked") }
						}
						if ui.button_icon("###b_secondary", "", "Secondary").clicked { ui.toast(.Info, "Secondary clicked") }
						if ui.tags("danger_button") {
							if ui.button_icon("###b_danger", ICON_TRASH, "Danger").clicked { ui.toast(.Bad, "Danger clicked") }
						}
						if ui.tags("ghost_button") {
							if ui.button_icon("###b_ghost", "", "Ghost").clicked { ui.toast(.Info, "Ghost clicked") }
						}
					}
					ui.spacer(ui.px(em * 0.3))
					if ui.flow({em * 0.2, em * 0.2}, "###iconrow") {
						icons := [?]string{ICON_PLAY, ICON_PAUSE, ICON_STOP, ICON_REFRESH, ICON_SAVE, ICON_PIN, ICON_CLIPBOARD, ICON_GEAR}
						tips := [?]string{"Play", "Pause", "Stop", "Refresh", "Save", "Pin", "Copy", "Settings"}
						for g, i in icons {
							ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2)})
							sig := ui.icon_button(fmt.tprintf("ib_%d", i), g)
							if ui.hovered_for(sig, 0.4) {
								if ui.tooltip() {
									ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 2))})
									ui.label(tips[i])
								}
							}
							if sig.clicked { ui.toast(.Info, "%s", tips[i]) }
						}
					}
					ui.spacer(ui.px(em * 0.3))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
					if ui.row(.Center, id = "###disrow") {
						ui.button_icon("###b_disabled", "", "Disabled", disabled = true)
						ui.spacer(ui.px(em * 0.8))
						if ui.tags("weak") {
							ui.next({width = ui.fill(), height = ui.pct(1)})
							ui.label("Hover, press (they squish), Ctrl+wheel zooms the whole UI.")
						}
					}
				}
				if ui.card("Selection", ICON_LIST) {
					if ui.form_row("Range") { ui.segmented("###seg1", seg_labels[:], &app.seg) }
					if ui.form_row("Tags") { ui.chips("chips1", chip_labels[:], &app.chips) }
					if ui.form_row("Language") { ui.dropdown("###dd_lang", lang_items[:], &app.dd[0]) }
					if ui.form_row("Sort by") { ui.dropdown("###dd_sort", sort_items[:], &app.dd[1]) }
				}
				if ui.card("Menus & tooltips", ICON_WINDOW) {
					ctx_key := ui.key_from_string(0, "ctx_demo")
					if ui.tags("input") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 5.5)), text_align = .Center, radius = em * 0.6})
						area := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Text, .Draw_Hot_Effects}, "Right-click anywhere in this box###ctx_area")
						area.cursor = .Arrow
						if ui.signal(area).right_clicked { ui.ctx_menu_open(ctx_key, ui.mouse_pos()) }
					}
					mw := em * 16
					if ui.ctx_menu(ctx_key, mw) {
						if ui.menu_item("Copy", "Ctrl+C", false, ICON_CLIPBOARD).clicked { ui.toast(.Info, "Copy") }
						if ui.menu_item("Paste", "Ctrl+V").clicked { ui.toast(.Info, "Paste") }
						if ui.menu_item("Duplicate", "Ctrl+D").clicked { ui.toast(.Info, "Duplicate") }
						ui.hline(ui.px(mw))
						if ui.menu_item("Show grid", "", app.ctx_check).clicked { app.ctx_check = !app.ctx_check }
						ui.hline(ui.px(mw))
						if ui.menu_item("Delete", "Del", false, ICON_TRASH).clicked { ui.toast(.Bad, "Delete") }
					}
					ui.spacer(ui.px(em * 0.7))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
					if ui.row(.Center, id = "###tiprow") {
						sig := ui.button_icon("###b_tip", ui.ICON_INFO, "Hover for a rich tooltip")
						if ui.hovered_for(sig, 0.4) {
							if ui.tooltip() {
								if ui.style({width = ui.text_size(em * 0.5), height = ui.px(ui.dense(em * 2))}) {
									if ui.style({font_size = math.round(em * 1.1)}) { ui.label("Rich tooltip") }
									if ui.tags("weak") { ui.label("Tooltips are floating boxes:") }
									if ui.tags("weak") { ui.label("any widgets work in them.") }
								}
							}
						}
					}
				}
			}
			ui.spacer(ui.px(em))
			if half("###right") {
				if ui.card("Toggles", ICON_TARGET) {
					if ui.style({width = ui.fill(), height = ui.px(ui.dense(em * 2.3))}) {
						ui.toggle("###sw0", "Wi-Fi", &app.sw[0])
						ui.toggle("###sw1", "Bluetooth", &app.sw[1])
						ui.toggle("###sw2", "Notifications", &app.sw[2])
						ui.checkbox("###ck0", "Remember me", &app.chk[0])
						ui.checkbox("###ck1", "Send anonymous usage data", &app.chk[1])
						ui.radio("###rd0", "Small", &app.radio_sel, 0)
						ui.radio("###rd1", "Medium", &app.radio_sel, 1)
						ui.radio("###rd2", "Large", &app.radio_sel, 2)
					}
				}
				if ui.card("Sliders & steppers", ICON_GRID) {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.3))})
					ui.toggle("###sl_on", "Enabled", &app.sliders_on)
					if ui.disabled(!app.sliders_on) {
						if ui.form_row("Volume") { ui.slider("###sl0", &app.slider[0], 0, 100, 1, "%.0f") }
						if ui.form_row("Opacity") { ui.slider("###sl1", &app.slider[1], 0, 1, 0, "%.2f") }
						if ui.form_row("Temperature") { ui.slider("###sl2", &app.slider[2], -10, 40, 0.5, "%.1f C") }
						if ui.form_row("Range") { ui.range_slider("###rng1", &app.range_lo, &app.range_hi, 0, 100) }
						if ui.form_row("Stepper") { ui.stepper("###step1", &app.stepper, 0, 99) }
						if ui.form_row("Rating") { ui.rating("###rate1", &app.rating) }
					}
				}
				if ui.card("Progress & feedback", ui.ICON_INFO) {
					if app.progress_run {
						app.progress += app.real_dt * 0.12
						app.frames_requested = 4
						if app.progress >= 1 { app.progress, app.progress_run = 1, false; ui.toast(.Good, "Download complete") }
					}
					if ui.form_row("Download") { ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 0.55))}); ui.progress("###pr_det", app.progress) }
					if ui.form_row("Loading") { ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 0.55))}); ui.progress("###pr_ind", 0, true) }
					ui.spacer(ui.px(em * 0.3))
					if ui.flow({em * 0.5, em * 0.5}, "###dlrow") {
						if ui.tags("accent_button") {
							if ui.button_icon("###b_dl", app.progress_run ? ICON_PAUSE : ICON_PLAY, app.progress_run ? "Pause" : "Start").clicked {
								if app.progress >= 1 { app.progress = 0 }
								app.progress_run = !app.progress_run
							}
						}
						if ui.button_icon("###b_dl_reset", ICON_UNDO, "Reset").clicked { app.progress, app.progress_run = 0, false }
					}
					ui.spacer(ui.px(em * 0.3))
					if ui.flow({em * 0.5, em * 0.5}, "###toastrow") {
						if ui.button_icon("###t_info", "", "Info").clicked { run_cmd(app, .Toast_Info) }
						if ui.button_icon("###t_good", "", "Success").clicked { run_cmd(app, .Toast_Good) }
						if ui.button_icon("###t_warn", "", "Warning").clicked { run_cmd(app, .Toast_Warn) }
						if ui.button_icon("###t_bad", "", "Error").clicked { run_cmd(app, .Toast_Bad) }
					}
					ui.spacer(ui.px(em * 0.3))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
					if ui.row(.Center, id = "###modalrow") {
						if ui.tags("ghost_button") {
							if ui.button_icon("###b_modal", ICON_QUESTION, "Open dialog").clicked { app.modal_open = true }
						}
					}
				}
			}
		}
	}
}

////////////////////////////////
// Inputs page

words := [?]string{
	"arena allocator", "box tree", "command palette", "context menu", "custom draw", "frame loop",
	"immediate mode", "keyboard focus", "layout pass", "linked list", "retained state", "scroll region",
	"signal flags", "style stack", "theme tags", "tooltip root", "virtual list", "zero is initialization",
}

email_valid :: proc(f: ^ui.Text_Field) -> bool {
	s := ui.field_string(f)
	at := strings.index_byte(s, '@')
	if at <= 0 || at >= len(s) - 1 { return false }
	return strings.index_byte(s[at:], '.') > 0
}

number_valid :: proc(f: ^ui.Text_Field) -> bool {
	s := ui.field_string(f)
	if len(s) == 0 { return false }
	for c, i in s { if !(c >= '0' && c <= '9' || (i == 0 && c == '-')) { return false } }
	return true
}

page_inputs :: proc(app: ^App) {
	em := ui.font_size()
	if page_begin("###pg_inputs") {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(id = "###cols") {
			if half("###left") {
				if ui.card("Text inputs", ICON_PENCIL) {
					email_ok := email_valid(&app.email)
					num_ok := number_valid(&app.number)
					if ui.form_row("Name") { ui.line_edit("###in_name", &app.name, "Your name") }
					if ui.form_row("Email") {
						if len(app.email.buf) > 0 && !email_ok { ui.push_tags("bad") }
						ui.line_edit("###in_email", &app.email, "you@example.com")
						if len(app.email.buf) > 0 && !email_ok { ui.pop_tags() }
					}
					hint(app, em, len(app.email.buf) == 0 ? 0 : (email_ok ? 1 : 2), "We never share it.", "Looks good.", "Needs an @ and a domain.")
					if ui.form_row("Number") {
						if len(app.number.buf) > 0 && !num_ok { ui.push_tags("bad") }
						ui.line_edit("###in_num", &app.number, "digits only")
						if len(app.number.buf) > 0 && !num_ok { ui.pop_tags() }
					}
					hint(app, em, len(app.number.buf) == 0 ? 0 : (num_ok ? 1 : 2), "Try typing letters.", "Valid integer.", "Not a number.")
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
						ui.label("Arrows, Home/End, Ctrl+arrows, Shift = select, Ctrl+A/C/X/V.")
					}
				}
				if ui.card("Live fuzzy search", ICON_FIND) {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
					ui.line_edit("###in_search", &app.search, "Search concepts (try: ar al)")
					needle := ui.field_string(&app.search)
					matches := 0
					for w, i in words {
						ranges, ok := ui.fuzzy_find(needle, w)
						if !ok { continue }
						matches += 1
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
						if ui.row(.Center, {.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###word_%d", i)) {
							sig := ui.signal(ui.parent_box())
							ui.spacer(ui.px(em * 0.5))
							if ui.tags("weak") { ui.icon(ICON_DOT, em * 1.2) }
							ui.next({width = ui.fill(), height = ui.pct(1)})
							ui.label_fuzzy(w, ranges)
							if sig.clicked { ui.toast(.Info, "Picked: %s", w) }
						}
					}
					if matches == 0 {
						if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))}); ui.label("No matches.") }
					}
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8)), font_size = math.round(em * 0.85)})
						ui.label(fmt.tprintf("%d of %d", matches, len(words)))
					}
				}
			}
			ui.spacer(ui.px(em))
			if half("###right") {
				if ui.card("Multi-line editor", ICON_PENCIL) {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 13))})
					res := ui.text_edit("###editor", &app.editor, "Write something...", line_numbers = true, tab_indents = app.editor_tab_indents)
					if res.committed { ui.toast(.Good, "Ctrl+Enter: %d lines", ui.area_line_count(&app.editor)) }
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.3))})
					if ui.row(.Center, id = "###editor_bar") {
						ui.next({width = ui.pct(0.55), height = ui.pct(1)})
						ui.checkbox("###editor_tab", "Tab inserts spaces", &app.editor_tab_indents)
						if ui.tags("weak") {
							ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.85), text_align = .Right})
							ui.label(fmt.tprintf("%d lines, %d chars", ui.area_line_count(&app.editor), len(app.editor.buf)))
						}
					}
				}
				if ui.card("Tag input", ICON_PIN) {
					ui.spacer(ui.px(em * 0.3))
					if ui.flow({em * 0.4, em * 0.4}, "###tagrow") {
						remove := -1
						for tag, i in app.tags {
							if ui.tags("button") {
								ui.next({width = ui.children_sum(), height = ui.px(ui.dense(em * 1.9)), radius = em * 0.95, axis = .X, cross = .Center})
								chip := ui.build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###tag_%s", tag))
								if ui.parent(chip) {
									ui.spacer(ui.px(em * 0.8))
									ui.next({width = ui.text_size(), height = ui.pct(1)})
									ui.label(tag)
									ui.next({width = ui.px(em * 1.6), height = ui.px(em * 1.6)})
									if ui.icon_button(fmt.tprintf("tag_x_%d", i), ui.ICON_X).clicked { remove = i }
									ui.spacer(ui.px(em * 0.3))
								}
							}
						}
						if remove >= 0 { delete(app.tags[remove]); ordered_remove(&app.tags, remove) }
					}
					ui.spacer(ui.px(em * 0.3))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
					ts := ui.line_edit("###in_tag", &app.tag_input, len(app.tags) >= 8 ? "Tag limit reached" : "Type a tag, press Enter")
					if ts.committed && len(app.tag_input.buf) > 0 && len(app.tags) < 8 {
						append(&app.tags, strings.clone(ui.field_string(&app.tag_input)))
						ui.field_clear(&app.tag_input)
					}
				}
				if ui.card("A small form", ICON_CLIPBOARD) {
					can_submit := len(app.name.buf) > 0 && email_valid(&app.email) && app.agree
					if ui.form_row("Title") { ui.line_edit("###in_bio", &app.bio, "Engineer, designer, ...") }
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.3))})
					ui.checkbox("###ck_agree", "I agree to the terms", &app.agree)
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
					if ui.row(.Center, id = "###submitrow") {
						if ui.tags("accent_button") {
							if ui.button_icon("###b_submit", ui.ICON_CHECK, "Submit", disabled = !can_submit).clicked {
								ui.toast(.Good, "Submitted: %s <%s>", ui.field_string(&app.name), ui.field_string(&app.email))
							}
						}
						ui.spacer(ui.px(em * 0.8))
						if ui.tags(can_submit ? "good" : "weak") {
							ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.85)})
							ui.label(can_submit ? "Ready to submit." : "Needs a name, a valid email and the checkbox.")
						}
					}
				}
				if ui.card("Keyboard shortcuts", ICON_GEAR) {
					Entry :: struct { keys, what: string }
					entries := [?]Entry{
						{"Ctrl+K", "Command palette"}, {"Ctrl+1..4", "Switch page"}, {"Ctrl+T", "Next theme"},
						{"Ctrl+B", "Toggle status bar"}, {"Ctrl+J", "Toggle animations"}, {"Ctrl+wheel", "Zoom"},
						{"Tab", "Next widget (Shift+Tab: previous)"}, {"Enter / Space", "Activate the focused widget"},
						{"Ctrl+Z / Ctrl+Y", "Undo / redo in the editor"},
					}
					for e in entries {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
						if ui.row(.Center, id = fmt.tprintf("###sc_%s", e.keys)) {
							ui.kbd(e.keys)
							ui.spacer(ui.px(em * 0.8))
							if ui.tags("weak") {
								ui.next({width = ui.fill(), height = ui.pct(1)})
								ui.label(e.what)
							}
						}
					}
				}
			}
		}
	}
}

@(private)
hint :: proc(app: ^App, em: f32, state: int, s0, s1, s2: string) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
	if ui.row(.Center, id = fmt.tprintf("###hint_%s", s0[:6])) {
		ui.spacer(ui.pct(0.34, 1))
		tag := state == 0 ? "weak" : (state == 1 ? "good" : "bad")
		if ui.tags(tag) {
			ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.85)})
			ui.label(state == 0 ? s0 : (state == 1 ? s1 : s2))
		}
	}
}

_ :: draw
