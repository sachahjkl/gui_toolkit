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
	cx := b.rect.max.x - 0.5   // on the cell separators of the rows below
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
	row_h := ui.dense(em * 2.1)

	ui.spacer(ui.px(em))
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row(id = "###data_cols") {
		ui.spacer(ui.px(em * 1.3))
		build_tree(app, em)
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###data_main") {
			// toolbar
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
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
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
			if ui.tags("weak") {
				if ui.style({font_size = math.round(em * 0.88)}) {
					e, has_sel := app.selected_disp.?
					if has_sel && e.row >= 0 {
						r := &app.rows[app.order[e.row]]
						ui.label(fmt.tprintf("Selected #%d: %s, %s, score %d, joined %d   (Up/Down/PgUp/PgDn/Home/End, Left: group)", r.id, row_name(r), dept_names[r.dept], r.score, r.year))
					} else if has_sel {
						ui.label(fmt.tprintf("%s group: Left / Right or double-click to fold it", dept_names[e.group]))
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
		{"ui", 0, true}, {"state.odin", 6, false}, {"layout.odin", 6, false}, {"widgets.odin", 6, false}, {"render", 0, true}, {"render.odin", 10, false}, {"rect.wgsl", 10, false},
		{"font", 0, true}, {"font.odin", 13, false}, {"draw", 0, true}, {"draw.odin", 15, false}, {"build.bat", 0, false}, {"README.md", 0, false},
	}
	if ui.tags("card") {
		ui.next({width = ui.px(em * 17, 0.3), height = ui.pct(1), axis = .Y, radius = em * 0.6})
		card := ui.build_box({.Draw_Background, .Draw_Border, .Clip}, "###tree_card")
		if ui.parent(card) {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
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
				flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects, .Draw_Border}   // border always laid out, visible when selected
				if selected { flags += {.Draw_Background} }
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2)), border = selected ? nil : draw.Color{}})
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

// One display line of the table: a department header (row = -1) or a data row (index into app.order).
Disp :: struct { group: i32, row: i32 }

Group_Sum :: struct { count, active, score_sum: int }

// Groups the filtered, sorted rows by department; closed groups keep only their header line. Cached: rebuilt only
// when the order (filter / sort) or a group's open state changes.
@(private)
build_display :: proc(app: ^App) -> (disp: []Disp, sums: [len(dept_names)]Group_Sum) {
	closed: u64
	for c, g in app.group_closed { if c { closed |= 1 << u64(g) } }
	key := app.order_key ~ (closed << 48) ~ 0x9e3779b97f4a7c15
	if key == app.disp_key { return app.disp[:], app.disp_sums }
	app.disp_key = key
	for i in 0 ..< app.order_count {
		r := &app.rows[app.order[i]]
		s := &sums[r.dept]
		s.count += 1
		s.score_sum += int(r.score)
		if r.status == 0 { s.active += 1 }
	}
	starts: [len(dept_names)]int
	n := 0
	for g in 0 ..< len(dept_names) {
		if sums[g].count == 0 { continue }
		starts[g] = n + 1
		n += 1 + (app.group_closed[g] ? 0 : sums[g].count)
	}
	resize(&app.disp, n)
	out := app.disp[:]
	fill := starts
	for g in 0 ..< len(dept_names) { if sums[g].count > 0 { out[starts[g] - 1] = {i32(g), -1} } }
	for i in 0 ..< app.order_count {
		g := app.rows[app.order[i]].dept
		if sums[g].count == 0 || app.group_closed[g] { continue }
		out[fill[g]] = {i32(g), i32(i)}
		fill[g] += 1
	}
	app.disp_sums = sums
	return out, sums
}

@(private)
pct_text :: proc(part, whole: int) -> string { return fmt.tprintf("%d%%", whole > 0 ? (part * 100 + whole / 2) / whole : 0) }

