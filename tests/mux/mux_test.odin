// The MP4 and WebM muxers, read back by a small box reader and a small EBML reader of their own (below), with
// hand-written H.264 access units (an SPS and a PPS made bit by bit, slices of a few bytes: the muxer does not decode),
// VP9 frames, Opus packets and ADTS frames: the boxes' order and sizes, the sample tables (stts, stss, stsc, stsz,
// stco) against the packets, the avcC against the SPS (cropping, the High profile's fields), B-frames (ctts), AAC
// from ADTS (esds, roll groups), fast start in memory and at the end (a stream), fragments (moof, traf, trun, mfra),
// WebM's EBML tree (EBML, Segment, SeekHead, Info, Tracks, Cluster, SimpleBlock, Cues) and its append-only form,
// and the errors.
//   odin test tests/mux -vet
package mux_test

import "core:testing"
import "core:time"
import mux "../../src/mux"

CREATION :: time.Time{_nsec = 1_700_000_000 * 1_000_000_000}

////////////////////////////////
// H.264 made by hand

@(private = "file")
Bits :: struct { bytes: [dynamic]u8, n: int }

@(private = "file")
put_bits :: proc(w: ^Bits, v: u32, count: int) {
	for i := count - 1; i >= 0; i -= 1 {
		if w.n % 8 == 0 { append(&w.bytes, 0) }
		if (v >> uint(i)) & 1 == 1 { w.bytes[w.n / 8] |= 0x80 >> uint(w.n % 8) }
		w.n += 1
	}
}

@(private = "file")
put_ue :: proc(w: ^Bits, v: u32) {
	x := v + 1
	bits := 0
	for r := x; r > 0; r >>= 1 { bits += 1 }
	put_bits(w, 0, bits - 1)
	put_bits(w, x, bits)
}

// An SPS of `width_mbs` x `height_units` macroblocks (progressive), cropped by `crop_bottom` chroma rows at the bottom.
@(private = "file")
make_sps :: proc(profile: u8, width_mbs, height_units: u32, crop_bottom: u32 = 0) -> []u8 {
	w := Bits{bytes = make([dynamic]u8, context.temp_allocator)}
	put_bits(&w, 0x67, 8)   // nal_ref_idc 3, type 7
	put_bits(&w, u32(profile), 8)
	put_bits(&w, 0x40, 8)   // constraint_set1
	put_bits(&w, 31, 8)     // level 3.1
	put_ue(&w, 0)           // seq_parameter_set_id
	if profile == 100 {
		put_ue(&w, 1)   // chroma_format_idc: 4:2:0
		put_ue(&w, 0)   // bit_depth_luma_minus8
		put_ue(&w, 0)   // bit_depth_chroma_minus8
		put_bits(&w, 0, 1)
		put_bits(&w, 0, 1)   // no scaling matrix
	}
	put_ue(&w, 0)    // log2_max_frame_num_minus4
	put_ue(&w, 2)    // pic_order_cnt_type
	put_ue(&w, 1)    // max_num_ref_frames
	put_bits(&w, 0, 1)
	put_ue(&w, width_mbs - 1)
	put_ue(&w, height_units - 1)
	put_bits(&w, 1, 1)   // frame_mbs_only_flag
	put_bits(&w, 1, 1)   // direct_8x8_inference_flag
	if crop_bottom > 0 {
		put_bits(&w, 1, 1)
		put_ue(&w, 0); put_ue(&w, 0); put_ue(&w, 0); put_ue(&w, crop_bottom)
	} else {
		put_bits(&w, 0, 1)
	}
	put_bits(&w, 0, 1)   // no VUI
	put_bits(&w, 1, 1)   // rbsp_stop_one_bit (the rest of the byte is zeros)
	// Emulation prevention: 00 00 then a byte up to 3 gets a 03 between
	out := make([dynamic]u8, context.temp_allocator)
	zeros := 0
	for b in w.bytes {
		if zeros == 2 && b <= 3 {
			append(&out, 3)
			zeros = 0
		}
		append(&out, b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	return out[:]
}

@(private = "file")
pps :: proc() -> []u8 {
	out := make([]u8, 4, context.temp_allocator)
	copy(out, []u8{0x68, 0xCE, 0x38, 0x80})
	return out
}

@(private = "file")
idr_slice :: proc(i: int) -> []u8 { return slice_of(0x65, i) }

@(private = "file")
delta_slice :: proc(i: int) -> []u8 { return slice_of(0x41, i) }

@(private = "file")
slice_of :: proc(header: u8, i: int) -> []u8 {
	out := make([]u8, 3 + i % 5, context.temp_allocator)
	out[0] = header
	for k in 1 ..< len(out) { out[k] = u8(0x80 + (i * 7 + k) % 100) }   // (no zero byte: no start code inside)
	return out
}

@(private = "file")
annex_b :: proc(units: ..[]u8) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	for u in units {
		append(&out, 0, 0, 0, 1)
		append(&out, ..u)
	}
	return out[:]
}

// The size of the units in AVCC: a 4-byte length each.
@(private = "file")
avcc_size :: proc(units: ..[]u8) -> int {
	n := 0
	for u in units { n += 4 + len(u) }
	return n
}

////////////////////////////////
// A box reader

@(private = "file")
Box :: struct {
	type:                string,
	start, size, header: int,
}

be16 :: proc(b: []u8) -> int { return int(b[0]) << 8 | int(b[1]) }
be32 :: proc(b: []u8) -> int { return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3]) }
be64 :: proc(b: []u8) -> int { return be32(b) << 32 | be32(b[4:]) }

