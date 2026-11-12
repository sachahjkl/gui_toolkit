package tk_png

// The tEXt chunks of a PNG file (PNG specification, 11.3.4.3): a keyword and a text, both Latin-1 with no NUL, read and
// written without touching the pixels. The thumbnails of the freedesktop.org cache carry their file's URI and date there.

import "core:bytes"
import "core:encoding/endian"
import "core:hash"
import "core:strings"

// One tEXt chunk.
Text :: struct {
	keyword, text: string,
}

@(private = "file") MAX_KEYWORD :: 79   // the specification's limit
@(private = "file") CHUNK_FRAME :: 12   // a chunk's length, type and CRC

// The tEXt chunks of a PNG file, in its order, without decoding its pixels; their strings are slices of `data`. ok is
// false when `data` is not a PNG file whose chunks hold together up to IEND (each length and CRC checked).
texts :: proc(data: []u8, allocator := context.temp_allocator) -> (out: []Text, ok: bool) {
	if !signed(data) { return }
	list := make([dynamic]Text, allocator)
	at := len(SIGNATURE)
	for {
		kind, body, _, found := chunk_next(data, &at)
		if !found { break }
		switch kind {
		case "tEXt":
			if z := bytes.index_byte(body, 0); z >= 1 && z <= MAX_KEYWORD { append(&list, Text{string(body[:z]), string(body[z + 1:])}) }
		case "IEND":
			return list[:], true
		}
	}
	delete(list)
	return nil, false
}

// `data`, a PNG file, with `add` as tEXt chunks right after its IHDR; a tEXt it had of the same keyword is left out (a
// keyword is said once). nil when `data` is not a whole PNG file (as `texts` checks it), or when a keyword is empty,
// longer than 79 bytes, or a keyword or a text holds a NUL.
with_texts :: proc(data: []u8, add: []Text, allocator := context.allocator) -> []u8 {
	extra := 0
	for x in add {
		if len(x.keyword) < 1 || len(x.keyword) > MAX_KEYWORD || strings.index_byte(x.keyword, 0) >= 0 || strings.index_byte(x.text, 0) >= 0 { return nil }
		extra += CHUNK_FRAME + len(x.keyword) + 1 + len(x.text)
	}
	if _, ok := texts(data); !ok { return nil }
	buf := make([dynamic]u8, 0, len(data) + extra, allocator)
	signature := SIGNATURE
	append(&buf, ..signature[:])
	at := len(signature)
	first := true
	for {
		kind, body, whole, found := chunk_next(data, &at)
		if !found { break }
		replaced := false
		if kind == "tEXt" {
			if z := bytes.index_byte(body, 0); z >= 0 {
				for x in add { if x.keyword == string(body[:z]) { replaced = true } }
			}
		}
		if !replaced { append(&buf, ..whole) }
		if first {
			// (after IHDR, which comes first: a reader that stops at IDAT still finds them)
			first = false
			for x in add {
				t := make([]u8, len(x.keyword) + 1 + len(x.text), context.temp_allocator)
				copy(t, x.keyword)
				copy(t[len(x.keyword) + 1:], x.text)
				chunk(&buf, "tEXt", t)
			}
		}
		if kind == "IEND" { break }
	}
	return buf[:]
}

@(private = "file")
signed :: proc(data: []u8) -> bool {
	signature := SIGNATURE
	return len(data) >= len(signature) && string(data[:len(signature)]) == string(signature[:])
}

// The chunk at `at` (moved past it): its type, its data, and all its bytes. Not found: the file ends, is cut short, or the
// chunk's CRC is wrong.
@(private = "file")
chunk_next :: proc(data: []u8, at: ^int) -> (kind: string, body, whole: []u8, found: bool) {
	if at^ + CHUNK_FRAME > len(data) { return }
	n, _ := endian.get_u32(data[at^:], .Big)
	if u64(n) > u64(len(data) - at^ - CHUNK_FRAME) { return }
	whole = data[at^:][:CHUNK_FRAME + int(n)]
	crc, _ := endian.get_u32(whole[8 + int(n):], .Big)
	if hash.crc32(whole[4:8 + int(n)]) != crc { return }
	at^ += len(whole)
	return string(whole[4:8]), whole[8:][:int(n)], whole, true
}