@(private)
build_table :: proc(app: ^App, em: f32, row_h: f32) {
	disp, sums := build_display(app)
	app.disp_count = len(disp)
	total: Group_Sum
	for s in sums { total.count += s.count; total.active += s.active; total.score_sum += s.score_sum }
	right := [DATA_COLS]bool{true, false, false, true, false}   // numeric columns are right-aligned

	if ui.tags("card") {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, radius = em * 0.6})
		card := ui.build_box({.Draw_Background, .Draw_Border, .Clip}, "###table_card")
		if ui.parent(card) {
			// header: name on top, the column total below; sortable, resizable
			app.disp_groups = 0
			for s in sums { if s.count > 0 { app.disp_groups += 1 } }
			totals := [DATA_COLS]string{
				fmt.tprintf("%d", total.count), "", fmt.tprintf("%d groups", app.disp_groups),
				fmt.tprintf("%.0f avg", total.count > 0 ? f32(total.score_sum) / f32(total.count) : 0),
				fmt.tprintf("%s active", pct_text(total.active, total.count)),
			}
			if ui.tags("bar") {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3.5))})
				if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###table_head") {
					ui.spacer(ui.px(em * 0.4))
					for c in 0 ..< DATA_COLS {
						sorting := app.sort_col == c
						ui.next({width = ui.px(em * app.col_w[c]), height = ui.pct(1), axis = .Y})
						hd := ui.build_box({.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###hd_%d", c))
						if ui.parent(hd) {
							ui.spacer(ui.fill())
							ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
							if ui.row(id = "###name") {
								ui.spacer(right[c] ? ui.fill() : ui.px(em * 0.45))
								if !sorting { ui.push_tags("weak") }
								ui.next({width = ui.text_size(), height = ui.px(em * 1.3), text_pad = 0})
								ui.label(col_names[c])
								if !sorting { ui.pop_tags() }
								if sorting {
									d := ui.frame_new(Sort_Arrow)
									d.asc = app.sort_asc
									d.color = ui.color("accent")
									ui.next({width = ui.px(em * 1.2), height = ui.px(em * 1.2)})
									ui.custom("arrow", sort_arrow_draw, d)
								}
								if right[c] { ui.spacer(ui.px(em * 0.1)) }
							}
							ui.next({width = ui.fill(), height = ui.px(em * 1.15), text_pad = right[c] ? em * 0.1 : em * 0.45, font = ui.mono_font(), font_size = math.round(em * 0.88), text_align = right[c] ? .Right : .Left})
							ui.label(fmt.tprintf("%s###tot", totals[c]))
							ui.spacer(ui.fill())
						}
						if ui.signal(hd).clicked {
							if sorting { app.sort_asc = !app.sort_asc } else { app.sort_col, app.sort_asc = c, true }
							app.order_key = max(u64)
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

			// virtualized lines
			ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
			if ui.row(id = "###table_inset") {
				ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
				list := ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, "###table_rows")
				n := len(disp)
				view_h := max(list.size.y, row_h * 4)
				handle_table_keys(app, list, disp, row_h, view_h)
				first := clamp(int(list.view_off.y / row_h), 0, max(0, n - 1))
				last := min(first + int(view_h / row_h) + 3, n)
				sep := ui.color("border")   // column separators (taken before row tags change the colours)
				if ui.parent(list) {
					ui.spacer(ui.px(f32(first) * row_h), exact = true)
					for i in first ..< last {
						e := disp[i]
						selected := i == app.selected_row
						zebra := !selected && e.row >= 0 && i & 1 == 1
						ui.push_tags(selected ? "selected" : (zebra ? "zebra" : "card"))
						flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects, .Draw_Border}   // border always laid out, visible when selected
						if selected || zebra { flags += {.Draw_Background} }
						if e.row < 0 {
							table_group_line(app, e.group, sums[e.group], i, row_h, flags, right)
						} else {
							table_data_line(app, &app.rows[app.order[e.row]], i, row_h, flags, sep, right)
						}
						ui.pop_tags()
					}
					ui.spacer(ui.px(f32(n - last) * row_h), exact = true)
				}
				_ = ui.signal(list)
				app.selected_disp = nil
				if app.selected_row >= 0 && app.selected_row < n { app.selected_disp = disp[app.selected_row] }
			}
		}
	}
}

@(private)
table_group_line :: proc(app: ^App, g: i32, s: Group_Sum, i: int, row_h: f32, flags: ui.Box_Flags, right: [DATA_COLS]bool) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(row_h), border = i == app.selected_row ? nil : draw.Color{}})
	if ui.row(.Center, flags, fmt.tprintf("###grp_%d", g)) {
		sig := ui.signal(ui.parent_box())
		open := !app.group_closed[g]
		ui.spacer(ui.px(em * 0.2))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * 1.4), height = ui.pct(1), font = app.icons, text_align = .Center})
			chev := ui.build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###chev", open ? "v" : ">"))
			if ui.signal(chev).clicked { toggle_group(app, g, i) }
		}
		// the label spans the ID, Name and Department columns; the group totals sit under Score and Status
		w := em * (app.col_w[0] + app.col_w[1] + app.col_w[2] + 0.7 * 3 - 1.2)
		ui.next({width = ui.px(w), height = ui.pct(1), font_size = math.round(em * 1.05)})
		ui.label(fmt.tprintf("%s (%d)###glabel", dept_names[g], s.count))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * (app.col_w[3] + 0.7)), height = ui.pct(1), font = ui.mono_font(), font_size = math.round(em * 0.9), text_align = .Right})
			ui.label(fmt.tprintf("%.0f###gavg", s.count > 0 ? f32(s.score_sum) / f32(s.count) : 0))
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.pct(1), font = ui.mono_font(), font_size = math.round(em * 0.9)})
			ui.label(fmt.tprintf("%s active###gact", pct_text(s.active, s.count)))
		}
		if sig.pressed { app.selected_row = i; app.table_focus = true }
		if sig.double_clicked { toggle_group(app, g, i) }
	}
}

