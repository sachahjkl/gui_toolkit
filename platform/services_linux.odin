package platform

// Smaller desktop services, behind a neutral API used on every system (the Windows forms live in platform_win32.odin
// where present; here is the Linux side): keeping the screen awake (idle inhibition), and the recent-files list. Open
// a URL is open_url (dialogs). These are thin and degrade to no-ops when the service is absent.

// A handle to an active screen-wake request (sleep_inhibit); 0 means none.
Idle_Inhibit :: distinct u64

// Asks the system not to blank the screen or sleep while something important is on screen (a video playing, a
// presentation). `reason` is shown to the user by some desktops. Returns a handle to release with idle_uninhibit; 0
// when the service is unavailable. Re-entrant: several inhibitions stack.
idle_inhibit :: proc(w: ^Window, reason := "Playing media") -> Idle_Inhibit {
	when ODIN_OS == .Linux { return idle_inhibit_linux(w, reason) }
	return 0
}

// Releases a screen-wake request from idle_inhibit.
idle_uninhibit :: proc(h: Idle_Inhibit) {
	when ODIN_OS == .Linux { idle_uninhibit_linux(h) }
}

// Adds a file to the desktop's recent-documents list (the "Recent" section of file managers and open dialogs), with
// its MIME type (""=guessed from the extension). A no-op where the list is not supported.
add_recent_file :: proc(path: string, mime := "") {
	when ODIN_OS == .Linux { add_recent_file_linux(path, mime) }
}
