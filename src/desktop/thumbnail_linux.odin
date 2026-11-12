package tk_desktop

// Thumbnails on Linux, the freedesktop.org Thumbnail Managing Standard (0.9):
//   - the cache: $XDG_CACHE_HOME/thumbnails (default ~/.cache/thumbnails), a folder per size: normal (128 pixels on the
//     longer side), large (256), x-large (512), xx-large (1024). A file's thumbnail is <MD5 of its URI, lower-case hex>.png,
//     its URI the file:// one of its absolute path as GLib writes it (thumbnail_uri): the name every program computes;
//   - a thumbnail is valid while its tEXt Thumb::URI is the file's URI and its Thumb::MTime the file's modification time
//     in whole seconds; the folder of the size asked is read, then the larger ones (reduced);
//   - on a miss, the thumbnailer of the file's type: the type its name says (the MIME database of open_with_linux.odin),
//     then its parents; the *.thumbnailer files in each data directory's thumbnailers/ folder (group [Thumbnailer
//     Entry]: TryExec, Exec with %i the path, %u the URI, %o the file to write, %s the size, MimeType); the first data
//     directory that has a file name wins. One whose TryExec (else its Exec's program) is not installed is none;
//   - what it writes gets Thumb::URI, Thumb::MTime, Thumb::Size and Software, and goes to the cache (a temporary file
//     renamed onto the name, 0600, its folders 0700). A thumbnailer that fails leaves fail/<THUMBNAIL_SOFTWARE>/<name>,
//     a 1x1 picture with the same keys: it is not run again for that file until the file changes.
// The thumbnailers read are kept while no file or folder read has changed (thumbnailer_cache, locked: any worker asks).

import "base:runtime"
import "core:crypto/legacy/md5"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "../platform"
import "../png"

// What the thumbnails written here say made them (Software), and the name of their folder of failures.
THUMBNAIL_SOFTWARE :: "gui_toolkit"

// How long a thumbnailer may run: past it, it is stopped and the file counts as a failure (a video it cannot read can hang).
@(private = "file") THUMBNAILER_LIMIT :: 30 * time.Second

@(private = "file")
Thumbnail_Folder :: struct {
	name: string,
	px:   int,
}

@(private = "file")
THUMBNAIL_FOLDERS :: [?]Thumbnail_Folder{{"normal", 128}, {"large", 256}, {"x-large", 512}, {"xx-large", 1024}}

// A file as the cache knows it: its URI, the name of its thumbnails, its date and size as their keys say them.
@(private)
Thumbnail_Source :: struct {
	uri, name, mtime, size: string,
}

// A thumbnailer: its Exec line and the types it makes thumbnails of.
@(private)
Thumbnailer :: struct {
	exec:  string,
	mimes: []string,
}

// The thumbnailers read last and the data directories they were read from (`key`), in `arena`. Locked: `mutex`.
@(private)
Thumbnailer_Cache :: struct {
	mutex:  sync.Mutex,
	arena:  virtual.Arena,
	ready:  bool,
	key:    string,
	list:   []Thumbnailer,       // the data directories' order, then their files' names
	stamps: [dynamic]File_Stamp,
	reads:  int,                 // how many times they were read (the tests count them)
}

@(private) thumbnailer_cache: Thumbnailer_Cache

@(private)
thumbnail_native :: proc(path: string, size: int, mode: Thumbnail_Mode, allocator: runtime.Allocator) -> (thumb: Thumbnail, ok: bool) {
	return thumbnail_in(xdg_roots(), xdg_cache_home(), path, size, mode, allocator)
}

@(private)
thumbnail_store_native :: proc(path: string, rgba: []u8, width, height: int) -> bool {
	return thumbnail_store_in(xdg_cache_home(), path, rgba, width, height)
}

