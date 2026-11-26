package gt_base

import i18n "../i18n"

// Why a restricted process refuses, in this system's words (Windows: an administrator) and in the language in use. Whole sentences: a
// language puts "as administrator" where its grammar wants it.
Restricted_Words :: enum u8 {
	Installs,       // setup's install, uninstall, update of the record; desktop's install and remove
	Opens,          // a URL, a file, "Open with", a shell menu's item, a terminal
	Plugins,        // the plugins' toast
	Updates,        // the Updates page and the updater's notice
	Update_Placed,  // update.place's error
}

restricted_words :: proc(w: Restricted_Words) -> string {
	switch w {
	case .Installs:      return i18n.tr("The program runs as administrator: it installs nothing. Install it from your own account, not as administrator.")
	case .Opens:         return i18n.tr("The program runs as administrator: it opens nothing with your programs.")
	case .Plugins:       return i18n.tr("The program runs as administrator: it runs no plugin.")
	case .Updates:       return i18n.tr("The program runs as administrator: it does not update itself. Update it from your own account.")
	case .Update_Placed: return i18n.tr("the program runs as administrator: it places no update")
	}
	return ""
}

// The same in English, for a log or a test.
restricted_reason :: proc() -> string {
	return restricted() ? "the program runs as administrator: it starts and installs nothing that a user can change" : ""
}
