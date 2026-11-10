// Package archive: what a zip or a tar (plain or gzipped) holds, and a file taken out of it. Read only; pure Odin (the
// toolkit's flate for the compressed parts), any target. The package is named tk_archive.
//
//	idx, err := archive.open("/home/me/photos.zip")    // the index: every entry, its size, its date
//	defer archive.index_destroy(&idx)
//	archive.children(&idx, "2024/june", &list)          // the entries right under a folder of it (its folders made up
//	                                                    // when the archive names only their files)
//	data, err := archive.read(&idx, "2024/june/a.jpg") // a file of it, whole
//	err := archive.extract(&idx, "2024/june/a.jpg", "/tmp/a.jpg")
//
// A zip is read from its end (its central directory, ZIP64 too): opening a large one reads a few kilobytes. A tar is read
// header by header; a gzipped one is inflated on the way (each open, each read goes through it again from its start).
// Names inside are '/'-separated, without a leading or a trailing '/'. A name that would leave the archive's folder
// ("../x", an absolute path) is refused by extract.
package tk_archive

import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import flate "../flate"

Kind :: enum u8 { Zip, Tar, Tar_Gz }

Error :: enum u8 {
	None,
	Unreadable,       // the file cannot be opened or read
	Not_An_Archive,   // no zip's end, no tar header
	Bad_Data,         // a header or a compressed part that does not hold together
	Unsupported,      // an encrypted entry, a compression other than stored and deflate
	Not_Found,        // no such entry, or a folder
	Too_Large,        // more than the limit asked
	Unsafe_Name,      // extract: a name that would leave its folder
}

Entry :: struct {
	name:   string,   // its path inside, in the index's arena
	dir:    bool,
	size:   i64,      // its bytes once taken out
	packed: i64,      // its bytes in the archive
	mtime:  i64,      // nanoseconds since 1970-01-01 UTC (0: unknown)
	offset: i64,      // zip: its local header; tar: its data in the (inflated) stream
	method: u16,      // zip: 0 stored, 8 deflate
	flags:  u16,      // zip: bit 0, encrypted
}

Index :: struct {
	path:    string,   // the archive's file (the arena's)
	kind:    Kind,
	entries: [dynamic]Entry,
	arena:   virtual.Arena,
}

// The kind of an archive by its name: .zip, .tar, .tar.gz, .tgz (any case). ok = false: none.
kind_of :: proc(name: string) -> (kind: Kind, ok: bool) {
	lower := strings.to_lower(name, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".zip"):                                        return .Zip, true
	case strings.has_suffix(lower, ".tar"):                                        return .Tar, true
	case strings.has_suffix(lower, ".tar.gz"), strings.has_suffix(lower, ".tgz"): return .Tar_Gz, true
	}
	return
}

index_destroy :: proc(idx: ^Index) {
	delete(idx.entries)
	virtual.arena_destroy(&idx.arena)
	idx^ = {}
}

@(private)
keep :: proc(idx: ^Index, s: string) -> string { return strings.clone(s, virtual.arena_allocator(&idx.arena)) }

// The name as the index keeps it: '/' between its parts, none at its ends, no "./" before it.
@(private)
clean_name :: proc(name: string) -> string {
	s, _ := strings.replace_all(name, "\\", "/", context.temp_allocator)
	for strings.has_prefix(s, "./") { s = s[2:] }
	return strings.trim(s, "/")
}

// The archive at `path`, read: its index (index_destroy it).
open :: proc(path: string, allocator := context.allocator) -> (idx: Index, err: Error) {
	kind, ok := kind_of(path)
	if !ok { return {}, .Not_An_Archive }
	idx.kind = kind
	idx.path = keep(&idx, path)
	idx.entries = make([dynamic]Entry, allocator)
	switch kind {
	case .Zip:            err = zip_index(&idx)
	case .Tar, .Tar_Gz:   err = tar_index(&idx)
	}
	if err != .None { index_destroy(&idx) }
	return
}

// The entry named `name` (nil: none).
find :: proc(idx: ^Index, name: string) -> ^Entry {
	want := clean_name(name)
	for &e in idx.entries { if e.name == want { return &e } }
	return nil
}

