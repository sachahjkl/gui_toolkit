package tk_desktop

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

// macOS: a stub, on purpose. What macOS lists is an application bundle: an <name>.app folder with an Info.plist that
// declares CFBundleURLTypes and CFBundleDocumentTypes, registered with Launch Services (lsregister). A program that is one
// executable outside any bundle cannot be a candidate in System Settings > Desktop & Dock > Default web browser, nor be
// listed in the Launchpad. Making a bundle under ~/Applications that only wraps the executable is possible, and would be
// this backend's `install` (the bundle is the mark; `remove` deletes that folder); it needs a Mac to be tested, so no
// half-working version is shipped. `supported` says false and the program hides the box.

@(private)
platform_backend :: proc() -> ^Backend { return nil }

// Where the bundle will go: ~/Applications/<name>.app, the folder macOS keeps for one person's applications. No vendor
// folder around it: the Finder, Launchpad and the Dock expect the bundle there (the data keeps the vendor's folder:
// ~/Library/Application Support/<vendor>/<name>). Said already, for the setup's field, before the backend exists.
@(private)
darwin_default_install_dir :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> string {
	home, found := os.lookup_env("HOME", context.temp_allocator)
	if !found || !filepath.is_abs(home) { return "" }
	return strings.concatenate({home, "/Applications/", o.identity.name, ".app"}, allocator)
}

set_process_identity :: proc(id: Identity) {}
