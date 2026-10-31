#+build !windows
package font

// Whether a cascade should keep a face rather than take its characters from another (color.odin has the Windows /
// DirectWrite answer, which depends on the OS version's COLR v1 support). Off Windows no face counts as a color face yet
// (Font.color stays false, no glyph is drawn in color: font_other.odin, color_canvas_other.odin): every face is kept.
color_renderable :: proc(s: ^State, id: Font_Id) -> bool { return true }
