#+build linux
package tk_desktop

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../png"

// The test's own data directory (a MIME database: PDF and text; a thumbnailer of PDF files that copies a red picture of
// 300 x 200 to its output) and cache, under a temporary folder named `tag` (tests run side by side). Never the person's.
@(private = "file")
thumbs_make :: proc(t: ^testing.T, tag: string) -> (roots: Xdg_Roots, cache, base: string) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	base = fmt.tprintf("%s/tk_thumbs_%d_%s", tmp, os.get_pid(), tag)
	_ = os.remove_all(base)
	_ = os.make_directory_all(fmt.tprintf("%s/data/mime", base))
	_ = os.make_directory_all(fmt.tprintf("%s/data/thumbnailers", base))
	write :: proc(t: ^testing.T, path: string, data: []u8) { testing.expect(t, os.write_entire_file(path, data) == nil, path) }
	write(t, fmt.tprintf("%s/data/mime/globs2", base), transmute([]u8)string("50:application/pdf:*.pdf\n50:text/plain:*.txt\n"))
	write(t, fmt.tprintf("%s/page.png", base), red_png(300, 200))
	page := fmt.tprintf("%s/page.png", base)
	write(t, fmt.tprintf("%s/data/thumbnailers/fake.thumbnailer", base), transmute([]u8)fmt.tprintf(
		"[Thumbnailer Entry]\nTryExec=cp\nExec=cp %s %%o\nMimeType=application/pdf;\n", escape_value(quote_exec_argument(page))))
	write(t, fmt.tprintf("%s/doc.pdf", base), transmute([]u8)string("%PDF-1.4 not really\n"))
	write(t, fmt.tprintf("%s/notes.txt", base), transmute([]u8)string("notes\n"))
	d := make([]string, 1, context.temp_allocator)
	d[0] = fmt.tprintf("%s/data", base)
	return {data = d}, fmt.tprintf("%s/cache", base), base
}

@(private = "file")
red_png :: proc(w, h: int) -> []u8 {
	px := make([]u8, w * h * 4, context.temp_allocator)
	for i := 0; i < len(px); i += 4 { px[i], px[i + 3] = 255, 255 }
	return png.encode(px, w, h, .Fast, context.temp_allocator)
}

// A file's URI and the name of its thumbnails as the standard and GLib make them (the standard's own example first).
@(test)
the_name_of_a_thumbnail :: proc(t: ^testing.T) {
	testing.expect_value(t, thumbnail_name(thumbnail_uri("/home/jens/photos/me.png")), "c6ee772d9e49320e97ec29a7eb5b1697.png")
	testing.expect_value(t, thumbnail_uri("/tmp/a b#c/é!$&()=@.pdf"), "file:///tmp/a%20b%23c/%C3%A9!$&()=@.pdf")
	testing.expect_value(t, thumbnail_folder(1), 0)
	testing.expect_value(t, thumbnail_folder(128), 0)
	testing.expect_value(t, thumbnail_folder(129), 1)
	testing.expect_value(t, thumbnail_folder(512), 2)
	testing.expect_value(t, thumbnail_folder(4096), 3)
}

// A thumbnailer's Exec line for one file, and the lines refused.
@(test)
a_thumbnailer_command :: proc(t: ^testing.T) {
	args, ok := thumbnailer_command(`tool -s %s %u "100%%" %i %o`, "/a b.pdf", "file:///a%20b.pdf", "/c/out.png", 256)
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(args, "|", context.temp_allocator), "tool|-s|256|file:///a%20b.pdf|100%|/a b.pdf|/c/out.png")
	for bad in ([]string{`sh -c "tool %i"`, "tool %f", "tool 100%", ""}) {
		_, refused := thumbnailer_command(bad, "/a", "file:///a", "/o", 128)
		testing.expectf(t, !refused, "%q is refused", bad)
	}
}

