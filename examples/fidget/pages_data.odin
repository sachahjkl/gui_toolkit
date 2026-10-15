package fidget

// Data page: a 20,000-row table (sortable, filterable, resizable columns, keyboard navigation) where only the
// visible rows become boxes, plus a file tree. The virtualization is plain toolkit usage: a top spacer, the visible
// rows, a bottom spacer.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../../draw"
import "../../platform"
import "../../ui"

first_names := [?]string{"Ada", "Alan", "Grace", "Linus", "Margaret", "Dennis", "Ken", "Barbara", "Edsger", "Donald", "Radia", "Tim", "Katherine", "Claude", "Hedy", "Niklaus", "Frances", "Bjarne", "Guido", "Yukihiro"}
last_names := [?]string{"Lovelace", "Turing", "Hopper", "Torvalds", "Hamilton", "Ritchie", "Thompson", "Liskov", "Dijkstra", "Knuth", "Perlman", "Lee", "Johnson", "Shannon", "Lamarr", "Wirth", "Allen", "Stroustrup", "Rossum", "Matsumoto"}
dept_names := [?]string{"Engineering", "Design", "Sales", "Support", "Legal"}
status_names := [?]string{"Active", "Away", "Offline"}
col_names := [?]string{"ID", "Name", "Department", "Score", "Status"}

data_init :: proc(app: ^App) {
	app.rows = make([]Data_Row, DATA_ROW_COUNT)
	app.order = make([]u32, DATA_ROW_COUNT)
	for &r, i in app.rows {
		r.id = u32(i) + 1
		name := fmt.tprintf("%s %s", first_names[rand_u64() % len(first_names)], last_names[rand_u64() % len(last_names)])
		r.name_n = u8(min(len(name), len(r.name)))
		copy(r.name[:], name[:r.name_n])
		r.dept = u8(rand_u64() % len(dept_names))
		r.status = u8(rand_u64() % 3)
		r.score = u16(rand_u64() % 1001)
		r.year = u16(2005 + rand_u64() % 22)
	}
	app.col_w = {5, 13, 10.5, 6, 8}   // em units: DPI and zoom independent
	app.order_key = max(u64)
	app.selected_row = -1
}

row_name :: proc(r: ^Data_Row) -> string { return string(r.name[:r.name_n]) }

@(private)
rebuild_order :: proc(app: ^App) {
	h: u64 = 0xcbf29ce484222325
	for c in app.filter.buf { h = (h ~ u64(c)) * 0x100000001b3 }
	key := h ~ (u64(app.sort_col) << 1) ~ (app.sort_asc ? 1 : 0)
	if key == app.order_key { return }
	app.order_key = key
	query := strings.to_lower(ui.field_string(&app.filter), context.temp_allocator)
	n := 0
	for &r, i in app.rows {
		if query != "" {
			name := strings.to_lower(row_name(&r), context.temp_allocator)
			if !strings.contains(name, query) && !strings.contains(strings.to_lower(dept_names[r.dept], context.temp_allocator), query) { continue }
		}
		app.order[n] = u32(i)
		n += 1
	}
	app.order_count = n
	rows := app.rows
	col, asc := app.sort_col, app.sort_asc
	slice.sort_by(app.order[:n], proc(a, b: u32) -> bool {
		app := the_app
		ra, rb := &app.rows[a], &app.rows[b]
		c := 0
		switch app.sort_col {
		case 0: c = int(ra.id) - int(rb.id)
		case 1: c = strings.compare(row_name(ra), row_name(rb))
		case 2: c = int(ra.dept) - int(rb.dept)
		case 3: c = int(ra.score) - int(rb.score)
		case 4: c = int(ra.status) - int(rb.status)
		}
		if c == 0 { c = int(ra.id) - int(rb.id) }
		return app.sort_asc ? c < 0 : c > 0
	})
	_ = rows
	_, _ = col, asc
	app.selected_row = -1
}

Resize_Draw :: struct { hot: f32, line, accent: draw.Color }

@(private)
resize_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Resize_Draw)(user)
	cx := (b.rect.min.x + b.rect.max.x) * 0.5
	half := 0.5 + d.hot
	draw.rect(dc, {{cx - half, b.rect.min.y + 4}, {cx + half, b.rect.max.y - 4}}, draw.mix(d.line, d.accent, d.hot))
}

Sort_Arrow :: struct { asc: bool, color: draw.Color }

@(private)
sort_arrow_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Sort_Arrow)(user)
	c := draw.rect_center(b.rect)
	s := b.font_size * 0.28
	for i in 0 ..< 3 {
		w := s * f32(3 - i)
		y := d.asc ? c.y + s - f32(i) * s * 0.8 : c.y - s + f32(i) * s * 0.8
		draw.rect(dc, {{c.x - w * 0.5, y - s * 0.35}, {c.x + w * 0.5, y + s * 0.35}}, d.color, s * 0.3)
	}
}

