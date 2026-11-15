#+build !windows
package tk_desktop

import i18n "../i18n"

// The launcher's place in the user's words, in the language in use.
menu_name :: proc() -> string { return i18n.tr("application menu") }

// Where the system lists the programs that can be the default browser, in the user's words (in the language in use).
default_apps_name :: proc() -> string { return i18n.tr("the default browser setting") }

@(private)
targets_words :: proc(browser: bool) -> string {
	return browser ? i18n.tr("application menu, default browser, PATH, session start") : i18n.tr("application menu, PATH, session start")
}
