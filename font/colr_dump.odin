package font

import "core:fmt"
import "core:strings"

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
	case .Graph: dump_paint(c, &r, &sb, at, 0, 0)
	}
	return strings.to_string(sb)
}

@(private = "file")
dump_paint :: proc(c: ^Colr, r: ^Rd, sb: ^strings.Builder, off, depth, budget: int) {
	if budget > 400 || depth > 40 { fmt.sbprintf(sb, "%*s...\n", depth * 2, ""); return }
	f := rd_u8(r, off)
	pad := depth * 2
	fmt.sbprintf(sb, "%*s@%d f%d: % x\n", pad, "", off, f, r.d[off:min(off + 16, len(r.d))])
	child := proc(r: ^Rd, off, at: int) -> int { return off + rd_u24(r, off + at) }
	switch f {
	case 1:
		n, first := rd_u8(r, off + 1), rd_u32(r, off + 2)
		fmt.sbprintf(sb, "%*sColrLayers %d from %d\n", pad, "", n, first)
		for i in 0 ..< n {
			if first + i >= c.n_layer_list { break }
			dump_paint(c, r, sb, c.layer_list + rd_u32(r, c.layer_list + 4 + (first + i) * 4), depth + 1, budget + i)
		}
	case 2, 3: fmt.sbprintf(sb, "%*sSolid pal %d alpha %.3f\n", pad, "", rd_u16(r, off + 1), rd_f2(r, off + 3))
	case 4, 5, 6, 7, 8, 9:
		names := [?]string{"Linear", "Linear", "Radial", "Radial", "Sweep", "Sweep"}
		line := child(r, off, 1)
		ext, n := rd_u8(r, line), rd_u16(r, line + 1)
		fmt.sbprintf(sb, "%*s%sGradient%s extend %d, %d stops:", pad, "", names[f - 4], f & 1 == 1 ? "(var)" : "", ext, n)
		vs := f % 2 == 1   // odd formats: 5, 7, 9 are the variable ones
		st := vs ? 10 : 6
		for i in 0 ..< min(n, 8) {
			o := line + 3 + i * st
			fmt.sbprintf(sb, " [%.2f pal %d a %.2f]", rd_f2(r, o), rd_u16(r, o + 2), rd_f2(r, o + 4))
		}
		switch f {
		case 4, 5: fmt.sbprintf(sb, "  p0 (%d,%d) p1 (%d,%d) p2 (%d,%d)", rd_i16(r, off + 4), rd_i16(r, off + 6), rd_i16(r, off + 8), rd_i16(r, off + 10), rd_i16(r, off + 12), rd_i16(r, off + 14))
		case 6, 7: fmt.sbprintf(sb, "  c0 (%d,%d) r0 %d c1 (%d,%d) r1 %d", rd_i16(r, off + 4), rd_i16(r, off + 6), rd_u16(r, off + 8), rd_i16(r, off + 10), rd_i16(r, off + 12), rd_u16(r, off + 14))
		case 8, 9: fmt.sbprintf(sb, "  c (%d,%d) %.1f..%.1f", rd_i16(r, off + 4), rd_i16(r, off + 6), rd_f2(r, off + 8) * 180, rd_f2(r, off + 10) * 180)
		}
		fmt.sbprintf(sb, "\n")
	case 10:
		fmt.sbprintf(sb, "%*sGlyph %d\n", pad, "", rd_u16(r, off + 4))
		dump_paint(c, r, sb, child(r, off, 1), depth + 1, budget + 1)
	case 11:
		fmt.sbprintf(sb, "%*sColrGlyph %d\n", pad, "", rd_u16(r, off + 1))
	case 12, 13:
		tm := child(r, off, 4)
		fmt.sbprintf(sb, "%*sTransform %.3f %.3f %.3f %.3f %.1f %.1f\n", pad, "", rd_fixed(r, tm), rd_fixed(r, tm + 4), rd_fixed(r, tm + 8), rd_fixed(r, tm + 12), rd_fixed(r, tm + 16), rd_fixed(r, tm + 20))
		dump_paint(c, r, sb, child(r, off, 1), depth + 1, budget + 1)
	case 14 ..= 31:
		names := [?]string{"Translate", "Translate", "Scale", "Scale", "ScaleAroundCenter", "ScaleAroundCenter", "ScaleUniform", "ScaleUniform", "ScaleUniformAroundCenter", "ScaleUniformAroundCenter", "Rotate", "Rotate", "RotateAroundCenter", "RotateAroundCenter", "Skew", "Skew", "SkewAroundCenter", "SkewAroundCenter"}
		fmt.sbprintf(sb, "%*s%s (format %d) args %d %d %d %d\n", pad, "", names[f - 14], f, rd_i16(r, off + 4), rd_i16(r, off + 6), rd_i16(r, off + 8), rd_i16(r, off + 10))
		dump_paint(c, r, sb, child(r, off, 1), depth + 1, budget + 1)
	case 32:
		fmt.sbprintf(sb, "%*sComposite mode %v\n", pad, "", Composite_Mode(rd_u8(r, off + 4)))
		fmt.sbprintf(sb, "%*s source:\n", pad, "")
		dump_paint(c, r, sb, child(r, off, 1), depth + 1, budget + 1)
		fmt.sbprintf(sb, "%*s backdrop:\n", pad, "")
		dump_paint(c, r, sb, child(r, off, 5), depth + 1, budget + 1)
	case: fmt.sbprintf(sb, "%*sformat %d?\n", pad, "", f)
	}
}
