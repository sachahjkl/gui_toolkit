package ui

// A program's commands in one table: each one's name, its group and its keys. The same table gives:
//
//   command_pressed   the key handling: a command's keys, pressed this frame
//   chord_text        the text of a key in a menu's line ("Ctrl+Shift+P"); command_tip, a tooltip's ("Kill (Shift+Delete)")
//   palette           the command palette: a dialog the user resizes, that searches (fuzzy_words), every command with
//                     its keys, grouped
//   shortcuts_sheet   a dialog that lists every command's keys, grouped
//
// A program keeps its commands in a table of its own (an enum of its commands indexing an array of Command) and says
// each frame which ones can act now (the `enabled` of palette): one place names a command and its keys, and its menus,
// tooltips, palette and sheet all say the same.
//
//   COMMANDS := [Cmd]ui.Command{.Kill = {label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}, {}}}, ...}
//   if ui.command_pressed(COMMANDS[.Kill]) { kill() }
//   ui.menu_item(COMMANDS[.Kill].label, ui.command_shortcut(COMMANDS[.Kill]))
//   if ui.key_press(.K, {.Ctrl}) { ui.palette_open(&palette) }
//   if i, _ := ui.palette(&palette, COMMANDS[:], enabled[:]); i >= 0 { run(Cmd(i)) }

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../draw"
import "../platform"

// The palette's size at first, in em, and the least it is made; where its top is, a share of the window's height; a line's
// height and a group heading's, in em.
PALETTE_WIDTH_EM :: 34
PALETTE_HEIGHT_EM :: 26
PALETTE_MIN_EM :: Vec2{22, 10}
PALETTE_TOP :: 0.12
PALETTE_ROW_EM :: 2
PALETTE_HEADING_EM :: 1.9
// What a match of the group's letters (not the label's alone) loses against one of the label's.
PALETTE_GROUP_MATCH_PENALTY :: 100
// What a match of a tag (a word the label does not say) loses against one of the label's, less than one of the group's.
@(private = "file") PALETTE_TAG_MATCH_PENALTY :: 50
// The sheet's width, in em; its list's height at most, a share of the window's height.
SHEET_WIDTH_EM :: 34
SHEET_HEIGHT :: 0.7

// A key with its modifiers. The zero value is no key.
Chord :: struct {
	key:  platform.Key,
	mods: platform.Modifiers,
}

Command :: struct {
	label: string,     // "End task": the menu's, the palette's and the sheet's text
	group: string,     // "Processes": the palette's and the sheet's heading ("" none)
	// other words the palette finds it by, that its label does not say ("exit", "close" for Quit)
	tags:  []string,
	keys:  [2]Chord,   // its keys, the first one shown in menus and tooltips; {} none
	icon:  string,     // a glyph of the state's icon_font (Lucide's): the palette's line shows it ("" none)
}

// "Ctrl+Shift+P", "Delete", "F5" ("" for no key). Modifiers come first, in the order Ctrl, Shift, Alt.
chord_text :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	if c.key == .None { return "" }
	b := strings.builder_make(allocator)
	if .Ctrl in c.mods { strings.write_string(&b, "Ctrl+") }
	if .Shift in c.mods { strings.write_string(&b, "Shift+") }
	if .Alt in c.mods { strings.write_string(&b, "Alt+") }
	strings.write_string(&b, key_name(c.key))
	return strings.to_string(b)
}

