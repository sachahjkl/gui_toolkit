// The mermaid package (native/mermaid's library, built by tools/tk build_mermaid): a diagram's text to a drawing, and a
// mistake to what mermaid says of it; the drawing drawn in a window (diagram.png beside the session's files).
//   odin test tests/mermaid -vet -define:ODIN_TEST_THREADS=1
package mermaid_test

import "core:strings"
import "core:testing"
import draw "../../src/draw"
import font "../../src/font"
import mermaid "../../src/mermaid"
import svg "../../src/svg"
import "../../src/testkit/session"
import "../../src/ui"

FLOW :: "flowchart TD\n  A[User types /goal] --> B{Commands read?}\n  B -->|yes| C[Send as command]\n  B -->|no| D[Wait for the catalog]\n  D --> B\n"

@(test)
a_diagram_is_a_drawing_and_a_mistake_says_why :: proc(t: ^testing.T) {
	doc, why := mermaid.diagram(FLOW, dark = true)
	defer svg.destroy(&doc)
	testing.expect_value(t, why, "")
	testing.expect(t, doc.view[2] > 0 && doc.view[3] > 0, "a size")
	labels := 0
	for it in doc.items { if tx, ok := it.(svg.Text); ok && strings.contains(tx.text, "Commands read?") { labels += 1 } }
	testing.expect_value(t, labels, 1)
	_, why2 := mermaid.diagram("this is no diagram")
	testing.expect(t, why2 != "", "why it is none")
	s, why3 := mermaid.to_svg("sequenceDiagram\n  A->>B: hi\n", allocator = context.temp_allocator)
	testing.expect(t, why3 == "" && strings.has_prefix(s, "<svg"), "a sequence as SVG")
}

@(private = "file")
App :: struct { doc: svg.Document, scale: f32 }

// Drawn with the toolkit's fonts: the labels' ink inside the window, the drawing at its size.
@(test)
a_diagram_is_drawn :: proc(t: ^testing.T) {
	app: App
	why: string
	app.doc, why = mermaid.diagram(FLOW, dark = true)
	defer svg.destroy(&app.doc)
	if !testing.expect_value(t, why, "") { return }
	app.scale = 1.5
	s := session.start(t, {size = {900, 700}, user = &app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		sz := svg.size(&app.doc, app.scale)
		ui.next({width = ui.px(sz.x), height = ui.px(sz.y)})
		b := ui.build_box({}, "###diagram")
		b.custom_user = app
		b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			app := (^App)(user)
			draw.rect(dc, b.rect, draw.hex(0x1e1e1eff))
			bold := font.styled_face(dc.fonts, b.font, true, false)
			svg.draw_doc(dc, &app.doc, b.rect.min, app.scale, {regular = b.font, bold = bold})
		}
	}})
	session.frames(s, 3)
	b := session.get(s, "diagram")
	testing.expect(t, b.rect.max.x - b.rect.min.x > 400, "at its size")
	session.save_png(s, "diagram.png")
	img := session.capture(s)
	inside := session.count_other(img, {int(b.rect.min.x) + 4, int(b.rect.min.y) + 4}, {int(b.rect.max.x) - 4, int(b.rect.max.y) - 4}, session.pixel(img, int(b.rect.min.x) + 2, int(b.rect.min.y) + 2))
	testing.expect(t, inside > 1000, "something is drawn")
}
