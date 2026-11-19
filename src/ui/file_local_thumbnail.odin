package ui

// The local source's thumbnails (src/md/features/thumbnails.md), on the chores: a picture gt:image reads is decoded and
// reduced (a large one read from the system's cache first, and kept there once made); any other file, or a picture it
// fails to decode, gets the system's thumbnail (its cache, else its thumbnailer). file_thumbnail_make is that work,
// public: a program with workers of its own makes its thumbnails by the same rules.

import "base:runtime"
import "core:os"
import "core:strings"
import desktop "../desktop"
import img "../image"

// A larger picture is not decoded here: the system's thumbnail, if it has one.
FILE_THUMB_DECODE_BYTES :: 64 << 20
// A larger picture's thumbnail is read from the system's cache first, and kept there once decoded.
FILE_THUMB_CACHED_BYTES :: 2 << 20

// One ask, carried to the chores and back.
@(private = "file")
Local_Thumb :: struct {
	reply:  File_Reply,
	path:   string,   // (heap)
	side:   int,
	rgba:   []u8,     // (heap) the answer
	width:  int,
	height: int,
}

@(private)
local_thumbnail :: proc(src: ^File_Source, path: string, px: int, reply: File_Reply) {
	a := runtime.heap_allocator()
	j := new(Local_Thumb, a)
	j^ = {reply = reply, path = strings.clone(path, a), side = max(px, 1)}
	task(reply.state, local_thumb_work, local_thumb_done, j, local_thumb_lost)
}

// Whether gt:image reads a file of this name (by its extension): a program asks it before it reads a file it means to
// decode itself (classeur's inspector). (A WebP in a program built without IMAGE_WEBP is listed too: its decode fails
// and the system is asked, as for a damaged file.)
file_thumbnail_decodes :: proc(name: string) -> bool {
	switch file_extension(name) {
	case "png", "jpg", "jpeg", "bmp", "webp", "gif": return true
	}
	return false
}

// A thumbnail made by file_thumbnail_make: straight RGBA8, row by row, `width` by `height`; `picture`, the size of the
// picture it was made from ({0, 0}: the system made it and does not say, or its cache gave it).
File_Thumbnail :: struct {
	rgba:          []u8,
	width, height: int,
	picture:       [2]int,
}

// The thumbnail of the file at `path`, at most `side` pixels on its longer side, its ratio kept, in `allocator`.
// `system` false: neither the system's cache nor its thumbnailer (a test, a program headless: the person's cache left
// alone), so only what gt:image decodes. Disk work, and the thumbnailer may take seconds: never on the interface's
// thread.
file_thumbnail_make :: proc(path: string, side: int, system: bool, allocator := context.allocator) -> (t: File_Thumbnail, ok: bool) {
	px := max(side, 1)
	// (the heap's, freed here: a worker's temporary memory is not freed between its jobs)
	a := runtime.heap_allocator()
	info, err := os.stat(path, a)
	if err != nil { return }
	size := info.size
	is_file := info.type == .Regular
	os.file_info_delete(info, a)
	if !is_file || size <= 0 { return }
	if !file_thumbnail_decodes(path) || size > FILE_THUMB_DECODE_BYTES {
		if system { return file_thumb_system(path, px, false, allocator) }
		return
	}
	// (a large picture: decoding it again costs more than reading the system's copy)
	large := system && size > FILE_THUMB_CACHED_BYTES
	if large {
		t, ok = file_thumb_system(path, px, true, allocator)
		if ok { return }
	}
	bytes, read_err := os.read_entire_file(path, a)
	if read_err != nil { return }
	defer delete(bytes, a)
	pic, _, decoded := img.decode(bytes, a)
	if !decoded {
		// (a WebP in a program built without its decoder, a picture gt:image cannot read: the system may)
		if system { return file_thumb_system(path, px, false, allocator) }
		return
	}
	defer delete(pic.pixels, a)
	t.picture = {pic.width, pic.height}
	w, h := pic.width, pic.height
	if max(w, h) > px {
		k := f32(px) / f32(max(w, h))
		w, h = max(1, int(f32(w) * k + 0.5)), max(1, int(f32(h) * k + 0.5))
		small := img.resize(pic, w, h, .Box, allocator)
		t.rgba, t.width, t.height = small.pixels, small.width, small.height
	} else {
		t.rgba = make([]u8, len(pic.pixels), allocator)
		copy(t.rgba, pic.pixels)
		t.width, t.height = w, h
	}
	if large { _ = desktop.thumbnail_store(path, t.rgba, t.width, t.height) }
	return t, true
}

// The system's thumbnail of `path`: from its cache only (`cached`), or made by its thumbnailer on a miss (the caller's
// thread waits for it). The picture's own size is not known there.
@(private = "file")
file_thumb_system :: proc(path: string, side: int, cached: bool, allocator: runtime.Allocator) -> (t: File_Thumbnail, ok: bool) {
	th: desktop.Thumbnail
	if cached {
		th, ok = desktop.thumbnail_cached(path, side, allocator)
	} else {
		th, ok = desktop.thumbnail(path, side, allocator)
	}
	if !ok { return }
	return {rgba = th.rgba, width = th.size.x, height = th.size.y}, true
}

@(private = "file")
local_thumb_work :: proc(d: rawptr) {
	j := (^Local_Thumb)(d)
	t, ok := file_thumbnail_make(j.path, j.side, true, runtime.heap_allocator())
	if ok { j.rgba, j.width, j.height = t.rgba, t.width, t.height }
}

// The answer, on the interface's thread: the pixels, or none (the card keeps its icon).
@(private = "file")
local_thumb_done :: proc(d: rawptr, _: u64) {
	j := (^Local_Thumb)(d)
	if j.rgba != nil {
		file_reply_thumbnail(j.reply, j.rgba, j.width, j.height)
	} else {
		file_reply_failed(j.reply, "")
	}
	local_thumb_free(j)
}

// The State went before the answer: nothing to answer, the memory freed.
@(private = "file")
local_thumb_lost :: proc(d: rawptr) { local_thumb_free((^Local_Thumb)(d)) }

@(private = "file")
local_thumb_free :: proc(j: ^Local_Thumb) {
	a := runtime.heap_allocator()
	delete(j.path, a)
	delete(j.rgba, a)
	free(j, a)
}
