// Package filesearch: fast typo-tolerant file and folder search over directory trees (src/md/features/file-search.md).
// Backed by fff-search in native/filesearch, a part of the toolkit's one native library: a program with
// toolbox.Feature.Filesearch builds it in (-define:GT_FILESEARCH=true, tools/tk build_native with filesearch). Without
// the define, available() is false and open() returns .Unavailable.
//
// None of these procedures belongs on the interface thread: open, search, note_opened and close run on a worker
// (ui.task) and post their results back.
package tk_filesearch

@(require) import "core:encoding/endian"
@(require) import "core:strings"

GT_FILESEARCH :: #config(GT_FILESEARCH, false)

when GT_FILESEARCH {
	when ODIN_OS == .Windows {
		foreign import gt_filesearch {
			"../../build/native/gt_native.lib",
			"system:ntdll.lib",
			"system:userenv.lib",
			"system:ws2_32.lib",
			"system:bcrypt.lib",
			"system:advapi32.lib",
			"system:kernel32.lib",
			"system:dbghelp.lib",
			"system:rpcrt4.lib",
			"system:ole32.lib",
			"system:shell32.lib",
			"system:winhttp.lib",
			"system:crypt32.lib",
			"system:secur32.lib",
			"system:Synchronization.lib",
		}
	} else when ODIN_OS == .Darwin {
		foreign import gt_filesearch {
			"../../build/native/libgt_native.a",
			"system:dl",
			"system:pthread",
			"system:m",
			"system:iconv",
			"system:CoreFoundation.framework",
			"system:CoreServices.framework",
			"system:Security.framework",
		}
	} else {
		foreign import gt_filesearch {
			"../../build/native/libgt_native.a",
			"system:dl",
			"system:pthread",
			"system:m",
		}
	}

	@(private = "file")
	C_Open :: struct {
		root:             [^]u8,
		root_len:         uint,
		frecency_dir:     [^]u8,
		frecency_dir_len: uint,
		flags:            u32,
	}

	@(private, default_calling_convention = "c")
	foreign gt_filesearch {
		gt_filesearch_open :: proc(opts: ^C_Open, out_id: ^u32) -> i32 ---
		gt_filesearch_close :: proc(id: u32) ---
		gt_filesearch_wait :: proc(id: u32, timeout_ms: u32) -> bool ---
		gt_filesearch_state :: proc(id: u32, out_scanning, out_watching: ^u8, out_scanned: ^uint) -> bool ---
		gt_filesearch_search :: proc(id: u32, query: [^]u8, query_len: uint, offset, limit: uint, dirs: u8, out_ptr: ^[^]u8, out_len: ^uint) -> i32 ---
		gt_filesearch_note_opened :: proc(id: u32, path: [^]u8, path_len: uint) -> bool ---
		gt_filesearch_free :: proc(ptr: [^]u8, len: uint) ---
	}
}

// An open search index over one directory tree. 0 is none.
Index :: distinct u32

Error :: enum u8 {
	None,
	Invalid_Path,   // root is empty or not an existing directory
	Failed,         // the search engine failed or the handle is invalid
	Unavailable,    // this build was compiled without GT_FILESEARCH
}

Open_Options :: struct {
	root:            string,   // directory to index
	frecency_dir:    string,   // optional LMDB folder shared across programs for frecency ranking ("": none)
	watch:           bool,     // keep the index updated via a background filesystem watcher
	follow_symlinks: bool,
	allow_home:      bool,     // required when root is the user's home directory
}

Search_Options :: struct {
	offset: int,    // pagination offset (0: from top)
	limit:  int,    // maximum results to return (0: 50)
	dirs:   bool,   // include directories interleaved with files (false: files only, with match ranges)
}

// Byte range [start, end) of a matched span inside Hit.path.
Match_Range :: [2]int

Hit :: struct {
	path:   string,        // relative to Open_Options.root (owned by Page)
	dir:    bool,
	score:  i32,
	ranges: []Match_Range, // matched byte spans in path (files-only search; nil in mixed mode)
}

Page :: struct {
	hits:          []Hit,
	total_matched: int,
	total_indexed: int,
}

State :: struct {
	scanning: bool,
	watching: bool,
	scanned:  int,
}

@(private = "file") FLAG_WATCH           :: u32(1 << 0)
@(private = "file") FLAG_FOLLOW_SYMLINKS :: u32(1 << 1)
@(private = "file") FLAG_ALLOW_HOME      :: u32(1 << 2)

// Whether this build links the file search engine (GT_FILESEARCH).
available :: proc() -> bool {
	return GT_FILESEARCH
}

// Opens an index over o.root; scanning (and watching when o.watch) starts on background threads.
open :: proc(o: Open_Options) -> (idx: Index, err: Error) {
	when !GT_FILESEARCH {
		return 0, .Unavailable
	} else {
		flags: u32
		if o.watch { flags |= FLAG_WATCH }
		if o.follow_symlinks { flags |= FLAG_FOLLOW_SYMLINKS }
		if o.allow_home { flags |= FLAG_ALLOW_HOME }
		c := C_Open{
			root = raw_data(o.root), root_len = uint(len(o.root)),
			frecency_dir = raw_data(o.frecency_dir), frecency_dir_len = uint(len(o.frecency_dir)),
			flags = flags,
		}
		id: u32
		switch gt_filesearch_open(&c, &id) {
		case 0: return Index(id), .None
		case 1: return 0, .Invalid_Path
		case:   return 0, .Failed
		}
	}
}

