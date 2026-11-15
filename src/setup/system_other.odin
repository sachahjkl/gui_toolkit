#+build !windows
package tk_setup

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
