package tk_desktop

import base "../base"

// What a program's settings ask of the desktop, made so: the launcher (general.menu) and the start with the session
// (general.autostart, gt:prefs_page's standard preferences) as `o` has them. A program calls it at each start and after
// each change of those preferences, on a worker: it reads the disk, and writes it only when something differs.

// Nothing on (no launcher, no shortcut, no PATH, no start with the session, no browser): the integration is taken away
// when there is one. Else it is written when it is not all there or runs another copy of the program (Repair, Absent);
// nothing is written when it is Installed and no part that is off is there. A platform with no integration is no error. Blocking: it reads and writes
// files, and on Windows the registry.
apply :: proc(o: ^Integration_Options) -> Result {
	// (a restricted process changes no install: an elevated copy's shortcuts would name it; base.restricted)
	if !supported() || base.restricted() { return {} }
	wanted := o.start_menu || o.desktop_shortcut || o.add_to_path || o.autostart || o.register_browser || o.default_file_manager || o.task_manager || opens_documents(o) || thumbnails_wanted(o)
	st := status(o, context.temp_allocator)
	if !wanted {
		if !half_present(o, st) && st.error == .None { return {} }
		return remove(o)
	}
	if half_in_place(o, st) && !unwanted_present(o, st) { return {} }
	return install(o)
}

// Something of the parts that this call writes is there (a system install's machine half is not this call's).
@(private)
half_present :: proc(o: ^Integration_Options, st: Status) -> bool {
	if o.scope != .System { return st.state != .Absent }
	for p in Part { if touches(o, p) && st.parts[p].present { return true } }
	return false
}

// The parts that this call writes are all there and run this program. A system install's person's half: only its own
// parts count. A part of the machine's half that is missing or turned off is not this call's to change (install
// leaves it), and counting it would write the person's half again at each start.
@(private)
half_in_place :: proc(o: ^Integration_Options, st: Status) -> bool {
	if o.scope != .System { return st.state == .Installed }
	for p in Part {
		if !touches(o, p) { continue }
		ps := st.parts[p]
		if ps.present && ps.stale { return false }
		if p in st.wanted && (!ps.present || ps.partial) { return false }
	}
	return true
}

// A part is there that the options turned off (the launcher, once general.menu is off): Installed says nothing of it,
// install takes it away. (Not the icons: a program that gives none would install again at each start. Not a part only
// an install for everyone has, nor any part of the machine's half: apply writes the person's half, never the machine's.)
@(private)
unwanted_present :: proc(o: ^Integration_Options, st: Status) -> bool {
	for p in Part {
		if !touches(o, p) { continue }
		if p != .Icons && p not_in SYSTEM_ONLY_PARTS && st.parts[p].present && p not_in st.wanted { return true }
	}
	return false
}