@(private = "file")
boxes_in :: proc(data: []u8, from, to: int) -> (list: [dynamic]Box, ok: bool) {
	list = make([dynamic]Box, context.temp_allocator)
	at := from
	for at < to {
		if at + 8 > to { return }
		size, header := be32(data[at:]), 8
		if size == 1 {
			size = be64(data[at + 8:])
			header = 16
		}
		if size < header || at + size > to { return }
		append(&list, Box{string(data[at + 4:at + 8]), at, size, header})
		at += size
	}
	return list, true
}

// Where a box's children start: after its own fields for the containers that have some.
@(private = "file")
children_of :: proc(data: []u8, b: Box) -> [dynamic]Box {
	skip := 0
	switch b.type {
	case "stsd", "dref":                 skip = 8
	case "avc1", "hvc1", "vp09", "av01": skip = 78
	case "mp4a", "Opus":                 skip = 28
	}
	list, ok := boxes_in(data, b.start + b.header + skip, b.start + b.size)
	if !ok { return {} }
	return list
}

@(private = "file")
payload :: proc(data: []u8, b: Box) -> []u8 { return data[b.start + b.header:b.start + b.size] }

@(private = "file")
find :: proc(data: []u8, parent: Box, path: ..string) -> (found: Box, ok: bool) {
	found = parent
	for type in path {
		next := false
		for c in children_of(data, found) {
			if c.type == type { found, next = c, true; break }
		}
		if !next { return {}, false }
	}
	return found, true
}

@(private = "file")
types :: proc(list: []Box) -> []string {
	out := make([]string, len(list), context.temp_allocator)
	for b, i in list { out[i] = b.type }
	return out
}

@(private = "file")
same :: proc(a, b: []string) -> bool {
	if len(a) != len(b) { return false }
	for s, i in a { if s != b[i] { return false } }
	return true
}

// The file as one root box, to find from.
@(private = "file")
root :: proc(data: []u8) -> Box { return {"root", 0, len(data), 0} }

////////////////////////////////
// What the tests mux

@(private = "file")
Frame :: struct {
	data:      []u8,
	timestamp: f64,
	key:       bool,
	size:      int,   // in the file
}

// `count` frames at `fps`, a key frame (SPS, PPS, IDR) every `gop`, in Annex B.
@(private = "file")
frames_annex_b :: proc(count, gop: int, fps: f64, sps: []u8) -> []Frame {
	out := make([]Frame, count, context.temp_allocator)
	for i in 0 ..< count {
		if i % gop == 0 {
			out[i] = {annex_b(sps, pps(), idr_slice(i)), f64(i) / fps, true, avcc_size(sps, pps(), idr_slice(i))}
		} else {
			out[i] = {annex_b(delta_slice(i)), f64(i) / fps, false, avcc_size(delta_slice(i))}
		}
	}
	return out
}

@(private = "file")
mux_frames :: proc(t: ^testing.T, m: ^mux.Muxer, frames: []Frame, fps: f64, width := 64, height := 48) -> []u8 {
	track, err := mux.add_video_track(m, {codec = .AVC, width = width, height = height, frame_rate = fps})
	testing.expect_value(t, err, mux.Error.None)
	for f in frames {
		e := mux.add_packet(m, track, f.data, f.timestamp, 1 / fps, f.key)
		testing.expect_value(t, e, mux.Error.None)
	}
	data, ferr := mux.finalize(m)
	testing.expect_value(t, ferr, mux.Error.None)
	return data
}

// A stream that keeps the file, and whether each write went where the last one ended (patches counted).
@(private = "file")
Stream :: struct {
	file:     [dynamic]u8,
	end:      i64,
	patches:  int,
	fail:     bool,
}

@(private = "file")
stream_write :: proc(user: rawptr, data: []u8, position: i64) -> bool {
	s := (^Stream)(user)
	if s.fail { return false }
	if position != s.end { s.patches += 1 }
	need := int(position) + len(data)
	if need > len(s.file) { resize(&s.file, need) }
	copy(s.file[position:], data)
	s.end = max(s.end, i64(need))
	return true
}

