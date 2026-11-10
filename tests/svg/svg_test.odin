// The svg package's reading: elements, paths, colours, transforms, markers and texts, on its own drawings and on what mermaid-svg
// writes (flowchart.svg, sequence.svg: native/mermaid's output, kept). Pure: no window.
//   odin test tests/svg -vet
package svg_test

import "core:math"
import "core:testing"
import svg "../../src/svg"

FLOWCHART :: #load("flowchart.svg", string)
SEQUENCE :: #load("sequence.svg", string)

@(private = "file")
texts :: proc(doc: ^svg.Document) -> [dynamic]svg.Text {
	out := make([dynamic]svg.Text, context.temp_allocator)
	for it in doc.items { if t, ok := it.(svg.Text); ok { append(&out, t) } }
	return out
}

@(private = "file")
shapes :: proc(doc: ^svg.Document) -> [dynamic]svg.Shape {
	out := make([dynamic]svg.Shape, context.temp_allocator)
	for it in doc.items { if s, ok := it.(svg.Shape); ok { append(&out, s) } }
	return out
}

@(private = "file")
near :: proc(a, b: [2]f32) -> bool { return abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }

// mermaid-svg's flowchart: its view, its boxes, its labels where it put them, an arrow at the end of each line.
@(test)
a_flowchart_of_mermaid_is_read :: proc(t: ^testing.T) {
	doc, ok := svg.parse(FLOWCHART)
	defer svg.destroy(&doc)
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, doc.view, [4]f32{0, 0, 422.5, 352})
	ts := texts(&doc)
	labels := map[string]bool{}
	defer delete(labels)
	for tx in ts { labels[tx.text] = true }
	for want in ([]string{"User types /goal", "Commands read?", "Send as command", "Wait for the catalog", "yes", "no"}) {
		testing.expectf(t, want in labels, "the label %q", want)
	}
	for tx in ts {
		if tx.text != "User types /goal" { continue }
		testing.expect(t, near(tx.at, {305.5, 51}), "at its x and baseline")
		testing.expect_value(t, tx.anchor, svg.Anchor.Middle)
		testing.expect_value(t, tx.size, f32(14))   // (the svg's font-size)
	}
	// 4 lines and a diamond, 5 rects, and an arrowhead at the end of each line (the markers' own paths are not drawn as such)
	ss := shapes(&doc)
	testing.expect_value(t, len(ss), 5 + 5 + 4)
	// the first line goes down to y 148: its arrowhead's tip is there
	head := ss[1]   // (the line, then its marker)
	tip_found := false
	for s in head.segs { if near(s.p, {305.5, 148}) { tip_found = true } }
	testing.expect(t, tip_found, "the arrow's tip at the line's end")
}

// Dashed lines and texts of mermaid-svg's sequence diagram.
@(test)
a_sequence_of_mermaid_is_read :: proc(t: ^testing.T) {
	doc, ok := svg.parse(SEQUENCE)
	defer svg.destroy(&doc)
	if !testing.expect(t, ok) { return }
	dashed := 0
	for s in shapes(&doc) { if len(s.dash) > 0 { dashed += 1 } }
	testing.expect(t, dashed >= 2, "the lifelines and the answer are dashed")
	found := false
	for tx in texts(&doc) { if tx.text == "/goal ship" { found = true } }
	testing.expect(t, found, "the message")
}

