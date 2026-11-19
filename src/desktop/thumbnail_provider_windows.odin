package tk_desktop

// The Thumbnails part on Windows (src/md/features/shell-thumbnails.md): the program's thumbnail provider, a COM DLL,
// written beside the executable and registered in the user's keys (under registry_root):
//
//   <exe folder>\<exe stem>_thumbnails.dll              the provider (thumbnail_dll_file), the bytes the build embedded
//   Classes\CLSID\<clsid>                                "<name> thumbnails", the mark, DocumentTypes (the extensions
//                                                        registered: a type taken out of the list goes at the next install)
//   Classes\CLSID\<clsid>\InprocServer32                 the DLL's path, ThreadingModel = Apartment
//   Classes\<ext>\ShellEx\{e357fccd-...}                 the clsid: Explorer asks it for the type's thumbnails
//   Classes\<ProgID>\ShellEx\{e357fccd-...}              the same under the program's ProgID of the type, when the
//                                                        Documents part makes one (documents_windows.odin)
//
// A ShellEx key is ours while it names the program's clsid. A DLL that Explorer's surrogate holds cannot be overwritten
// nor deleted: it is renamed to `.old` (write_in_use), and the uninstall's file list gets it (files_remove).

import "base:runtime"
import "core:os"
import "core:strings"
import ascii "../ascii"

// The shell's slot for a type's thumbnail provider: IID_IThumbnailProvider.
@(private = "file") THUMBNAIL_HANDLER :: "{e357fccd-a995-4576-b01f-234630154e96}"
// The value of the CLSID's key that lists the extensions an install registered.
@(private = "file") TYPES_VALUE :: "DocumentTypes"

@(private = "file")
Thumbnails_Layout :: struct {
	classes: string,   // <root>\Classes
	clsids:  string,   // <root>\Classes\CLSID
	clsid:   string,   // <root>\Classes\CLSID\<clsid>
	server:  string,   // <clsid>\InprocServer32
	dll:     string,   // the provider's file
}

@(private = "file")
thumbnails_layout :: proc(o: ^Integration_Options) -> (l: Thumbnails_Layout) {
	l.classes = reg_join(registry_root_of(o), "Classes")
	l.clsids = reg_join(l.classes, "CLSID")
	l.clsid = reg_join(l.clsids, o.thumbnail_clsid)
	l.server = reg_join(l.clsid, "InprocServer32")
	l.dll = normalize_slashes(thumbnail_dll_file(o.exe))
	return
}

// <Classes>\<class>\ShellEx\{IID_IThumbnailProvider}: `class` an extension or a ProgID.
@(private = "file")
handler_key :: proc(l: Thumbnails_Layout, class: string) -> string { return reg_join(l.classes, class, "ShellEx", THUMBNAIL_HANDLER) }

@(private = "file")
handler_named :: proc(o: ^Integration_Options, l: Thumbnails_Layout, class: string) -> bool {
	v, ok := reg_get(handler_key(l, class), "")
	return ok && ascii.equal_fold(v, o.thumbnail_clsid)
}

// The file at `path` holds `bytes` (no bytes to compare: whatever is there).
@(private = "file")
dll_current :: proc(path: string, bytes: []byte) -> bool {
	if !os.is_file(path) { return false }
	if len(bytes) == 0 { return true }
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.size != i64(len(bytes)) { return false }
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	return rerr == nil && string(data) == string(bytes)
}

// Present when the CLSID's key carries the mark or a type's slot names the clsid; whole when every slot names it, the
// server is the DLL beside the executable, and the DLL is there with the bytes of this build (an update brings another).
@(private)
thumbnails_status :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> (ps: Part_Status) {
	if !clsid_valid(o.thumbnail_clsid) { return }
	l := thumbnails_layout(o)
	mark, _ := reg_get(l.clsid, o.identity.registry_mark)
	clsid_mine := mark == identity_aumid(o.identity)
	any_named, all_named := false, true
	for d in o.document_types {
		named := handler_named(o, l, d.extension)
		any_named ||= named
		all_named &&= named
		if opens_documents(o) { all_named &&= handler_named(o, l, document_progid(o, d.extension)) }
	}
	if !clsid_mine && !any_named { return }
	ps.present = true
	server, server_ok := reg_get(l.server, "")
	threading, _ := reg_get(l.server, "ThreadingModel")
	if server_ok && server != "" {
		ps.target = clone_or_empty(thumbnail_dll_owner(server), allocator)
		ps.stale = !same_path(server, l.dll)
	}
	whole := clsid_mine && server_ok && ascii.equal_fold(threading, "Apartment") && all_named
	ps.partial = !(whole && dll_current(l.dll, thumbnail_dll_bytes(o)))
	return
}

