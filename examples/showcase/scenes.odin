package showcase

// The pages of the scenes. Each one is laid out for a window of 1280 × 800: what it shows fits without a scroll.

import "core:fmt"
import "core:math"
import lucide "../../src/lucide"
import prefs_page "../../src/prefs_page"
import "../../src/ui"

INTENT_GLYPHS := [ui.Intent]string{
	.Neutral = lucide.SQUARE, .Primary = lucide.SEND, .Info = lucide.INFO, .Success = lucide.CHECK,
	.Warning = lucide.ALERT_TRIANGLE, .Danger = lucide.TRASH_2, .Cancel = lucide.X,
}
INTENT_WORDS := [ui.Intent]string{
	.Neutral = "Neutral", .Primary = "Send", .Info = "Details", .Success = "Save", .Warning = "Stop", .Danger = "Delete", .Cancel = "Cancel",
}
HUE_NAMES := [ui.Hue]string{
	.Accent = "accent", .Blue = "blue", .Purple = "purple", .Green = "green", .Yellow = "yellow", .Red = "red", .Cyan = "cyan", .Rose = "rose",
}

FILES := [?][3]string{
	{"harbour-at-dusk.webp", "58 KB", "today, 18:42"},
	{"harbour-at-dusk-2.webp", "61 KB", "today, 18:44"},
	{"pier-in-fog.png", "1.2 MB", "yesterday"},
	{"lighthouse.jpg", "340 KB", "yesterday"},
	{"notes.md", "4 KB", "3 days ago"},
	{"release-0.248.mp4", "18 MB", "last week"},
	{"palette.json", "2 KB", "last week"},
}
FILE_CHOSEN :: 2   // the row the menu was opened on

scene_build :: proc(app: ^App, s: Scene, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###page") {
		ui.spacer(ui.px(em * 1.6))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###content") {
			ui.spacer(ui.px(em * 1.2))
			#partial switch s {
			case .Intents:  intents_build(app, em)
			case .Controls: controls_build(app, em)
			case .Menus:    menus_build(app, em)
			case .Graph:    heading("A node graph and its inspector", "gt:flowgraph holds the workflow and runs it; ui.node_graph draws it in the theme's finish, ui.node_inspector edits a node from its kind's schema.", em); graph_build(app, em)
			case .Themes:   themes_build(app, em)
			}
			ui.spacer(ui.px(em * 1.2))
		}
		ui.spacer(ui.px(em * 1.6))
	}
}

// A page's title and what it shows, in the weak text.
heading :: proc(title, words: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.text_size(), font_size = math.round(em * 1.55), text_pad = 0})
	ui.label(fmt.tprintf("%s###heading", title))
	ui.spacer(ui.px(em * 0.3))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###heading_words", words))
	}
	ui.spacer(ui.px(em * 1.1))
}

// Two columns side by side, `left` and `right` built in them.
@(private = "file")
columns :: proc(app: ^App, id: string, em: f32, left, right: proc(app: ^App, em: f32)) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = id) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###left") { left(app, em) }
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###right") { right(app, em) }
	}
}

// A line of words in the weak text, `width` wide (0: as wide as they are).
@(private = "file")
weak :: proc(id, words: string, width: f32, em: f32, mono := false) {
	if ui.tags("weak") {
		m := ui.Style_Mod{width = width > 0 ? ui.px(width) : ui.text_size(), height = ui.pct(1), text_pad = 0}
		if mono { m.font = ui.mono_font() }
		ui.next(m)
		ui.label(fmt.tprintf("%s###%s", words, id))
	}
}

////////////////////////////////
// Intents, faces and hues

