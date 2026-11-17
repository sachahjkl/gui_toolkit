package platform

// The system's list of recent documents, one API on every system: Linux appends to the freedesktop
// recently-used.xbel (services_impl_linux.odin), Windows tells the shell (recent_files_windows.odin), the others have
// none.

import base "../base"

// Adds a file to the desktop's recent-documents list (the "Recent" section of file managers and open dialogs; on
// Windows also the program's jump list), with its MIME type (""=guessed from the extension; Windows names the type by
// the extension alone). `path` is absolute. A no-op where the list is not supported. Blocking: it writes a file
// (Linux) or calls the shell (Windows), so call it from a worker, never from the interface's thread.
add_recent_file :: proc(path: string, mime := "", loc := #caller_location) {
	base.blocking("platform.add_recent_file", loc)
	when ODIN_OS == .Linux {
		add_recent_file_linux(path, mime)
	} else when ODIN_OS == .Windows {
		add_recent_file_windows(path)
	}
}