// The checks of the sample table of a video track against its frames (offsets into `data`).
@(private = "file")
check_video_table :: proc(t: ^testing.T, data: []u8, trak: Box, frames: []Frame, units_per_frame: int) {
	stbl, ok := find(data, trak, "mdia", "minf", "stbl")
	testing.expect(t, ok, "no stbl")
	stts, _ := find(data, stbl, "stts")
	p := payload(data, stts)
	total := 0
	for i in 0 ..< be32(p[4:]) {
		total += be32(p[8 + 8 * i:])
		testing.expect_value(t, be32(p[12 + 8 * i:]), units_per_frame)
	}
	testing.expect_value(t, total, len(frames))

	keys := make([dynamic]int, context.temp_allocator)
	for f, i in frames { if f.key { append(&keys, i + 1) } }
	stss, has_stss := find(data, stbl, "stss")
	testing.expect(t, has_stss)
	p = payload(data, stss)
	testing.expect_value(t, be32(p[4:]), len(keys))
	for k, i in keys { testing.expect_value(t, be32(p[8 + 4 * i:]), k) }

	stsz, _ := find(data, stbl, "stsz")
	p = payload(data, stsz)
	testing.expect_value(t, be32(p[8:]), len(frames))
	for f, i in frames { testing.expect_value(t, be32(p[12 + 4 * i:]), f.size) }

	// Sample i is at its chunk's offset plus the sizes before it in the chunk
	stsc, _ := find(data, stbl, "stsc")
	stco, _ := find(data, stbl, "stco")
	sc, co := payload(data, stsc), payload(data, stco)
	chunks := be32(co[4:])
	sample := 0
	for c in 0 ..< chunks {
		per_chunk := 0
		for e in 0 ..< be32(sc[4:]) {
			if be32(sc[8 + 12 * e:]) <= c + 1 { per_chunk = be32(sc[12 + 12 * e:]) }
		}
		at := be32(co[8 + 4 * c:])
		for _ in 0 ..< per_chunk {
			f := frames[sample]
			// The first NAL unit's length, then its header: the SPS on a key frame, the slice else
			first := f.key ? 0x67 : 0x41
			testing.expectf(t, at + 5 <= len(data) && int(data[at + 4]) == first, "sample %d at %d", sample, at)
			at += f.size
			sample += 1
		}
	}
	testing.expect_value(t, sample, len(frames))
}

////////////////////////////////
// MP4

@(test)
mp4_annex_b_in_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(66, 4, 3)
	frames := frames_annex_b(6, 3, 30, sps)
	m, _ := mux.mp4_open_memory({creation_time = CREATION})
	data := mux_frames(t, m, frames, 30)
	defer delete(data)

	top, ok := boxes_in(data, 0, len(data))
	testing.expect(t, ok, "the boxes do not cover the file")
	testing.expectf(t, same(types(top[:]), {"ftyp", "moov", "mdat"}), "%v", types(top[:]))
	ftyp := payload(data, top[0])
	testing.expect_value(t, string(ftyp[:4]), "isom")
	testing.expect(t, string(ftyp[8:12]) == "isom" && string(ftyp[12:16]) == "avc1" && string(ftyp[16:20]) == "mp41")

	mvhd, _ := find(data, root(data), "moov", "mvhd")
	p := payload(data, mvhd)
	testing.expect_value(t, be32(p[12:]), mux.GLOBAL_TIMESCALE)
	testing.expect_value(t, be32(p[16:]), 6 * mux.GLOBAL_TIMESCALE / 30)
	testing.expect_value(t, be32(p[96:]), 2)   // next track ID

	trak, _ := find(data, root(data), "moov", "trak")
	tkhd, _ := find(data, trak, "tkhd")
	p = payload(data, tkhd)
	testing.expect_value(t, be32(p[12:]), 1)
	testing.expect(t, be32(p[76:]) == 64 << 16 && be32(p[80:]) == 48 << 16)
	mdhd, _ := find(data, trak, "mdia", "mdhd")
	p = payload(data, mdhd)
	testing.expect(t, be32(p[12:]) == 30 && be32(p[16:]) == 6)
	hdlr, _ := find(data, trak, "mdia", "hdlr")
	testing.expect_value(t, string(payload(data, hdlr)[8:12]), "vide")

	avc1, has_avc1 := find(data, trak, "mdia", "minf", "stbl", "stsd", "avc1")
	testing.expect(t, has_avc1)
	p = payload(data, avc1)
	testing.expect(t, be16(p[24:]) == 64 && be16(p[26:]) == 48)
	avcc, _ := find(data, avc1, "avcC")
	p = payload(data, avcc)
	testing.expect(t, p[0] == 1 && p[1] == 66 && p[2] == 0x40 && p[3] == 31 && p[4] == 0xFF && p[5] == 0xE1)
	testing.expect_value(t, be16(p[6:]), len(sps))
	testing.expect_value(t, string(p[8:][:len(sps)]), string(sps))
	at := 8 + len(sps)
	testing.expect(t, p[at] == 1 && be16(p[at + 1:]) == len(pps()))
	testing.expect_value(t, len(p), at + 3 + len(pps()))   // Baseline: no High profile fields

	check_video_table(t, data, trak, frames, 1)
	stbl, _ := find(data, trak, "mdia", "minf", "stbl")
	_, has_ctts := find(data, stbl, "ctts")
	testing.expect(t, !has_ctts)
	// 0.2 s: one chunk, right after the mdat's header
	stco, _ := find(data, stbl, "stco")
	testing.expect_value(t, be32(payload(data, stco)[8:]), top[2].start + 8)
}

@(test)
mp4_high_profile_and_cropping :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(100, 120, 68, 4)   // 1920 x 1088, 8 rows cropped: 1080
	frames := frames_annex_b(4, 4, 25, sps)
	m, _ := mux.mp4_open_memory({creation_time = CREATION})
	data := mux_frames(t, m, frames, 25, 1920, 1080)
	defer delete(data)
	avcc, ok := find(data, root(data), "moov", "trak", "mdia", "minf", "stbl", "stsd", "avc1", "avcC")
	testing.expect(t, ok)
	p := payload(data, avcc)
	testing.expect(t, p[1] == 100)
	tail := p[len(p) - 4:]   // chroma_format 1, 8-bit luma and chroma, no SPS extension
	testing.expect(t, tail[0] == 0xFD && tail[1] == 0xF8 && tail[2] == 0xF8 && tail[3] == 0)

	m2, _ := mux.mp4_open_memory()
	track, _ := mux.add_video_track(m2, {codec = .AVC, width = 1920, height = 1088, frame_rate = 25})
	testing.expect_value(t, mux.add_packet(m2, track, frames[0].data, 0, 0.04, true), mux.Error.Size_Mismatch)
	mux.destroy(m2)
}