@(private = "file")
intents_build :: proc(app: ^App, em: f32) {
	heading("Intents, faces and hues", "An intent says what an act means, and so its colour: the soft pair of one of the theme's hues, in every theme. A face says how the button sits: raised, a ghost, or held down.", em)
	if ui.card("Buttons", lucide.SQUARE) {
		face_row("Raised", .Raised, em)
		face_row("Ghost", .Ghost, em)
		ui.next({width = ui.fill(), height = ui.px(em * 2.7), axis = .X, cross = .Center})
		if ui.row(id = "###toggled") {
			weak("toggled_words", "Toggled", em * 5.5, em)
			marks := [3]string{lucide.BOLD, lucide.ITALIC, lucide.UNDERLINE}
			names := [3]string{"Bold", "Italic", "Underline"}
			held := [3]^bool{&app.bold, &app.italic, nil}
			for m, i in marks {
				ui.next({width = ui.px(em * 2.3), height = ui.px(em * 2.2), radius = em * 0.45})
				on := held[i] != nil && held[i]^
				if ui.button(fmt.tprintf("mark%d", i), icon = m, o = {tip = names[i], face = on ? .Toggled : .Raised}).clicked && held[i] != nil { held[i]^ = !held[i]^ }
				ui.spacer(ui.px(em * 0.3))
			}
			ui.spacer(ui.px(em * 1.2))
			views := [2]string{"Grid", "List"}
			view_glyphs := [2]string{lucide.SQUARE, lucide.ALIGN_LEFT}
			for v, i in views {
				if ui.button(fmt.tprintf("###view%d", i), v, view_glyphs[i], {face = app.view == i ? .Toggled : .Raised}).clicked { app.view = i }
				ui.spacer(ui.px(em * 0.3))
			}
			ui.spacer(ui.px(em * 1.2))
			ui.button("###lit", "Lit: its menu is open", lucide.CHEVRON_RIGHT, {lit = true})
			ui.spacer(ui.px(em * 0.45))
			ui.button("###disabled", "Disabled", lucide.CLOUD, {disabled = true})
			ui.spacer(ui.px(em * 0.45))
			ui.button("###quiet", "Quiet", o = {quiet = true})
		}
	}
	columns(app, "###intents_columns", em, hues_card, marks_card)
}

@(private = "file")
face_row :: proc(words: string, face: ui.Button_Face, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2.7), axis = .X, cross = .Center})
	if ui.row(id = fmt.tprintf("###face%v", face)) {
		weak("face_words", words, em * 5.5, em)
		for it in ui.Intent {
			ui.button(fmt.tprintf("###%v%v", face, it), INTENT_WORDS[it], INTENT_GLYPHS[it], {intent = it, face = face})
			ui.spacer(ui.px(em * 0.45))
		}
	}
}

// Each hue of the theme in its eleven shades (ui.shade, S50 to S950), then its soft pair (ui.soft_pair): the fill and
// the words a tag or a soft button takes.
@(private = "file")
hues_card :: proc(app: ^App, em: f32) {
	if ui.card("Shades and soft pairs", lucide.PALETTE) {
		side := math.round(em * 1.3)
		for h in ui.Hue {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.65)), axis = .X, cross = .Center})
			if ui.row(id = fmt.tprintf("###hue%v", h)) {
				weak("name", HUE_NAMES[h], em * 4, em, mono = true)
				base := ui.hue_color(h)
				base.a = 1
				for s in ui.Shade {
					ui.next({width = ui.px(side), height = ui.px(side), bg = ui.shade(base, s), radius = math.round(em * 0.22)})
					ui.build_box({.Draw_Background}, fmt.tprintf("###s%v", s))
					ui.spacer(ui.px(2))
				}
				ui.spacer(ui.px(em * 0.8))
				fill, ink := ui.soft_pair(base)
				ui.next({width = ui.text_size(em * 0.7), height = ui.px(math.round(em * 1.35)), bg = fill, fg = ink, radius = math.round(em * 0.68), font_size = math.round(em * 0.86), text_align = .Center})
				ui.build_box({.Draw_Background, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###pair", HUE_NAMES[h]))
			}
		}
	}
}

