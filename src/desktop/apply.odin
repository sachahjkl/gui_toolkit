package tk_desktop

// What a program's settings ask of the desktop, made so: the launcher (general.menu) and the start with the session
// (general.autostart, gt:prefs_page's standard preferences) as `o` has them. A program calls it at each start and after
// each change of those preferences, on a worker: it reads the disk, and writes it only when something differs.

// Nothing on (no launcher, no shortcut, no PATH, no start with the session, no browser): the integration is taken away
// when there is one. Else it is written when it is not all there or runs another copy of the program (Repair, Absent);
// nothing is written when it is Installed and no part that is off is there. A platform with no integration is no error. Blocking: it reads and writes
// files, and on Windows the registry.
apply :: proc(o: ^Options) -> Result {
	if !supported() { return {} }
	wanted := o.start_menu || o.desktop_shortcut || o.add_to_path || o.autostart || o.register_browser
	st := status(o, context.temp_allocator)
	if !wanted {
		if st.state == .Absent && st.error == .None { return {} }
		return remove(o)
	}
	if st.state == .Installed && !unwanted_present(st) { return {} }
	return install(o)
}

// A part is there that the options turned off (the launcher, once general.menu is off): Installed says nothing of it,
// install takes it away. (Not the icons: a program that gives none would install again at each start.)
@(private = "file")
unwanted_present :: proc(st: Status) -> bool {
	for p in Part {
		if p != .Icons && st.parts[p].present && p not_in st.wanted { return true }
	}
	return false
}
