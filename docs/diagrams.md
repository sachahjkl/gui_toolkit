# Diagrams: the `svg` and `mermaid` packages

A diagram is drawn by the toolkit itself, in its paths and its fonts: no browser, no image.

## svg: a drawing in SVG

`svg.parse(text)` reads a drawing into shapes (paths in the drawing's coordinates, with their fill, stroke, width and dashes)
and texts (a line each, with its pen, anchor, size and weight). `svg.draw_doc(dc, &doc, at, scale, o)` draws it with
its top-left corner at `at`, `scale` screen pixels per unit of its viewBox; `svg.size(&doc, scale)` is its size there.
`svg.destroy(&doc)` frees it.

```odin
doc, ok := svg.parse(text)
defer svg.destroy(&doc)
bold := font.styled_face(dc.fonts, regular, true, false)
svg.draw_doc(dc, &doc, b.rect.min, scale, {regular = regular, bold = bold})
```

It reads what diagrams and icons use: `svg`, `g`, `path` (every command, arcs too), `rect` (rounded), `circle`, `ellipse`,
`line`, `polyline`, `polygon`, `text` and `tspan`, markers (an arrowhead at a line's end, turned to it), `transform`,
`fill`, `stroke`, `stroke-width`, `stroke-dasharray`, the opacities, `font-size`, `font-weight`, `text-anchor` and the
`style` attribute. A linear gradient is its first colour. Style sheets, filters, images and clips are left out; the rest
is drawn. The paths are built at the screen's scale: curves are smooth and strokes as wide as the scale makes them at
every zoom. `Draw_Options.recolor` turns the drawing's colours into the program's (its theme).

`svg.raster(&doc, scale, fonts, o, background)` makes the same drawing into pixels on the CPU, where no frame is
drawn: a `paint.Canvas` to copy (`paint.to_rgba8`) or to save (`paint.png_encode`). Its texts are filled from the outlines
of the options' faces; a glyph without an outline (a colour emoji) is left out.

```odin
c := svg.raster(&doc, 2, &fonts, {regular = regular, bold = bold}, background = {1, 1, 1, 1})
defer paint.canvas_destroy(&c)
platform.clipboard_set_image(win, {rgba = paint.to_rgba8(c, context.temp_allocator), size = {c.width, c.height}})
```

## mermaid: a diagram's text

`mermaid.diagram(text, dark)` lays out a [Mermaid](https://mermaid.js.org) diagram (flowchart, sequence, class, state, ER,
gantt, pie, mindmap, timeline, git graph, and more) and gives the drawing `svg.draw_doc` draws; `why` says what is wrong
with a text that is no diagram. `mermaid.to_svg` gives the SVG itself.

The layout is mermaid-svg's (native/mermaid, a Rust crate of one dependency, MIT), built by `tools/tk build_mermaid` into
`build/mermaid/gt_mermaid.lib` (`libgt_mermaid.a` on Linux), which the package links. A program that has a Rust library of
its own builds `gt_mermaid` into it (`gt_mermaid = { path = "…/native/mermaid" }`, its `gt_mermaid_*` functions stay
exported) and builds with `-define:MERMAID_NATIVE_LINK=false`, as for the text backend. It adds about 1 MB to a program.

### A graph laid out in another direction

A flowchart says its direction on its header (`flowchart LR`); a class, state, ER or requirement diagram on a line of its
own (`direction LR`). `mermaid.diagram(text, dark, direction = .Left_Right)` lays the same diagram out another way:
`.Top_Down`, `.Left_Right`, `.Bottom_Top`, `.Right_Left` (`.Text`: as the text says). `takes_direction(text)` says whether
its kind has one, `direction_of(text)` which one its text says, `with_direction(text, d)` gives the text rewritten.
mermaid-svg has one layout (layered, Sugiyama): `flowchart-elk` and `layout: elk` are laid out with it too.

A layout takes time in proportion to the diagram: a program that lays one out again while it shows it (a viewer where the
person picks the direction) does it in a task (`ui.task`) and keeps the result.
