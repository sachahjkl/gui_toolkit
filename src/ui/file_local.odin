package ui

// The computer's own files as a File_Source (docs/file-browser.md): every reading on the chores (ui.task), its answer
// at a next build of the State that asked. Its places (Home, Desktop..., the drives on Windows, "/" elsewhere) and the
// local time's offset are read once per State, on the chores too (file_local_warm): the interface's thread asks the
// system nothing, not even where the home folder is.

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/timezone"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// The computer's files: all caps, its own separator.
local_files :: proc() -> File_Source {
	return {
		caps        = {.Size, .Modified, .Read, .Make_Folder},
		separator   = ODIN_OS == .Windows ? '\\' : '/',
		list        = local_list,
		read        = local_read,
		make_folder = local_make_folder,
		places      = local_places,
		start       = local_start,
	}
}

// What the local source reads once per State: its places and its first folder, and the local time's offset (the
// dates of every source are told on it).
@(private)
File_Local :: struct {
	ready:          bool,             // read (the places below are there)
	asked:          bool,             // a reading is on its way
	places:         [dynamic]platform.File_Place,   // (strings in the heap)
	home:           string,
	offset_minutes: int,
}

@(private)
file_local_destroy :: proc(l: ^File_Local) {
	a := runtime.heap_allocator()
	for p in l.places { delete(p.name, a); delete(p.path, a) }
	delete(l.places)
	delete(l.home, a)
	l^ = {}
}

// What the reading of the places carries to the chores and back.
@(private = "file")
Local_Warm :: struct {
	state:          ^State,
	places:         [dynamic]platform.File_Place,
	home:           string,
	offset_minutes: int,
}

// Asks for the places and the offset of `s` once (nothing when they are read or on their way).
@(private)
file_local_warm :: proc(s: ^State) {
	fb := file_browser_of(s)
	if fb.local.ready || fb.local.asked { return }
	fb.local.asked = true
	w := new(Local_Warm, runtime.heap_allocator())
	w.state = s
	w.places = make([dynamic]platform.File_Place, runtime.heap_allocator())
	work :: proc(d: rawptr) {
		w := (^Local_Warm)(d)
		a := runtime.heap_allocator()
		Known :: struct { k: platform.Known_Folder, name, icon: string }
		// (the English: tr is read when the place is shown, in the language then in use)
		known := [?]Known{
			{.Home, i18n.later("Home"), lucide.HOME}, {.Desktop, i18n.later("Desktop"), lucide.MONITOR},
			{.Documents, i18n.later("Documents"), lucide.FILE_TEXT}, {.Downloads, i18n.later("Downloads"), lucide.DOWNLOAD},
			{.Pictures, i18n.later("Pictures"), lucide.IMAGE}, {.Music, i18n.later("Music"), lucide.MUSIC},
			{.Videos, i18n.later("Videos"), lucide.VIDEO},
		}
		for k in known {
			p := platform.known_folder_path(k.k, a)
			if p == "" { continue }
			// (a folder the system names but the person never made is no place)
			if k.k != .Home && !os.is_directory(p) { delete(p, a); continue }
			if k.k == .Home { w.home = strings.clone(p, a) }
			append(&w.places, platform.File_Place{name = strings.clone(k.name, a), path = p, icon = k.icon})
		}
		roots := platform.file_roots(a)
		for r in roots { append(&w.places, platform.File_Place{name = strings.clone(r, a), path = r, icon = lucide.HARD_DRIVE}) }
		delete(roots, a)
		w.offset_minutes = local_offset_minutes()
	}
	done :: proc(d: rawptr, _: u64) {
		w := (^Local_Warm)(d)
		if fb := w.state.files; fb != nil {
			file_local_destroy(&fb.local)
			fb.local = {ready = true, places = w.places, home = w.home, offset_minutes = w.offset_minutes}
			file_browser_local_ready(fb)
		}
		free(w, runtime.heap_allocator())
	}
	lost :: proc(d: rawptr) {
		w := (^Local_Warm)(d)
		a := runtime.heap_allocator()
		for p in w.places { delete(p.name, a); delete(p.path, a) }
		delete(w.places)
		delete(w.home, a)
		free(w, a)
	}
	task(s, work, done, w, lost)
}

// The local clock's offset from UTC now, in minutes (the system's time zone: its file read on Linux).
@(private = "file")
local_offset_minutes :: proc() -> int {
	a := runtime.heap_allocator()
	region, ok := timezone.region_load("local", a)
	if !ok || region == nil { return 0 }
	defer timezone.region_destroy(region, a)
	now := time.now()
	utc, utc_ok := time.time_to_datetime(now)
	if !utc_ok { return 0 }
	local, local_ok := timezone.datetime_to_tz(utc, region)
	if !local_ok { return 0 }
	local.tz = nil
	at, at_ok := time.compound_to_time(local)
	if !at_ok { return 0 }
	return int(time.diff(now, at) / time.Minute)
}

// (what the State's reading found; nothing before it came)
@(private = "file")
local_places :: proc(src: ^File_Source, allocator: mem.Allocator) -> []platform.File_Place {
	if current == nil || current.files == nil || !current.files.local.ready { return nil }
	l := &current.files.local
	out := make([]platform.File_Place, len(l.places), allocator)
	for p, i in l.places { out[i] = {name = i18n.tr(p.name), path = strings.clone(p.path, allocator), icon = p.icon} }
	return out
}