// The small marks: dots of each intent, the spinner and a progress bar, keys, a badge, actions said in words, a well.
@(private = "file")
marks_card :: proc(app: ^App, em: f32) {
	if ui.card("Marks and wells", lucide.SPARKLES) {
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(id = "###dots") {
			weak("dots_words", "ui.dot", em * 7.5, em, mono = true)
			for it in ui.Intent {
				if it == .Neutral { continue }
				ui.dot(fmt.tprintf("###dot%v", it), math.round(em * 0.7), it)
				ui.spacer(ui.px(em * 0.55))
			}
		}
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(id = "###busy") {
			weak("busy_words", "ui.spinner", em * 7.5, em, mono = true)
			ui.spinner("###spinner", math.round(em * 1.2))
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.5))})
			ui.progress("###progress", 0.62)
		}
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(id = "###keys") {
			weak("keys_words", "ui.kbd", em * 7.5, em, mono = true)
			ui.kbd("Ctrl")
			ui.spacer(ui.px(em * 0.25))
			ui.kbd("Shift")
			ui.spacer(ui.px(em * 0.25))
			ui.kbd("P")
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2), radius = em * 0.45})
			inbox := ui.button("inbox", icon = lucide.BELL, o = {tip = "Messages", face = .Raised})
			ui.badge(inbox.box, 12)
		}
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(id = "###hints") {
			weak("hints_words", "face = .Link", em * 7.5, em, mono = true)
			ui.button("###restore", "Restore the defaults", lucide.ROTATE_CCW, {face = .Link, icon_font = ui.lucide_icons()})
			ui.spacer(ui.px(em))
			ui.button("###clear", "Clear the cache", lucide.TRASH_2, {face = .Link, icon_font = ui.lucide_icons(), intent = .Danger})
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.children_sum(), radius = math.round(em * 0.45)})
		if ui.well("###code") {
			ui.spacer(ui.px(em * 0.5))
			lines := [?]string{
				`fill, ink := ui.soft_pair(ui.hue_color(.Green))`,
				`ui.button("save", "Save", lucide.SAVE, {intent = .Success})`,
				`ui.button("bold", icon = lucide.BOLD, o = {face = .Toggled})`,
			}
			for l, i in lines {
				ui.next({width = ui.fill(), height = ui.px(em * 1.45), axis = .X})
				if ui.row(id = fmt.tprintf("###code%d", i)) {
					ui.spacer(ui.px(em * 0.8))
					ui.next({width = ui.fill(), height = ui.pct(1), font = ui.mono_font(), font_size = math.round(em * 0.86), text_pad = 0})
					ui.label(fmt.tprintf("%s###line", l))
				}
			}
			ui.spacer(ui.px(em * 0.5))
		}
	}
}

////////////////////////////////
// Numbers, ranges and wells

@(private = "file")
controls_build :: proc(app: ^App, em: f32) {
	heading("Numbers, ranges and wells", "ui.number is the one widget for a number one sets: − and +, a field for its exact value, its unit, and a track when it has both bounds. The keys, the wheel and the buttons step it; Shift, Ctrl and Alt change the step.", em)
	columns(app, "###controls_columns", em, export_card, options_card)
}

@(private = "file")
export_card :: proc(app: ^App, em: f32) {
	if ui.card("Export", lucide.DOWNLOAD) {
		if ui.form_row("Quality") { ui.number("###quality", &app.quality, lo = 1, hi = 100, unit = "%", track = true) }
		if ui.form_row("Width") { ui.number("###width", &app.width, lo = 1, hi = 40, step = 0.5, unit = "px", track = true) }
		if ui.form_row("Copies") { ui.number("###copies", &app.copies, lo = 1) }
		if ui.form_row("Hours") { ui.range_slider("###hours", &app.from, &app.to, 0, 24, 1, "%.0f h") }
		if ui.form_row("Volume") { ui.slider("###volume", &app.volume, 0, 1, 0.01, "%.2f") }
		if ui.form_row("Format") {
			formats := [3]string{"PNG", "JPEG", "WebP"}
			ui.segmented("###format", formats[:], &app.format)
		}
	}
	if ui.card("What it makes", lucide.FILE_TEXT) {
		facts_well("###facts", em)
	}
}

@(private = "file")
facts_well :: proc(id: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), radius = math.round(em * 0.45)})
	if ui.well(id) {
		ui.spacer(ui.px(em * 0.45))
		facts := [?]string{"size      1280 × 800", "colour    sRGB, 8 bits", "file      harbour-at-dusk.webp", "weight    58 KB"}
		for f, i in facts {
			ui.next({width = ui.fill(), height = ui.px(em * 1.45), axis = .X})
			if ui.row(id = fmt.tprintf("###fact%d", i)) {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.pct(1), font = ui.mono_font(), font_size = math.round(em * 0.9), text_pad = 0})
				ui.label(fmt.tprintf("%s###words", f))
			}
		}
		ui.spacer(ui.px(em * 0.45))
	}
}