// The thumbnail of `path` from the data directories of `roots` and the cache under `cache_home` (the tests give theirs).
@(private)
thumbnail_in :: proc(roots: Xdg_Roots, cache_home, path: string, size: int, mode: Thumbnail_Mode, allocator: runtime.Allocator) -> (thumb: Thumbnail, ok: bool) {
	if cache_home == "" { return }
	src, found := thumbnail_source(path)
	if !found { return }
	base := strings.concatenate({cache_home, "/thumbnails"}, context.temp_allocator)
	folders := THUMBNAIL_FOLDERS
	for f in folders[thumbnail_folder(size):] {
		data, err := os.read_entire_file(strings.concatenate({base, "/", f.name, "/", src.name}, context.temp_allocator), context.temp_allocator)
		if err != nil || !thumbnail_valid(data, src.uri, src.mtime) { continue }
		rgba, w, h, decoded := png.decode(data, allocator)
		if !decoded { continue }
		return thumbnail_fit(rgba, w, h, size, allocator), true
	}
	if mode == .Cached { return }
	// (it failed on this file as it is: not run again)
	fail := strings.concatenate({base, "/fail/", THUMBNAIL_SOFTWARE, "/", src.name}, context.temp_allocator)
	if data, err := os.read_entire_file(fail, context.temp_allocator); err == nil && thumbnail_valid(data, src.uri, src.mtime) { return }
	exec := thumbnailer_of(roots, path)
	if exec == "" { return }
	folder := folders[thumbnail_folder(size)]
	dir := strings.concatenate({base, "/", folder.name}, context.temp_allocator)
	if !folder_made(dir) { return }
	// (beside the cache's file: the thread's own name, as two workers may make two thumbnails at once)
	out := fmt.tprintf("%s/.%s-%d-%d.png", dir, THUMBNAIL_SOFTWARE, os.get_pid(), os.get_current_thread_id())
	defer os.remove(out)
	made := false
	rgba: []u8
	w, h: int
	if args, valid := thumbnailer_command(exec, path, src.uri, out, folder.px); valid && thumbnailer_run(args) {
		if data, err := os.read_entire_file(out, context.temp_allocator); err == nil { rgba, w, h, made = png.decode(data, allocator) }
	}
	if !made {
		px: [4]u8
		_ = thumbnail_write(base, "fail/" + THUMBNAIL_SOFTWARE, src, px[:], 1, 1)
		return
	}
	kept := thumbnail_fit(rgba, w, h, folder.px, allocator)
	_ = thumbnail_write(base, folder.name, src, kept.rgba, kept.size.x, kept.size.y)
	return thumbnail_fit(kept.rgba, kept.size.x, kept.size.y, size, allocator), true
}

// Keeps a program's picture of `path` in the cache under `cache_home`: in the largest folder it fills (reduced to it),
// the normal one for a smaller picture.
@(private)
thumbnail_store_in :: proc(cache_home, path: string, rgba: []u8, width, height: int) -> bool {
	if cache_home == "" { return false }
	src, found := thumbnail_source(path)
	if !found { return false }
	folders := THUMBNAIL_FOLDERS
	side := max(width, height)
	folder := folders[0]
	for f in folders { if f.px <= side { folder = f } }
	pixels, w, h := rgba, width, height
	if side > folder.px {
		k := f32(folder.px) / f32(side)
		w, h = max(1, int(f32(width) * k + 0.5)), max(1, int(f32(height) * k + 0.5))
		pixels = platform.rgba_resample(rgba, width, height, w, h, context.temp_allocator)
	}
	return thumbnail_write(strings.concatenate({cache_home, "/thumbnails"}, context.temp_allocator), folder.name, src, pixels, w, h)
}

// The index in THUMBNAIL_FOLDERS of the folder for `size`: the first whose thumbnails are as large, else the largest.
@(private)
thumbnail_folder :: proc(size: int) -> int {
	folders := THUMBNAIL_FOLDERS
	for f, i in folders { if f.px >= size { return i } }
	return len(folders) - 1
}

// The URI of `path` as the cache names it: file:// and the path, each byte but those GLib's g_filename_to_uri leaves
// (letters, digits, -._~!$&'()*+,=:@/) written %XX in upper case: the MD5 is then the one other programs compute.
@(private)
thumbnail_uri :: proc(path: string, allocator := context.temp_allocator) -> string {
	hex := "0123456789ABCDEF"
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file://")
	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', '=', ':', '@', '/':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 0xF])
		}
	}
	return strings.to_string(b)
}

