package ui

// The local source's thumbnails (src/md/features/thumbnails.md), on the chores: a picture gt:image reads is decoded and
// reduced (a large one read from the system's cache first, and kept there once made); any other file gets the
// system's thumbnail (its cache, else its thumbnailer).

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

// Whether gt:image reads a file of this name (by its extension).
@(private = "file")
local_thumb_decodes :: proc(name: string) -> bool {
	switch file_extension(name) {
	case "png", "jpg", "jpeg", "bmp", "webp", "gif": return true
	}
	return false
}

@(private = "file")
local_thumb_work :: proc(d: rawptr) {
	j := (^Local_Thumb)(d)
	a := runtime.heap_allocator()
	info, err := os.stat(j.path, a)
	if err != nil { return }
	size := info.size
	is_file := info.type == .Regular
	os.file_info_delete(info, a)
	if !is_file || size <= 0 { return }
	if !local_thumb_decodes(j.path) || size > FILE_THUMB_DECODE_BYTES {
		local_thumb_system(j, false)
		return
	}
	// (a large picture: decoding it again costs more than reading the system's copy)
	large := size > FILE_THUMB_CACHED_BYTES
	if large && local_thumb_system(j, true) { return }
	bytes, read_err := os.read_entire_file(j.path, a)
	if read_err != nil { return }
	defer delete(bytes, a)
	pic, _, ok := img.decode(bytes, a)
	if !ok { return }
	defer delete(pic.pixels, a)
	// at most `side` on its longer side, its ratio kept (a smaller one as it is)
	w, h := pic.width, pic.height
	if max(w, h) > j.side {
		k := f32(j.side) / f32(max(w, h))
		w, h = max(1, int(f32(w) * k + 0.5)), max(1, int(f32(h) * k + 0.5))
		small := img.resize(pic, w, h, .Box, a)
		j.rgba, j.width, j.height = small.pixels, small.width, small.height
	} else {
		j.rgba = make([]u8, len(pic.pixels), a)
		copy(j.rgba, pic.pixels)
		j.width, j.height = w, h
	}
	if large { _ = desktop.thumbnail_store(j.path, j.rgba, j.width, j.height) }
}

// The system's thumbnail of the job's file: from its cache only (`cached`), or made by its thumbnailer on a miss (this
// chore waits for it). False: it has none.
@(private = "file")
local_thumb_system :: proc(j: ^Local_Thumb, cached: bool) -> bool {
	a := runtime.heap_allocator()
	th: desktop.Thumbnail
	ok: bool
	if cached {
		th, ok = desktop.thumbnail_cached(j.path, j.side, a)
	} else {
		th, ok = desktop.thumbnail(j.path, j.side, a)
	}
	if !ok { return false }
	j.rgba, j.width, j.height = th.rgba, th.size.x, th.size.y
	return true
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