@(private = "file")
local_start :: proc(src: ^File_Source, allocator: mem.Allocator) -> string {
	if current == nil || current.files == nil { return "" }
	return strings.clone(current.files.local.home, allocator)
}

// One call of the local source, carried to the chores and back.
@(private = "file")
Local_Job :: struct {
	reply:    File_Reply,
	path:     string,
	max:      int,
	entries:  [dynamic]File_Entry,   // (names in the heap)
	bytes:    []u8,
	size:     i64,
	failed:   bool,
	refused:  bool,
	missing:  bool,
	message:  string,                // (in the heap)
}

@(private = "file")
local_job :: proc(path: string, max: int, reply: File_Reply) -> ^Local_Job {
	a := runtime.heap_allocator()
	j := new(Local_Job, a)
	j^ = {reply = reply, path = strings.clone(path, a), max = max, size = -1}
	j.entries = make([dynamic]File_Entry, a)
	return j
}

@(private = "file")
local_job_free :: proc(d: rawptr) {
	j := (^Local_Job)(d)
	a := runtime.heap_allocator()
	for e in j.entries { delete(e.name, a) }
	delete(j.entries)
	delete(j.bytes, a)
	delete(j.message, a)
	delete(j.path, a)
	free(j, a)
}

// The answer, on the interface's thread.
@(private = "file")
local_job_done :: proc(d: rawptr, _: u64) {
	j := (^Local_Job)(d)
	switch {
	case j.failed:            file_reply_failed(j.reply, j.message, j.refused, j.missing)
	case j.reply.kind == .List: file_reply_listed(j.reply, j.entries[:])
	case j.reply.kind == .Read: file_reply_read(j.reply, j.bytes, j.size)
	case j.reply.kind == .Make: file_reply_made(j.reply)
	}
	local_job_free(j)
}

// What went wrong, in the person's words (`what`: a format of the system's reason).
@(private = "file")
local_fail :: proc(j: ^Local_Job, err: os.Error, what: string) {
	j.failed = true
	j.refused = err == io.Error.Permission_Denied
	j.missing = err == os.General_Error.Not_Exist
	a := runtime.heap_allocator()
	delete(j.message, a)
	switch {
	case j.refused: j.message = strings.clone(i18n.tr("You are not allowed to read it."), a)
	case j.missing: j.message = strings.clone(i18n.tr("It is not there any more."), a)
	case err == os.General_Error.Exist: j.message = strings.clone(i18n.tr("Something of this name is there already."), a)
	case:           j.message = fmt.aprintf(what, os.error_string(err), allocator = a)
	}
}

@(private = "file")
local_list :: proc(src: ^File_Source, path: string, reply: File_Reply) {
	work :: proc(d: rawptr) {
		j := (^Local_Job)(d)
		a := runtime.heap_allocator()
		infos, err := os.read_all_directory_by_path(j.path, a)
		if err != nil {
			local_fail(j, err, i18n.tr("The folder could not be read: %s."))
			return
		}
		defer os.file_info_slice_delete(infos, a)
		reserve(&j.entries, len(infos))
		for fi in infos {
			e := File_Entry{name = strings.clone(fi.name, a), size = fi.size, modified = time.to_unix_nanoseconds(fi.modification_time) / 1_000_000}
			switch fi.type {
			case .Directory: e.kind = .Folder
			case .Symlink:
				// (a link is what it points to: a folder to enter, a file to choose)
				e.link = true
				if to, to_err := os.stat(fi.fullpath, a); to_err == nil {
					if to.type == .Directory { e.kind = .Folder }
					e.size = to.size
					os.file_info_delete(to, a)
				}
			case .Undetermined, .Regular, .Named_Pipe, .Socket, .Block_Device, .Character_Device:
			}
			if e.kind == .Folder { e.size = -1 }
			append(&j.entries, e)
		}
	}
	task(reply.state, work, local_job_done, local_job(path, 0, reply), local_job_free)
}

@(private = "file")
local_read :: proc(src: ^File_Source, path: string, max: int, reply: File_Reply) {
	work :: proc(d: rawptr) {
		j := (^Local_Job)(d)
		a := runtime.heap_allocator()
		f, err := os.open(j.path)
		if err != nil {
			local_fail(j, err, i18n.tr("The file could not be read: %s."))
			return
		}
		defer os.close(f)
		if fi, fi_err := os.fstat(f, a); fi_err == nil {
			j.size = fi.size
			os.file_info_delete(fi, a)
		}
		want := j.max
		if j.size >= 0 { want = int(min(i64(want), j.size)) }
		buf := make([]u8, want, a)
		n := 0
		for n < len(buf) {
			got, read_err := os.read(f, buf[n:])
			n += got
			if read_err != nil || got == 0 { break }
		}
		j.bytes = buf[:n]
	}
	task(reply.state, work, local_job_done, local_job(path, max, reply), local_job_free)
}

@(private = "file")
local_make_folder :: proc(src: ^File_Source, path: string, reply: File_Reply) {
	work :: proc(d: rawptr) {
		j := (^Local_Job)(d)
		if err := os.make_directory(j.path); err != nil { local_fail(j, err, i18n.tr("The folder could not be made: %s.")) }
	}
	task(reply.state, work, local_job_done, local_job(path, 0, reply), local_job_free)
}
