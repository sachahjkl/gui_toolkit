#+build !windows
package font

// Whether this package can draw the color glyphs of a face in color (color.odin has the Windows / DirectWrite answer,
// which depends on the OS version's COLR v1 support). Off Windows the native backend draws color glyphs through the
// built-in COLR / CPAL interpreter (colr.odin) and the raster of the bitmap-emoji and SVG tables, so a color face is
// renderable whenever the package has the interpreter for it; a face without color is always renderable. This keeps a
// cascade from skipping an emoji face that the native backend can in fact draw.
color_renderable :: proc(s: ^State, id: Font_Id) -> bool {
	f := face_ptr(s, id)
	if f == nil || !f.color { return true }
	// a face whose colour comes from COLR / CPAL is drawn by the built-in interpreter; other colour tables (sbix, CBDT,
	// SVG) are rasterized by the native backend too, so the face is renderable in colour either way.
	return true
}
