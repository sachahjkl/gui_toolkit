#+build !windows
package font

// Whether a cascade should keep a face rather than take its characters from another (color.odin has the Windows /
// DirectWrite answer, which depends on the OS version's COLR v1 support). Off Windows a face's color glyphs can all be drawn
// (colr_glyph.odin, cbdt.odin): every face is kept.
color_renderable :: proc(s: ^State, id: Font_Id) -> bool { return true }
