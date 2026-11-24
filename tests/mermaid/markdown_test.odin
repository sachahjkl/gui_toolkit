package mermaid_test

// A ```mermaid block in Markdown with the real layout (mermaid.layout, the native library): its text at the first frame,
// then its diagram, drawn, once the chore answers.

import "core:testing"
import "gt:markdown"
import mermaid "gt:mermaid"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
Md_App :: struct {
	doc:      markdown.Doc,
	diagrams: markdown.Diagrams,
}

@(private = "file")
MD_TEXT :: "Before.\n\n```mermaid\n" + FLOW + "```\n\nAfter.\n"

@(test)
a_markdown_mermaid_block_becomes_its_diagram :: proc(t: ^testing.T) {
	app: Md_App
	app.diagrams.layout = mermaid.layout
	defer markdown.diagrams_destroy(&app.diagrams)
	defer markdown.doc_destroy(&app.doc)
	s := session.start(t, {size = {900, 700}, user = &app, build = proc(s: ^session.Session) {
		app := (^Md_App)(s.user)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") { markdown.view(&app.doc, "md", MD_TEXT, {diagrams = &app.diagrams}) }
	}})
	testing.expect(t, session.find(s, "md_b1") != nil, "its text first")
	testing.expect(t, session.find(s, "md_b1_diagram") == nil, "no diagram at the first frame")
	b := session.wait_box(s, "md_b1_diagram")
	session.frames(s, 2)
	b = session.get(s, "md_b1_diagram")
	testing.expect(t, b.rect.max.x - b.rect.min.x > 100, "at its size")
	img := session.capture(s)
	inside := session.count_other(img, {int(b.rect.min.x) + 2, int(b.rect.min.y) + 2}, {int(b.rect.max.x) - 2, int(b.rect.max.y) - 2}, session.pixel(img, int(b.rect.min.x) + 1, int(b.rect.min.y) + 1))
	testing.expectf(t, inside > 500, "the diagram is drawn: %d pixels", inside)
	session.save_png(s, "markdown_diagram.png")
}
