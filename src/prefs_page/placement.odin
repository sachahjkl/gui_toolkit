package tk_prefs_page

// The main window's place, kept in the standard preference window.placement (registered with Standard_Set.Appearance):
// it opens where it was, on the monitor it was on (platform.set_placement brings it onto one that is there), at its size,
// maximized again when it was. Every program kept its own copy of this (a preference of its own, a line of its session
// file); one keeper now. Wayland places a window itself: only the size and maximized come back there.
//
// It is looked at now and then while the program runs, not only at the close: an update's restart, a crash or a session's
// end find it kept.

import "core:strings"
import config "../config"
import "../platform"

PLACEMENT_PREF :: "window.placement"
// How often a running program's window is looked at.
PLACEMENT_CHECK_MS :: 2000

Placement_Keeper :: struct {
	seen:       string,   // the placement as last kept (owned)
	checked_ms: f64,
}

// Before the window is shown: it goes where window.placement says. false: nothing kept (the first start: the program's
// own size), or not read.
placement_restore :: proc(k: ^Placement_Keeper, prefs: ^config.Prefs, win: ^platform.Window) -> bool {
	if win == nil || config.ref_of(prefs, PLACEMENT_PREF) == config.NO_REF { return false }
	p, ok := platform.placement_parse(config.string_of(prefs, PLACEMENT_PREF))
	if !ok { return false }
	platform.set_placement(win, p)
	placement_seen(k, platform.placement_text(p))
	return true
}

// At each frame (cheap: it looks every PLACEMENT_CHECK_MS): where the window is now, kept in window.placement when it
// changed. true: the preference changed, the program writes its preferences as it does for any change. Not while
// minimized: get_placement says where it comes back to, but nothing moved.
placement_track :: proc(k: ^Placement_Keeper, prefs: ^config.Prefs, win: ^platform.Window, now_ms: f64) -> (changed: bool) {
	if win == nil || now_ms - k.checked_ms < PLACEMENT_CHECK_MS || platform.is_minimized(win) { return false }
	k.checked_ms = now_ms
	if config.ref_of(prefs, PLACEMENT_PREF) == config.NO_REF { return false }
	text := platform.placement_text(platform.get_placement(win))
	if text == k.seen { return false }
	placement_seen(k, text)
	return config.set_string(prefs, PLACEMENT_PREF, text) == .None
}

// At the close, whatever the time since the last look (the program then writes its preferences).
placement_keep :: proc(k: ^Placement_Keeper, prefs: ^config.Prefs, win: ^platform.Window) -> (changed: bool) {
	k.checked_ms = 0
	return placement_track(k, prefs, win, PLACEMENT_CHECK_MS)
}

placement_keeper_destroy :: proc(k: ^Placement_Keeper) {
	delete(k.seen)
	k^ = {}
}

@(private = "file")
placement_seen :: proc(k: ^Placement_Keeper, text: string) {
	delete(k.seen)
	k.seen = strings.clone(text)
}