// A key's name as keyboards and menus print it.
key_name :: proc(k: platform.Key) -> string {
	#partial switch k {
	case .A ..= .Z:
		letters := KEY_LETTERS
		return letters[int(k) - int(platform.Key.A)]
	case .N0 ..= .N9:
		digits := KEY_DIGITS
		return digits[int(k) - int(platform.Key.N0)]
	case .F1 ..= .F12:
		functions := KEY_FUNCTIONS
		return functions[int(k) - int(platform.Key.F1)]
	case .Escape:     return "Escape"
	case .Return:     return "Enter"
	case .Tab:        return "Tab"
	case .Space:      return "Space"
	case .Backspace:  return "Backspace"
	case .Delete:     return "Delete"
	case .Insert:     return "Insert"
	case .Left:       return "Left"
	case .Right:      return "Right"
	case .Up:         return "Up"
	case .Down:       return "Down"
	case .Home:       return "Home"
	case .End:        return "End"
	case .Page_Up:    return "Page Up"
	case .Page_Down:  return "Page Down"
	case .Comma:      return ","
	case .Period:     return "."
	case .Slash:      return "/"
	case .Minus:      return "-"
	case .Equal:      return "="
	case .Menu:       return "Menu"
	case .Num_Add:    return "Num +"
	case .Num_Subtract: return "Num -"
	}
	return ""
}

@(private = "file")
KEY_LETTERS :: [26]string{"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}
@(private = "file")
KEY_DIGITS :: [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
@(private = "file")
KEY_FUNCTIONS :: [12]string{"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"}

// The text of a command's first key, for a menu's line ("" when it has none).
command_shortcut :: proc(c: Command) -> string { return chord_text(c.keys[0]) }

// Every key of a command, apart by commas ("Ctrl+K, Ctrl+Shift+P").
command_keys_text :: proc(c: Command, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, 0, len(c.keys), context.temp_allocator)
	for k in c.keys { if k.key != .None { append(&parts, chord_text(k)) } }
	return strings.join(parts[:], ", ", allocator)
}

// A tooltip's text: the label and its first key ("Kill (Shift+Delete)"), or the label alone.
command_tip :: proc(c: Command, allocator := context.temp_allocator) -> string {
	k := command_shortcut(c)
	if k == "" { return strings.clone(c.label, allocator) }
	return fmt.aprintf("%s (%s)", c.label, k, allocator = allocator)
}

// Whether one of the command's keys was pressed this frame (the press is taken: nothing else sees it). A command that
// cannot act now (`enabled` false) takes no key: the key stays for what else wants it.
command_pressed :: proc(c: Command, enabled := true) -> bool {
	if !enabled { return false }
	for k in c.keys {
		if k.key != .None && key_press(k.key, k.mods) { return true }
	}
	return false
}

////////////////////////////////
// The palette

// The palette: a dialog at the top centre of the window (modal_sized: its edges and its corner resize it), a field that
// searches what is typed, and the commands under it. The program keeps it between frames; `size` is the size the user
// gave it (logical pixels; {} the default), for the program to keep between starts.
Command_Palette :: struct {
	open:   bool,
	size:   Vec2,
	field:  Text_Field,
	sel:    int,    // the line selected, among the commands listed
	fresh:  bool,   // opened this frame: the field takes the keyboard
	reveal: bool,   // the selected line is brought into view at the next build
	mouse:  Vec2,   // the pointer at the last build (a line takes the selection when the pointer moves over it)
	// the modifiers of the Enter that chose (Ctrl+Enter, Alt+Enter, Shift+Enter: what else the program does with the
	// command chosen; {} plain Enter or a click)
	chosen_mods: platform.Modifiers,
}

// The field's strip: a field's darker background, its top corners the dialog's, a line under it. A raised dialog
// (machined, edged) has a lit rim just inside its border: the strip begins inside it, or the dialog's edge was lost along
// the strip's top and sides and showed only at its corners.
@(private = "file")
palette_strip_draw :: proc(b: ^Box, _: rawptr, dc: ^draw.Context) {
	r := b.rect
	if machined() {
		p := px1()
		r = {{r.min.x + p, r.min.y + p}, {r.max.x - p, r.max.y}}
	}
	radius := max(0, b.radius - (r.min.y - b.rect.min.y))
	well := color_from_tags(gs(), b.tags_key, "well")
	draw.rect_corners(dc, r, {well, well, well, well}, {radius, 0, radius, 0})
	// the line that parts the field from the results: carved (machined, edged), the border's colour (flat)
	y := b.rect.max.y - (machined() ? 2 : 1) * px1()
	machined_groove(dc, {r.min.x, y}, {r.max.x, y})
}

// What a program adds to its palette (every field optional).
Palette_Options :: struct {
	recent:       []int,       // commands run last (their indices, the last first): a group of their own on top while nothing is typed
	recent_title: string,      // that group's heading ("": "Recent")
	first:        Maybe(int),  // a command put first while something is typed (an alias typed whole: its command)
	keys:         []string,    // per command (by index): the text of its keys, as the program shows them ("Ctrl+M, T", one's own keys), instead of its first chord
	foot:         string,      // a line under the list (its keys' help)
}

// What a palette makes of `query` for one of its entries, best first: its label holds it whole or at the starts of its words
// (fuzzy_words), then with its tags (other words it is found by), then with its group; then the same with a slip or two in
// each word (fuzzy_typos), after every exact match. `ranges`: what lights in the label (none when the tags or the group
// found it). A program's own palette (sessions, settings and commands together) ranks its entries with it too.
palette_match :: proc(query, label, group: string, tags: []string) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	if s, r, found := fuzzy_words(query, label); found { return s, r, true }
	joined := strings.join(tags, " ", context.temp_allocator)
	if joined != "" {
		if s, _, found := fuzzy_words(query, fmt.tprintf("%s %s", label, joined)); found { return s - PALETTE_TAG_MATCH_PENALTY, nil, true }
	}
	if group != "" {
		if s, _, found := fuzzy_words(query, fmt.tprintf("%s %s %s", label, group, joined)); found { return s - PALETTE_GROUP_MATCH_PENALTY, nil, true }
	}
	if s, r, found := fuzzy_typos(query, label); found { return s, r, true }
	if joined != "" {
		if s, _, found := fuzzy_typos(query, fmt.tprintf("%s %s", label, joined)); found { return s - PALETTE_TAG_MATCH_PENALTY, nil, true }
	}
	return 0, nil, false
}

