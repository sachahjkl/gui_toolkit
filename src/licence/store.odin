package tk_licence

// Where a program keeps its licence: a small file, licence<ext> in the user's configuration folder of the program
// (platform.user_dir(.Config, program)), or memory only for a profile that is not kept. Every procedure here that touches
// the file waits on the disk: the program calls it in a task (ui.task), never on the interface's thread; its result comes
// back with the task (docs/licence.md):
//
//	ui.task(&app.ui, proc(d: rawptr) { a := (^App)(d); a.status_next = licence.store_read(&a.licences, runtime.heap_allocator()) },
//	        proc(d: rawptr, _: u64) { a := (^App)(d); licence.status_destroy(&a.status, runtime.heap_allocator()); a.status = a.status_next }, app)
//
// A store is shared by the interface and its tasks: its own lock keeps one operation at a time.

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "../ascii"
import base "../base"
import "../fsx"
import "../platform"

Store_Options :: struct {
	product:    Product,
	program:    string,   // the program's folder in the user's configuration folder ("": product.name)
	path:       string,   // the licence's file ("": licence<ext> in that folder; store_path)
	memory:     bool,     // kept in memory only: no file is read or written (a profile that is not kept)
	public_key: string,   // licences are checked with this key ("": the product's): a fork that sells its own, a test
	accept_dev: bool,     // the product's dev_public_key is accepted too: a development build, never a release
	seed:       string,   // the licence this build is handed out with ("": none), put in place once (store_read)
	released:   string,   // the day this version was released ("YYYY-MM-DD"), for Status.covered ("": not known)
}

Store :: struct {
	options:  Store_Options,   // (its strings owned, but the product's: a constant of the program)
	lock:     sync.Mutex,      // the fields below, and one operation on the file at a time
	path:     string,          // (owned) the file, found at the first use (on a task: user_dir may ask the system)
	found:    bool,            // path is found
	held:     [MAX_TEXT]u8,    // memory: the key
	held_len: int,
	seeded:   bool,            // memory: the seed was put there in this run
}

// What the store holds, for the program to say.
Status :: struct {
	licence:    Licence,   // when registered (licence_destroy, or status_destroy)
	stored:     bool,      // some key is stored (it may not check out: err)
	registered: bool,      // stored and checked
	covered:    bool,      // registered, and its updates cover Store_Options.released (always, for a product that does not count them)
	err:        Error,
}

// The name of the marker beside the file: the build's own licence was put there once (store_read).
SEED_MARKER :: ".seeded"

store_init :: proc(s: ^Store, o: Store_Options) {
	a := runtime.heap_allocator()
	s^ = {}
	s.options = o
	s.options.program = strings.clone(o.program, a)
	s.options.path = strings.clone(o.path, a)
	s.options.public_key = strings.clone(o.public_key, a)
	s.options.seed = strings.clone(o.seed, a)
	s.options.released = strings.clone(o.released, a)
}

store_destroy :: proc(s: ^Store) {
	a := runtime.heap_allocator()
	delete(s.options.program, a); delete(s.options.path, a); delete(s.options.public_key, a)
	delete(s.options.seed, a); delete(s.options.released, a); delete(s.path, a)
	s^ = {}
}

status_destroy :: proc(st: ^Status, allocator := context.allocator) {
	licence_destroy(&st.licence, allocator)
	st^ = {}
}

// Checks `text` with the store's key; a store that accepts the development pair also takes a licence made with it. No file
// is read: any thread.
store_check :: proc(s: ^Store, text: string, allocator := context.allocator) -> (lic: Licence, err: Error) {
	p := s.options.product
	lic, err = verify(p, text, s.options.public_key, allocator)
	if err != .None && s.options.accept_dev && p.dev_public_key != "" {
		if dev, dev_err := verify(p, text, p.dev_public_key, allocator); dev_err == .None {
			licence_destroy(&lic, allocator)
			return dev, .None
		}
	}
	return
}

// The licence's file ("": memory only), in `allocator`. Blocks: a task.
store_path :: proc(s: ^Store, allocator := context.allocator, loc := #caller_location) -> string {
	base.blocking("licence.store_path", loc)
	sync.guard(&s.lock)
	return strings.clone(path_locked(s), allocator)
}

// What is stored, checked; the build's own licence put in place first when it never was (Store_Options.seed). Blocks: a task.
store_read :: proc(s: ^Store, allocator := context.allocator, loc := #caller_location) -> Status {
	base.blocking("licence.store_read", loc)
	sync.guard(&s.lock)
	seed_locked(s)
	text := stored_text_locked(s)
	if strings.trim_space(text) == "" { return {} }
	lic, err := store_check(s, text, allocator)
	st := Status{licence = lic, stored = true, registered = err == .None, err = err}
	st.covered = st.registered && covers(s.options.product, lic, s.options.released)
	return st
}

// Checks `text` and keeps it (normalized: the key alone). Nothing is written when it does not check out. Blocks: a task.
store_install :: proc(s: ^Store, text: string, loc := #caller_location) -> Error {
	base.blocking("licence.store_install", loc)
	sync.guard(&s.lock)
	return install_locked(s, text)
}

