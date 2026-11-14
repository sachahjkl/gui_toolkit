package ui

import "../font"

// `dst`, a window of the program that is not its main one (a view's own window), takes the settings of `src` that the
// user sets for the whole program: zoom, density, rounding, the feel, animations, smooth scrolling, the scroll bars,
// autoscroll, the icon and monospaced fonts, the theme and the fonts (shared: the same ones, not copies). Its families
// (set_family) are read from `src`'s through State.style_owner (state_families), never copied: one map, freed once.
// A view's window follows its owner by itself (State.style_owner: at the start of each of its builds); a program's own
// other window calls this before each build. Its scale stays its own (its monitor's).
style_follow :: proc(dst, src: ^State) {
	if dst == nil || src == nil || dst == src { return }
	dst.zoom, dst.density, dst.rounding = src.zoom, src.density, src.rounding
	dst.feel = src.feel
	dst.animations, dst.smooth_scroll = src.animations, src.smooth_scroll
	dst.scrollbar_size, dst.scrollbar_autohide = src.scrollbar_size, src.scrollbar_autohide
	dst.scroll_cfg, dst.scroll_cfg_set = src.scroll_cfg, src.scroll_cfg_set
	dst.auto_cfg, dst.auto_cfg_set, dst.auto_off = src.auto_cfg, src.auto_cfg_set, src.auto_off
	dst.icon_font, dst.menu_icon_font, dst.mono_font = src.icon_font, src.menu_icon_font, src.mono_font
	dst.toast_pos = src.toast_pos
	if src.theme != nil { dst.theme = src.theme }
	if src.fonts != nil { dst.fonts = src.fonts }
}

// The window `s` looks like at the end of its chain of owners (itself when it follows none).
@(private)
style_root :: proc(s: ^State) -> ^State {
	r := s
	for i := 0; r.style_owner != nil && r.style_owner != r && i < 8; i += 1 { r = r.style_owner }
	return r
}

// The families the bold and italic faces of `s` come from: its own, or those of the window it follows (one map). What
// lays rich text out outside the toolkit (Rich_Context.faces) reads this, not State.families.
state_families :: proc(s: ^State) -> ^map[font.Font_Id][4]font.Font_Id {
	return &style_root(s).families
}
