package font

import "core:fmt"
import "core:strings"

// What a listing shows at most: paints, depth, bytes of a paint, stops of a color line.
@(private = "file") DUMP_PAINTS_MAX :: 400
@(private = "file") DUMP_DEPTH_MAX :: 40
@(private = "file") DUMP_PAINT_BYTES :: 16
@(private = "file") DUMP_STOPS_MAX :: 8

// A readable listing of a glyph's paint graph (diagnostics: tools/colrcompare, tests).
colr_dump :: proc(c: ^Colr, gid: u16, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	at, kind := colr_find(c, gid)
	r := Rd{d = c.colr}
	switch kind {
	case .None: fmt.sbprintf(&sb, "glyph %d: no color description\n", gid)
	case .Layers:
		first, n := rd_u16(&r, at + 2), rd_u16(&r, at + 4)
		fmt.sbprintf(&sb, "glyph %d: %d v0 layers from %d\n", gid, n, first)
	case .Graph:
		lines := 0
		dump_paint(c, &r, &sb, at, 0, &lines)
	}
	return strings.to_string(sb)
}

// `lines` counts the paints listed in all: a graph with shared parts is listed part by part, and could be exponential.
@(private = "file")
dump_paint :: proc(c: ^Colr, r: ^Rd, sb: ^strings.Builder, off, depth: int, lines: ^int) {
	lines^ += 1
	if lines^ > DUMP_PAINTS_MAX || depth > DUMP_DEPTH_MAX { fmt.sbprintf(sb, "%*s...\n", depth * 2, ""); return }
	if off < 0 || off >= len(r.d) { fmt.sbprintf(sb, "%*s@%d: outside the table\n", depth * 2, "", off); return }
	p := decode_paint(r, off)
	f := p.format
	pad := depth * 2
	fmt.sbprintf(sb, "%*s@%d f%d: % x\n", pad, "", off, f, r.d[off:min(off + DUMP_PAINT_BYTES, len(r.d))])
	switch p.kind {
	case .Layers:
		fmt.sbprintf(sb, "%*sColrLayers %d from %d\n", pad, "", p.count, p.first)
		for i in 0 ..< p.count {
			if p.first + i >= c.n_layer_list { break }
			dump_paint(c, r, sb, c.layer_list + rd_u32(r, c.layer_list + COLR_LIST_COUNT_BYTES + (p.first + i) * COLR_LAYER_PAINT_BYTES), depth + 1, lines)
		}
	case .Solid: fmt.sbprintf(sb, "%*sSolid pal %d alpha %.3f\n", pad, "", p.palette, p.alpha)
	case .Gradient:
		g := p.gradient
		ext, n := rd_u8(r, p.line), rd_u16(r, p.line + 1)
		fmt.sbprintf(sb, "%*s%vGradient%s extend %d, %d stops:", pad, "", g.kind, p.var ? "(var)" : "", ext, n)
		for i in 0 ..< min(n, DUMP_STOPS_MAX) {
			t, palette, alpha := color_stop(r, p.line, i, p.var)
			fmt.sbprintf(sb, " [%.2f pal %d a %.2f]", t, palette, alpha)
		}
		switch g.kind {
		case .Linear: fmt.sbprintf(sb, "  p0 (%.0f,%.0f) p1 (%.0f,%.0f) p2 (%.0f,%.0f)", g.p0.x, g.p0.y, g.p1.x, g.p1.y, g.p2.x, g.p2.y)
		case .Radial: fmt.sbprintf(sb, "  c0 (%.0f,%.0f) r0 %.0f c1 (%.0f,%.0f) r1 %.0f", g.p0.x, g.p0.y, g.r0, g.p1.x, g.p1.y, g.r1)
		case .Sweep: fmt.sbprintf(sb, "  c (%.0f,%.0f) %.1f..%.1f", g.p0.x, g.p0.y, g.a0, g.a1)
		}
		fmt.sbprintf(sb, "\n")
	case .Glyph:
		fmt.sbprintf(sb, "%*sGlyph %d\n", pad, "", p.gid)
		dump_paint(c, r, sb, p.child, depth + 1, lines)
	case .Colr_Glyph:
		fmt.sbprintf(sb, "%*sColrGlyph %d\n", pad, "", p.gid)
	case .Transform:
		names := [?]string{"Transform", "Translate", "Scale", "ScaleAroundCenter", "ScaleUniform", "ScaleUniformAroundCenter", "Rotate", "RotateAroundCenter", "Skew", "SkewAroundCenter"}
		fmt.sbprintf(sb, "%*s%s (format %d) %.3f %.3f %.3f %.3f %.1f %.1f\n", pad, "", names[(f - 12) / 2], f, p.m[0], p.m[1], p.m[2], p.m[3], p.m[4], p.m[5])
		dump_paint(c, r, sb, p.child, depth + 1, lines)
	case .Composite:
		fmt.sbprintf(sb, "%*sComposite mode %v\n", pad, "", Composite_Mode(p.mode))
		fmt.sbprintf(sb, "%*s source:\n", pad, "")
		dump_paint(c, r, sb, p.child, depth + 1, lines)
		fmt.sbprintf(sb, "%*s backdrop:\n", pad, "")
		dump_paint(c, r, sb, p.backdrop, depth + 1, lines)
	case .Unknown: fmt.sbprintf(sb, "%*sformat %d?\n", pad, "", f)
	}
}
