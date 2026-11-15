package tk_host

// The interface's face, one rule for a window's fonts and a worker's: the system's (Segoe UI on Windows), else the
// toolkit's own (font.FALLBACK_UI_DATA). And a worker thread's own fonts: a font.State is one thread's, so a worker that
// draws text (a watermark on a picture, a thumbnail's caption) keeps one of its own, made at its first use.

import "../font"
import "../platform"

// The interface's face loaded in `s`. `headless`: the toolkit's own alone (a test's pixels do not depend on the machine).
load_ui_font :: proc(s: ^font.State, headless := false) -> (id: font.Font_Id, ok: bool) {
	id, ok, _ = font.load_system_or_embedded(s, headless ? "" : platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	return
}

Worker_Fonts :: struct {
	state: font.State,
	face:  font.Font_Id,   // the interface's face (0: none could be loaded)
	made:  bool,
}

// On the worker's thread, each time it needs them: its fonts, made at the first call.
worker_fonts :: proc(f: ^Worker_Fonts, headless := false) -> ^Worker_Fonts {
	if f.made { return f }
	f.made = true
	font.init(&f.state)
	f.face, _ = load_ui_font(&f.state, headless)
	return f
}

// On the worker's thread, when it ends.
worker_fonts_destroy :: proc(f: ^Worker_Fonts) {
	if f.made { font.destroy(&f.state) }
	f^ = {}
}