// Paths: absolute and relative steps, H and V, smooth curves, arcs, implicit lines after M.
@(test)
a_path_is_read :: proc(t: ^testing.T) {
	segs := svg.path_of("M10 10 20 10 h10 v10 l-10 0 z")
	testing.expect_value(t, len(segs), 6)
	testing.expect(t, segs[1].kind == .Line && near(segs[1].p, {20, 10}), "a pair after M is a line")
	testing.expect(t, near(segs[2].p, {30, 10}) && near(segs[3].p, {30, 20}) && near(segs[4].p, {20, 20}))
	testing.expect_value(t, segs[5].kind, svg.Seg_Kind.Close)
	c := svg.path_of("M0 0C10 0 20 10 20 20S30 40 40 40")
	testing.expect_value(t, len(c), 3)
	testing.expect(t, near(c[2].c1, {20, 30}), "S reflects the last control point")
	// a half circle: from (0,0) to (20,0), radius 10, ending exactly there, through (10,-10) or (10,10)
	a := svg.path_of("M0 0 A10 10 0 0 1 20 0")
	testing.expect(t, len(a) >= 3, "an arc as cubics")
	testing.expect(t, near(a[len(a) - 1].p, {20, 0}), "it ends where it says")
	mid := a[1].p
	testing.expect(t, abs(abs(mid.y) - 10) < 0.01 && abs(mid.x - 10) < 0.01, "through the top or bottom of its circle")
	flags := svg.path_of("M0 0a10 10 0 0120 0")   // (flags that touch)
	testing.expect(t, near(flags[len(flags) - 1].p, {20, 0}))
}

// Colours, opacity, groups' transforms and styles, a stroke's width under a scale.
@(test)
styles_and_transforms_are_applied :: proc(t: ^testing.T) {
	src := `<svg viewBox="0 0 100 100"><g transform="translate(10 20) scale(2)" fill="#f00" opacity="0.5">
		<rect x="1" y="2" width="3" height="4" stroke="rgb(0, 255, 0)" stroke-width="1.5"/>
		<circle cx="0" cy="0" r="1" style="fill: #00f; stroke: none"/>
		<text x="5" y="6" font-size="8" font-weight="bold" text-anchor="end">A &amp; B</text></g></svg>`
	doc, ok := svg.parse(src)
	defer svg.destroy(&doc)
	if !testing.expect(t, ok) { return }
	ss := shapes(&doc)
	testing.expect_value(t, len(ss), 2)
	r := ss[0]
	testing.expect(t, near(r.segs[0].p, {12, 24}), "the group's transform")
	testing.expect_value(t, r.stroke_width, f32(3))
	fill := r.fill.? or_else {}
	testing.expect_value(t, fill, svg.Color{1, 0, 0, 0.5})
	stroke := r.stroke.? or_else {}
	testing.expect_value(t, stroke, svg.Color{0, 1, 0, 0.5})
	c := ss[1]
	cf := c.fill.? or_else {}
	testing.expect_value(t, cf, svg.Color{0, 0, 1, 0.5})   // (the style attribute wins)
	_, has_stroke := c.stroke.?
	testing.expect(t, !has_stroke)
	ts := texts(&doc)
	testing.expect_value(t, len(ts), 1)
	testing.expect_value(t, ts[0].text, "A & B")
	testing.expect(t, ts[0].bold && ts[0].anchor == .End)
	testing.expect_value(t, ts[0].size, f32(16))
	testing.expect(t, near(ts[0].at, {20, 32}))
}

// A marker turned to its line: an arrow at the end of a line going down points down.
@(test)
a_marker_turns_with_its_line :: proc(t: ^testing.T) {
	src := `<svg viewBox="0 0 100 100"><defs><marker id="m" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="10" markerHeight="10" orient="auto"><path d="M0 0 L10 5 L0 10z"/></marker></defs>
		<path d="M50 10 L50 90" stroke="#000" stroke-width="1" marker-end="url(#m)"/></svg>`
	doc, ok := svg.parse(src)
	defer svg.destroy(&doc)
	if !testing.expect(t, ok) { return }
	ss := shapes(&doc)
	testing.expect_value(t, len(ss), 2)
	head := ss[1]
	testing.expect(t, near(head.segs[1].p, {50, 90}), "its tip (10,5) on the line's end")
	testing.expect(t, near(head.segs[0].p, {55, 80}) || near(head.segs[0].p, {45, 80}), "its back, 10 above")
	_ = math.PI
}

@(test)
what_is_not_svg_is_no_drawing :: proc(t: ^testing.T) {
	_, ok := svg.parse("<html><body>no</body></html>")
	testing.expect(t, !ok)
	_, ok = svg.parse("")
	testing.expect(t, !ok)
}