// Reads the licence file `file` (dropped on the window, given on the command line, chosen in a dialog) and installs it.
// Blocks: a task.
store_install_file :: proc(s: ^Store, file: string, loc := #caller_location) -> Error {
	base.blocking("licence.store_install_file", loc)
	data, ok := fsx.read_all(file, context.temp_allocator, MAX_TEXT + 1)
	if !ok { return fsx.path_kind(file) == .File ? .Too_Long : .Not_Read }
	if len(data) > MAX_TEXT { return .Too_Long }
	sync.guard(&s.lock)
	return install_locked(s, string(data))
}

// Removes the stored licence. A licence the build was handed out with stays removed (its marker stays). Blocks: a task.
store_remove :: proc(s: ^Store, loc := #caller_location) -> bool {
	base.blocking("licence.store_remove", loc)
	sync.guard(&s.lock)
	path := path_locked(s)
	if path == "" { s.held_len = 0; return true }
	if fsx.path_kind(path) == .Absent { return true }
	return fsx.delete_file(path)
}

// Whether `path` names a licence file of the product (by its extension, any case): what a program installs instead of
// opening. No file is read.
is_licence_file :: proc(p: Product, path: string) -> bool {
	ext := p.file_extension
	return ext != "" && len(path) > len(ext) && ascii.equal_fold(path[len(path) - len(ext):], ext)
}

// The Open dialog of a licence file, for ui.file_dialog (which copies it): `title` and `filter_name` are the program's
// words ("Choose a licence file", "App licence"). Its slices are in the temporary allocator.
file_dialog :: proc(p: Product, title, filter_name: string) -> platform.File_Dialog {
	patterns := make([]string, 1, context.temp_allocator)
	patterns[0] = strings.concatenate({"*", p.file_extension}, context.temp_allocator)
	filters := make([]platform.File_Filter, 1, context.temp_allocator)
	filters[0] = {name = filter_name, patterns = patterns}
	return {title = title, filters = filters, all_files = true, remember_id = "licence"}
}

////////////////////////////////

@(private = "file")
path_locked :: proc(s: ^Store) -> string {
	if s.options.memory { return "" }
	if s.found { return s.path }
	s.found = true
	if s.options.path != "" {
		s.path = strings.clone(s.options.path, runtime.heap_allocator())
		return s.path
	}
	program := s.options.program != "" ? s.options.program : s.options.product.name
	dir := platform.user_dir(.Config, program, context.temp_allocator)
	if dir != "" {
		name := strings.concatenate({"licence", s.options.product.file_extension}, context.temp_allocator)
		s.path, _ = filepath.join({dir, name}, runtime.heap_allocator())
	}
	return s.path
}

@(private = "file")
stored_text_locked :: proc(s: ^Store) -> string {
	path := path_locked(s)
	if s.options.memory { return string(s.held[:s.held_len]) }
	if path == "" { return "" }
	data, ok := fsx.read_all(path, context.temp_allocator, MAX_TEXT)
	return ok ? string(data) : ""
}

@(private = "file")
install_locked :: proc(s: ^Store, text: string) -> Error {
	lic, err := store_check(s, text, context.temp_allocator)
	if err != .None { return err }
	_ = lic
	canonical := normalize(text, context.temp_allocator)
	if s.options.memory {
		s.held_len = copy(s.held[:], canonical)
		return .None
	}
	path := path_locked(s)
	if path == "" { return .Not_Written }
	fsx.make_dirs(filepath.dir(path))
	data := strings.concatenate({canonical, "\n"}, context.temp_allocator)
	return fsx.write_atomic(path, transmute([]byte)data, flush = true, private = true) ? .None : .Not_Written
}

// The licence a build is handed out with goes where the store keeps its licence ONCE: only when nothing is stored and it was
// never put there. The marker beside the file says it was: removing the licence then removes it for good, and installing
// another replaces it, as for one the user typed in. A store that holds a licence keeps its own. A text this store does
// not accept (a release has no key for it) is put nowhere. A memory-only store is given it once per run.
@(private = "file")
seed_locked :: proc(s: ^Store) {
	text := s.options.seed
	if strings.trim_space(text) == "" { return }
	if s.options.memory {
		if s.seeded || s.held_len > 0 { return }
		s.seeded = true
		if _, err := store_check(s, text, context.temp_allocator); err == .None {
			s.held_len = copy(s.held[:], normalize(text, context.temp_allocator))
		}
		return
	}
	path := path_locked(s)
	if path == "" { return }
	marker := strings.concatenate({path, SEED_MARKER}, context.temp_allocator)
	if fsx.path_kind(path) != .Absent || fsx.path_kind(marker) != .Absent { return }
	if install_locked(s, text) == .None {
		note := "the licence of this build was put here once; removing it keeps it removed\n"
		_ = fsx.write_atomic(marker, transmute([]byte)note)
	}
}
