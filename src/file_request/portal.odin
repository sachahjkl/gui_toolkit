package file_request

// The XDG desktop portal's FileChooser backend interface (org.freedesktop.impl.portal.FileChooser) as values: a call
// of OpenFile, SaveFile or SaveFiles read into a File_Request, and an answer written as the call's reply (response,
// results). Pure: the bytes are a D-Bus message's body, read and written with gt:dbus's marshalling. The server that
// owns the bus name is apps/file-picker's (src/md/features/file-picker.md).
//
//	OpenFile  (o handle, s app_id, s parent_window, s title, a{sv} options) -> (u response, a{sv} results)
//	SaveFile  (the same)
//	SaveFiles (the same)

import "core:strings"
import "../dbus"
import "../platform"

// The interface, and the object the backend serves it at.
PORTAL_INTERFACE :: "org.freedesktop.impl.portal.FileChooser"
PORTAL_REQUEST_INTERFACE :: "org.freedesktop.impl.portal.Request"
PORTAL_OBJECT :: "/org/freedesktop/portal/desktop"
// The backend's bus name, as a portals.conf names it ("gtfilepicker").
PORTAL_BUS_NAME :: "org.freedesktop.impl.portal.desktop.gtfilepicker"

// The reply's response: chosen, cancelled by the person, ended otherwise.
PORTAL_RESPONSE_SUCCESS :: 0
PORTAL_RESPONSE_CANCELLED :: 1
PORTAL_RESPONSE_OTHER :: 2

Portal_Method :: enum u8 { Open_File, Save_File, Save_Files }

// One call, read.
Portal_Call :: struct {
	method:  Portal_Method,
	handle:  string,                  // the Request object's path (its Close ends the call)
	app_id:  string,
	parent:  string,                  // the caller's window: "x11:<hex>", "wayland:<handle>", "" none
	modal:   bool,
	request: platform.File_Request,
	files:   []string,                // SaveFiles: the names saved in the folder chosen
	mime_filters: []bool,             // per filter of the request: its patterns came from MIME types
}

// The method of a call's member, ok false for another.
portal_method :: proc(member: string) -> (m: Portal_Method, ok: bool) {
	switch member {
	case "OpenFile":  return .Open_File, true
	case "SaveFile":  return .Save_File, true
	case "SaveFiles": return .Save_Files, true
	}
	return {}, false
}

// Reads the body of a call of `member` (a reader at its start) into a request, in `allocator`. ok false: a member of
// another name, or a body that does not read.
portal_read_call :: proc(member: string, r: ^dbus.Reader, allocator := context.allocator) -> (c: Portal_Call, ok: bool) {
	context.allocator = allocator
	c.method = portal_method(member) or_return
	c.handle = strings.clone(dbus.r_string(r))
	c.app_id = strings.clone(dbus.r_string(r))
	c.parent = strings.clone(dbus.r_string(r))
	d := &c.request.dialog
	d.title = strings.clone(dbus.r_string(r))
	switch c.method {
	case .Open_File:  c.request.kind = .Open
	case .Save_File:  c.request.kind = .Save; d.overwrite_prompt = true
	case .Save_Files: c.request.kind = .Folder
	}
	filters := make([dynamic]platform.File_Filter)
	mimes := make([dynamic]bool)
	current: Maybe(platform.File_Filter)
	current_mime := false
	choices := make([dynamic]platform.File_Choice)
	files := make([dynamic]string)
	end := dbus.r_array_begin(r, "{sv}")
	for r.pos < end && !r.err {
		dbus.r_align_entry(r)
		key := dbus.r_string(r)
		sig := dbus.r_variant_sig(r)
		switch {
		case key == "accept_label" && sig == "s": d.act = strings.clone(portal_mnemonic_off(dbus.r_string(r)))
		case key == "modal" && sig == "b":        c.modal = dbus.r_bool(r)
		case key == "multiple" && sig == "b":     d.multiple = dbus.r_bool(r) && c.method == .Open_File
		case key == "directory" && sig == "b":
			if dbus.r_bool(r) && c.method == .Open_File { c.request.kind = .Folder }
		case key == "filters" && sig == "a(sa(us))":
			fend := dbus.r_array_begin(r, "(sa(us))")
			for r.pos < fend && !r.err {
				f, mime := portal_read_filter(r)
				append(&filters, f)
				append(&mimes, mime)
			}
		case key == "current_filter" && sig == "(sa(us))":
			current, current_mime = portal_read_filter(r)
		case key == "choices" && sig == "a(ssa(ss)s)":
			cend := dbus.r_array_begin(r, "(ssa(ss)s)")
			for r.pos < cend && !r.err {
				dbus.r_align_entry(r)
				ch: platform.File_Choice
				ch.id = strings.clone(dbus.r_string(r))
				ch.label = strings.clone(dbus.r_string(r))
				options := make([dynamic]platform.File_Choice_Option)
				oend := dbus.r_array_begin(r, "(ss)")
				for r.pos < oend && !r.err {
					dbus.r_align_entry(r)
					id := strings.clone(dbus.r_string(r))
					label := strings.clone(dbus.r_string(r))
					append(&options, platform.File_Choice_Option{id = id, label = label})
				}
				ch.options = options[:]
				ch.initial = strings.clone(dbus.r_string(r))
				append(&choices, ch)
			}
		case key == "current_name" && sig == "s": d.suggested_name = strings.clone(dbus.r_string(r))
		case key == "current_folder" && sig == "ay": d.start_dir = portal_read_path(r)
		case key == "current_file" && sig == "ay":
			// (a file to save over: its folder shown, its name suggested)
			path := portal_read_path(r)
			if slash := strings.last_index_byte(path, '/'); slash >= 0 {
				d.start_dir = strings.clone(path[:max(slash, 1)])
				d.suggested_name = strings.clone(path[slash + 1:])
			}
		case key == "files" && sig == "aay":
			aend := dbus.r_array_begin(r, "ay")
			for r.pos < aend && !r.err { append(&files, portal_read_path(r)) }
		case:
			dbus.r_skip(r, sig)
		}
	}
	if r.err { return c, false }
	// (the filter chosen first: one of the list by its name, or the only one when there is no list)
	if f, has := current.?; has {
		found := -1
		for x, i in filters { if x.name == f.name { found = i; break } }
		if found >= 0 {
			d.filter_index = found
		} else if len(filters) == 0 {
			append(&filters, f)
			append(&mimes, current_mime)
		}
	}
	d.filters = filters[:]
	d.choices = choices[:]
	c.mime_filters = mimes[:]
	c.files = files[:]
	return c, true
}