// The entries right under the folder `dir` of the archive ("": its top), appended to `out` (their names are the index's).
// A folder an archive names only through its files (most zips) is made up, once, its date unknown.
children :: proc(idx: ^Index, dir: string, out: ^[dynamic]Entry) {
	d := clean_name(dir)
	prefix := d == "" ? "" : strings.concatenate({d, "/"}, context.temp_allocator)
	seen := make(map[string]bool, 64, context.temp_allocator)
	for e in idx.entries {
		if !strings.has_prefix(e.name, prefix) || len(e.name) == len(prefix) { continue }
		rest := e.name[len(prefix):]
		if slash := strings.index_byte(rest, '/'); slash >= 0 {
			// (deeper: its first part is a folder right under `dir`)
			sub := e.name[:len(prefix) + slash]
			if sub in seen { continue }
			seen[sub] = true
			append(out, Entry{name = sub, dir = true})
			continue
		}
		if e.name in seen {
			// (a folder named after the one made up for its files: its own date wins)
			if e.dir { for &o in out { if o.name == e.name { o.mtime = e.mtime } } }
			continue
		}
		seen[e.name] = true
		append(out, e)
	}
}

// A file of the archive, whole (`limit`: the most bytes it may have, 0 none).
read :: proc(idx: ^Index, name: string, limit: i64 = 0, allocator := context.allocator) -> (data: []u8, err: Error) {
	e := find(idx, name)
	if e == nil || e.dir { return nil, .Not_Found }
	if limit > 0 && e.size > limit { return nil, .Too_Large }
	switch idx.kind {
	case .Zip:          return zip_read(idx, e^, allocator)
	case .Tar, .Tar_Gz: return tar_read(idx, e^, allocator)
	}
	return nil, .Unsupported
}

// A file of the archive written to `out` (its folders made). A name that would leave the archive (".." in it, an absolute
// path) is refused: the name chooses nothing outside of `out`.
extract :: proc(idx: ^Index, name: string, out: string, limit: i64 = 0) -> Error {
	n := clean_name(name)
	for part in strings.split(n, "/", context.temp_allocator) { if part == ".." { return .Unsafe_Name } }
	if len(n) > 1 && n[1] == ':' { return .Unsafe_Name }
	data, err := read(idx, n, limit, context.temp_allocator)
	if err != .None { return err }
	if slash := max(strings.last_index_byte(out, '/'), strings.last_index_byte(out, '\\')); slash > 0 {
		_ = os.make_directory_all(out[:slash])
	}
	if os.write_entire_file(out, data) != nil { return .Unreadable }
	return .None
}

// A time from its parts (UTC; an archive's own time is often the local one: shown as it is).
@(private)
time_of :: proc(year, month, day, hour, minute, second: int) -> i64 {
	dt, err := datetime.components_to_datetime(i64(year), i8(month), i8(day), i8(hour), i8(minute), i8(second))
	if err != nil { return 0 }
	t, ok := time.datetime_to_time(dt)
	return ok ? time.to_unix_nanoseconds(t) : 0
}

// An octal number of a tar header (spaces and NULs around it).
@(private)
octal :: proc(field: []u8) -> i64 {
	s := strings.trim(string(field), " \x00")
	if len(field) > 0 && field[0] & 0x80 != 0 {
		// (GNU's base-256 for a size past 8 GiB: the bytes after the first, big-endian)
		v: i64
		for b in field[1:] { v = v << 8 | i64(b) }
		return v
	}
	v, _ := strconv.parse_i64_of_base(s, 8)
	return v
}

////////////////////////////////
// zip

@(private = "file") EOCD_SIG     :: 0x06054b50
@(private = "file") EOCD64_LOC   :: 0x07064b50
@(private = "file") EOCD64_SIG   :: 0x06064b50
@(private = "file") CENTRAL_SIG  :: 0x02014b50
@(private = "file") LOCAL_SIG    :: 0x04034b50
@(private = "file") EOCD_MIN     :: 22
@(private = "file") COMMENT_MAX  :: 65535

@(private = "file")
u16le :: proc(b: []u8, at: int) -> u16 { return u16(b[at]) | u16(b[at + 1]) << 8 }
@(private = "file")
u32le :: proc(b: []u8, at: int) -> u32 { return u32(u16le(b, at)) | u32(u16le(b, at + 2)) << 16 }
@(private = "file")
u64le :: proc(b: []u8, at: int) -> u64 { return u64(u32le(b, at)) | u64(u32le(b, at + 4)) << 32 }

