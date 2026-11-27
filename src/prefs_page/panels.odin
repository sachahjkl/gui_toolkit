package tk_prefs_page

// How far the window frame's bottom and top panels go across (src/md/features/views.md, section 6.1b), on the page
// "window", under its preferences. Not preferences: the views' memory keeps the choice with the layout, and "Reset the
// layout" forgets it. A line has the look of a preference's (setting): its words, a reset while the person chose, a
// segmented choice.

import "core:fmt"
import "core:math"
import i18n "../i18n"
import "../ui"

// The page that shows the panels' lines.
@(private) PANELS_PAGE :: "window"

// The lines of Page_Options.views's frame: the bottom panel's always (any panel can be docked there), the top panel's
// while the frame has a top zone or the person chose its span.
@(private)
panel_lines :: proc(p: ^Page, o: Page_Options, em: f32) {
	if o.views == nil { return }
	_, top_chosen := ui.views_space_span(o.views, "", .Top)
	if .Top in ui.views_space_zones(o.views, "") || top_chosen { panel_line(p, o, .Top, em) }
	panel_line(p, o, .Bottom, em)
}

@(private = "file")
panel_line :: proc(p: ^Page, o: Page_Options, edge: ui.View_Edge, em: f32) {
	top := edge == .Top
	title := top ? i18n.tr("Top panel") : i18n.tr("Bottom panel")
	note := top ? i18n.tr("How far the panel at the top of the window goes across.") : i18n.tr("How far the panel at the bottom of the window goes across.")
	labels := []string{i18n.tr("Content"), i18n.tr("Left"), i18n.tr("Right"), i18n.tr("Full")}
	tips: [4]string
	if top {
		tips = {i18n.tr("Over the content only: the side panels go up to the window's top"), i18n.tr("Over the left panel and the content"),
			i18n.tr("Over the content and the right panel"), i18n.tr("Across the whole window")}
	} else {
		tips = {i18n.tr("Under the content only: the side panels go down to the window's bottom"), i18n.tr("Under the left panel and the content"),
			i18n.tr("Under the content and the right panel"), i18n.tr("Across the whole window")}
	}
	span, chosen := ui.views_space_span(o.views, "", edge)
	name := top ? "panels.top" : "panels.bottom"
	if p.rule_before { ui.hline(ui.fill()) }
	p.rule_before = true
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###set_%s", name)) {
		ui.space(ui.ROW_PAD)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###line") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###words") {
				ui.next({width = ui.fill(), height = ui.px(em * 1.5), font_size = math.round(em * 0.92), text_pad = 0})
				ui.label(fmt.tprintf("%s###t", title))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###d", note))
				}
			}
			ui.space(ui.CONTROL_GAP)
			if chosen {
				if reset_button(o, em) { ui.views_space_set_span(o.views, "", edge, nil) }
				ui.space(ui.CONTROL_GAP)
			}
			// (the segmented choice takes its words' width, a list when the line is narrower: ui.segmented)
			selected := int(span)
			if ui.segmented(fmt.tprintf("%s_choice", name), labels, &selected, tips[:]) {
				ui.views_space_set_span(o.views, "", edge, ui.View_Span(selected))
			}
		}
		ui.space(ui.ROW_PAD)
	}
}