@(private = "file")
options_card :: proc(app: ^App, em: f32) {
	if ui.card("Options", lucide.SETTINGS) {
		switches := [3]string{"Open the folder after", "Keep the metadata", "Upload at once"}
		for words, i in switches {
			ui.next({width = ui.fill(), height = ui.px(em * 2.1)})
			ui.toggle(fmt.tprintf("###switch%d", i), words, &app.switches[i])
		}
		ui.spacer(ui.px(em * 0.4))
		ui.hline(ui.fill())
		ui.spacer(ui.px(em * 0.4))
		checks := [2]string{"Round the corners", "Add a shadow"}
		for words, i in checks {
			ui.next({width = ui.fill(), height = ui.px(em * 2)})
			ui.checkbox(fmt.tprintf("###check%d", i), words, &app.checks[i])
		}
		ui.spacer(ui.px(em * 0.4))
		fits := [3]string{"Fit", "Fill", "Stretch"}
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(id = "###fits") {
			for words, i in fits {
				ui.next({width = ui.px(em * 6.5), height = ui.pct(1)})
				ui.radio(fmt.tprintf("###fit%d", i), words, &app.radio, i)
				ui.spacer(ui.px(em * 0.8))
			}
		}
	}
	if ui.card("Encoding 3 of 8", lucide.TIMER) {
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(id = "###encoding") {
			ui.spinner("###encoding_spinner", math.round(em * 1.1))
			ui.spacer(ui.px(em * 0.7))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.5))})
			ui.progress("###encoding_progress", 0.38)
		}
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(id = "###encoding_acts") {
			ui.button("###stop", "Stop", lucide.SQUARE, {face = .Link, icon_font = ui.lucide_icons(), intent = .Danger})
			ui.spacer(ui.px(em * 1.2))
			ui.button("###background", "Go on in the background", lucide.CHEVRON_RIGHT, {face = .Link, icon_font = ui.lucide_icons()})
		}
	}
}

////////////////////////////////
// Menus

// The key of the menu opened on a file: a context menu that searches.
@(private = "file")
MENU_SEED :: "showcase_file_menu"

@(private = "file")
menus_build :: proc(app: ^App, em: f32) {
	heading("Menus", "A menu is as wide as its widest row: its icons, its words, its keys. Typing searches it: a band at its top shows what is typed, the rows that do not match go, a submenu's rows come up.", em)
	menu := ui.key_from_string(0, MENU_SEED)
	if ui.card("~/Pictures/Shots", lucide.FOLDER_OPEN) {
		for f, i in FILES {
			chosen := i == FILE_CHOSEN
			b: ^ui.Box
			if chosen { ui.push_tags("menu_item", "selected") } else { ui.push_tags("menu_item") }
			ui.next({width = ui.fill(), height = ui.px(em * 2.1), axis = .X, cross = .Center, radius = math.round(em * 0.4)})
			b = ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###file%d", i))
			if ui.parent(b) {
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.px(em * 1.6), height = ui.pct(1), font = ui.lucide_icons(), text_align = .Center})
				ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###icon", i == 4 ? lucide.FILE_TEXT : lucide.IMAGE))
				ui.spacer(ui.px(em * 0.5))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###name", f[0]))
				weak("size", f[1], em * 6, em, mono = true)
				weak("date", f[2], em * 8, em)
			}
			ui.pop_tags()
			if ui.signal(b).right_clicked { ui.ctx_menu_open(menu, ui.mouse_pos()) }
			// (the menu stands open on the chosen file from the second build, once its row is laid out)
			if chosen && app.builds == 2 { ui.ctx_menu_open(menu, {b.rect.min.x + em * 13, b.rect.max.y - em * 0.4}) }
		}
	}
	if ui.ctx_menu(menu) {
		ui.menu_item("Open", "Enter", icon = lucide.FOLDER_OPEN)
		if ui.menu_submenu("Open with", lucide.EXTERNAL_LINK) {
			ui.menu_item("The picture viewer", icon = lucide.IMAGE)
			ui.menu_item("The browser", icon = lucide.GLOBE)
			ui.menu_item("Another program…")
		}
		ui.menu_separator()
		ui.menu_item("Copy", "Ctrl+C", icon = lucide.COPY)
		ui.menu_item("Cut", "Ctrl+X", icon = lucide.SCISSORS)
		ui.menu_item("Copy the path", "Ctrl+Shift+C", icon = lucide.CLIPBOARD)
		ui.menu_item("Rename…", "F2", icon = lucide.PENCIL)
		if ui.menu_submenu("Share", lucide.SHARE_2) {
			ui.menu_item("Upload and copy the link", icon = lucide.UPLOAD)
			ui.menu_item("Send by mail", icon = lucide.SEND)
		}
		ui.menu_separator()
		ui.menu_item("Show the hidden files", "Ctrl+H", checked = true)
		ui.menu_item("Compress into an archive", icon = lucide.ARCHIVE, enabled = false)
		ui.menu_separator()
		ui.menu_item("Delete", "Delete", icon = lucide.TRASH_2)
	}
}

