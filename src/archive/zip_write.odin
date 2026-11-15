package tk_archive

// A zip written file by file. The writer may start after bytes that are already in the file (a program's executable):
// the offsets it records are the file's own, so the whole file opens as a zip (open_as(path, .Zip)) and the program
// that carries it reads its own files. That is how a self-installing bundle ships many programs as one download.
//
//	w: archive.Zip_Writer
//	archive.zip_begin(&w, "build/bundle", after = "build/host")   // the host's bytes first ("": a zip alone)
//	archive.zip_add(&w, "papier/papier", data, mode = 0o755)
//	err := archive.zip_end(&w)
//
// Each file is deflated unless that makes it larger (then stored). Sizes and offsets stay under 4 GiB (no ZIP64 is
// written): past that, Too_Large.

import "core:hash"
import "core:os"
import "core:time"
import flate "../flate"

Zip_Writer :: struct {
	f:       ^os.File,
	at:      i64,            // where the next local header goes
	central: [dynamic]u8,    // the central directory, built as the files come
	count:   int,
	err:     Error,          // the first error: every later call does nothing and zip_end returns it
}

@(private = "file") LIMIT :: i64(0xFFFFFFFF)

@(private = "file")
put16 :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v), u8(v >> 8)) }
@(private = "file")
put32 :: proc(b: ^[dynamic]u8, v: i64) { put16(b, int(v)); put16(b, int(v >> 16)) }

// Opens `path` for writing (made or emptied). `after`: a file whose bytes come first, copied as they are ("": none).
zip_begin :: proc(w: ^Zip_Writer, path: string, after := "") -> Error {
	w^ = {}
	w.central = make([dynamic]u8)
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if err != nil { w.err = .Unreadable; return w.err }
	w.f = f
	if after != "" {
		head, rerr := os.read_entire_file(after, context.allocator)
		if rerr != nil { w.err = .Unreadable; return w.err }
		defer delete(head)
		if !write_all(w, head) { return w.err }
	}
	return .None
}

// Adds a file named `name` ('/' between its parts) holding `data`. `mode`: its Unix permissions (0o755 for a program).
zip_add :: proc(w: ^Zip_Writer, name: string, data: []u8, mode: u32 = 0o644) -> Error {
	if w.err != .None { return w.err }
	n := clean_name(name)
	if !safe_name(n) { w.err = .Unsafe_Name; return w.err }
	packed := flate.deflate(.Raw, data)
	defer delete(packed)
	method := 8
	body := packed
	if len(packed) >= len(data) { method, body = 0, data }   // (already compressed: stored costs nothing to read)
	if i64(len(data)) > LIMIT || i64(len(body)) > LIMIT || w.at > LIMIT { w.err = .Too_Large; return w.err }
	crc := hash.crc32(data)
	dos_time, dos_date := dos_now()

	local := make([dynamic]u8, 0, 30 + len(n), context.temp_allocator)
	put32(&local, 0x04034b50); put16(&local, 20); put16(&local, 0x0800); put16(&local, method)   // (bit 11: UTF-8 name)
	put16(&local, dos_time); put16(&local, dos_date)
	put32(&local, i64(crc)); put32(&local, i64(len(body))); put32(&local, i64(len(data)))
	put16(&local, len(n)); put16(&local, 0)
	append(&local, ..transmute([]u8)n)
	header_at := w.at
	if !write_all(w, local[:]) || !write_all(w, body) { return w.err }

	c := &w.central
	put32(c, 0x02014b50); put16(c, 3 << 8 | 20); put16(c, 20); put16(c, 0x0800); put16(c, method)   // (made by Unix: the mode below is read)
	put16(c, dos_time); put16(c, dos_date)
	put32(c, i64(crc)); put32(c, i64(len(body))); put32(c, i64(len(data)))
	put16(c, len(n)); put16(c, 0); put16(c, 0); put16(c, 0); put16(c, 0)
	put32(c, i64(0o100000 | mode) << 16)   // (a regular file and its permissions, as Info-ZIP keeps them)
	put32(c, header_at)
	append(c, ..transmute([]u8)n)
	w.count += 1
	return .None
}

// Writes the central directory and its end, and closes the file. Returns the first error of the whole writing.
zip_end :: proc(w: ^Zip_Writer) -> Error {
	defer {
		delete(w.central)
		if w.f != nil { os.close(w.f) }
		w.f = nil
	}
	if w.err != .None { return w.err }
	if w.count > 0xFFFF { w.err = .Too_Large; return w.err }
	cd_at := w.at
	if !write_all(w, w.central[:]) { return w.err }
	end := make([dynamic]u8, 0, 22, context.temp_allocator)
	put32(&end, 0x06054b50); put16(&end, 0); put16(&end, 0); put16(&end, w.count); put16(&end, w.count)
	put32(&end, i64(len(w.central))); put32(&end, cd_at); put16(&end, 0)
	if !write_all(w, end[:]) { return w.err }
	return .None
}

@(private = "file")
write_all :: proc(w: ^Zip_Writer, b: []u8) -> bool {
	if len(b) == 0 { return true }
	n, err := os.write(w.f, b)
	if err != nil || n != len(b) { w.err = .Unreadable; return false }
	w.at += i64(n)
	return true
}

// Now as a zip keeps it: DOS time and date, UTC.
@(private = "file")
dos_now :: proc() -> (dos_time, dos_date: int) {
	y, mo, d := time.date(time.now())
	h, mi, s := time.clock(time.now())
	return h << 11 | mi << 5 | s / 2, (max(y, 1980) - 1980) << 9 | int(mo) << 5 | d
}