// `n` bytes of `f` at `at` (temp memory); nil when they are not all there.
@(private = "file")
read_at :: proc(f: ^os.File, at: i64, n: int) -> []u8 {
	if n < 0 || at < 0 { return nil }
	buf := make([]u8, n, context.temp_allocator)
	got := 0
	for got < n {
		k, err := os.read_at(f, buf[got:], at + i64(got))
		if err != nil || k <= 0 { return nil }
		got += k
	}
	return buf
}

@(private = "file")
zip_index :: proc(idx: ^Index) -> Error {
	f, oerr := os.open(idx.path)
	if oerr != nil { return .Unreadable }
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil || size < EOCD_MIN { return .Not_An_Archive }
	// its end: the last "end of central directory" record, within the comment's reach
	tail_n := int(min(size, EOCD_MIN + COMMENT_MAX))
	tail := read_at(f, size - i64(tail_n), tail_n)
	if tail == nil { return .Unreadable }
	at := -1
	for i := tail_n - EOCD_MIN; i >= 0; i -= 1 {
		if u32le(tail, i) == EOCD_SIG { at = i; break }
	}
	if at < 0 { return .Not_An_Archive }
	count := i64(u16le(tail, at + 10))
	cd_size := i64(u32le(tail, at + 12))
	cd_at := i64(u32le(tail, at + 16))
	if count == 0xFFFF || cd_size == 0xFFFFFFFF || cd_at == 0xFFFFFFFF {
		// ZIP64: its locator just before, and its record where the locator says
		eocd := size - i64(tail_n) + i64(at)
		loc := read_at(f, eocd - 20, 20)
		if loc == nil || u32le(loc, 0) != EOCD64_LOC { return .Bad_Data }
		rec := read_at(f, i64(u64le(loc, 8)), 56)
		if rec == nil || u32le(rec, 0) != EOCD64_SIG { return .Bad_Data }
		count, cd_size, cd_at = i64(u64le(rec, 32)), i64(u64le(rec, 40)), i64(u64le(rec, 48))
	}
	if cd_at + cd_size > size || cd_size > 1 << 31 { return .Bad_Data }
	cd := read_at(f, cd_at, int(cd_size))
	if cd == nil { return .Unreadable }
	p := 0
	for _ in 0 ..< count {
		if p + 46 > len(cd) || u32le(cd, p) != CENTRAL_SIG { return .Bad_Data }
		flags, method := u16le(cd, p + 8), u16le(cd, p + 10)
		dos_time, dos_date := int(u16le(cd, p + 12)), int(u16le(cd, p + 14))
		packed, unpacked := i64(u32le(cd, p + 20)), i64(u32le(cd, p + 24))
		name_n, extra_n, comment_n := int(u16le(cd, p + 28)), int(u16le(cd, p + 30)), int(u16le(cd, p + 32))
		offset := i64(u32le(cd, p + 42))
		if p + 46 + name_n + extra_n + comment_n > len(cd) { return .Bad_Data }
		raw := string(cd[p + 46:][:name_n])
		// ZIP64's sizes and offset, those the record leaves at 0xFFFFFFFF, in that order
		extra := cd[p + 46 + name_n:][:extra_n]
		for x := 0; x + 4 <= len(extra); {
			id, n := u16le(extra, x), int(u16le(extra, x + 2))
			if x + 4 + n > len(extra) { break }
			if id == 0x0001 {
				v := extra[x + 4:][:n]
				k := 0
				if unpacked == 0xFFFFFFFF && k + 8 <= n { unpacked = i64(u64le(v, k)); k += 8 }
				if packed == 0xFFFFFFFF && k + 8 <= n { packed = i64(u64le(v, k)); k += 8 }
				if offset == 0xFFFFFFFF && k + 8 <= n { offset = i64(u64le(v, k)); k += 8 }
			}
			x += 4 + n
		}
		name := clean_name(raw)
		if name != "" {
			append(&idx.entries, Entry{
				name = keep(idx, name), dir = strings.has_suffix(raw, "/") || strings.has_suffix(raw, "\\"),
				size = unpacked, packed = packed, offset = offset, method = method, flags = flags,
				mtime = time_of(1980 + dos_date >> 9, dos_date >> 5 & 15, dos_date & 31, dos_time >> 11, dos_time >> 5 & 63, (dos_time & 31) * 2),
			})
		}
		p += 46 + name_n + extra_n + comment_n
	}
	return .None
}