// A filter (sa(us)): its name, and its patterns, 0 a glob, 1 a MIME type read as the extensions of MIME_EXTENSIONS
// (an unknown type: every file). `mime` says whether one pattern was a MIME type.
@(private = "file")
portal_read_filter :: proc(r: ^dbus.Reader) -> (f: platform.File_Filter, mime: bool) {
	dbus.r_align_entry(r)
	f.name = strings.clone(dbus.r_string(r))
	patterns := make([dynamic]string)
	end := dbus.r_array_begin(r, "(us)")
	for r.pos < end && !r.err {
		dbus.r_align_entry(r)
		kind := dbus.r_u32(r)
		pattern := dbus.r_string(r)
		if kind == 0 {
			append(&patterns, strings.clone(pattern))
			continue
		}
		mime = true
		exts := mime_extensions(pattern)
		if exts == "" { append(&patterns, "*"); continue }
		for e in strings.fields_iterator(&exts) { append(&patterns, strings.concatenate({"*.", e})) }
	}
	f.patterns = patterns[:]
	return
}

// A path as the portal gives it: bytes ending with a NUL.
@(private = "file")
portal_read_path :: proc(r: ^dbus.Reader) -> string {
	end := dbus.r_array_begin(r, "y")
	b := make([dynamic]u8, context.temp_allocator)
	for r.pos < end && !r.err { append(&b, dbus.r_u8(r)) }
	for len(b) > 0 && b[len(b) - 1] == 0 { pop(&b) }
	return strings.clone(string(b[:]))
}

// A label with GTK's mnemonic marks ("_Open") as a person reads it ("Open"; "__" is one "_").
portal_mnemonic_off :: proc(label: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(label); i += 1 {
		if label[i] == '_' {
			if i + 1 < len(label) && label[i + 1] == '_' { strings.write_byte(&b, '_'); i += 1 }
			continue
		}
		strings.write_byte(&b, label[i])
	}
	return strings.to_string(b)
}

// The response of an answer: success, cancelled, or other.
portal_response :: proc(a: platform.Dialog_Result) -> u32 {
	#partial switch a.status {
	case .Chosen:    return PORTAL_RESPONSE_SUCCESS
	case .Cancelled: return PORTAL_RESPONSE_CANCELLED
	}
	return PORTAL_RESPONSE_OTHER
}