page_data :: proc(app: ^App) {
	em := ui.font_size()
	rebuild_order(app)
	row_h := em * 2.1

	ui.spacer(ui.px(em))
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row(id = "###data_cols") {
		ui.spacer(ui.px(em * 1.3))
		build_tree(app, em)
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###data_main") {
			// toolbar
			ui.next({width = ui.fill(), height = ui.px(em * 2.8)})
			if ui.row(.Center, id = "###data_bar") {
				ui.next({width = ui.px(em * 20, 0), height = ui.px(em * 2.3)})
				ui.line_edit("###data_filter", &app.filter, "Filter rows (name or department)")
				ui.spacer(ui.px(em))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1)})
					ui.label(fmt.tprintf("%d of %d rows  |  only visible rows become boxes", app.order_count, DATA_ROW_COUNT))
				}
			}
			ui.spacer(ui.px(em * 0.5))
			build_table(app, em, row_h)
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.px(em * 1.8)})
			if ui.tags("weak") {
				if ui.style({font_size = math.round(em * 0.88)}) {
					if app.selected_row >= 0 && app.selected_row < app.order_count {
						r := &app.rows[app.order[app.selected_row]]
						ui.label(fmt.tprintf("Selected #%d: %s, %s, score %d, joined %d   (Up/Down/PgUp/PgDn/Home/End)", r.id, row_name(r), dept_names[r.dept], r.score, r.year))
					} else {
						ui.label("Click a row, then use the keyboard. Drag column borders to resize, click headers to sort.")
					}
				}
			}
			ui.spacer(ui.px(em * 0.8))
		}
		ui.spacer(ui.px(em * 1.3))
	}
}

@(private)
build_tree :: proc(app: ^App, em: f32) {
	nodes := [?]Tree_Node{
		{"gui_toolkit", -1, true}, {"examples", 0, true}, {"fidget", 1, true}, {"main.odin", 2, false}, {"pages.odin", 2, false}, {"shell.odin", 2, false},
		{"ui", 0, true}, {"state.odin", 6, false}, {"layout.odin", 6, false}, {"widgets.odin", 6, false}, {"render", 0, true}, {"render.odin", 10, false}, {"rect.hlsl", 10, false},
		{"font", 0, true}, {"font.odin", 13, false}, {"draw", 0, true}, {"draw.odin", 15, false}, {"build.bat", 0, false}, {"README.md", 0, false},
	}
	if ui.tags("card") {
		ui.next({width = ui.px(em * 17, 0.3), height = ui.pct(1), axis = .Y, radius = em * 0.6})
		card := ui.build_box({.Draw_Background, .Draw_Border, .Clip}, "###tree_card")
		if ui.parent(card) {
			ui.next({width = ui.fill(), height = ui.px(em * 2.6)})
			if ui.row(.Center, id = "###tree_head") {
				ui.spacer(ui.px(em * 0.9))
				if ui.tags("weak") { ui.icon(ICON_FOLDER_OPEN, em * 1.8) }
				ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.05)})
				ui.label("Explorer")
			}
			ui.hline(ui.fill())
			for node, i in nodes {
				visible := true
				depth := 0
				for p := node.parent; p >= 0; p = nodes[p].parent {
					depth += 1
					if !app.tree_open[p] { visible = false }
				}
				if !visible { continue }
				selected := app.tree_sel == i
				if selected { ui.push_tags("selected") }
				flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects}
				if selected { flags += {.Draw_Background} }
				ui.next({width = ui.fill(), height = ui.px(em * 2)})
				if ui.row(.Center, flags, fmt.tprintf("###tree_%d", i)) {
					sig := ui.signal(ui.parent_box())
					ui.spacer(ui.px(em * (0.5 + 1.1 * f32(depth))))
					if node.dir {
						if ui.tags("weak") {
							ui.next({width = ui.px(em * 1.4), height = ui.pct(1), font = app.icons, text_align = .Center})
							exp := ui.build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###exp_%d", app.tree_open[i] ? "v" : ">", i))
							if ui.signal(exp).clicked { app.tree_open[i] = !app.tree_open[i] }
						}
					} else {
						ui.spacer(ui.px(em * 1.4))
					}
					if ui.tags("weak") { ui.icon(node.dir ? (app.tree_open[i] ? ICON_FOLDER_OPEN : ICON_FOLDER) : ICON_FILE, em * 1.7) }
					ui.next({width = ui.fill(), height = ui.pct(1)})
					ui.label(node.name)
					if sig.clicked { app.tree_sel = i }
					if sig.double_clicked && node.dir { app.tree_open[i] = !app.tree_open[i] }
				}
				if selected { ui.pop_tags() }
			}
		}
	}
}