@(test)
mp4_avcc_with_description :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(66, 4, 3)
	record := make([dynamic]u8, context.temp_allocator)
	append(&record, 1, 66, 0x40, 31, 0xFF, 0xE1, u8(len(sps) >> 8), u8(len(sps)))
	append(&record, ..sps)
	append(&record, 1, 0, u8(len(pps())))
	append(&record, ..pps())

	m, _ := mux.mp4_open_memory({creation_time = CREATION})
	track, _ := mux.add_video_track(m, {codec = .AVC, width = 64, height = 48, frame_rate = 30, description = record[:]})
	packets := [3][]u8{[]u8{0, 0, 0, 5, 0x65, 1, 2, 3, 4}, []u8{0, 0, 0, 3, 0x41, 9, 9}, []u8{0, 0, 0, 2, 0x41, 7}}
	for p, i in packets {
		testing.expect_value(t, mux.add_packet(m, track, p, f64(i) / 30, 1.0 / 30, i == 0), mux.Error.None)
	}
	data, err := mux.finalize(m)
	defer delete(data)
	testing.expect_value(t, err, mux.Error.None)
	stbl, _ := find(data, root(data), "moov", "trak", "mdia", "minf", "stbl")
	avcc, _ := find(data, stbl, "stsd", "avc1", "avcC")
	testing.expect_value(t, string(payload(data, avcc)), string(record[:]))
	stsz, _ := find(data, stbl, "stsz")
	p := payload(data, stsz)
	for packet, i in packets { testing.expect_value(t, be32(p[12 + 4 * i:]), len(packet)) }
	stco, _ := find(data, stbl, "stco")
	at := be32(payload(data, stco)[8:])
	testing.expect_value(t, string(data[at:][:len(packets[0])]), string(packets[0]))
}

@(test)
mp4_b_frames :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(66, 4, 3)
	// Decode order I P B B: presentation 0, 3, 1, 2
	order := [4]int{0, 3, 1, 2}
	m, _ := mux.mp4_open_memory({creation_time = CREATION})
	track, _ := mux.add_video_track(m, {codec = .AVC, width = 64, height = 48, frame_rate = 30})
	for pts, i in order {
		p := i == 0 ? annex_b(sps, pps(), idr_slice(0)) : annex_b(delta_slice(i))
		testing.expect_value(t, mux.add_packet(m, track, p, f64(pts) / 30, 1.0 / 30, i == 0), mux.Error.None)
	}
	data, err := mux.finalize(m)
	defer delete(data)
	testing.expect_value(t, err, mux.Error.None)
	stbl, _ := find(data, root(data), "moov", "trak", "mdia", "minf", "stbl")
	ctts, has_ctts := find(data, stbl, "ctts")
	_, has_cslg := find(data, stbl, "cslg")
	testing.expect(t, has_ctts && has_cslg)
	// Decode times 0 1 2 3: offsets 0, +2, -1, -1
	p := payload(data, ctts)
	testing.expect_value(t, p[0], 1)   // version 1: signed offsets
	testing.expect_value(t, be32(p[4:]), 3)
	expected := [3][2]i32{{1, 0}, {1, 2}, {2, -1}}
	for e, i in expected {
		testing.expect(t, i32(be32(p[8 + 8 * i:])) == e[0] && i32(u32(be32(p[12 + 8 * i:]))) == e[1])
	}
}

@(test)
mp4_without_fast_start :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(66, 4, 3)
	frames := frames_annex_b(45, 15, 30, sps)   // 1.5 s: chunks of half a second
	s := Stream{file = make([dynamic]u8)}   // (the heap: the muxer frees the temporary bytes of each call)
	defer delete(s.file)
	m, _ := mux.mp4_open_stream(stream_write, &s, {fast_start = .Off, creation_time = CREATION})
	result := mux_frames(t, m, frames, 30)
	testing.expect(t, result == nil)
	data := s.file[:]
	testing.expect_value(t, s.patches, 1)   // the mdat's size

	top, ok := boxes_in(data, 0, len(data))
	testing.expect(t, ok, "the boxes do not cover the file")
	testing.expectf(t, same(types(top[:]), {"ftyp", "mdat", "moov"}), "%v", types(top[:]))
	trak, _ := find(data, top[2], "trak")
	check_video_table(t, data, trak, frames, 1)
	stco, _ := find(data, trak, "mdia", "minf", "stbl", "stco")
	testing.expect(t, be32(payload(data, stco)[4:]) >= 3)
	// The 8 bytes the large size reserved stay at the mdat's start
	testing.expect_value(t, be32(payload(data, stco)[8:]), top[1].start + 16)

	// The same frames in memory: the same samples, moov first
	m2, _ := mux.mp4_open_memory({creation_time = CREATION})
	memory := mux_frames(t, m2, frames, 30)
	defer delete(memory)
	top2, _ := boxes_in(memory, 0, len(memory))
	testing.expectf(t, same(types(top2[:]), {"ftyp", "moov", "mdat"}), "%v", types(top2[:]))
	testing.expect_value(t, top2[2].size + 8, top[1].size)
}