palette_destroy :: proc(p: ^Command_Palette) { field_destroy(&p.field) }

// Opens the palette, its field empty and its first command selected.
palette_open :: proc(p: ^Command_Palette) {
	p.open, p.fresh, p.sel, p.reveal = true, true, 0, true
	field_clear(&p.field)
}

// The palette while it is open: every command, under its group's heading, with its keys. What is typed keeps the
// commands whose label (or label and group) holds it whole or in pieces that begin words (fuzzy_words), the best matches
// first (the headings go then; each line says its group); the first one is selected. Up, Down, Page Up, Page Down move
// the selection, Enter runs it, Escape closes the palette. A command that cannot act now (`enabled[i]` false; nil: all
// can) is greyed and is not chosen. Returns the index of the command chosen (-1: none), and `resized` when the user
// changed its size this frame (`p.size`: keep it). Enter with Ctrl, Alt or Shift chooses too: `p.chosen_mods` says which.
// `opts`: the recent commands on top, a command first, the keys' texts, a foot line (Palette_Options).
palette :: proc(p: ^Command_Palette, commands: []Command, enabled: []bool = nil, opts := Palette_Options{}) -> (chosen: int, resized: bool) {
	chosen = -1
	p.chosen_mods = {}
	if !p.open { return }
	em := font_size()
	query := strings.trim_space(field_string(&p.field))
	list := palette_list(commands, query, opts)
	n := len(list)
	can :: proc(enabled: []bool, i: int) -> bool { return enabled == nil || (i < len(enabled) && enabled[i]) }
	row_h := math.round(dense(em * PALETTE_ROW_EM))
	if n > 0 {
		page := max(int(p_view_h(p) / row_h), 1)
		// (the palette's own keys, read before its dialog is built)
		if key_press_any(.Down) { p.sel = (p.sel + 1) % n; p.reveal = true }
		if key_press_any(.Up) { p.sel = (p.sel + n - 1) % n; p.reveal = true }
		if key_press_any(.Page_Down) { p.sel = min(p.sel + page, n - 1); p.reveal = true }
		if key_press_any(.Page_Up) { p.sel = max(p.sel - page, 0); p.reveal = true }
	}
	p.sel = clamp(p.sel, 0, max(n - 1, 0))
	mouse := mouse_pos()
	moved := abs(mouse.x - p.mouse.x) + abs(mouse.y - p.mouse.y) > 0.5
	p.mouse = mouse
	before := p.size
	if modal_sized("palette", {em * PALETTE_WIDTH_EM, em * PALETTE_HEIGHT_EM}, &p.size, &p.open, {em * PALETTE_MIN_EM.x, em * PALETTE_MIN_EM.y}, top = PALETTE_TOP) {
		// (the field from edge to edge, its strip and a line under it: no frame of its own inside the dialog's, but the
		// darker background of a field, so that it reads as the place to type: palette_strip_draw)
		next({width = fill(), height = px(dense(em * 2.6)), axis = .X, cross = .Center, radius = em * 0.8})
		if row(.Center, {}, "###palette_top") {
			parent_box().custom = palette_strip_draw
			spacer(px(em * 0.4))
			next({width = fill(), height = pct(1), font_size = em * 1.05})
			push_tags("bare")
			res := line_edit("###palette_field", &p.field, "Type to search")
			pop_tags()
			if p.fresh { set_focus(res.box.key); p.fresh = false }
			if res.changed { p.sel = 0; p.reveal = true }
			if res.cancelled { p.open = false }   // (Escape in the field: the field takes it before the dialog)
			if res.committed && n > 0 && list[p.sel].index >= 0 && can(enabled, list[p.sel].index) { chosen = list[p.sel].index }
			// (Enter with a modifier: the program's other use of the command chosen)
			for m in ([]platform.Modifiers{{.Ctrl}, {.Alt}, {.Shift}}) {
				if n > 0 && can(enabled, list[p.sel].index) && key_press_any(.Return, m) { chosen, p.chosen_mods = list[p.sel].index, m }
			}
			spacer(px(em * 0.4))
		}
		spacer(px(em * 0.3))
		next({width = fill(), height = fill()})
		if scroll_y("###palette_list") {
			lb := parent_box()
			view_h := lb.rect.max.y - lb.rect.min.y
			if p.reveal && view_h > row_h && n > 0 {   // (a search that keeps nothing: no line to show)
				top := palette_line_top(list, p.sel, row_h, em)
				lb.view_target.y = view_reveal_offset(lb.view_target.y, top, top + row_h, view_h)
				p.reveal = false
			}
			if n == 0 {
				next({width = fill(), height = px(row_h), text_align = .Center})
				if tags("weak") { label("Nothing matches###palette_none") }
			}
			// (a column of icons when a command has one and the state has an icon font)
			icons := false
			if gs().icon_font != 0 { for c in commands { if c.icon != "" { icons = true; break } } }
			for line, k in list {
				c := commands[line.index]
				if line.heading != "" {
					if tags("weak") {
						next({width = fill(), height = px(em * PALETTE_HEADING_EM), font_size = em * 0.9, text_pad = em * 0.7})
						build_box({.Draw_Text}, fmt.tprintf("%s###palette_h_%d", line.heading, k))
					}
				}
				text := c.label
				if query != "" && c.group != "" { text = fmt.tprintf("%s  ·  %s", c.label, c.group) }
				on := can(enabled, line.index)
				sel := k == p.sel
				push_tags("menu_item")
				if sel { push_tags("selected") }
				next({width = fill(), height = px(row_h), axis = .X, cross = .Center, bg = color("background"), radius = em * 0.3})
				flags := Box_Flags{.Clickable, .Draw_Hot_Effects}
				if sel { flags += {.Draw_Background} }
				if !on { flags += {.Disabled} }
				rb := build_box(flags, fmt.tprintf("###palette_%d_%d", line.index, k))
				a11y_default(rb, {role = .Menu_Item, name = text, selected = sel})
				rs := signal(rb)
				if rs.hovering && moved { p.sel = k }
				if rs.clicked && on { chosen = line.index }
				if parent(rb) {
					spacer(px(em * 0.7))
					if icons {
						if !sel { push_tags("weak") }
						next({width = px(em * 1.7), height = pct(1), font = gs().icon_font, font_size = em * 0.95, text_align = .Center, text_pad = 0})
						build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", c.icon))
						if !sel { pop_tags() }
						spacer(px(em * 0.5))
					}
					// (what the search found in the label lit; its tags, which the line does not show, light nothing)
					ranges: []Fuzzy_Range
					if query != "" {
						_, ranges, _ = palette_match(query, c.label, c.group, c.tags)
						if ranges == nil { ranges = word_ranges(c.label, query) }   // (found by its tags or group: its words that are in the label)
					}
					next({width = fill(), text_pad = 0})
					matched_label("###t", text, ranges)
					keys := line.index < len(opts.keys) ? opts.keys[line.index] : command_shortcut(c)
					if keys != "" {
						if tags("weak") {
							next({width = text_size(), height = pct(1), text_pad = 0, font_size = em * 0.9})
							label(fmt.tprintf("%s###k", keys))
						}
					}
					// (clear of the scroll bar, along the list's right edge)
					bar_w, bar_m := scrollbar_size(em)
					spacer(px(em * 0.5 + bar_w + 2 * bar_m))
				}
				if sel { pop_tags() }
				pop_tags()
			}
		}
		if opts.foot != "" {
			next({width = fill(), height = px(dense(em * 2)), axis = .X, cross = .Center})
			if row(.Center, {.Draw_Side_Top}, "###palette_foot") {
				spacer(px(em * 0.7))
				if tags("weak") {
					next({width = fill(), height = pct(1), font_size = em * 0.85})
					label(fmt.tprintf("%s###palette_foot_text", opts.foot))
				}
				spacer(px(em * 1.4))   // (the corner's grip)
			}
		} else {
			spacer(px(em * 0.4))
		}
	}
	resized = p.size != before
	if chosen >= 0 { p.open = false }
	return
}