// End to end: nothing cached; the thumbnailer of the type makes one, kept in the cache with the standard's keys and read
// from there after; a file changed is not given its old one; a thumbnailer that fails leaves a failure that keeps it
// from being run again for that file; a type with no thumbnailer has none.
@(test)
a_thumbnail_made_cached_and_failed :: proc(t: ^testing.T) {
	if _, found := find_on_path("cp"); !found {
		fmt.println("thumbnails: cp is not on the PATH: the end-to-end check is skipped")
		return
	}
	roots, cache, base := thumbs_make(t, "made")
	defer os.remove_all(base)
	pdf := fmt.tprintf("%s/doc.pdf", base)
	src, sok := thumbnail_source(pdf)
	testing.expect(t, sok, "the PDF is a file")

	_, cached := thumbnail_in(roots, cache, pdf, 128, .Cached, context.allocator)
	testing.expect(t, !cached, "nothing cached yet")
	th, ok := thumbnail_in(roots, cache, pdf, 128, .Make, context.allocator)
	defer thumbnail_destroy(&th)
	testing.expect(t, ok, "made by the thumbnailer")
	testing.expect_value(t, th.size, [2]int{128, 85})
	if ok { testing.expectf(t, th.rgba[0] > 250 && th.rgba[1] < 5 && th.rgba[3] > 250, "red: %v", th.rgba[:4]) }

	// in the cache, with its keys
	kept, rerr := os.read_entire_file(fmt.tprintf("%s/thumbnails/normal/%s", cache, src.name), context.temp_allocator)
	testing.expect(t, rerr == nil, "in the normal folder")
	testing.expect(t, thumbnail_valid(kept, src.uri, src.mtime), "its URI and date")
	keys, _ := png.texts(kept)
	found_software, found_size := false, false
	for k in keys {
		if k.keyword == "Software" { found_software = k.text == THUMBNAIL_SOFTWARE }
		if k.keyword == "Thumb::Size" { found_size = k.text == src.size }
	}
	testing.expect(t, found_software && found_size, "Software and Thumb::Size")

	// read from the cache: the thumbnailer cannot run any more (its picture is gone)
	testing.expect(t, os.remove(fmt.tprintf("%s/page.png", base)) == nil)
	again, aok := thumbnail_in(roots, cache, pdf, 100, .Cached, context.allocator)
	defer thumbnail_destroy(&again)
	testing.expect(t, aok, "from the cache")
	testing.expect_value(t, again.size, [2]int{100, 66})   // (reduced to the size asked)

	// the file changed: its old thumbnail is not it; the thumbnailer fails: a failure is kept
	later := time.time_add(time.now(), 10 * time.Second)
	testing.expect(t, os.change_times(pdf, later, later) == nil)
	_, stale := thumbnail_in(roots, cache, pdf, 128, .Cached, context.allocator)
	testing.expect(t, !stale, "a changed file's old thumbnail is not given")
	_, failed := thumbnail_in(roots, cache, pdf, 128, .Make, context.allocator)
	testing.expect(t, !failed, "the thumbnailer failed")
	now, _ := thumbnail_source(pdf)
	fail, ferr := os.read_entire_file(fmt.tprintf("%s/thumbnails/fail/%s/%s", cache, THUMBNAIL_SOFTWARE, now.name), context.temp_allocator)
	testing.expect(t, ferr == nil && thumbnail_valid(fail, now.uri, now.mtime), "the failure is kept")
	// (the thumbnailer could work again: the failure still stops it for this file and date)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/page.png", base), red_png(300, 200)) == nil)
	_, retried := thumbnail_in(roots, cache, pdf, 128, .Make, context.allocator)
	testing.expect(t, !retried, "not run again")

	// a type with no thumbnailer: none, and no failure written
	txt := fmt.tprintf("%s/notes.txt", base)
	_, none := thumbnail_in(roots, cache, txt, 128, .Make, context.allocator)
	testing.expect(t, !none, "no thumbnailer for text")
	ts, _ := thumbnail_source(txt)
	testing.expect(t, !os.exists(fmt.tprintf("%s/thumbnails/fail/%s/%s", cache, THUMBNAIL_SOFTWARE, ts.name)), "no failure for a type with no thumbnailer")
}

// A program's own picture kept in the cache: in the largest folder it fills, reduced to it, then given back.
@(test)
a_thumbnail_stored :: proc(t: ^testing.T) {
	_, cache, base := thumbs_make(t, "stored")
	defer os.remove_all(base)
	txt := fmt.tprintf("%s/notes.txt", base)
	px := make([]u8, 600 * 300 * 4, context.temp_allocator)
	for i := 0; i < len(px); i += 4 { px[i + 1], px[i + 3] = 255, 255 }
	testing.expect(t, thumbnail_store_in(cache, txt, px, 600, 300), "stored")
	src, _ := thumbnail_source(txt)
	testing.expect(t, os.exists(fmt.tprintf("%s/thumbnails/x-large/%s", cache, src.name)), "in x-large (512 pixels)")
	th, ok := thumbnail_in({}, cache, txt, 256, .Cached, context.allocator)
	defer thumbnail_destroy(&th)
	testing.expect(t, ok, "read back from the larger folder")
	testing.expect_value(t, th.size, [2]int{256, 128})
	if ok { testing.expectf(t, th.rgba[1] > 250, "green: %v", th.rgba[:4]) }
	testing.expect(t, !thumbnail_store_in(cache, "relative/path.txt", px, 600, 300), "not an absolute path")
}

// The thumbnailers are read once, and again when their folder changes; one whose program is not installed is none.
@(test)
the_thumbnailers_are_cached :: proc(t: ^testing.T) {
	roots, _, base := thumbs_make(t, "cache")
	defer os.remove_all(base)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/data/thumbnailers/missing.thumbnailer", base),
		"[Thumbnailer Entry]\nTryExec=/nonexistent/tool\nExec=/nonexistent/tool %i %o\nMimeType=text/plain;\n") == nil)
	c: Thumbnailer_Cache
	defer virtual.arena_destroy(&c.arena)
	cp_here := false
	if _, found := find_on_path("cp"); found { cp_here = true }
	testing.expect_value(t, len(thumbnailers_get(&c, roots)), cp_here ? 1 : 0)
	_ = thumbnailers_get(&c, roots)
	testing.expect_value(t, c.reads, 1)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/data/thumbnailers/abs.thumbnailer", base),
		fmt.tprintf("[Thumbnailer Entry]\nExec=%s %%i %%o\nMimeType=text/plain;\n", escape_value(quote_exec_argument(os.args[0])))) == nil)
	list := thumbnailers_get(&c, roots)
	testing.expect_value(t, c.reads, 2)
	testing.expect_value(t, len(list), cp_here ? 2 : 1)
}
