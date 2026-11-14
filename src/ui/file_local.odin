package ui

// The computer's own files as a File_Source (docs/file-browser.md): every reading on the chores (ui.task), its answer
// at a next build of the State that asked. Its places (Home, Desktop..., the drives on Windows, "/" elsewhere) are read
// once per State, on the chores too (file_local_warm): the interface's thread asks the system nothing, not even where
// the home folder is.

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// The entries a search in subfolders looks at, at most: a search from a disk's root ends.
FILE_FIND_VISIT_MAX :: 200_000

// The computer's files: all caps, its own separator.
local_files :: proc() -> File_Source {
	return {
		caps        = {.Size, .Modified, .Read, .Make_Folder},
		separator   = ODIN_OS == .Windows ? '\\' : '/',
		list        = local_list,
		read        = local_read,
		make_folder = local_make_folder,
		find        = local_find,
		places      = local_places,
		start       = local_start,
	}
}

// What the local source reads once per State: its places and its first folder.
@(private)
File_Local :: struct {
	ready:  bool,             // read (the places below are there)
	asked:  bool,             // a reading is on its way
	places: [dynamic]platform.File_Place,   // (strings in the heap)
	home:   string,
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
	state:  ^State,
	places: [dynamic]platform.File_Place,
	home:   string,
}

