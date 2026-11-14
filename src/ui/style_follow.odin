package ui

// `dst`, a window of the program that is not its main one (a view's own window), takes the settings of `src` that the
// user sets for the whole program: zoom, density, rounding, the feel, animations, smooth scrolling, the scroll bars,
// autoscroll, the icon and monospaced fonts. Call it before each build of `dst` (between frames): a change in the main
// window shows in every window at their next frame. Its scale stays its own (its monitor's).
style_follow :: proc(dst, src: ^State) {
	if dst == nil || src == nil || dst == src { return }
	dst.zoom, dst.density, dst.rounding = src.zoom, src.density, src.rounding
	dst.feel = src.feel
	dst.animations, dst.smooth_scroll = src.animations, src.smooth_scroll
	dst.scrollbar_autohide, dst.scrollbar_arrows = src.scrollbar_autohide, src.scrollbar_arrows
	dst.scroll_cfg, dst.scroll_cfg_set = src.scroll_cfg, src.scroll_cfg_set
	dst.auto_cfg, dst.auto_cfg_set, dst.auto_off = src.auto_cfg, src.auto_cfg_set, src.auto_off
	dst.icon_font, dst.menu_icon_font, dst.mono_font = src.icon_font, src.menu_icon_font, src.mono_font
	dst.toast_pos = src.toast_pos
}
