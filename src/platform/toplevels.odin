package platform

// The windows of the session, other programs' too, as a task bar knows them: what each one is (its app's id, its
// title, whether it has the focus or is minimized), and one brought to the front. A task manager shows an app's window
// from its row; a launcher switches to a program's window rather than start it again.
//
//	for t in platform.toplevels(win, context.temp_allocator) {
//		if t.app_id == "org.mozilla.firefox" { platform.toplevel_activate(win, t.id) }
//	}
//
// Where the system tells it: Wayland with wlr-foreign-toplevel-management (sway, Hyprland, niri, labwc, river,
// ShojiWM...). Elsewhere (GNOME, KDE, X11, Windows, an offscreen window) the list is empty: a program hides what needs it.

// A window of the session. `id` names it while it is open (toplevel_activate); `app_id` is its app's (Wayland's
// app_id: a desktop entry's id, or its StartupWMClass).
Toplevel :: struct {
	id:        u64,
	app_id:    string,
	title:     string,
	active:    bool,   // it has the focus
	minimized: bool,
}