// Stops any background watcher and frees the index. Safe on 0 or an already-closed index.
close :: proc(idx: Index) {
	when GT_FILESEARCH {
		if idx != 0 { gt_filesearch_close(u32(idx)) }
	}
}

// Waits up to timeout_ms for the initial scan to finish; returns true if complete.
wait_ready :: proc(idx: Index, timeout_ms: int) -> bool {
	when !GT_FILESEARCH {
		return false
	} else {
		if idx == 0 { return false }
		return gt_filesearch_wait(u32(idx), u32(max(timeout_ms, 0)))
	}
}

// Current scan and watcher state of the index.
state :: proc(idx: Index) -> (st: State) {
	when GT_FILESEARCH {
		if idx == 0 { return }
		sc, wa: u8
		n: uint
		if gt_filesearch_state(u32(idx), &sc, &wa, &n) {
			st = {scanning = sc != 0, watching = wa != 0, scanned = int(n)}
		}
	}
	return
}

// Queries the index. Call page_destroy on the returned Page when done.
search :: proc(idx: Index, query: string, o := Search_Options{}, allocator := context.allocator) -> (page: Page, err: Error) {
	when !GT_FILESEARCH {
		return {}, .Unavailable
	} else {
		if idx == 0 { return {}, .Failed }
		ptr: [^]u8
		n: uint
		rc := gt_filesearch_search(
			u32(idx), raw_data(query), uint(len(query)),
			uint(max(o.offset, 0)), uint(max(o.limit, 0)), o.dirs ? 1 : 0,
			&ptr, &n,
		)
		if rc != 0 { return {}, .Failed }
		defer gt_filesearch_free(ptr, n)
		return decode_page(ptr[:n], allocator)
	}
}

// Records that the user opened path (relative to root or absolute) so frecency ranks it higher.
note_opened :: proc(idx: Index, path: string) -> bool {
	when !GT_FILESEARCH {
		return false
	} else {
		if idx == 0 || len(path) == 0 { return false }
		return gt_filesearch_note_opened(u32(idx), raw_data(path), uint(len(path)))
	}
}

page_destroy :: proc(p: ^Page, allocator := context.allocator) {
	for h in p.hits {
		delete(h.path, allocator)
		delete(h.ranges, allocator)
	}
	delete(p.hits, allocator)
	p^ = {}
}

@(private = "file")
decode_page :: proc(buf: []u8, allocator := context.allocator) -> (page: Page, err: Error) {
	if len(buf) < 12 { return {}, .Failed }
	pos := 0
	read_u16 :: proc(b: []u8, pos: ^int) -> (u16, bool) {
		if pos^ + 2 > len(b) { return 0, false }
		v, ok := endian.get_u16(b[pos^:pos^ + 2], .Little)
		pos^ += 2
		return v, ok
	}
	read_u32 :: proc(b: []u8, pos: ^int) -> (u32, bool) {
		if pos^ + 4 > len(b) { return 0, false }
		v, ok := endian.get_u32(b[pos^:pos^ + 4], .Little)
		pos^ += 4
		return v, ok
	}
	read_i32 :: proc(b: []u8, pos: ^int) -> (i32, bool) {
		if pos^ + 4 > len(b) { return 0, false }
		v, ok := endian.get_i32(b[pos^:pos^ + 4], .Little)
		pos^ += 4
		return v, ok
	}
	total_matched, ok1 := read_u32(buf, &pos)
	total_indexed, ok2 := read_u32(buf, &pos)
	count, ok3 := read_u32(buf, &pos)
	if !ok1 || !ok2 || !ok3 { return {}, .Failed }
	hits := make([]Hit, int(count), allocator)
	page = {hits = hits, total_matched = int(total_matched), total_indexed = int(total_indexed)}
	for i in 0 ..< int(count) {
		if pos >= len(buf) { page_destroy(&page, allocator); return {}, .Failed }
		flags := buf[pos]; pos += 1
		score, ok_s := read_i32(buf, &pos)
		plen, ok_p := read_u32(buf, &pos)
		if !ok_s || !ok_p || pos + int(plen) > len(buf) { page_destroy(&page, allocator); return {}, .Failed }
		path := strings.clone(string(buf[pos:pos + int(plen)]), allocator)
		pos += int(plen)
		rc, ok_r := read_u16(buf, &pos)
		if !ok_r || pos + int(rc) * 8 > len(buf) { delete(path, allocator); page_destroy(&page, allocator); return {}, .Failed }
		ranges: []Match_Range
		if rc > 0 {
			ranges = make([]Match_Range, int(rc), allocator)
			for k in 0 ..< int(rc) {
				s, _ := read_u32(buf, &pos)
				e, _ := read_u32(buf, &pos)
				ranges[k] = {int(s), int(e)}
			}
		}
		hits[i] = {path = path, dir = (flags & 1) != 0, score = score, ranges = ranges}
	}
	return page, .None
}
