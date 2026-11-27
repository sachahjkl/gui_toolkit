package showcase

// The tabs' design proposals (src/md/features/tab-styles.md): a row of tabs over a card (a panel's switcher, as feuille's
// signature) and over a terminal (its own ground, as ardoise), in the style --tabs= names. The editor's scene shows the
// third context, a dock.
//   build/showcase --tabs=folder --tab-demo=card        silhouette, folder, underline, segmented, header; card, terminal

import "core:fmt"
import "core:math"
import lucide "gt:lucide"
import "gt:ui"

Tab_Demo :: enum { None, Card, Terminal }
TAB_DEMO_NAMES := [Tab_Demo]string{.None = "", .Card = "card", .Terminal = "terminal"}
TAB_STYLE_NAMES := [ui.Tab_Style]string{.Silhouette = "silhouette", .Folder = "folder", .Underline = "underline", .Segmented = "segmented", .Header = "header"}

Tab_Demo_State :: struct {
	card_tab, term_tab: int,
	name:     ui.Line_Edit,
	slant:    f32,
	flourish: bool,
	ready:    bool,
}

// A terminal's ground: off the page, as a terminal's palette is (darker on a dark theme, paper on a light one).
@(private = "file")
terminal_surface :: proc() -> ui.Tab_Surface {
	page := ui.color("background")
	page.a = 1
	light := ui.luminance(page) > 0.5
	return {ground = light ? ui.lighten(page, 0.75) : ui.darken(page, 0.42)}
}

tab_demo_build :: proc(app: ^App, em: f32) {
	t := &app.tab_demo_state
	if !t.ready {
		t.ready = true
		ui.line_edit_set(&t.name, "Camille Martin")
		t.slant, t.flourish = 4, true
	}
	switch app.tab_demo {
	case .None:
	case .Card:     tab_demo_card(t, em)
	case .Terminal: tab_demo_terminal(t, em)
	}
}

// A dialog's panel with its switcher (feuille's signature: typed, drawn or imported).
@(private = "file")
tab_demo_card :: proc(t: ^Tab_Demo_State, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###tab_card_page") {
		ui.spacer(ui.px(math.round(em * 2)))
		ui.next({width = ui.px(math.round(em * 30)), height = ui.fill(), axis = .Y})
		if ui.column(id = "###tab_card_col") {
			ui.spacer(ui.px(math.round(em * 1.5)))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2))})
			ui.label("Signature###tab_card_title")
			ui.spacer(ui.px(math.round(em * 0.5)))
			surface: ui.Tab_Surface
			if ui.tags("card") { surface = {ground = ui.color("background"), edge = ui.color("border")} }
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 19))})
			if _, ok := ui.tab_panel("###sig_tabs", {"Type it", "Draw it", "Import"}, nil, &t.card_tab, {surface = surface}); ok {
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.2))})
				ui.line_edit("###sig_name", &t.name, {placeholder = "Your name"})
				ui.spacer(ui.px(math.round(em * 0.8)))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 2))})
				if ui.row(.Center, id = "###sig_slant") {
					ui.next({width = ui.px(math.round(em * 6)), height = ui.pct(1)})
					if ui.tags("weak") { ui.label("Slant###sig_slant_l") }
					ui.next({width = ui.fill(), height = ui.pct(1)})
					ui.slider("###sig_slant_s", &t.slant, -10, 10, 1, "%.0f°")
				}
				ui.spacer(ui.px(math.round(em * 0.5)))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 2))})
				ui.toggle("###sig_flourish", "A flourish under the name", &t.flourish)
				ui.spacer(ui.px(math.round(em * 0.8)))
				// the preview: the signature on paper
				edge: ui.Color
				if ui.tags("card") { edge = ui.color("border") }
				ui.next({width = ui.fill(), height = ui.fill(), bg = {1, 1, 1, 1}, fg = {0.16, 0.22, 0.55, 1}, border = edge, radius = math.round(em * 0.3), font_size = em * 1.5, text_align = .Center})
				ui.build_box({.Draw_Background, .Draw_Border, .Draw_Text}, "Camille Martin###sig_preview")
			}
		}
	}
}

@(private = "file", rodata)
TERMINAL_LINES := [?]string{
	"$ git log --oneline -4",
	"7d1c2e0 (HEAD -> master) Panes resume from their offset",
	"4be91aa The smallest client sizes the pane",
	"19f3c07 Snapshots over the protocol",
	"a02d6b1 Keeps your shells alive",
	"$ ls",
	"CHANGELOG.md  README.md  ROADMAP.md  docs  src  tests",
	"$ _",
}

// A terminal's window: its tabs and their "+" over the shell's own ground (ardoise).
@(private = "file")
tab_demo_terminal :: proc(t: ^Tab_Demo_State, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###tab_term_page") {
		ui.spacer(ui.px(math.round(em * 1)))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###tab_term_col") {
			ui.spacer(ui.px(math.round(em * 1)))
			opts := ui.Tab_Panel_Options{surface = terminal_surface(), pad = math.round(em * 0.75)}
			opts.tabs.after = proc(_: rawptr) {
				em := ui.font_size()
				ui.next({width = ui.px(math.round(em * 2)), height = ui.px(math.round(em * 2))})
				if ui.tags("icon_button", "weak") { ui.button("###term_new", "", lucide.PLUS) }
			}
			ui.next({width = ui.fill(), height = ui.fill()})
			if _, ok := ui.tab_panel("###term_tabs", {"sh · sacha", "sh · sacha", "htop"}, nil, &t.term_tab, opts); ok {
				for line, i in TERMINAL_LINES {
					ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.45)), font = ui.mono_font(), text_pad = 0})
					ui.build_box({.Draw_Text}, fmt.tprintf("%s###term_line_%d", line, i))
				}
			}
			ui.spacer(ui.px(math.round(em * 1)))
		}
		ui.spacer(ui.px(math.round(em * 1)))
	}
}
