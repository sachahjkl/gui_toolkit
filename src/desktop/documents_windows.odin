package tk_desktop

// The Documents part on Windows (src/md/features/document-handler.md): the program in "Open with" of its document
// types, all in the user's keys (under registry_root):
//
//   Classes\<vendor_key>.<key>.<ext>                 the ProgID of a type: its description, DefaultIcon, the command
//                                                    `"<exe>" "%1"`, the AppUserModelID (the jump list of the files it
//                                                    opens is the program's), the mark
//   Classes\<ext>\OpenWithProgids\<ProgID>           an empty value: "Open with" lists the ProgID
//   Classes\Applications\<exe name>                  the program's record: its name, command and SupportedTypes\<ext>
//   <vendor_key>\<key>\Capabilities                  ApplicationName, ApplicationDescription, FileAssociations\<ext>
//   RegisteredApplications\<key>.Documents           the Capabilities' path: Settings > Default apps lists the program
//
// Windows keeps the default of a type in Explorer\FileExts\<ext>\UserChoice, with a hash only the shell makes: with
// default_documents, install opens Settings at the program's page when a type's choice is another program's.

import "base:runtime"
import "core:strings"
import win "core:sys/windows"
import ascii "../ascii"

@(private = "file")
Documents_Layout :: struct {
	classes:      string,   // <root>\Classes
	application:  string,   // <root>\Classes\Applications\<exe name>
	capabilities: string,   // <root>\<vendor_key>\<key>\Capabilities
	program:      string,   // <root>\<vendor_key>\<key>
	vendor:       string,   // <root>\<vendor_key>
	registered:   string,   // <root>\RegisteredApplications
	value_name:   string,   // <key>.Documents: the value of RegisteredApplications
}

@(private = "file")
documents_layout :: proc(o: ^Integration_Options) -> (l: Documents_Layout) {
	root := registry_root_of(o)
	id := o.identity
	l.classes = reg_join(root, "Classes")
	exe := o.exe
	name := exe[max(strings.last_index_byte(exe, '\\'), strings.last_index_byte(exe, '/')) + 1:]
	l.application = reg_join(l.classes, "Applications", name)
	l.vendor = reg_join(root, id.vendor_key)
	l.program = reg_join(l.vendor, id.key)
	l.capabilities = reg_join(l.program, "Capabilities")
	l.registered = reg_join(root, "RegisteredApplications")
	// (apart from a browser's <key>: a program that is both keeps two lists that never overwrite each other)
	l.value_name = strings.concatenate({id.key, ".Documents"}, context.temp_allocator)
	return
}

// The ProgID of a type: <vendor_key>.<key>.<ext without its dot> ("FromentSoftware.Feuille.pdf"; validate keeps each
// piece letters and digits, as a ProgID wants). (The Thumbnails part names its provider there too.)
@(private)
document_progid :: proc(o: ^Integration_Options, ext: string) -> string {
	return strings.concatenate({o.identity.vendor_key, ".", o.identity.key, ".", ext[1:]}, context.temp_allocator)
}

// A key of the part is the program's: its mark, or its executable in the command.
@(private = "file")
documents_key_mine :: proc(o: ^Integration_Options, key: string) -> (command: string, command_ok, mine: bool) {
	command, command_ok = reg_get(reg_join(key, "shell", "open", "command"), "")
	mark, _ := reg_get(key, o.identity.registry_mark)
	mine = mark == identity_aumid(o.identity) || (command_ok && same_path(command_program(command), o.exe))
	return
}

