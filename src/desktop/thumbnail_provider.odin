package tk_desktop

// The Thumbnails part (src/md/features/shell-thumbnails.md): the file managers show the program's documents
// (`document_types`) as thumbnails that the program draws.
//
//   Windows   the program's own thumbnail provider, an in-process COM DLL (gt:shell_thumbnail) that the build embeds
//             (gt:toolbox: -define:GT_THUMBNAIL_DLL=<file>), written beside the executable as thumbnail_dll_file(exe)
//             and registered in HKCU (thumbnail_provider_windows.odin)
//   Linux     a .thumbnailer file that runs the program itself (thumbnail_provider_linux.odin, thumbnailer_text)
//
// Nothing here touches the disk: the backends do.

import "core:fmt"
import "core:strings"
import "../ascii"
import "../shell_thumbnail"

// The thumbnail provider the build embedded ("": none, as in a check from Linux, a test, or a program without one).
BUILT_THUMBNAIL_DLL_FILE :: #config(GT_THUMBNAIL_DLL, "")

when BUILT_THUMBNAIL_DLL_FILE != "" {
	@(private = "file") built_thumbnail_dll :: proc() -> []byte { return #load(BUILT_THUMBNAIL_DLL_FILE) }
} else {
	@(private = "file") built_thumbnail_dll :: proc() -> []byte { return nil }
}

// What the Linux file managers run by default: the program with the document (%i), the PNG to write (%o) and the size
// (%s), the codes of the Thumbnail Managing Standard.
THUMBNAIL_ARGUMENTS_DEFAULT :: "--thumbnail %i %o %s"

// The DLL these options write (Windows): theirs, else the one the build embedded.
thumbnail_dll_bytes :: proc(o: ^Integration_Options) -> []byte { return len(o.thumbnail_dll) > 0 ? o.thumbnail_dll : built_thumbnail_dll() }

// The options ask for the Thumbnails part: the option, types to draw, and on Windows a DLL to register (a build without
// one has no part to miss: it would read as to repair at each start).
thumbnails_wanted :: proc(o: ^Integration_Options) -> bool {
	if !o.thumbnails || len(o.document_types) == 0 { return false }
	when ODIN_OS == .Windows { return len(thumbnail_dll_bytes(o)) > 0 } else { return true }
}

// The thumbnail provider of the executable `exe`: `<folder>\<exe's name without its extension>_thumbnails.dll`
// ("C:\...\Feuille\feuille.exe" -> "C:\...\Feuille\feuille_thumbnails.dll"). A constant rule: install, status, removal
// and the uninstall's file list all find it from the executable alone. "" for no executable.
thumbnail_dll_file :: proc(exe: string, allocator := context.temp_allocator) -> string {
	slash := max(strings.last_index_byte(exe, '\\'), strings.last_index_byte(exe, '/'))
	name := exe[slash + 1:]
	if name == "" { return "" }
	if dot := strings.last_index_byte(name, '.'); dot > 0 { name = name[:dot] }
	return strings.concatenate({exe[:slash + 1], name, "_thumbnails.dll"}, allocator)
}

// The executable a thumbnail provider's path belongs to (the rule of thumbnail_dll_file the other way): what a
// registration that points elsewhere names as its program. The path as it is when it does not follow the rule.
thumbnail_dll_owner :: proc(dll: string, allocator := context.temp_allocator) -> string {
	SUFFIX :: "_thumbnails.dll"
	if len(dll) <= len(SUFFIX) || !ascii.equal_fold(dll[len(dll) - len(SUFFIX):], SUFFIX) { return dll }
	return strings.concatenate({dll[:len(dll) - len(SUFFIX)], ".exe"}, allocator)
}

// A CLSID as the registry writes it ("{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}"): the program's thumbnail provider.
clsid_valid :: proc(s: string) -> bool {
	_, ok := shell_thumbnail.guid_parse(s)
	return ok
}

// The .thumbnailer file of `o` (the Thumbnail Managing Standard's, read by every file manager of the freedesktop.org
// family): the program itself with `thumbnail_arguments`, for the MIME types of `document_types`, marked as the
// program's as its desktop entry is.
thumbnailer_text :: proc(o: ^Integration_Options, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	line :: proc(sb: ^strings.Builder, key, value: string) { fmt.sbprintf(sb, "%s=%s\n", key, value) }
	arguments := o.thumbnail_arguments != "" ? o.thumbnail_arguments : THUMBNAIL_ARGUMENTS_DEFAULT
	strings.write_string(&sb, "[Thumbnailer Entry]\n")
	line(&sb, "TryExec", escape_value(o.exe))
	line(&sb, "Exec", escape_value(strings.concatenate({quote_exec_argument(o.exe), " ", arguments}, context.temp_allocator)))
	mimes := strings.builder_make(context.temp_allocator)
	for m in document_mimes(o) { strings.write_string(&mimes, m); strings.write_byte(&mimes, ';') }
	line(&sb, "MimeType", strings.to_string(mimes))
	line(&sb, o.identity.entry_marker, o.identity.slug)
	return strings.to_string(sb)
}
