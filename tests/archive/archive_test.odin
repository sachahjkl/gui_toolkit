// The archive package (src/archive): a zip's index (a stored entry, a deflated one, a folder named only by its file),
// a tar's and a gzipped tar's (a GNU long name), their files read back, a name that would leave its folder refused.
//   odin test tests/archive -vet
package archive_test

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import archive "../../src/archive"
import flate "../../src/flate"
import "../../src/testkit"

@(private = "file")
le16 :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v), u8(v >> 8)) }
@(private = "file")
le32 :: proc(b: ^[dynamic]u8, v: int) { le16(b, v); le16(b, v >> 16) }

@(private = "file")
Zip_File :: struct { name: string, data: string, deflate: bool }

// A zip of `files`, as a zip writer makes one: local headers and data, the central directory, its end.
@(private = "file")
make_zip :: proc(files: []Zip_File) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	central := make([dynamic]u8, context.temp_allocator)
	for f in files {
		packed := transmute([]u8)f.data
		if f.deflate { packed = flate.deflate(.Raw, transmute([]u8)f.data, context.temp_allocator) }
		at := len(b)
		le32(&b, 0x04034b50); le16(&b, 20); le16(&b, 0); le16(&b, f.deflate ? 8 : 0)
		le16(&b, 0); le16(&b, 0x5a21)   // (time, date: 2025-01-01)
		le32(&b, 0); le32(&b, len(packed)); le32(&b, len(f.data)); le16(&b, len(f.name)); le16(&b, 0)
		append(&b, ..transmute([]u8)f.name)
		append(&b, ..packed)
		le32(&central, 0x02014b50); le16(&central, 20); le16(&central, 20); le16(&central, 0); le16(&central, f.deflate ? 8 : 0)
		le16(&central, 0); le16(&central, 0x5a21)
		le32(&central, 0); le32(&central, len(packed)); le32(&central, len(f.data)); le16(&central, len(f.name)); le16(&central, 0); le16(&central, 0)
		le16(&central, 0); le16(&central, 0); le32(&central, 0); le32(&central, at)
		append(&central, ..transmute([]u8)f.name)
	}
	cd_at := len(b)
	append(&b, ..central[:])
	le32(&b, 0x06054b50); le16(&b, 0); le16(&b, 0); le16(&b, len(files)); le16(&b, len(files))
	le32(&b, len(central)); le32(&b, cd_at); le16(&b, 0)
	return b[:]
}

// A tar header block (ustar) for `name`, of `size` bytes, of `kind`.
@(private = "file")
tar_header :: proc(b: ^[dynamic]u8, name: string, size: int, kind: u8) {
	h: [512]u8
	copy(h[0:100], name)
	copy(h[100:108], "0000644\x00")
	copy(h[124:136], fmt.tprintf("%011o\x00", size))
	copy(h[136:148], fmt.tprintf("%011o\x00", 1735689600))   // (2025-01-01)
	h[156] = kind
	copy(h[257:263], "ustar\x00")
	copy(h[263:265], "00")
	for i in 148 ..< 156 { h[i] = ' ' }
	sum := 0
	for x in h { sum += int(x) }
	copy(h[148:156], fmt.tprintf("%06o\x00 ", sum))
	append(b, ..h[:])
}

@(private = "file")
tar_data :: proc(b: ^[dynamic]u8, data: string) {
	append(b, ..transmute([]u8)data)
	for len(b) % 512 != 0 { append(b, 0) }
}

@(private = "file")
LONG :: "a folder with a name longer than a hundred letters, as GNU tar writes it in an entry of its own before the file/notes.txt"

@(private = "file")
make_tar :: proc() -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	tar_header(&b, "x/", 0, '5')
	tar_header(&b, "x/c.txt", 4, '0'); tar_data(&b, "tar!")
	tar_header(&b, "././@LongLink", len(LONG) + 1, 'L'); tar_data(&b, strings.concatenate({LONG, "\x00"}, context.temp_allocator))
	tar_header(&b, "short", 5, '0'); tar_data(&b, "long!")
	for _ in 0 ..< 1024 { append(&b, 0) }
	return b[:]
}