@(test)
mp4_fragmented :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(66, 4, 3)
	frames := frames_annex_b(90, 30, 30, sps)   // 3 s, a key frame a second
	s := Stream{file = make([dynamic]u8)}   // (the heap: the muxer frees the temporary bytes of each call)
	defer delete(s.file)
	m, _ := mux.mp4_open_stream(stream_write, &s, {fast_start = .Fragmented, creation_time = CREATION})
	mux_frames(t, m, frames, 30)
	data := s.file[:]
	testing.expect_value(t, s.patches, 0)   // a fragmented file goes out in order

	top, ok := boxes_in(data, 0, len(data))
	testing.expect(t, ok, "the boxes do not cover the file")
	testing.expectf(t, same(types(top[:]), {"ftyp", "moov", "moof", "mdat", "moof", "mdat", "moof", "mdat", "mfra"}), "%v", types(top[:]))
	testing.expect_value(t, string(payload(data, top[0])[:4]), "iso5")
	trex, has_trex := find(data, top[1], "mvex", "trex")
	testing.expect(t, has_trex && be32(payload(data, trex)[4:]) == 1)

	samples := 0
	for f in 0 ..< 3 {
		moof, mdat := top[2 + 2 * f], top[3 + 2 * f]
		mfhd, _ := find(data, moof, "mfhd")
		testing.expect_value(t, be32(payload(data, mfhd)[4:]), f + 1)
		tfhd, _ := find(data, moof, "traf", "tfhd")
		testing.expect_value(t, be32(payload(data, tfhd)[4:]), 1)
		tfdt, _ := find(data, moof, "traf", "tfdt")
		testing.expect_value(t, be64(payload(data, tfdt)[4:]), 30 * f)   // timescale 30
		trun, _ := find(data, moof, "traf", "trun")
		p := payload(data, trun)
		flags := be32(p[:4]) & 0xFFFFFF
		count := be32(p[4:])
		testing.expect_value(t, count, 30)
		testing.expect(t, flags & 0x0004 != 0, "a key frame then deltas: the first sample's flags")
		testing.expect(t, flags & 0x0200 != 0, "the sizes differ")
		// The data offset is from the moof: the mdat's payload
		testing.expect_value(t, moof.start + be32(p[8:]), mdat.start + 8)
		at := mdat.start + 8
		for k in 0 ..< count {
			frame := frames[samples]
			testing.expect_value(t, int(data[at + 4]), frame.key ? 0x67 : 0x41)
			at += frame.size
			samples += 1
			_ = k
		}
		testing.expect_value(t, at, mdat.start + mdat.size)
	}
	testing.expect_value(t, samples, 90)

	mfra := top[8]
	testing.expect_value(t, be32(data[len(data) - 4:]), mfra.size)
	tfra, _ := find(data, mfra, "tfra")
	p := payload(data, tfra)
	testing.expect_value(t, be32(p[12:]), 3)
	for f in 0 ..< 3 {
		entry := p[16 + 28 * f:]
		testing.expect(t, be64(entry) == 30 * f && be64(entry[8:]) == top[2 + 2 * f].start)
	}
}

@(private = "file")
adts :: proc(payload_bytes: []u8) -> []u8 {
	n := 7 + len(payload_bytes)
	out := make([dynamic]u8, context.temp_allocator)
	// Sync word, MPEG-4, layer 0, no CRC; AAC LC (1), 48 kHz (3), 2 channels; frame length; fullness 0x7FF; 1 frame
	append(&out, 0xFF, 0xF1, 1 << 6 | 3 << 2, 2 << 6 | u8(n >> 11), u8(n >> 3), u8(n & 7) << 5 | 0x1F, 0xFC)
	append(&out, ..payload_bytes)
	return out[:]
}