// Writes the reply's body (u response, a{sv} results) of call `c` answered `a`: "uris" (file:// URIs; SaveFiles: each
// of its files in the folder chosen), "choices" a(ss), "current_filter" (sa(us)) when the request had filters.
portal_write_reply :: proc(w: ^dbus.Writer, c: Portal_Call, a: platform.Dialog_Result) {
	dbus.w_u32(w, portal_response(a))
	la, ca := dbus.arg_dict_begin(w)
	if a.status == .Chosen {
		dbus.arg_dict_entry(w, "uris")
		dbus.w_signature(w, "as")
		l, s := dbus.w_array_begin(w, 4)
		for p in a.paths {
			if c.method == .Save_Files {
				for name in c.files { dbus.w_string(w, file_uri(join_slash(p, name))) }
			} else {
				dbus.w_string(w, file_uri(p))
			}
		}
		dbus.w_array_end(w, l, s)
		if len(a.choices) > 0 {
			dbus.arg_dict_entry(w, "choices")
			dbus.w_signature(w, "a(ss)")
			cl, cs := dbus.w_array_begin(w, 8)
			for x in a.choices {
				dbus.w_struct(w)
				dbus.w_string(w, x.id)
				dbus.w_string(w, x.value)
			}
			dbus.w_array_end(w, cl, cs)
		}
		filters := c.request.dialog.filters
		if a.filter >= 0 && a.filter < len(filters) {
			f := filters[a.filter]
			mime := a.filter < len(c.mime_filters) && c.mime_filters[a.filter]
			dbus.arg_dict_entry(w, "current_filter")
			dbus.w_signature(w, "(sa(us))")
			dbus.w_struct(w)
			dbus.w_string(w, f.name)
			pl, ps := dbus.w_array_begin(w, 8)
			for p in f.patterns {
				dbus.w_struct(w)
				dbus.w_u32(w, 0)   // (the globs the MIME types became: the caller matches them as globs)
				dbus.w_string(w, p)
			}
			dbus.w_array_end(w, pl, ps)
			_ = mime
		}
	}
	dbus.arg_dict_end(w, la, ca)
}

// `folder` and `name` joined by one "/".
@(private = "file")
join_slash :: proc(folder, name: string) -> string {
	if strings.has_suffix(folder, "/") { return strings.concatenate({folder, name}, context.temp_allocator) }
	return strings.concatenate({folder, "/", name}, context.temp_allocator)
}

// A local path as a file:// URI: its bytes, those outside RFC 3986's unreserved set and "/" written %XX. Temporary
// memory.
file_uri :: proc(path: string, allocator := context.temp_allocator) -> string {
	hex := "0123456789ABCDEF"
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file://")
	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~', '/':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 15])
		}
	}
	return strings.to_string(b)
}

// The extensions of a MIME type the portal may name separated by spaces ("": unknown): the types a desktop's programs ask most (GTK's and
// Qt's file choosers), by their common extensions. A type ending in "/*" takes its family's.
mime_extensions :: proc(mime: string) -> string {
	switch mime {
	case "image/png":     return "png"
	case "image/jpeg":    return "jpg jpeg"
	case "image/gif":     return "gif"
	case "image/webp":    return "webp"
	case "image/bmp":     return "bmp"
	case "image/svg+xml": return "svg"
	case "image/tiff":    return "tif tiff"
	case "image/x-icon":  return "ico"
	case "image/avif":    return "avif"
	case "image/heic":    return "heic"
	case "image/*":       return "png jpg jpeg gif webp bmp svg tif tiff ico avif heic"
	case "text/plain":    return "txt text log"
	case "text/markdown": return "md markdown"
	case "text/csv":      return "csv"
	case "text/html":     return "html htm"
	case "text/css":      return "css"
	case "text/xml", "application/xml": return "xml"
	case "application/json": return "json"
	case "application/pdf":  return "pdf"
	case "application/zip":  return "zip"
	case "application/x-tar": return "tar"
	case "application/gzip": return "gz tgz"
	case "application/x-7z-compressed": return "7z"
	case "audio/mpeg":    return "mp3"
	case "audio/ogg":     return "ogg oga opus"
	case "audio/flac":    return "flac"
	case "audio/x-wav", "audio/wav": return "wav"
	case "audio/*":       return "mp3 ogg oga opus flac wav m4a aac"
	case "video/mp4":     return "mp4 m4v"
	case "video/webm":    return "webm"
	case "video/x-matroska": return "mkv"
	case "video/*":       return "mp4 m4v webm mkv mov avi"
	case "application/vnd.oasis.opendocument.text": return "odt"
	case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
	}
	return ""
}