@(private)
table_data_line :: proc(app: ^App, r: ^Data_Row, i: int, row_h: f32, flags: ui.Box_Flags, sep: draw.Color, right: [DATA_COLS]bool) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(row_h), border = i == app.selected_row ? nil : draw.Color{}})
	if ui.row(.Center, flags, fmt.tprintf("###row_%d", r.id)) {
		sig := ui.signal(ui.parent_box())
		ui.spacer(ui.px(em * 0.4))
		cell :: proc(w: f32, text: string, sep: draw.Color, right: bool, mono := false, weak := false) {
			em := ui.font_size()
			if weak { ui.push_tags("weak") }
			ui.next({width = ui.px(w + em * 0.7), height = ui.pct(1), font = mono ? ui.mono_font() : ui.top_style().font, font_size = mono ? math.round(em * 0.9) : em, border = sep, text_align = right ? .Right : .Left})
			ui.build_box({.Draw_Text, .Draw_Side_Right}, fmt.tprintf("%s###c%d", text, ui.parent_box().child_count))
			if weak { ui.pop_tags() }
		}
		cell(em * app.col_w[0], fmt.tprintf("%d", r.id), sep, right[0], true, true)
		cell(em * app.col_w[1], row_name(r), sep, right[1])
		cell(em * app.col_w[2], dept_names[r.dept], sep, right[2], false, true)
		cell(em * app.col_w[3], fmt.tprintf("%d", r.score), sep, right[3], true)
		ui.spacer(ui.px(em * 0.4))
		status_tag := r.status == 0 ? "good" : (r.status == 1 ? "warn" : "weak")
		if ui.tags(status_tag) {
			ui.icon(ICON_DOT, em * 1.2)
			ui.next({width = ui.text_size(), height = ui.pct(1)})
			ui.label(status_names[r.status])
		}
		if sig.pressed { app.selected_row = i; app.table_focus = true }
	}
}

// Opens or closes a group; the selection moves to its header (whose index does not change: only later lines move).
@(private)
toggle_group :: proc(app: ^App, g: i32, header: int) {
	app.group_closed[g] = !app.group_closed[g]
	app.selected_row = header
	app.table_focus = true
}

@(private)
handle_table_keys :: proc(app: ^App, list: ^ui.Box, disp: []Disp, row_h, view_h: f32) {
	n := len(disp)
	if !app.table_focus || n == 0 || app.palette_open || app.modal_open { return }
	if ui.focus_key() != 0 { return }   // a text field owns the keyboard
	sel := app.selected_row
	page := int(view_h / row_h)
	if ui.key_press(.Down) { sel = sel < 0 ? 0 : min(sel + 1, n - 1) }
	if ui.key_press(.Up) { sel = max(sel - 1, 0) }
	if ui.key_press(.Page_Down) { sel = min(max(sel, 0) + page, n - 1) }
	if ui.key_press(.Page_Up) { sel = max(max(sel, 0) - page, 0) }
	if ui.key_press(.Home) { sel = 0 }
	if ui.key_press(.End) { sel = n - 1 }
	// Left: close the group (from a row: jump to its header first); Right: open it
	if sel >= 0 && sel < n {
		e := disp[sel]
		if ui.key_press(.Left) {
			if e.row >= 0 {
				for j := sel; j >= 0; j -= 1 { if disp[j].row < 0 { sel = j; break } }
			} else if !app.group_closed[e.group] {
				toggle_group(app, e.group, sel)
			}
		}
		if ui.key_press(.Right) && e.row < 0 && app.group_closed[e.group] { toggle_group(app, e.group, sel) }
	}
	if sel != app.selected_row {
		app.selected_row = sel
		y := f32(sel) * row_h
		if y < list.view_target.y { list.view_target.y = y }
		if y + row_h > list.view_target.y + view_h { list.view_target.y = y + row_h - view_h }
	}
}