@(private = "file")
names :: proc(list: []archive.Entry) -> string {
	n := make([dynamic]string, context.temp_allocator)
	for e in list { append(&n, e.dir ? strings.concatenate({e.name, "/"}, context.temp_allocator) : e.name) }
	slice.sort(n[:])
	return strings.join(n[:], " ", context.temp_allocator)
}

@(test)
a_zip_is_listed_and_read :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	path := fmt.tprintf("%s/a.zip", dir)
	files := []Zip_File{{"a.txt", "hello", false}, {"dir/b.txt", strings.repeat("deflated ", 50, context.temp_allocator), true}}
	testing.expect(t, os.write_entire_file(path, make_zip(files)) == nil)
	idx, err := archive.open(path)
	defer archive.index_destroy(&idx)
	testing.expect_value(t, err, archive.Error.None)
	top := make([dynamic]archive.Entry, context.temp_allocator)
	archive.children(&idx, "", &top)
	testing.expect_value(t, names(top[:]), "a.txt dir/")
	inside := make([dynamic]archive.Entry, context.temp_allocator)
	archive.children(&idx, "dir", &inside)
	testing.expect_value(t, names(inside[:]), "dir/b.txt")
	a, aerr := archive.read(&idx, "a.txt", allocator = context.temp_allocator)
	testing.expect(t, aerr == .None && string(a) == "hello", "stored")
	b, berr := archive.read(&idx, "dir/b.txt", allocator = context.temp_allocator)
	testing.expect(t, berr == .None && string(b) == files[1].data, "deflated")
	testing.expect(t, inside[0].mtime > 0, "its date")
	out := fmt.tprintf("%s/out/b.txt", dir)
	testing.expect_value(t, archive.extract(&idx, "dir/b.txt", out), archive.Error.None)
	got, _ := os.read_entire_file(out, context.temp_allocator)
	testing.expect_value(t, string(got), files[1].data)
	_, nerr := archive.read(&idx, "nope.txt")
	testing.expect_value(t, nerr, archive.Error.Not_Found)
}

@(test)
a_tar_and_a_gzipped_tar_are_listed_and_read :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	plain := make_tar()
	for name in ([]string{"b.tar", "b.tar.gz"}) {
		path := fmt.tprintf("%s/%s", dir, name)
		data := strings.has_suffix(name, ".gz") ? flate.deflate(.Gzip, plain, context.temp_allocator) : plain
		testing.expect(t, os.write_entire_file(path, data) == nil)
		idx, err := archive.open(path)
		defer archive.index_destroy(&idx)
		testing.expect_value(t, err, archive.Error.None)
		top := make([dynamic]archive.Entry, context.temp_allocator)
		archive.children(&idx, "", &top)
		testing.expectf(t, names(top[:]) == "a folder with a name longer than a hundred letters, as GNU tar writes it in an entry of its own before the file/ x/", "%s: %s", name, names(top[:]))
		c, cerr := archive.read(&idx, "x/c.txt", allocator = context.temp_allocator)
		testing.expectf(t, cerr == .None && string(c) == "tar!", "%s: %v %q", name, cerr, string(c))
		l, lerr := archive.read(&idx, LONG, allocator = context.temp_allocator)
		testing.expectf(t, lerr == .None && string(l) == "long!", "%s: the long name: %v", name, lerr)
	}
}

@(test)
a_name_out_of_its_folder_is_refused :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	path := fmt.tprintf("%s/evil.zip", dir)
	testing.expect(t, os.write_entire_file(path, make_zip({{"../evil.txt", "no", false}})) == nil)
	idx, _ := archive.open(path)
	defer archive.index_destroy(&idx)
	testing.expect_value(t, archive.extract(&idx, "../evil.txt", fmt.tprintf("%s/out/evil.txt", dir)), archive.Error.Unsafe_Name)
	_, kerr := archive.open(fmt.tprintf("%s/not.txt", dir))
	testing.expect_value(t, kerr, archive.Error.Not_An_Archive)
}