@(test)
mp4_audio_and_video :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(66, 4, 3)
	frames := frames_annex_b(30, 30, 30, sps)
	m, _ := mux.mp4_open_memory({creation_time = CREATION})
	video, _ := mux.add_video_track(m, {codec = .AVC, width = 64, height = 48, frame_rate = 30})
	audio, err := mux.add_audio_track(m, {codec = .AAC, sample_rate = 48000, channels = 2})
	testing.expect_value(t, err, mux.Error.None)
	aac_frames := 47   // 1024 samples each, about a second
	sizes := make([dynamic]int, context.temp_allocator)
	vi, ai := 0, 0
	for vi < len(frames) || ai < aac_frames {
		vt := vi < len(frames) ? frames[vi].timestamp : 1e9
		at := ai < aac_frames ? f64(ai) * 1024 / 48000 : 1e9
		if vt <= at {
			testing.expect_value(t, mux.add_packet(m, video, frames[vi].data, vt, 1.0 / 30, frames[vi].key), mux.Error.None)
			vi += 1
		} else {
			bytes := [4]u8{0x21, u8(ai), 0x40, 0x07}
			raw := bytes[:2 + ai % 3]
			append(&sizes, len(raw))
			testing.expect_value(t, mux.add_packet(m, audio, adts(raw), at, 1024.0 / 48000, true), mux.Error.None)
			ai += 1
		}
	}
	data, ferr := mux.finalize(m)
	defer delete(data)
	testing.expect_value(t, ferr, mux.Error.None)

	moov, _ := find(data, root(data), "moov")
	traks := make([dynamic]Box, context.temp_allocator)
	for c in children_of(data, moov) { if c.type == "trak" { append(&traks, c) } }
	testing.expect_value(t, len(traks), 2)
	mvhd, _ := find(data, moov, "mvhd")
	testing.expect_value(t, be32(payload(data, mvhd)[96:]), 3)
	check_video_table(t, data, traks[0], frames, 1)

	stbl, _ := find(data, traks[1], "mdia", "minf", "stbl")
	mp4a, has_mp4a := find(data, stbl, "stsd", "mp4a")
	testing.expect(t, has_mp4a)
	p := payload(data, mp4a)
	testing.expect(t, be16(p[16:]) == 2 && be16(p[24:]) == 48000)
	esds, _ := find(data, mp4a, "esds")
	e := payload(data, esds)
	// The AudioSpecificConfig made from the ADTS header: AAC LC, 48 kHz, 2 channels
	testing.expect(t, e[len(e) - 7] == 0x05 && e[len(e) - 6] == 2 && e[len(e) - 5] == 0x11 && e[len(e) - 4] == 0x90)
	stsz, _ := find(data, stbl, "stsz")
	p = payload(data, stsz)
	testing.expect_value(t, be32(p[8:]), aac_frames)
	for n, i in sizes { testing.expect_value(t, be32(p[12 + 4 * i:]), n) }   // the ADTS headers are gone
	mdhd, _ := find(data, traks[1], "mdia", "mdhd")
	testing.expect_value(t, be32(payload(data, mdhd)[12:]), 48000)
	// AAC needs the sample before: one roll group (-1) for all but the first
	sgpd, has_sgpd := find(data, stbl, "sgpd")
	sbgp, has_sbgp := find(data, stbl, "sbgp")
	testing.expect(t, has_sgpd && has_sbgp)
	p = payload(data, sgpd)
	testing.expect(t, string(p[4:8]) == "roll" && be32(p[12:]) == 1 && i16(be16(p[16:])) == -1)
	p = payload(data, sbgp)
	testing.expect(t, be32(p[8:]) == 2 && be32(p[12:]) == 1 && be32(p[16:]) == 0 && be32(p[20:]) == aac_frames - 1 && be32(p[24:]) == 1)
}

@(test)
mp4_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sps := make_sps(66, 4, 3)
	key := annex_b(sps, pps(), idr_slice(0))

	m, _ := mux.mp4_open_memory()
	track, _ := mux.add_video_track(m, {codec = .AVC, width = 64, height = 48})
	testing.expect_value(t, mux.add_packet(m, track, annex_b(idr_slice(0)), 0, 0.04, true), mux.Error.No_Parameter_Sets)
	testing.expect_value(t, mux.add_packet(m, track, key, 0, 0.04, false), mux.Error.Not_Key_Frame)
	testing.expect_value(t, mux.add_packet(m, track, key, 1, 0.04, true), mux.Error.None)
	testing.expect_value(t, mux.add_packet(m, track, key, 0.5, 0.04, true), mux.Error.Timestamp_Order)
	testing.expect_value(t, mux.add_packet(m, track, nil, 2, 0.04, true), mux.Error.Invalid_Packet)
	testing.expect_value(t, mux.add_packet(m, mux.Track(7), key, 2, 0.04, true), mux.Error.Unknown_Track)
	_, err := mux.add_audio_track(m, {codec = .Opus, sample_rate = 48000, channels = 2})
	testing.expect_value(t, err, mux.Error.Tracks_Started)
	testing.expect_value(t, mux.close_track(m, track), mux.Error.None)
	testing.expect_value(t, mux.add_packet(m, track, key, 3, 0.04, true), mux.Error.Track_Closed)
	mux.destroy(m)

	m, _ = mux.mp4_open_memory()
	_, err = mux.add_video_track(m, {codec = .AVC, width = 0, height = 48})
	testing.expect_value(t, err, mux.Error.Invalid_Track)
	_, err = mux.add_video_track(m, {codec = .HEVC, width = 64, height = 48})
	testing.expect_value(t, err, mux.Error.Invalid_Track)
	mux.destroy(m)

	w, _ := mux.webm_open_memory()
	_, err = mux.add_video_track(w, {codec = .AVC, width = 64, height = 48})
	testing.expect_value(t, err, mux.Error.Unsupported_Codec)
	_, err = mux.add_audio_track(w, {codec = .AAC, sample_rate = 48000, channels = 2})
	testing.expect_value(t, err, mux.Error.Unsupported_Codec)
	mux.destroy(w)

	// A writer that refuses: the muxer stops
	s := Stream{file = make([dynamic]u8, context.temp_allocator), fail = true}
	m, _ = mux.mp4_open_stream(stream_write, &s, {fast_start = .Fragmented})
	track, _ = mux.add_video_track(m, {codec = .AVC, width = 64, height = 48})
	testing.expect_value(t, mux.add_packet(m, track, key, 0, 0.04, true), mux.Error.Write_Failed)
	testing.expect_value(t, mux.add_packet(m, track, key, 1, 0.04, true), mux.Error.Write_Failed)
	_, err = mux.finalize(m)
	testing.expect_value(t, err, mux.Error.Write_Failed)
}

////////////////////////////////
// An EBML reader

@(private = "file")
Element :: struct {
	id:         u32,
	start:      int,   // the ID's first byte
	data_start: int,
	end:        int,
	unknown:    bool,  // an unknown size (all ones)
}