// Present when a ProgID, the program's record or the list entry is the program's; whole when every type has its
// ProgID and the three lists name it.
@(private)
documents_status :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> (ps: Part_Status) {
	if len(o.document_types) == 0 { return }
	l := documents_layout(o)
	any_mine, all := false, true
	target := ""
	for d in o.document_types {
		progid := document_progid(o, d.extension)
		cmd, cmd_ok, mine := documents_key_mine(o, reg_join(l.classes, progid))
		any_mine ||= mine
		all &&= mine && cmd_ok
		if mine && cmd_ok && (target == "" || same_path(target, o.exe)) { target = command_program(cmd) }
		_, listed := reg_get(reg_join(l.classes, d.extension, "OpenWithProgids"), progid)
		_, supported := reg_get(reg_join(l.application, "SupportedTypes"), d.extension)
		associated, _ := reg_get(reg_join(l.capabilities, "FileAssociations"), d.extension)
		all &&= listed && supported && associated == progid
	}
	_, app_ok, app_mine := documents_key_mine(o, l.application)
	registered, registered_ok := reg_get(l.registered, l.value_name)
	registered_mine := registered_ok && ascii.equal_fold(registered, l.capabilities)
	any_mine ||= app_mine || registered_mine
	all &&= app_mine && app_ok && registered_mine
	if !any_mine { return }
	ps.present, ps.partial = true, !all
	ps.target = clone_or_empty(target, allocator)
	ps.stale = target != "" && !same_path(target, o.exe)
	return
}

@(private)
documents_write :: proc(o: ^Integration_Options) -> Result {
	l := documents_layout(o)
	id := o.identity
	aumid := identity_aumid(id)
	icon := strings.concatenate({o.exe, ",0"}, context.temp_allocator)
	open := strings.concatenate({"\"", o.exe, "\" \"%1\""}, context.temp_allocator)
	failed :: proc(path: string) -> Result { return {.System, strings.concatenate({"cannot write HKCU\\", path}, context.temp_allocator)} }

	// a type of an earlier install that the list no longer has goes first (its ProgID is the Capabilities')
	for ext in reg_value_names(reg_join(l.capabilities, "FileAssociations")) {
		kept := false
		for d in o.document_types { if ascii.equal_fold(d.extension, ext) { kept = true; break } }
		if !kept && len(ext) > 1 && ext[0] == '.' { _ = document_type_remove(o, l, ascii.lower(ext, context.temp_allocator)) }
	}

	for d in o.document_types {
		progid := reg_join(l.classes, document_progid(o, d.extension))
		if !reg_set(progid, "", d.description != "" ? d.description : id.name) { return failed(progid) }
		if !reg_set(progid, id.registry_mark, aumid) || !reg_set(progid, "AppUserModelID", aumid) { return failed(progid) }
		if !reg_set(reg_join(progid, "DefaultIcon"), "", icon) { return failed(progid) }
		if !reg_set(reg_join(progid, "shell", "open", "command"), "", open) { return failed(progid) }
		open_with := reg_join(l.classes, d.extension, "OpenWithProgids")
		if !reg_set(open_with, document_progid(o, d.extension), "") { return failed(open_with) }
		if !reg_set(reg_join(l.application, "SupportedTypes"), d.extension, "") { return failed(l.application) }
		if !reg_set(reg_join(l.capabilities, "FileAssociations"), d.extension, document_progid(o, d.extension)) { return failed(l.capabilities) }
	}
	if !reg_set(l.application, "FriendlyAppName", id.name) || !reg_set(l.application, id.registry_mark, aumid) { return failed(l.application) }
	if !reg_set(reg_join(l.application, "DefaultIcon"), "", icon) { return failed(l.application) }
	if !reg_set(reg_join(l.application, "shell", "open", "command"), "", open) { return failed(l.application) }
	if !reg_set(l.capabilities, "ApplicationName", id.name) || !reg_set(l.capabilities, "ApplicationIcon", icon) { return failed(l.capabilities) }
	if !reg_set(l.capabilities, "ApplicationDescription", id.description != "" ? id.description : id.name) { return failed(l.capabilities) }
	if !reg_set(l.registered, l.value_name, l.capabilities) { return failed(l.registered) }
	return {}
}