// The cache's file name for a URI: its MD5 in lower-case hex, then .png.
@(private)
thumbnail_name :: proc(uri: string, allocator := context.temp_allocator) -> string {
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, transmute([]u8)uri)
	sum: [md5.DIGEST_SIZE]u8
	md5.final(&ctx, sum[:])
	hex := "0123456789abcdef"
	b := strings.builder_make(allocator)
	for x in sum {
		strings.write_byte(&b, hex[x >> 4])
		strings.write_byte(&b, hex[x & 0xF])
	}
	strings.write_string(&b, ".png")
	return strings.to_string(b)
}

// The file at `path` as the cache knows it (temporary memory). Not found: not an absolute path to a regular file.
@(private)
thumbnail_source :: proc(path: string) -> (src: Thumbnail_Source, found: bool) {
	if !filepath.is_abs(path) { return }
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil || fi.type != .Regular { return }
	src.uri = thumbnail_uri(path)
	src.name = thumbnail_name(src.uri)
	src.mtime = fmt.tprint(time.to_unix_seconds(fi.modification_time))
	src.size = fmt.tprint(fi.size)
	return src, true
}

// The thumbnail file `data` is of the file as it is now: a PNG whose Thumb::URI and Thumb::MTime are `uri` and `mtime`.
@(private)
thumbnail_valid :: proc(data: []u8, uri, mtime: string) -> bool {
	list, ok := png.texts(data)
	if !ok { return false }
	same_uri, same_mtime := false, false
	for x in list {
		switch x.keyword {
		case "Thumb::URI":   same_uri = x.text == uri
		case "Thumb::MTime": same_mtime = x.text == mtime
		}
	}
	return same_uri && same_mtime
}