// Asks for the places of `s` once (nothing when they are read or on their way).
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
	}
	done :: proc(d: rawptr, _: u64) {
		w := (^Local_Warm)(d)
		if fb := w.state.files; fb != nil {
			file_local_destroy(&fb.local)
			fb.local = {ready = true, places = w.places, home = w.home}
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
	local_job_free_fields(j)
	free(j, runtime.heap_allocator())
}

// What a job holds (a find's job too, inside its own struct).
@(private = "file")
local_job_free_fields :: proc(j: ^Local_Job) {
	a := runtime.heap_allocator()
	for e in j.entries { delete(e.name, a) }
	delete(j.entries)
	delete(j.bytes, a)
	delete(j.message, a)
	delete(j.path, a)
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

////////////////////////////////
// Search in subfolders

// The stop of a browser's local walks: a newer find, another folder, the toggle off and the dialog closing bump
// `generation`; a walk that sees another value than its own stops. Shared by the browser and its walks, counted: a
// walk may end after ui.destroy freed the browser.
@(private)
File_Find_Stop :: struct {
	generation: u64,   // (atomic)
	refs:       int,   // (atomic) the browser's and each walk's
}

// The walks on their way stop (nothing when none was started).
@(private)
file_find_stop :: proc(fb: ^File_Browser) {
	if fb.find_stop != nil { sync.atomic_add(&fb.find_stop.generation, 1) }
}

@(private)
file_find_stop_release :: proc(st: ^File_Find_Stop) {
	if st != nil && sync.atomic_sub(&st.refs, 1) == 1 { free(st, runtime.heap_allocator()) }
}

// One entry found, and its score (fuzzy_score of its path relative to the folder).
@(private = "file")
Local_Found :: struct {
	entry: File_Entry,   // (its name in the heap)
	score: int,
}

// One find of the local source, carried to the chores and back. `job` holds the reply, the folder and a failure.
@(private = "file")
Local_Find :: struct {
	using job:  Local_Job,
	query:      string,      // (in the heap)
	limit:      int,
	sep:        u8,
	stop:       ^File_Find_Stop,
	generation: u64,         // the stop's value when this find began
	stopped:    bool,        // given up for a newer one: nothing to answer
	found:      [dynamic]Local_Found,
}

@(private = "file")
local_find :: proc(src: ^File_Source, folder, query: string, limit: int, reply: File_Reply) {
	fb := reply.state != nil ? reply.state.files : nil
	if fb == nil { return }
	a := runtime.heap_allocator()
	if fb.find_stop == nil {
		fb.find_stop = new(File_Find_Stop, a)
		fb.find_stop.refs = 1
	}
	j := new(Local_Find, a)
	j.job = {reply = reply, path = strings.clone(folder, a), size = -1, entries = make([dynamic]File_Entry, a)}
	j.query, j.limit, j.sep = strings.clone(query, a), max(limit, 1), src.separator != 0 ? src.separator : '/'
	j.found = make([dynamic]Local_Found, a)
	// (a newer find stops the older one: its own generation from here)
	j.stop = fb.find_stop
	j.generation = sync.atomic_add(&j.stop.generation, 1) + 1
	sync.atomic_add(&j.stop.refs, 1)
	task(reply.state, local_find_work, local_find_done, j, local_find_free)
}

// The walk, breadth first (what is near the folder is seen first, and kept when the bound is reached): each name's path
// relative to the folder is scored against the query; the best `limit` are kept.
@(private = "file")
local_find_work :: proc(d: rawptr) {
	j := (^Local_Find)(d)
	a := runtime.heap_allocator()
	// (each folder's reading and scoring in `scratch`, freed after it; the folders to walk in `paths`; the needle in
	// `keep`: the walk's own memory, whatever the chores' thread had)
	scratch, paths, keep: virtual.Arena
	defer { virtual.arena_destroy(&scratch); virtual.arena_destroy(&paths); virtual.arena_destroy(&keep) }
	context.temp_allocator = virtual.arena_allocator(&scratch)
	needle := fuzzy_needle(j.query, virtual.arena_allocator(&keep))
	folders := make([dynamic]string, a)
	defer delete(folders)
	append(&folders, "")
	low := make([dynamic]u8, a)
	defer delete(low)
	visited := 0
	walk: for head := 0; head < len(folders); head += 1 {
		rel := folders[head]
		full := rel == "" ? j.path : file_path_join(j.path, rel, j.sep)
		infos, err := os.read_all_directory_by_path(full, context.temp_allocator)
		if err != nil {
			// (the folder itself: said; a subfolder that cannot be read: left out)
			if rel == "" { local_fail(&j.job, err, i18n.tr("The folder could not be read: %s.")); return }
			continue
		}
		for fi in infos {
			if sync.atomic_load(&j.stop.generation) != j.generation { j.stopped = true; break walk }
			visited += 1
			if visited > FILE_FIND_VISIT_MAX { break walk }
			if !j.reply.hidden && len(fi.name) > 0 && fi.name[0] == '.' { continue }
			path := rel == "" ? fi.name : file_path_join(rel, fi.name, j.sep)
			e := File_Entry{kind = .File, size = fi.size, modified = time.to_unix_nanoseconds(fi.modification_time) / 1_000_000}
			#partial switch fi.type {
			case .Directory:
				e.kind = .Folder
				append(&folders, strings.clone(path, virtual.arena_allocator(&paths)))
			case .Symlink:
				// (a link is what it points to, and is not entered: a link to a folder above would loop)
				e.link = true
				if to, to_err := os.stat(fi.fullpath, context.temp_allocator); to_err == nil {
					if to.type == .Directory { e.kind = .Folder }
					e.size = to.size
				}
			}
			if e.kind == .Folder { e.size = -1 }
			resize(&low, len(path))
			fold_lower_into(low[:], path)
			score, _, ok := fuzzy_score_folded(needle, Fuzzy_Text{path, string(low[:])}, context.temp_allocator)
			if !ok { continue }
			e.name = strings.clone(path, a)
			append(&j.found, Local_Found{entry = e, score = score})
			// (trimmed now and then, not at each entry: a sort per 2 * limit found)
			if len(j.found) >= 2 * j.limit { local_find_trim(j) }
		}
		virtual.arena_free_all(&scratch)
	}
	local_find_trim(j)
}

// The best `limit` found, best first: the higher score, then the shorter path, then by name.
@(private = "file")
local_find_trim :: proc(j: ^Local_Find) {
	slice.sort_by(j.found[:], proc(x, y: Local_Found) -> bool {
		if x.score != y.score { return x.score > y.score }
		if len(x.entry.name) != len(y.entry.name) { return len(x.entry.name) < len(y.entry.name) }
		return x.entry.name < y.entry.name
	})
	for i in j.limit ..< len(j.found) { delete(j.found[i].entry.name, runtime.heap_allocator()) }
	if len(j.found) > j.limit { resize(&j.found, j.limit) }
}

// The answer, on the interface's thread (a find given up answers nothing: a newer one is on its way, or none is wanted).
@(private = "file")
local_find_done :: proc(d: rawptr, _: u64) {
	j := (^Local_Find)(d)
	switch {
	case j.stopped:
	case j.failed: file_reply_failed(j.reply, j.message, j.refused, j.missing)
	case:
		entries := make([]File_Entry, len(j.found), context.temp_allocator)
		for f, i in j.found { entries[i] = f.entry }
		file_reply_found(j.reply, entries)
	}
	local_find_free(j)
}

@(private = "file")
local_find_free :: proc(d: rawptr) {
	j := (^Local_Find)(d)
	a := runtime.heap_allocator()
	for f in j.found { delete(f.entry.name, a) }
	delete(j.found)
	delete(j.query, a)
	file_find_stop_release(j.stop)
	local_job_free_fields(&j.job)
	free(j, a)
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