@(private)
build_table :: proc(app: ^App, em: f32, row_h: f32) {
	if ui.tags("card") {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, radius = em * 0.6})
		card := ui.build_box({.Draw_Background, .Draw_Border, .Clip}, "###table_card")
		if ui.parent(card) {
			// header: sortable, resizable
			if ui.tags("bar") {
				ui.next({width = ui.fill(), height = ui.px(em * 2.4)})
				if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###table_head") {
					ui.spacer(ui.px(em * 0.4))
					for c in 0 ..< DATA_COLS {
						sorting := app.sort_col == c
						if ui.tags("weak") {
							ui.next({width = ui.px(em * app.col_w[c]), height = ui.pct(1), axis = .X, cross = .Center})
							hd := ui.build_box({.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###hd_%d", c))
							if ui.parent(hd) {
								ui.next({width = ui.text_size(), height = ui.pct(1)})
								ui.label(col_names[c])
								if sorting {
									d := ui.frame_new(Sort_Arrow)
									d.asc = app.sort_asc
									d.color = ui.color("accent")
									ui.next({width = ui.px(em * 1.4), height = ui.pct(1)})
									ui.custom("arrow", sort_arrow_draw, d)
								}
							}
							if ui.signal(hd).clicked {
								if sorting { app.sort_asc = !app.sort_asc } else { app.sort_col, app.sort_asc = c, true }
								app.order_key = max(u64)
							}
						}
						ui.next({width = ui.px(em * 0.7), height = ui.pct(1), cursor = platform.Cursor.Resize_H})
						rz := ui.build_box({.Clickable}, fmt.tprintf("###colsz_%d", c))
						d := ui.frame_new(Resize_Draw)
						d.hot = max(rz.hot_t, rz.active_t)
						d.line, d.accent = ui.color("border"), ui.color("accent")
						rz.custom, rz.custom_user = resize_draw, d
						zs := ui.signal(rz)
						if zs.pressed { ui.drag_store({app.col_w[c], 0, 0, 0}) }
						if zs.dragging { app.col_w[c] = max(3, ui.drag_load()[0] + zs.drag_delta.x / em) }
					}
				}
			}

			// virtualized rows
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			list := ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, "###table_rows")
			view_h := max(list.size.y, row_h * 4)
			handle_table_keys(app, list, row_h, view_h)
			first := clamp(int(list.view_off.y / row_h), 0, max(0, app.order_count - 1))
			last := min(first + int(view_h / row_h) + 3, app.order_count)
			if ui.parent(list) {
				ui.spacer(ui.px(f32(first) * row_h))
				for i in first ..< last {
					r := &app.rows[app.order[i]]
					selected := i == app.selected_row
					zebra := i & 1 == 1
					ui.push_tags(selected ? "selected" : "card")
					flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects}
					if selected || zebra { flags += {.Draw_Background} }
					if !selected && zebra { ui.pop_tags(); ui.push_tags("zebra") }
					ui.next({width = ui.fill(), height = ui.px(row_h)})
					if ui.row(.Center, flags, fmt.tprintf("###row_%d", r.id)) {
						sig := ui.signal(ui.parent_box())
						ui.spacer(ui.px(em * 0.4))
						cell :: proc(w: f32, text: string, mono := false, weak := false) {
							em := ui.font_size()
							if weak { ui.push_tags("weak") }
							ui.next({width = ui.px(w + em * 0.7), height = ui.pct(1), font = mono ? ui.mono_font() : ui.top_style().font, font_size = mono ? math.round(em * 0.9) : em})
							ui.build_box({.Draw_Text}, fmt.tprintf("%s###c%d", text, ui.parent_box().child_count))
							if weak { ui.pop_tags() }
						}
						cell(em * app.col_w[0], fmt.tprintf("%d", r.id), true, true)
						cell(em * app.col_w[1], row_name(r))
						cell(em * app.col_w[2], dept_names[r.dept], false, true)
						cell(em * app.col_w[3], fmt.tprintf("%d", r.score), true)
						status_tag := r.status == 0 ? "good" : (r.status == 1 ? "warn" : "weak")
						if ui.tags(status_tag) {
							ui.icon(ICON_DOT, em * 1.2)
							ui.next({width = ui.text_size(), height = ui.pct(1)})
							ui.label(status_names[r.status])
						}
						if sig.pressed { app.selected_row = i; app.table_focus = true }
					}
					ui.pop_tags()
				}
				ui.spacer(ui.px(f32(app.order_count - last) * row_h))
			}
			_ = ui.signal(list)
		}
	}
}

@(private)
handle_table_keys :: proc(app: ^App, list: ^ui.Box, row_h, view_h: f32) {
	if !app.table_focus || app.order_count == 0 || app.palette_open || app.modal_open { return }
	if ui.focus_key() != 0 { return }   // a text field owns the keyboard
	sel := app.selected_row
	page := int(view_h / row_h)
	if ui.key_press(.Down) { sel = sel < 0 ? 0 : min(sel + 1, app.order_count - 1) }
	if ui.key_press(.Up) { sel = max(sel - 1, 0) }
	if ui.key_press(.Page_Down) { sel = min(max(sel, 0) + page, app.order_count - 1) }
	if ui.key_press(.Page_Up) { sel = max(max(sel, 0) - page, 0) }
	if ui.key_press(.Home) { sel = 0 }
	if ui.key_press(.End) { sel = app.order_count - 1 }
	if sel != app.selected_row {
		app.selected_row = sel
		y := f32(sel) * row_h
		if y < list.view_target.y { list.view_target.y = y }
		if y + row_h > list.view_target.y + view_h { list.view_target.y = y + row_h - view_h }
	}
}