@(private = "file")
zip_read :: proc(idx: ^Index, e: Entry, allocator := context.allocator) -> (data: []u8, err: Error) {
	if e.flags & 1 != 0 { return nil, .Unsupported }   // (encrypted)
	f, oerr := os.open(idx.path)
	if oerr != nil { return nil, .Unreadable }
	defer os.close(f)
	local := read_at(f, e.offset, 30)
	if local == nil || u32le(local, 0) != LOCAL_SIG { return nil, .Bad_Data }
	start := e.offset + 30 + i64(u16le(local, 26)) + i64(u16le(local, 28))
	if e.packed > 1 << 31 || e.size > 1 << 31 { return nil, .Too_Large }
	packed := read_at(f, start, int(e.packed))
	if packed == nil { return nil, .Bad_Data }
	switch e.method {
	case 0:
		out := make([]u8, len(packed), allocator)
		copy(out, packed)
		return out, .None
	case 8:
		out, ferr := flate.inflate(.Raw, packed, limit = int(max(e.size, 1)), allocator = allocator)
		if ferr != .None { delete(out, allocator); return nil, .Bad_Data }
		return out, .None
	}
	return nil, .Unsupported
}

////////////////////////////////
// tar

@(private = "file") BLOCK :: 512
@(private = "file") READ_CHUNK :: 256 * 1024

// A tar read as a stream of bytes: its headers, and each entry's data handed to `data` (or skipped).
@(private = "file")
Tar_Scan :: struct {
	idx:       ^Index,
	pending:   [dynamic]u8,   // bytes not yet taken (a header's, a long name's)
	at:        i64,           // the stream's position of pending[0]
	skip:      i64,           // data still to pass (the entry's, padded to its block)
	long_name: string,        // GNU's 'L', or pax's path, for the next entry (temp)
	collect:   u8,            // 'L' or 'x': the data being read is the next entry's name, or pax records
	collect_n: i64,
	zeros:     int,           // empty blocks in a row (two: the end)
	ended:     bool,
	// reading one entry back (tar_read): from `want` on, `want_n` bytes into `got`
	want:      i64,
	want_n:    i64,
	got:       [dynamic]u8,
}

@(private = "file")
tar_feed :: proc(s: ^Tar_Scan, data: []u8) -> Error {
	append(&s.pending, ..data)
	p := 0
	defer {
		// (what was taken goes; what is left waits for more)
		copy(s.pending[:], s.pending[p:])
		resize(&s.pending, len(s.pending) - p)
		s.at += i64(p)
	}
	for !s.ended {
		buf := s.pending[p:]
		if s.skip > 0 {
			n := int(min(s.skip, i64(len(buf))))
			if n == 0 { return .None }
			// (the entry read back: its bytes as they pass)
			pos := s.at + i64(p)
			if s.want_n > 0 && pos + i64(n) > s.want && pos < s.want + s.want_n {
				from := max(s.want - pos, 0)
				to := min(s.want + s.want_n - pos, i64(n))
				append(&s.got, ..buf[from:to])
			}
			if s.collect != 0 && s.collect_n > 0 {
				k := int(min(s.collect_n, i64(n)))
				tar_collect(s, buf[:k])
				s.collect_n -= i64(k)
			}
			s.skip -= i64(n)
			p += n
			if s.want_n > 0 && i64(len(s.got)) >= s.want_n { s.ended = true }
			continue
		}
		if len(buf) < BLOCK { return .None }
		h := buf[:BLOCK]
		p += BLOCK
		empty := true
		for b in h { if b != 0 { empty = false; break } }
		if empty {
			s.zeros += 1
			if s.zeros >= 2 { s.ended = true }
			continue
		}
		s.zeros = 0
		// a header: its checksum (the sum of its bytes, the checksum's own as spaces)
		sum: i64
		for b, i in h { sum += (i >= 148 && i < 156) ? 32 : i64(b) }
		if octal(h[148:156]) != sum { return len(s.idx.entries) == 0 && s.at + i64(p) == BLOCK ? .Not_An_Archive : .Bad_Data }
		size := octal(h[124:136])
		padded := (size + BLOCK - 1) / BLOCK * BLOCK
		kind := h[156]
		name := string(h[0:100])
		if z := strings.index_byte(name, 0); z >= 0 { name = name[:z] }
		if string(h[257:262]) == "ustar" {
			prefix := string(h[345:500])
			if z := strings.index_byte(prefix, 0); z >= 0 { prefix = prefix[:z] }
			if prefix != "" { name = strings.concatenate({prefix, "/", name}, context.temp_allocator) }
		}
		switch kind {
		case 'L', 'x':
			// the next entry's name (GNU), or its records (pax: "path=" is its name)
			s.collect, s.collect_n, s.skip = kind, size, padded
			s.long_name = ""
			continue
		case 'g':
			s.skip = padded   // (pax's global records: nothing for a listing)
			continue
		}
		if s.long_name != "" { name = s.long_name; s.long_name = "" }
		clean := clean_name(name)
		if clean != "" && (kind == '0' || kind == 0 || kind == '7' || kind == '5' || kind == '1' || kind == '2') {
			dir := kind == '5' || strings.has_suffix(name, "/")
			append(&s.idx.entries, Entry{
				name = keep(s.idx, clean), dir = dir, size = dir ? 0 : size, packed = size,
				mtime = octal(h[136:148]) * i64(time.Second), offset = s.at + i64(p),
			})
		}
		s.skip = padded
	}
	return .None
}