// The palette's list's height at the last build (0: not laid out yet).
@(private = "file")
p_view_h :: proc(p: ^Command_Palette) -> f32 {
	s := gs()
	b := box_from_key(key_from_string(key_from_string(s.root.key, "###modal_palette"), "###palette_list"))
	if b == nil { return 0 }
	return b.rect.max.y - b.rect.min.y
}

// The top of line `k` in the list, the headings counted (a list with no search has one before each group).
@(private = "file")
palette_line_top :: proc(list: []Palette_Line, k: int, row_h, em: f32) -> f32 {
	return f32(k) * row_h + f32(list[k].headings) * (em * PALETTE_HEADING_EM)
}

// A command's line, the headings above it (to place it), and the heading shown just above it ("": none).
@(private = "file")
Palette_Line :: struct { index, headings: int, heading: string }

// The commands the palette lists for `query`: every one in the table's order (with no query; the recent ones first, under
// their heading), else the matches, the best first (the label's letters matter more than the group's), `opts.first` before
// them.
@(private = "file")
palette_list :: proc(commands: []Command, query: string, opts: Palette_Options) -> []Palette_Line {
	out := make([dynamic]Palette_Line, 0, len(commands), context.temp_allocator)
	if query == "" {
		headings := 0
		recent := 0
		for i in opts.recent {
			if i < 0 || i >= len(commands) { continue }
			heading := ""
			if recent == 0 {
				heading = opts.recent_title != "" ? opts.recent_title : "Recent"
				headings += 1
			}
			append(&out, Palette_Line{i, headings, heading})
			recent += 1
		}
		group := ""
		for c, i in commands {
			heading := ""
			if c.group != group || (recent > 0 && i == 0) {
				if c.group != "" { heading = c.group; headings += 1 }
				group = c.group
			}
			append(&out, Palette_Line{i, headings, heading})
		}
		return out[:]
	}
	Ranked :: struct { index, score: int }
	ranked := make([dynamic]Ranked, 0, len(commands), context.temp_allocator)
	for c, i in commands {
		if score, _, ok := palette_match(query, c.label, c.group, c.tags); ok { append(&ranked, Ranked{i, score}) }
	}
	slice.stable_sort_by(ranked[:], proc(a, b: Ranked) -> bool { return a.score > b.score })
	if f, ok := opts.first.?; ok && f >= 0 && f < len(commands) {
		append(&out, Palette_Line{f, 0, ""})
	}
	for r in ranked {
		if f, ok := opts.first.?; ok && r.index == f { continue }
		append(&out, Palette_Line{r.index, 0, ""})
	}
	return out[:]
}

