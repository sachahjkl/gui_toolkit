#+build !windows
package tk_setup

import desktop "../desktop"
import i18n "../i18n"

// No record of the installed programs that a person sees: the install's record is its icons (a desktop entry's).
SYSTEM_RECORD :: false
// On the PATH, the program alone: a shell's terminal is its console already.
PATH_LAUNCHER :: false

// The words of this system for the pieces of an install, in the language in use (whole sentences: a language puts the
// pieces' words where its grammar wants them).
@(private) words_menu :: proc() -> string { return i18n.tr("Applications menu") }
@(private) words_record :: proc() -> string { return i18n.tr("Icons") }
@(private) words_installed :: proc() -> string { return i18n.tr("Installed. Start it from the applications menu, or now:") }
@(private) words_pieces_missing :: proc() -> string { return i18n.tr("Installed, but the menu entry, an icon or a file is missing.") }
// What a scope means here: where the program goes, and who allows it.
@(private) words_scope :: proc(scope: desktop.Scope) -> string {
	if scope == .System { return i18n.tr("In /opt, for every account. The system asks for an administrator's password now, and for each update.") }
	return i18n.tr("In your home folder, with no administrator. Updates install by themselves.")
}
