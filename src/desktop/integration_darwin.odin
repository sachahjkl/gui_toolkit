package tk_desktop

// macOS: a stub, on purpose. What macOS lists is an application bundle: an <name>.app folder with an Info.plist that
// declares CFBundleURLTypes and CFBundleDocumentTypes, registered with Launch Services (lsregister). A program that is one
// executable outside any bundle cannot be a candidate in System Settings > Desktop & Dock > Default web browser, nor be
// listed in the Launchpad. Making a bundle under ~/Applications that only wraps the executable is possible, and would be
// this backend's `install` (the bundle is the mark; `remove` deletes that folder); it needs a Mac to be tested, so no
// half-working version is shipped. `supported` says false and the program hides the box.

@(private)
platform_backend :: proc() -> ^Backend { return nil }

set_process_identity :: proc(id: Identity) {}
