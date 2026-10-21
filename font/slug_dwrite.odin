#+build windows
package font

import "base:runtime"

// The Slug outline provider on DirectWrite: IDWriteFontFace::GetGlyphRunOutline pours the glyph into a geometry sink
// (ID2D1SimplifiedGeometrySink: lines and cubic Béziers) that this file implements. Variable instances and simulated
// bold / slant are honored, since the face carries them. DirectWrite raises TrueType quadratics to cubics; they are
// recognized and come back as the original quadratics (slug_outline.odin).

IDWriteGeometrySink :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteGeometrySink_VTable,
}
IDWriteGeometrySink_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	SetFillMode:     proc "system" (this: ^IDWriteGeometrySink, mode: u32),
	SetSegmentFlags: proc "system" (this: ^IDWriteGeometrySink, flags: u32),
	// the point arrives by value in one register (two floats = 8 bytes)
	BeginFigure:     proc "system" (this: ^IDWriteGeometrySink, start: u64, begin: u32),
	AddLines:        proc "system" (this: ^IDWriteGeometrySink, points: [^][2]f32, count: u32),
	AddBeziers:      proc "system" (this: ^IDWriteGeometrySink, beziers: [^][3][2]f32, count: u32),
	EndFigure:       proc "system" (this: ^IDWriteGeometrySink, end: u32),
	Close:           proc "system" (this: ^IDWriteGeometrySink) -> HRESULT,
}

@(private)
Outline_Sink :: struct {
	using iface: IDWriteGeometrySink,
	ctx:   runtime.Context,
	out:   ^Outline,
	scale: f32,          // em units per unit received (1 / design units per em)
	tol:   f32,          // em units
	start, cur: [2]f32,  // em units, y up
	open:  bool,
}

@(private)
sink_point :: #force_inline proc "contextless" (s: ^Outline_Sink, p: [2]f32) -> [2]f32 {
	return {p.x * s.scale, -p.y * s.scale}   // DirectWrite: y down from the baseline
}

@(private)
outline_sink_vtable := IDWriteGeometrySink_VTable{
	QueryInterface = proc "system" (this: ^IDWriteGeometrySink, riid: ^IID, out: ^rawptr) -> HRESULT {
		if riid^ == IID_IUnknown || riid^ == IID_ID2D1SimplifiedGeometrySink { out^ = this; return S_OK }
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^IDWriteGeometrySink) -> u32 { return 1 },    // lives on the caller's stack
	Release = proc "system" (this: ^IDWriteGeometrySink) -> u32 { return 1 },
	SetFillMode = proc "system" (this: ^IDWriteGeometrySink, mode: u32) {},
	SetSegmentFlags = proc "system" (this: ^IDWriteGeometrySink, flags: u32) {},
	BeginFigure = proc "system" (this: ^IDWriteGeometrySink, start: u64, begin: u32) {
		s := (^Outline_Sink)(this)
		p := transmute([2]f32)start
		s.start = sink_point(s, p)
		s.cur = s.start
		s.open = true
	},
	AddLines = proc "system" (this: ^IDWriteGeometrySink, points: [^][2]f32, count: u32) {
		s := (^Outline_Sink)(this)
		context = s.ctx
		for i in 0 ..< int(count) {
			p := sink_point(s, points[i])
			outline_line(s.out, s.cur, p)
			s.cur = p
		}
	},
	AddBeziers = proc "system" (this: ^IDWriteGeometrySink, beziers: [^][3][2]f32, count: u32) {
		s := (^Outline_Sink)(this)
		context = s.ctx
		for i in 0 ..< int(count) {
			b := beziers[i]
			c1, c2, p3 := sink_point(s, b[0]), sink_point(s, b[1]), sink_point(s, b[2])
			outline_cubic(s.out, s.cur, c1, c2, p3, s.tol)
			s.cur = p3
		}
	},
	EndFigure = proc "system" (this: ^IDWriteGeometrySink, end: u32) {
		s := (^Outline_Sink)(this)
		context = s.ctx
		if s.open { outline_end(s.out, s.start, s.cur) }
		s.open = false
	},
	Close = proc "system" (this: ^IDWriteGeometrySink) -> HRESULT { return S_OK },
}

@(private)
IID_ID2D1SimplifiedGeometrySink := IID{0x2cd9069e, 0x12e2, 0x11dc, {0x9f, 0xed, 0x00, 0x11, 0x43, 0xa0, 0x55, 0xf9}}
// The provider State.slug.provider starts with on Windows.
dwrite_outline_provider :: proc(s: ^State, face: Font_Id, gid: u16, tolerance: f32, out: ^Outline) -> bool {
	f := face_ptr(s, face)
	if f == nil { return false }
	ids := [1]u16{gid}
	advs := [1]f32{0}
	offs := [1]DWRITE_GLYPH_OFFSET{}
	sink := Outline_Sink{iface = {vtable = &outline_sink_vtable}, ctx = context, out = out, scale = 1 / f.upem, tol = tolerance}
	if f.dw->GetGlyphRunOutline(f.upem, &ids[0], &advs[0], &offs[0], 1, false, false, &sink.iface) < 0 { return false }
	if sink.open { outline_end(out, sink.start, sink.cur) }
	outline_bounds(out)
	return true
}
