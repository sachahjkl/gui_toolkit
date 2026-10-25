#+build !windows
package font

import "base:runtime"

// The system's fonts on a platform the package does not support yet: no list, no fallback. The text backend there can
// only be the native one (backend.odin), with fonts the application loads itself.
// TODO(linux): fontconfig (FcFontList for families, FcFontSort / FcFontMatch on a charset for the fallback of a character).
// TODO(macos): CoreText (CTFontManagerCopyAvailableFontFamilyNames, CTFontCreateForString for the fallback).
@(private)
unsupported_system := System_Fonts{
	name     = "unsupported",
	fallback = nil,
	families = proc(s: ^State, allocator: runtime.Allocator) -> []string { return nil },
}
