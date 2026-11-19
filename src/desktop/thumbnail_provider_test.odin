package tk_desktop

// The Thumbnails part's rules that touch no disk, on every system.

import "core:strings"
import "core:testing"

@(private = "file") PDF_TYPE := [?]Document_Type{{".pdf", "application/pdf", "PDF Document"}, {".fdf", "application/vnd.fdf", ""}}

// The provider's file of an executable: its folder, its name without the extension, `_thumbnails.dll`; and back.
@(test)
the_thumbnail_dll_follows_the_executable :: proc(t: ^testing.T) {
	testing.expect_value(t, thumbnail_dll_file(`C:\Programs\Feuille\feuille.exe`), `C:\Programs\Feuille\feuille_thumbnails.dll`)
	testing.expect_value(t, thumbnail_dll_file("/opt/feuille/feuille"), "/opt/feuille/feuille_thumbnails.dll")
	testing.expect_value(t, thumbnail_dll_file(""), "")
	testing.expect_value(t, thumbnail_dll_owner(`C:\a\feuille_THUMBNAILS.dll`), `C:\a\feuille.exe`)
	testing.expect_value(t, thumbnail_dll_owner(`C:\a\other.dll`), `C:\a\other.dll`)
}

@(test)
the_thumbnail_clsid_is_checked :: proc(t: ^testing.T) {
	testing.expect(t, clsid_valid("{0b6a3f3e-2d1c-4b8e-9a7f-5c4d3e2f1a0b}"), "a CLSID")
	testing.expect(t, !clsid_valid("0b6a3f3e-2d1c-4b8e-9a7f-5c4d3e2f1a0b"), "no braces")
	o := Integration_Options{identity = test_identity(), exe = "x", thumbnail_clsid = "nope"}
	testing.expect_value(t, validate(&o, false).error, Error.Bad_Options)
	o.thumbnail_clsid = "{0b6a3f3e-2d1c-4b8e-9a7f-5c4d3e2f1a0b}"
	o.thumbnail_arguments = "--thumbnail\n%i"
	testing.expect_value(t, validate(&o, false).error, Error.Bad_Options)
}

// The .thumbnailer: the group, the program quoted, the arguments (the default without any), each type once, the mark.
@(test)
the_thumbnailer_runs_the_program_for_its_types :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), exe = "/opt/a b/sample", document_types = PDF_TYPE[:]}
	text := thumbnailer_text(&o)
	testing.expect(t, strings.has_prefix(text, "[Thumbnailer Entry]\n"), text)
	testing.expect(t, strings.contains(text, "\nExec=\"/opt/a b/sample\" --thumbnail %i %o %s\n"), text)
	testing.expect(t, strings.contains(text, "\nTryExec=/opt/a b/sample\n"), text)
	testing.expect(t, strings.contains(text, "\nMimeType=application/pdf;application/vnd.fdf;\n"), text)
	testing.expect(t, strings.contains(text, "\nX-Sample-Integration=sample\n"), text)
	o.thumbnail_arguments = "thumb %i %o"
	testing.expect(t, strings.contains(thumbnailer_text(&o), "\nExec=\"/opt/a b/sample\" thumb %i %o\n"), "the program's arguments")
	// (no type: no part to want; a type: wanted, but on Windows only with a provider to write)
	testing.expect(t, !thumbnails_wanted(&o), "the option off")
	o.thumbnails = true
	when ODIN_OS == .Windows {
		testing.expect_value(t, thumbnails_wanted(&o), len(thumbnail_dll_bytes(&o)) > 0)
	} else {
		testing.expect(t, thumbnails_wanted(&o), "the option and a type")
	}
	o.document_types = nil
	testing.expect(t, !thumbnails_wanted(&o), "no type")
}