// Takes the part away: every type of the options and of the Capabilities, the program's record, the Capabilities and
// the list entry, then the parents left empty.
@(private)
documents_remove :: proc(o: ^Integration_Options) -> Result {
	l := documents_layout(o)
	res: Result
	failed :: proc(path: string) -> Result { return {.System, strings.concatenate({"cannot delete HKCU\\", path}, context.temp_allocator)} }
	for d in o.document_types {
		if r := document_type_remove(o, l, d.extension); r.error != .None && res.error == .None { res = r }
	}
	for ext in reg_value_names(reg_join(l.capabilities, "FileAssociations")) {
		if len(ext) < 2 || ext[0] != '.' { continue }
		if r := document_type_remove(o, l, ascii.lower(ext, context.temp_allocator)); r.error != .None && res.error == .None { res = r }
	}
	if _, _, mine := documents_key_mine(o, l.application); mine && !reg_delete_tree(l.application) && res.error == .None { res = failed(l.application) }
	_ = reg_delete_if_empty(reg_join(l.classes, "Applications"))
	// (the Capabilities are in the program's own key: nothing else writes there)
	if !reg_delete_tree(l.capabilities) && res.error == .None { res = failed(l.capabilities) }
	if reg_delete_if_empty(l.program) { _ = reg_delete_if_empty(l.vendor) }
	if registered, ok := reg_get(l.registered, l.value_name); ok && ascii.equal_fold(registered, l.capabilities) {
		if !reg_delete_value(l.registered, l.value_name) && res.error == .None { res = failed(l.registered) }
	}
	return res
}

// One type away: its ProgID when it is the program's, the values that name it (in the program's namespace: ours
// whatever their content), and the extension's keys left empty. The UserChoice stays: the shell falls back when the
// ProgID is gone, and its hash forbids an edit.
@(private = "file")
document_type_remove :: proc(o: ^Integration_Options, l: Documents_Layout, ext: string) -> Result {
	failed :: proc(path: string) -> Result { return {.System, strings.concatenate({"cannot delete HKCU\\", path}, context.temp_allocator)} }
	res: Result
	name := document_progid(o, ext)
	progid := reg_join(l.classes, name)
	if _, _, mine := documents_key_mine(o, progid); mine && !reg_delete_tree(progid) { res = failed(progid) }
	open_with := reg_join(l.classes, ext, "OpenWithProgids")
	if !reg_delete_value(open_with, name) && res.error == .None { res = failed(open_with) }
	if reg_delete_if_empty(open_with) { _ = reg_delete_if_empty(reg_join(l.classes, ext)) }
	supported := reg_join(l.application, "SupportedTypes")
	if !reg_delete_value(supported, ext) && res.error == .None { res = failed(supported) }
	_ = reg_delete_if_empty(supported)
	associations := reg_join(l.capabilities, "FileAssociations")
	if !reg_delete_value(associations, ext) && res.error == .None { res = failed(associations) }
	return res
}

// Some type's default is another program's: the person's choice in Explorer\FileExts\<ext>\UserChoice names another
// ProgID (or none).
@(private)
documents_default_elsewhere :: proc(o: ^Integration_Options) -> bool {
	root := registry_root_of(o)
	for d in o.document_types {
		choice, _ := reg_get(reg_join(root, "Microsoft", "Windows", "CurrentVersion", "Explorer", "FileExts", d.extension, "UserChoice"), "ProgId")
		if !ascii.equal_fold(choice, document_progid(o, d.extension)) { return true }
	}
	return false
}

// Opens Settings at the program's page of default apps (Windows 11; Windows 10 opens the general page): the person
// makes the program the default there, as Windows wants.
@(private)
documents_open_defaults :: proc(o: ^Integration_Options) -> bool {
	l := documents_layout(o)
	uri := strings.concatenate({"ms-settings:defaultapps?registeredAppUser=", l.value_name}, context.temp_allocator)
	r := win.ShellExecuteW(nil, win.L("open"), wide(uri), nil, nil, win.SW_SHOWNORMAL)
	return uintptr(r) > 32
}