// The data of a GNU long name or of pax records, as it passes.
@(private = "file")
tar_collect :: proc(s: ^Tar_Scan, data: []u8) {
	text := string(data)
	switch s.collect {
	case 'L':
		if z := strings.index_byte(text, 0); z >= 0 { text = text[:z] }
		s.long_name = strings.concatenate({s.long_name, text}, context.temp_allocator)
	case 'x':
		// records "<length> <key>=<value>\n" (a record cut between two pushes is rare: its block is 512 bytes)
		for line in strings.split_lines(text, context.temp_allocator) {
			sp := strings.index_byte(line, ' ')
			if sp < 0 { continue }
			kv := line[sp + 1:]
			if strings.has_prefix(kv, "path=") { s.long_name = strings.clone(kv[5:], context.temp_allocator) }
		}
	}
	if s.collect_n - i64(len(data)) <= 0 { s.collect = 0 }
}

// Runs the stream of the tar through `s`: the file as it is, or inflated on the way.
@(private = "file")
tar_run :: proc(idx: ^Index, s: ^Tar_Scan) -> Error {
	f, oerr := os.open(idx.path)
	if oerr != nil { return .Unreadable }
	defer os.close(f)
	chunk := make([]u8, READ_CHUNK, context.temp_allocator)
	z: flate.Inflater
	gz := idx.kind == .Tar_Gz
	if gz { flate.inflater_init(&z, .Gzip) }
	defer if gz { flate.inflater_destroy(&z) }
	out := make([dynamic]u8, context.temp_allocator)
	for !s.ended {
		n, rerr := os.read(f, chunk)
		if n <= 0 || rerr != nil { break }
		if gz {
			clear(&out)
			if ferr := flate.inflate_push(&z, chunk[:n], &out); ferr != .None && ferr != .Junk_After_End { return .Bad_Data }
			if err := tar_feed(s, out[:]); err != .None { return err }
		} else {
			if err := tar_feed(s, chunk[:n]); err != .None { return err }
		}
	}
	return .None
}

@(private = "file")
tar_index :: proc(idx: ^Index) -> Error {
	s := Tar_Scan{idx = idx}
	s.pending = make([dynamic]u8, context.temp_allocator)
	err := tar_run(idx, &s)
	if err == .None && len(idx.entries) == 0 && s.at == 0 { return .Not_An_Archive }
	return err
}

@(private = "file")
tar_read :: proc(idx: ^Index, e: Entry, allocator := context.allocator) -> (data: []u8, err: Error) {
	if e.size == 0 { return make([]u8, 0, allocator), .None }
	// (an index of its own: the scan adds the entries it passes, again)
	again: Index
	defer index_destroy(&again)
	again.path, again.kind = idx.path, idx.kind
	s := Tar_Scan{idx = &again, want = e.offset, want_n = e.size}
	s.pending = make([dynamic]u8, context.temp_allocator)
	s.got = make([dynamic]u8, allocator)
	if err = tar_run(idx, &s); err != .None { delete(s.got); return nil, err }
	if i64(len(s.got)) != e.size { delete(s.got); return nil, .Bad_Data }
	return s.got[:], .None
}