SEGMENT :: 0x18538067
SEEK_HEAD :: 0x114D9B74
INFO :: 0x1549A966
TRACKS :: 0x1654AE6B
CLUSTER :: 0x1F43B675
CUES :: 0x1C53BB6B

@(private = "file")
vint :: proc(data: []u8, at: int, keep_marker: bool) -> (value: u64, width: int, all_ones: bool, ok: bool) {
	if at >= len(data) || data[at] == 0 { return }
	width = 1
	for data[at] & (0x80 >> uint(width - 1)) == 0 { width += 1 }
	if at + width > len(data) { return }
	all_ones = true
	for i in 0 ..< width {
		b := data[at + i]
		if i == 0 && !keep_marker { b &= 0xFF >> uint(width) }
		value = value << 8 | u64(b)
		mask := u8(i == 0 ? 0xFF >> uint(width) : 0xFF)
		if data[at + i] & mask != mask { all_ones = false }
	}
	return value, width, all_ones, true
}

@(private = "file")
is_level_1 :: proc(id: u32) -> bool { return id == SEEK_HEAD || id == INFO || id == TRACKS || id == CLUSTER || id == CUES }

@(private = "file")
elements :: proc(data: []u8, from, to: int) -> (list: [dynamic]Element, ok: bool) {
	list = make([dynamic]Element, context.temp_allocator)
	at := from
	for at < to {
		id, id_width, _, ok_id := vint(data, at, true)
		if !ok_id { return }
		size, size_width, unknown, ok_size := vint(data, at + id_width, false)
		if !ok_size { return }
		e := Element{u32(id), at, at + id_width + size_width, 0, unknown}
		if unknown {
			// Until the next element of level 1 (a Cluster's end) or the end
			e.end = to
			if u32(id) != SEGMENT {
				k := e.data_start
				for k < to {
					cid, cw, _, cok := vint(data, k, true)
					if !cok { return }
					if is_level_1(u32(cid)) { break }
					csize, csw, _, sok := vint(data, k + cw, false)
					if !sok { return }
					k += cw + csw + int(csize)
				}
				e.end = k
			}
		} else {
			e.end = e.data_start + int(size)
		}
		if e.end > to { return }
		append(&list, e)
		at = e.end
	}
	return list, true
}

@(private = "file")
child :: proc(data: []u8, parent: Element, id: u32) -> (Element, bool) {
	list, _ := elements(data, parent.data_start, parent.end)
	for e in list { if e.id == id { return e, true } }
	return {}, false
}

@(private = "file")
uint_of :: proc(data: []u8, e: Element) -> int {
	v := 0
	for b in data[e.data_start:e.end] { v = v << 8 | int(b) }
	return v
}

@(private = "file")
Webm_Read :: struct {
	segment:              Element,
	children:             [dynamic]Element,
	video_blocks, audio_blocks: int,
	group_blocks:         int,
	clusters:             [dynamic]Element,
}

@(private = "file")
read_webm :: proc(t: ^testing.T, data: []u8) -> (r: Webm_Read) {
	top, ok := elements(data, 0, len(data))
	testing.expect(t, ok && len(top) == 2, "EBML and Segment")
	if len(top) != 2 { return }
	doc, _ := child(data, top[0], 0x4282)
	testing.expect_value(t, string(data[doc.data_start:doc.end]), "webm")
	r.segment = top[1]
	testing.expect_value(t, r.segment.id, SEGMENT)
	r.children, ok = elements(data, r.segment.data_start, r.segment.end)
	testing.expect(t, ok, "the Segment's elements")
	r.clusters = make([dynamic]Element, context.temp_allocator)
	for c in r.children {
		if c.id != CLUSTER { continue }
		append(&r.clusters, c)
		blocks, _ := elements(data, c.data_start, c.end)
		for b in blocks {
			at := -1
			switch b.id {
			case 0xA3: at = b.data_start
			case 0xA0:
				inner, _ := child(data, b, 0xA1)
				at = inner.data_start
				r.group_blocks += 1
			}
			if at < 0 { continue }
			if data[at] == 0x81 { r.video_blocks += 1 } else if data[at] == 0x82 { r.audio_blocks += 1 }
		}
	}
	return
}

@(private = "file")
mux_webm :: proc(t: ^testing.T, m: ^mux.Muxer) -> (video_frames, audio_packets: int) {
	video, err := mux.add_video_track(m, {codec = .VP9, width = 640, height = 360, frame_rate = 30, vp9 = {profile = 0, level = 31, chroma_subsampling = 1}})
	testing.expect_value(t, err, mux.Error.None)
	audio, aerr := mux.add_audio_track(m, {codec = .Opus, sample_rate = 48000, channels = 2})
	testing.expect_value(t, aerr, mux.Error.None)
	video_frames, audio_packets = 60, 100   // 2 s: 30 fps, 20 ms packets
	vi, ai := 0, 0
	for vi < video_frames || ai < audio_packets {
		vt := vi < video_frames ? f64(vi) / 30 : 1e9
		at := ai < audio_packets ? f64(ai) * 0.02 : 1e9
		if vt <= at {
			frame := []u8{0x82, 0x49, 0x83, 0x42, u8(vi)}
			testing.expect_value(t, mux.add_packet(m, video, frame, vt, 1.0 / 30, vi % 30 == 0), mux.Error.None)
			vi += 1
		} else {
			packet := []u8{0x78, u8(ai), 0x55}   // TOC: config 15 (20 ms), one frame
			testing.expect_value(t, mux.add_packet(m, audio, packet, at, 0.02, true), mux.Error.None)
			ai += 1
		}
	}
	return
}

