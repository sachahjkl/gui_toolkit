package tk_setup

import desktop "../desktop"
import i18n "../i18n"

// The system keeps a record of the programs installed, which a person sees (Settings > Apps): the install's record is
// that entry, and the page says whether it is there.
SYSTEM_RECORD :: true
// On the PATH, the program comes with its console launcher (the .com that waits for it).
PATH_LAUNCHER :: true

// The words of this system for the pieces of an install, in the language in use (whole sentences: a language puts the
// pieces' words where its grammar wants them).
// (a key of a line, capitalised: desktop.menu_name says the same place inside a sentence)
@(private) words_menu :: proc() -> string { return i18n.tr("setup key", "Start menu") }
@(private) words_record :: proc() -> string { return i18n.tr("Settings > Apps") }
@(private) words_installed :: proc() -> string { return i18n.tr("Installed. Start it from the Start menu, or now:") }
@(private) words_pieces_missing :: proc() -> string { return i18n.tr("Installed, but a shortcut, the Settings entry or a file is missing.") }
// What a scope means here: where the program goes, and who allows it.
@(private) words_scope :: proc(scope: desktop.Scope) -> string {
	if scope == .System { return i18n.tr("In Program Files, for every account. Windows asks for an administrator now, and for each update.") }
	return i18n.tr("In your profile, with no administrator. Updates install by themselves.")
}