////////////////////////////////
// Themes

@(private = "file")
themes_build :: proc(app: ^App, em: f32) {
	heading(fmt.tprintf("%d themes, five finishes", len(app.themes)), "Every theme in its own colours: its surface, its text and its hues. The last two are a user's, from the themes file beside the settings. A finish says how surfaces are painted: flat, a gradient, glass, machined or edged.", em)
	ui.next({width = ui.fill(), height = ui.px(em * 2.4), axis = .X, cross = .Center})
	if ui.row(id = "###look") {
		weak("finish_words", "Finish", em * 4.5, em)
		finishes := [5]string{"Flat", "Gradient", "Glass", "Machined", "Edged"}
		f := int(app.choice.finish)
		ui.next({width = ui.px(em * 31), height = ui.px(em * 2.1)})
		if ui.segmented("###finish", finishes[:], &f) { app.choice.finish = ui.Finish(f) }
		ui.spacer(ui.px(em * 2))
		weak("mode_words", "Version", em * 4.5, em)
		modes := [2]string{"Dark", "Light"}
		m := app.choice.mode == .Light ? 1 : 0
		ui.next({width = ui.px(em * 11), height = ui.px(em * 2.1)})
		if ui.segmented("###mode", modes[:], &m) { app.choice.mode = m == 1 ? .Light : .Dark }
	}
	ui.spacer(ui.px(em))
	half := (len(app.themes) + 1) / 2
	half += (3 - half % 3) % 3   // (whole rows of three on the left)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###walls") {
		lists := [2][]ui.Theme_Def{app.themes[:half], app.themes[half:]}
		for list, i in lists {
			if i > 0 { ui.spacer(ui.px(em * 0.5)) }
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = fmt.tprintf("###wall%d", i)) {
				if picked := prefs_page.theme_cards(list, app.shown.def.name, app.shown.light, em); picked >= 0 {
					app.choice.name = list[picked].name
				}
			}
		}
	}
}

////////////////////////////////
// The overlays' scenes

// A dialog of its own: its header with the close button in its corner, its body, its buttons. It fades in.
dialog_build :: proc(app: ^App, em: f32) {
	if ui.modal_sized("export", {em * 31, 0}, &app.dialog_size, &app.dialog_open) {
		if ui.dialog_header("export_head", "Export pictures", {icon = lucide.DOWNLOAD, icon_font = ui.lucide_icons(), close = true}) {}
		if ui.dialog_body("export_body") {
			if ui.form_row("Name") { ui.line_edit("###export_name", &app.file_name, "The file's name") }
			if ui.form_row("Format") {
				formats := [3]string{"PNG", "JPEG", "WebP"}
				ui.segmented("###export_format", formats[:], &app.format)
			}
			if ui.form_row("Quality") { ui.number("###export_quality", &app.quality, lo = 1, hi = 100, unit = "%", track = true) }
			if ui.form_row("Width") { ui.number("###export_width", &app.width, lo = 1, hi = 40, step = 0.5, unit = "px", track = true) }
			ui.next({width = ui.fill(), height = ui.px(em * 2.1)})
			ui.toggle("###export_open", "Open the folder after", &app.switches[0])
			ui.spacer(ui.px(em * 0.5))
			facts_well("###export_facts", em)
		}
		if ui.dialog_buttons("export_buttons") {
			if ui.button("export_cancel", "Cancel", lucide.X, {intent = .Cancel}).clicked { app.dialog_open = false }
			ui.spacer(ui.px(em * 0.6))
			if ui.button("export_go", "Export 4 pictures", lucide.DOWNLOAD, {intent = .Primary}).clicked {
				app.dialog_open = false
				ui.announce(&app.announcer, .Good, "4 pictures exported", "~/Pictures/Shots")
			}
		}
	}
}

// What a program says of what it did: toasts of the window here (Announcer.mode Window), a line or a title and its words.
toasts_say :: proc(app: ^App) {
	ui.toast(.Info, "Workflow saved: 7 nodes, 6 links")
	ui.announce(&app.announcer, .Good, "Link copied", "https://example.org/s/4hx2")
	ui.toast(.Warn, "The host is slow: 4 s for the last picture")
	ui.toast_titled(.Bad, "Upload failed", "The server refused the picture: 413, too large. Lower the quality and try again.")
}