@(test)
webm_tree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m, _ := mux.webm_open_memory({creation_time = CREATION})
	frames, packets := mux_webm(t, m)
	data, err := mux.finalize(m)
	defer delete(data)
	testing.expect_value(t, err, mux.Error.None)
	r := read_webm(t, data)
	testing.expect(t, !r.segment.unknown && r.segment.end == len(data), "the Segment's size is the rest of the file")

	ids := make([dynamic]u32, context.temp_allocator)
	for c in r.children { append(&ids, c.id) }
	testing.expectf(t, len(ids) == 6 && ids[0] == SEEK_HEAD && ids[1] == INFO && ids[2] == TRACKS && ids[3] == CLUSTER &&
		ids[4] == CLUSTER && ids[5] == CUES, "%x", ids[:])
	if len(ids) != 6 { return }

	// The duration: the last block's end, in milliseconds
	duration, has_duration := child(data, r.children[1], 0x4489)
	testing.expect(t, has_duration && duration.end - duration.data_start == 8)
	bits := u64(0)
	for b in data[duration.data_start:duration.end] { bits = bits << 8 | u64(b) }
	testing.expect_value(t, transmute(f64)bits, 2000)
	scale, _ := child(data, r.children[1], 0x2AD7B1)
	testing.expect_value(t, uint_of(data, scale), 1_000_000)

	entries, _ := elements(data, r.children[2].data_start, r.children[2].end)
	testing.expect_value(t, len(entries), 2)
	codec, _ := child(data, entries[0], 0x86)
	testing.expect_value(t, string(data[codec.data_start:codec.end]), "V_VP9")
	private, _ := child(data, entries[0], 0x63A2)
	testing.expect_value(t, private.end - private.data_start, 12)
	video, _ := child(data, entries[0], 0xE0)
	width, _ := child(data, video, 0xB0)
	testing.expect_value(t, uint_of(data, width), 640)
	codec, _ = child(data, entries[1], 0x86)
	testing.expect_value(t, string(data[codec.data_start:codec.end]), "A_OPUS")
	private, _ = child(data, entries[1], 0x63A2)
	testing.expect_value(t, string(data[private.data_start:][:8]), "OpusHead")

	testing.expect_value(t, r.video_blocks, frames)
	testing.expect_value(t, r.audio_blocks, packets)
	testing.expect_value(t, r.group_blocks, 4)   // each track's last block in each cluster has a BlockDuration

	// Cluster timestamps 0 and 1000 (a key frame a second, a cluster a second)
	for c, i in r.clusters {
		ts, _ := child(data, c, 0xE7)
		testing.expect_value(t, uint_of(data, ts), 1000 * i)
	}

	// A CuePoint a cluster, both tracks in it, pointing at the cluster and at a block in it
	points, _ := elements(data, r.children[5].data_start, r.children[5].end)
	testing.expect_value(t, len(points), 2)
	for point, i in points {
		time_of, _ := child(data, point, 0xB3)
		testing.expect_value(t, uint_of(data, time_of), 1000 * i)
		positions, _ := elements(data, point.data_start, point.end)
		testing.expect_value(t, len(positions), 3)   // CueTime and two CueTrackPositions
		for p in positions[1:] {
			cluster_position, _ := child(data, p, 0xF1)
			relative, _ := child(data, p, 0xF0)
			cluster := r.clusters[i]
			testing.expect_value(t, r.segment.data_start + uint_of(data, cluster_position), cluster.start)
			block_at := cluster.data_start + uint_of(data, relative)
			testing.expect(t, data[block_at] == 0xA3 || data[block_at] == 0xA0)
		}
	}

	// The SeekHead points at the Info, the Tracks and the Cues
	seeks, _ := elements(data, r.children[0].data_start, r.children[0].end)
	testing.expect_value(t, len(seeks), 3)
	for seek, i in seeks {
		position, _ := child(data, seek, 0x53AC)
		targets := [3]int{1, 2, 5}
		target := targets[i]
		testing.expect_value(t, r.segment.data_start + uint_of(data, position), r.children[target].start)
	}
}

@(test)
webm_append_only :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := Stream{file = make([dynamic]u8)}   // (the heap: the muxer frees the temporary bytes of each call)
	defer delete(s.file)
	m, _ := mux.webm_open_stream(stream_write, &s, {append_only = true, creation_time = CREATION})
	frames, packets := mux_webm(t, m)
	_, err := mux.finalize(m)
	testing.expect_value(t, err, mux.Error.None)
	testing.expect_value(t, s.patches, 0)   // no seek back
	data := s.file[:]
	r := read_webm(t, data)
	testing.expect(t, r.segment.unknown, "an unknown Segment size")
	ids := make([dynamic]u32, context.temp_allocator)
	for c in r.children { append(&ids, c.id) }
	testing.expectf(t, len(ids) == 5 && ids[0] == INFO && ids[3] == CLUSTER && ids[4] == CUES, "%x", ids[:])
	if len(ids) != 5 { return }
	_, has_duration := child(data, r.children[0], 0x4489)
	testing.expect(t, !has_duration)
	for c in r.clusters { testing.expect(t, c.unknown) }
	testing.expect_value(t, r.video_blocks, frames)
	testing.expect_value(t, r.audio_blocks, packets)
}
