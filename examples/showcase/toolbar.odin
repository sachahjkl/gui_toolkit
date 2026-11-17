package showcase

// The tool bars scene: one editor's tool bar, declared once, shown twice at the same narrow width: folding what does not
// fit into its "…" menu (open from the start, so a picture shows its sections), then wrapping onto more lines.

import "core:fmt"
import "core:math"
import "gt:draw"
import lucide "gt:lucide"
import "gt:ui"

BAR_TOOLS :: [?]string{lucide.MOUSE_POINTER, lucide.PENCIL, lucide.HIGHLIGHTER, lucide.MOVE_UP_RIGHT, lucide.SQUARE, lucide.CIRCLE, lucide.TYPE, lucide.CROP}
BAR_TOOL_NAMES :: [?]string{"Select", "Pen", "Highlighter", "Arrow", "Rectangle", "Ellipse", "Text", "Crop"}
BAR_TOOL_KEYS :: [?]string{"V", "P", "H", "A", "R", "E", "T", "C"}
BAR_HUES :: [?]f32{0.0, 0.08, 0.14, 0.38, 0.6, 0.8}
BAR_DASHES :: [?]string{"Solid", "Dashed", "Dotted"}
// The width both bars stand in: narrow enough that the colours and the style of the folding one go into its "…" menu.
BAR_WIDTH_EM :: 56
FOLD_BAR :: "editor_fold"
INSERT_MENU :: "insert_menu"

toolbar_build :: proc(app: ^App, em: f32) {
	heading("Tool bars", "One tool bar, declared once: its groups, tools and controls. Too narrow, it wraps onto more lines, each group whole (above), or folds what does not fit into its \"…\" menu, a section per group (below).", em)
	// (the wrapping bar first: the "…" menu opens down, over what stands under the folding bar)
	// (BAR_WIDTH_EM, giving way to a narrower page down to what its bars need: the wrapping bar's widest group)
	ui.next({width = ui.px(math.round(em * BAR_WIDTH_EM), 0), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###bars") {
		bar_caption("Wrap, centred: the bar takes more lines, each one centred", em)
		editor_bar(app, "editor_wrap", .Wrap, .Center, em)
		ui.spacer(ui.px(em * 1.6))
		bar_caption("Fold, from the start (the default): what does not fit goes into the \"…\" menu", em)
		editor_bar(app, FOLD_BAR, .Fold, .Start, em)
	}
	// (its "…" menu open from the start, so that a picture shows its sections: once its button is laid out; a person who
	// comes to the scene later opens it themselves)
	if !app.bar_menu_opened {
		app.bar_menu_opened = app.builds > 12 || ui.toolbar_menu_show(FOLD_BAR)
	}
	// (the Insert tool's menu, built where a program builds its menus: the tool opens it in either bar, or as a submenu
	// of the "…" menu)
	if ui.menu(INSERT_MENU) {
		if ui.menu_item("Image…", "Ctrl+I", icon = lucide.IMAGE, icon_font = ui.lucide_icons()).clicked { ui.announce(&app.announcer, .Info, "Insert an image") }
		if ui.menu_item("Sticker", icon = lucide.STICKER, icon_font = ui.lucide_icons()).clicked { ui.announce(&app.announcer, .Info, "Insert a sticker") }
		if ui.menu_item("Step number", icon = lucide.HASH, icon_font = ui.lucide_icons()).clicked { ui.announce(&app.announcer, .Info, "Insert a step number") }
	}
}

@(private = "file")
bar_caption :: proc(words: string, em: f32) {
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.text_size(), text_pad = 0})
		ui.label(fmt.tprintf("%s###cap_%s", words, words[:4]))
	}
	ui.spacer(ui.px(em * 0.4))
}

// The bar of an editor, as cliche's: what draws, what it inserts, its colours and style, the edits, then Cancel and Done.
@(private = "file")
editor_bar :: proc(app: ^App, id: string, overflow: ui.Toolbar_Overflow, align: ui.Toolbar_Align, em: f32) {
	icons := ui.lucide_icons()
	tools, names, keys, hues, dashes := BAR_TOOLS, BAR_TOOL_NAMES, BAR_TOOL_KEYS, BAR_HUES, BAR_DASHES
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8))})
	if ui.toolbar(id, {overflow = overflow, align = align}) {
		if ui.toolbar_group("tools", {title = "Tools", priority = 3}) {
			for glyph, i in tools {
				if ui.toolbar_tool(fmt.tprintf("tool%d", i), {label = names[i], icon = glyph, shortcut = keys[i], icon_font = icons, on = app.bar_tool == i}) { app.bar_tool = i }
			}
		}
		if ui.toolbar_group("insert", {title = "Insert", priority = 2, separator = true}) {
			_ = ui.toolbar_tool("insert", {label = "Insert", icon = lucide.PLUS, words = true, icon_font = icons, menu = INSERT_MENU})
		}
		if ui.toolbar_group("colours", {title = "Colours", separator = true}) {
			if ui.toolbar_control("colour", {label = "Colour"}) {
				side := math.round(em * 1.3)
				for h, i in hues {
					if i > 0 { ui.spacer(ui.px(math.round(em * 0.25))) }
					ui.next({width = ui.px(side), height = ui.px(side), radius = side * 0.5, bg = draw.hsv(h, 0.7, 0.92), border = app.bar_colour == i ? nil : draw.Color{}})
					sw := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Fixed_Radius}, fmt.tprintf("###swatch%d", i))
					sw.cursor = .Hand
					if ui.signal(sw).clicked { app.bar_colour = i }
				}
			}
		}
		if ui.toolbar_group("style", {title = "Style", separator = true}) {
			if ui.toolbar_control("width", {label = "Width", labelled = true}) {
				ui.next({height = ui.px(math.round(em * 1.6))})   // (its width: the slider's own)
				ui.slider("###width", &app.bar_width, 1, 20, 1, "%.0f px")
			}
			if ui.toolbar_tool("bold", {label = "Bold", icon = lucide.BOLD, shortcut = "Ctrl+B", icon_font = icons, on = app.bar_bold}) { app.bar_bold = !app.bar_bold }
			if ui.toolbar_control("dashes", {label = "Dashes"}) {
				ui.next({height = ui.px(math.round(em * 1.8))})
				ui.segmented("###dashes", dashes[:], &app.bar_dash)
			}
		}
		if ui.toolbar_group("edit", {title = "Edit", priority = 1, separator = true}) {
			if ui.toolbar_tool("undo", {label = "Undo", icon = lucide.UNDO_2, shortcut = "Ctrl+Z", icon_font = icons}) { ui.announce(&app.announcer, .Info, "Undo") }
			if ui.toolbar_tool("redo", {label = "Redo", icon = lucide.REDO_2, shortcut = "Ctrl+Y", icon_font = icons}) { ui.announce(&app.announcer, .Info, "Redo") }
			if ui.toolbar_tool("copy", {label = "Copy", icon = lucide.COPY, shortcut = "Ctrl+C", icon_font = icons}) { ui.announce(&app.announcer, .Info, "Copied") }
			if ui.toolbar_tool("save", {label = "Save", icon = lucide.SAVE, shortcut = "Ctrl+S", icon_font = icons}) { ui.announce(&app.announcer, .Good, "Saved") }
		}
		if ui.toolbar_group("end", {pinned = true}) {
			if ui.toolbar_tool("cancel", {label = "Cancel", words = true}) { ui.announce(&app.announcer, .Info, "Cancelled") }
			if ui.toolbar_tool("done", {label = "Done", words = true, intent = .Primary}) { ui.announce(&app.announcer, .Good, "Done") }
		}
	}
}