// Writes a thumbnail of `src` into the folder `folder` of the cache `base`: the PNG with the standard's keys, through a
// temporary file renamed onto its name (another program never reads half of one), readable by the user alone.
@(private = "file")
thumbnail_write :: proc(base, folder: string, src: Thumbnail_Source, rgba: []u8, w, h: int) -> bool {
	dir := strings.concatenate({base, "/", folder}, context.temp_allocator)
	if !folder_made(dir) { return false }
	keys := []png.Text{{"Thumb::URI", src.uri}, {"Thumb::MTime", src.mtime}, {"Thumb::Size", src.size}, {"Software", THUMBNAIL_SOFTWARE}}
	file := png.with_texts(png.encode(rgba, w, h, .Small, context.temp_allocator), keys, context.temp_allocator)
	if file == nil { return false }
	tmp := fmt.tprintf("%s/.%s-%d-%d.tmp", dir, THUMBNAIL_SOFTWARE, os.get_pid(), os.get_current_thread_id())
	if os.write_entire_file(tmp, file, os.perm(0o600)) != nil || os.rename(tmp, strings.concatenate({dir, "/", src.name}, context.temp_allocator)) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

// The folder `dir` is there, made with its parents for the user alone when it was not.
@(private = "file")
folder_made :: proc(dir: string) -> bool {
	_ = os.make_directory_all(dir, os.perm(0o700))   // (one already there is an error: is_dir says)
	return os.is_dir(dir)
}

// The Exec line of the thumbnailer of the file at `path` (temporary memory), "" when its type has none.
@(private)
thumbnailer_of :: proc(roots: Xdg_Roots, path: string) -> string {
	types: []string
	{
		sync.mutex_guard(&mime_cache.mutex)
		db := mime_cache_get(&mime_cache, roots)
		family := mime_family(db, mime_of_name(db, filepath.base(path)))
		// (copied: the database's memory is not reached after the lock)
		types = make([]string, len(family), context.temp_allocator)
		for t, i in family { types[i] = strings.clone(t, context.temp_allocator) }
	}
	sync.mutex_guard(&thumbnailer_cache.mutex)
	list := thumbnailers_get(&thumbnailer_cache, roots)
	// (the nearest type first: a thumbnailer of application/pdf before one of its parent)
	for t in types {
		for th in list { if slice.contains(th.mimes, t) { return strings.clone(th.exec, context.temp_allocator) } }
	}
	return ""
}

// The thumbnailers of the data directories of `roots`: the ones read last while it is the same directories and no file
// or folder read has changed, else read again. The caller holds `c.mutex`.
@(private)
thumbnailers_get :: proc(c: ^Thumbnailer_Cache, roots: Xdg_Roots) -> []Thumbnailer {
	key := strings.join(roots.data, ":", context.temp_allocator)
	if c.ready && c.key == key && stamps_current(c.stamps[:]) { return c.list }
	if c.ready { virtual.arena_destroy(&c.arena) }
	c.arena = {}
	_ = virtual.arena_init_growing(&c.arena)   // (a failure leaves an arena whose allocations fail: no thumbnailer)
	a := virtual.arena_allocator(&c.arena)
	c.key = strings.clone(key, a)
	c.stamps = make([dynamic]File_Stamp, a)
	list := make([dynamic]Thumbnailer, a)
	seen := make(map[string]bool, context.temp_allocator)
	for root in roots.data {
		dir := strings.concatenate({root, "/thumbnailers"}, context.temp_allocator)
		s := stamp_of(dir)
		s.path = strings.clone(dir, a)
		append(&c.stamps, s)   // (a thumbnailer added or taken off changes its folder)
		if !s.found { continue }
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { continue }
		slice.sort_by(entries, proc(x, y: os.File_Info) -> bool { return x.name < y.name })
		for fi in entries {
			// (the first data directory with a name wins: the user's before the system's)
			if !strings.has_suffix(fi.name, ".thumbnailer") || seen[fi.name] { continue }
			seen[fi.name] = true
			fs := stamp_of(fi.fullpath)
			fs.path = strings.clone(fi.fullpath, a)
			append(&c.stamps, fs)
			text, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			if th, usable := thumbnailer_read(string(text), a); usable { append(&list, th) }
		}
	}
	c.list = list[:]
	c.ready = true
	c.reads += 1
	return c.list
}

// A .thumbnailer file's thumbnailer, in `a`. Not usable: no Exec, or its program (TryExec, else Exec's first argument)
// is not installed.
@(private = "file")
thumbnailer_read :: proc(text: string, a: runtime.Allocator) -> (th: Thumbnailer, usable: bool) {
	GROUP :: "[Thumbnailer Entry]"
	exec, _ := group_value(text, GROUP, "Exec")
	try_exec, _ := group_value(text, GROUP, "TryExec")
	mimes, _ := group_value(text, GROUP, "MimeType")
	if exec == "" { return }
	program := try_exec != "" ? unescape_value(try_exec) : exec_program(exec)
	if program == "" { return }
	if strings.index_byte(program, '/') >= 0 {
		if !os.is_file(program) { return }
	} else {
		if _, found := find_on_path(program); !found { return }
	}
	return {strings.clone(exec, a), split_list(strings.clone(unescape_value(mimes), a), a)}, true
}

// The command of a thumbnailer's Exec line for one file: %i its path, %u its URI, %o the file to write, %s the size,
// %% a %. Not ok for a code it does not list, a `%` at the end, or a code in a quoted argument (a shell would read the
// name: the Desktop Entry specification's rule, whose Exec lines these are).
@(private)
thumbnailer_command :: proc(exec, path, uri, out: string, size: int) -> (args: []string, ok: bool) {
	list := make([dynamic]string, context.temp_allocator)
	for a in exec_arguments(exec, context.temp_allocator) {
		sb := strings.builder_make(context.temp_allocator)
		for i := 0; i < len(a.text); i += 1 {
			if a.text[i] != '%' { strings.write_byte(&sb, a.text[i]); continue }
			if i + 1 >= len(a.text) { return nil, false }
			i += 1
			code := a.text[i]
			if code == '%' { strings.write_byte(&sb, '%'); continue }
			if a.quoted { return nil, false }
			switch code {
			case 'i': strings.write_string(&sb, path)
			case 'u': strings.write_string(&sb, uri)
			case 'o': strings.write_string(&sb, out)
			case 's': strings.write_int(&sb, size)
			case:     return nil, false
			}
		}
		append(&list, strings.to_string(sb))
	}
	if len(list) == 0 { return nil, false }
	return list[:], true
}

// Runs a thumbnailer and waits for it, at most THUMBNAILER_LIMIT. True when it exited with 0.
@(private = "file")
thumbnailer_run :: proc(args: []string) -> bool {
	p, err := os.process_start({command = args})
	if err != nil { return false }
	state, werr := os.process_wait(p, THUMBNAILER_LIMIT)
	if werr != nil {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		return false
	}
	return state.exited && state.exit_code == 0
}