@(private)
thumbnails_write :: proc(o: ^Integration_Options) -> Result {
	if !clsid_valid(o.thumbnail_clsid) { return {.Bad_Options, "the Thumbnails part needs thumbnail_clsid, the CLSID of the program's provider"} }
	l := thumbnails_layout(o)
	if l.dll == "" { return {.No_Executable, error_text(.No_Executable)} }
	failed :: proc(path: string) -> Result { return {.System, strings.concatenate({"cannot write HKCU\\", path}, context.temp_allocator)} }

	// the file first: the registration never names a DLL that is not there
	bytes := thumbnail_dll_bytes(o)
	if !dll_current(l.dll, bytes) {
		if r := write_in_use(l.dll, bytes); r.error != .None { return r }
	}
	_ = os.remove(strings.concatenate({l.dll, OLD_SUFFIX}, context.temp_allocator))   // (one the surrogate let go of)

	// a type of an earlier install that the list no longer has goes first
	old, _ := reg_get(l.clsid, TYPES_VALUE)
	for ext in split_list(old) {
		kept := false
		for d in o.document_types { if ascii.equal_fold(d.extension, ext) { kept = true; break } }
		if !kept && len(ext) > 1 && ext[0] == '.' {
			e := ascii.lower(ext, context.temp_allocator)
			_ = handler_remove(o, l, e)
			_ = handler_remove(o, l, document_progid(o, e))
		}
	}

	types := make([dynamic]string, context.temp_allocator)
	for d in o.document_types { append(&types, d.extension) }
	if !reg_set(l.clsid, "", strings.concatenate({o.identity.name, " thumbnails"}, context.temp_allocator)) { return failed(l.clsid) }
	if !reg_set(l.clsid, o.identity.registry_mark, identity_aumid(o.identity)) { return failed(l.clsid) }
	if !reg_set(l.clsid, TYPES_VALUE, strings.join(types[:], ";", context.temp_allocator)) { return failed(l.clsid) }
	// (Apartment: the shell calls each provider on the thread that made it; the render is thread-safe all the same,
	// as the surrogate runs several such threads)
	if !reg_set(l.server, "", l.dll) || !reg_set(l.server, "ThreadingModel", "Apartment") { return failed(l.server) }
	for d in o.document_types {
		if key := handler_key(l, d.extension); !reg_set(key, "", o.thumbnail_clsid) { return failed(key) }
		progid := document_progid(o, d.extension)
		if opens_documents(o) {
			if key := handler_key(l, progid); !reg_set(key, "", o.thumbnail_clsid) { return failed(key) }
		} else if r := handler_remove(o, l, progid); r.error != .None {
			return r
		}
	}
	return {}
}

// Takes the part away: the slots that name the clsid (the types of the options and of the last install), the CLSID's
// key when it carries the mark, the parents left empty, and the DLL.
@(private)
thumbnails_remove :: proc(o: ^Integration_Options) -> Result {
	res: Result
	if clsid_valid(o.thumbnail_clsid) {
		l := thumbnails_layout(o)
		exts := make([dynamic]string, context.temp_allocator)
		for d in o.document_types { append(&exts, d.extension) }
		old, _ := reg_get(l.clsid, TYPES_VALUE)
		for ext in split_list(old) {
			if len(ext) > 1 && ext[0] == '.' { append(&exts, ascii.lower(ext, context.temp_allocator)) }
		}
		for ext in exts {
			if r := handler_remove(o, l, ext); r.error != .None && res.error == .None { res = r }
			if r := handler_remove(o, l, document_progid(o, ext)); r.error != .None && res.error == .None { res = r }
		}
		if mark, _ := reg_get(l.clsid, o.identity.registry_mark); mark == identity_aumid(o.identity) {
			if !reg_delete_tree(l.clsid) && res.error == .None { res = {.System, strings.concatenate({"cannot delete HKCU\\", l.clsid}, context.temp_allocator)} }
			_ = reg_delete_if_empty(l.clsids)
		}
	}
	dll_remove(normalize_slashes(thumbnail_dll_file(o.exe)))
	return res
}

// One type's slot away when it names the clsid (another program's handler stays), then its parents left empty.
@(private = "file")
handler_remove :: proc(o: ^Integration_Options, l: Thumbnails_Layout, class: string) -> Result {
	key := handler_key(l, class)
	if !handler_named(o, l, class) { return {} }
	if !reg_delete_tree(key) { return {.System, strings.concatenate({"cannot delete HKCU\\", key}, context.temp_allocator)} }
	shell_ex := reg_join(l.classes, class, "ShellEx")
	if reg_delete_if_empty(shell_ex) { _ = reg_delete_if_empty(reg_join(l.classes, class)) }
	return {}
}

// Deletes the provider's file (named after the executable: the program's namespace). One that Explorer's surrogate holds
// is renamed to `.old`, never an error: the uninstall's file list reports it and its deferred deletion retries.
// (MoveFileExW's MOVEFILE_DELAY_UNTIL_REBOOT is refused: it writes HKLM, which needs administrator rights.)
@(private = "file")
dll_remove :: proc(path: string) {
	if path == "" { return }
	old := strings.concatenate({path, OLD_SUFFIX}, context.temp_allocator)
	if os.exists(old) { _ = os.remove(old) }
	if !os.exists(path) || os.remove(path) == nil { return }
	_ = os.rename(path, old)
}