////////////////////////////////
// The sheet of the keys

// The dialog `id` while `open`: every command that has a key, under its group's heading, its keys at the right. It
// scrolls when it is taller than SHEET_HEIGHT of the window; Escape and its Close button close it.
shortcuts_sheet :: proc(id: string, commands: []Command, open: ^bool, title := "Keyboard shortcuts", width_em: f32 = SHEET_WIDTH_EM) {
	s := gs()
	em := font_size()
	w := em * width_em
	if modal(id, w, open) { sheet_body(commands, open, title, w, em, s.window_size.y) }
}

@(private = "file")
sheet_body :: proc(commands: []Command, open: ^bool, title: string, w, em, window_h: f32) {
	pad := em * 1.2
	next({width = px(w), height = children_sum(), axis = .Y})
	if column(id = "###sheet") {
		spacer(px(pad * 0.8))
		next({width = px(w), height = children_sum()})
		if row(.Center, {}, "###sheet_title") {
			spacer(px(pad))
			next({width = fill(), height = px(em * 1.8), font_size = em * 1.2, text_pad = 0})
			label(fmt.tprintf("%s###sheet_title_text", title))
			spacer(px(pad))
		}
		spacer(px(em * 0.5))
		lines := 0
		for c in commands { if c.keys[0].key != .None { lines += 1 } }
		height := min(window_h * SHEET_HEIGHT, f32(lines) * em * 2.2 + em * 6)
		next({width = px(w), height = px(height)})
		if scroll_y("###sheet_list") {
			group := ""
			for c, i in commands {
				if c.keys[0].key == .None { continue }
				if c.group != group {
					group = c.group
					spacer(px(em * 0.5))
					next({width = fill(), height = px(em * 1.7)})
					if row(.Center, {}, fmt.tprintf("###sheet_group_%d", i)) {
						spacer(px(pad))
						next({width = fill(), height = pct(1), text_pad = 0, fg = color("accent")})
						label(fmt.tprintf("%s###g", group))
					}
				}
				next({width = fill(), height = px(dense(em * 1.7))})
				if row(.Center, {}, fmt.tprintf("###sheet_line_%d", i)) {
					spacer(px(pad))
					next({width = fill(), height = pct(1), text_pad = 0})
					label(fmt.tprintf("%s###l", c.label))
					if tags("weak") {
						next({width = text_size(), height = pct(1), text_pad = 0})
						label(fmt.tprintf("%s###k", command_keys_text(c)))
					}
					spacer(px(pad))
				}
			}
			spacer(px(em * 0.5))
		}
		hline(px(w))
		spacer(px(em * 0.6))
		next({width = px(w), height = children_sum()})
		if row(.Center, {}, "###sheet_foot") {
			spacer(fill())
			next({width = text_size(em * 1.2), height = px(dense(em * 2.1))})
			if button("Close###sheet_close").clicked { open^ = false }
			spacer(px(pad))
		}
		spacer(px(em * 0.6))
	}
}
