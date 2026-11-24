package markdown_test

// Mermaid blocks (markdown.Diagrams), with a layout of the test's own (the real one is gt:mermaid's: tests/mermaid): a
// closed block shows its text, then its diagram once the chore answers; a block still being written and a text that is
// no diagram stay text; the bound drops the diagram drawn least recently; the cache destroyed while a layout runs.

import "core:strings"
import "core:testing"
import "gt:markdown"
import svg "gt:svg"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
FAKE_SVG :: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100"><rect x="0" y="0" width="200" height="100" fill="#ff0000"/></svg>`

// A "graph" is a diagram of 200 × 100; anything else is none.
@(private = "file")
fake_layout :: proc(text: string, dark: bool) -> (doc: svg.Document, why: string) {
	if !strings.has_prefix(text, "graph") { return {}, "no diagram here" }
	d, _ := svg.parse(FAKE_SVG)
	return d, ""
}

@(private = "file")
Diagram_App :: struct {
	doc:      markdown.Doc,
	diagrams: markdown.Diagrams,
	text:     string,
}

@(private = "file")
diagram_build :: proc(s: ^session.Session) {
	app := (^Diagram_App)(s.user)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###col") { markdown.view(&app.doc, "md", app.text, {diagrams = &app.diagrams}) }
}

@(private = "file")
pending_count :: proc(ds: ^markdown.Diagrams) -> (n: int) {
	for _, d in ds.entries { if d.pending { n += 1 } }
	return
}

@(test)
a_mermaid_block_shows_its_text_then_its_diagram :: proc(t: ^testing.T) {
	app: Diagram_App
	app.diagrams.layout = fake_layout
	defer markdown.diagrams_destroy(&app.diagrams)
	defer markdown.doc_destroy(&app.doc)
	app.text = "# Title\n\n```mermaid\ngraph TD\nA-->B\n```\n\n```Mermaid\nnot one\n```\n\n```mermaid\ngraph LR\n"
	s := session.start(t, {size = {600, 500}, user = &app, build = diagram_build})
	// the first frame: each closed block asked of the chores, shown as its text
	testing.expect_value(t, len(app.diagrams.entries), 2)
	testing.expect_value(t, pending_count(&app.diagrams), 2)
	testing.expect(t, session.find(s, "md_b1") != nil, "the first block's text")
	testing.expect(t, session.find(s, "md_b1_diagram") == nil, "no diagram yet")
	// the chore answers: the diagram, at the text's size, no wider than the column
	b := session.wait_box(s, "md_b1_diagram")
	w := b.rect.max.x - b.rect.min.x
	testing.expectf(t, w > 0 && w <= 600, "drawn at a width that fits: %v", w)
	testing.expect(t, session.find(s, "md_b1") == nil, "the text gave way")
	// no diagram: the text stays (its reason kept); a block still being written: its text, nothing asked
	testing.expect(t, session.find(s, "md_b2") != nil, "not a diagram: its text")
	testing.expect(t, session.find(s, "md_b2_diagram") == nil, "no diagram for it")
	testing.expect(t, session.find(s, "md_b3") != nil, "a block still being written: its text")
	testing.expect_value(t, len(app.diagrams.entries), 2)
	testing.expect_value(t, pending_count(&app.diagrams), 0)
	why_found := false
	for _, d in app.diagrams.entries { if d.why == "no diagram here" { why_found = true } }
	testing.expect(t, why_found, "the reason kept")
}

@(test)
the_bound_drops_the_diagram_drawn_least_recently :: proc(t: ^testing.T) {
	app: Diagram_App
	app.diagrams = {layout = fake_layout, kept = 1}
	defer markdown.diagrams_destroy(&app.diagrams)
	defer markdown.doc_destroy(&app.doc)
	app.text = "```mermaid\ngraph A\n```\n"
	s := session.start(t, {user = &app, build = diagram_build})
	session.wait_box(s, "md_b0_diagram")
	app.text = "```mermaid\ngraph B\n```\n"
	session.frames(s, 1)
	testing.expect_value(t, len(app.diagrams.entries), 1)   // (A went for B)
	session.wait_box(s, "md_b0_diagram")
	testing.expect_value(t, pending_count(&app.diagrams), 0)
}

@(test)
the_cache_goes_while_a_layout_runs :: proc(t: ^testing.T) {
	app: Diagram_App
	app.diagrams.layout = fake_layout
	defer markdown.doc_destroy(&app.doc)
	app.text = "```mermaid\ngraph A\n```\n"
	s := session.start(t, {user = &app, build = proc(s: ^session.Session) {
		app := (^Diagram_App)(s.user)
		if app.diagrams.layout != nil { markdown.view(&app.doc, "md", app.text, {diagrams = &app.diagrams}) }
	}})
	testing.expect_value(t, pending_count(&app.diagrams), 1)
	markdown.diagrams_destroy(&app.diagrams)
	app.diagrams.layout = nil
	session.frames(s, 3)   // (the answer finds no cache: it frees its drawing)
	testing.expect_value(t, len(app.diagrams.entries), 0)
	ui.chores_stop()
}
