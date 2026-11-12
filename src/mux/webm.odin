// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Ported to Odin from Mediabunny (https://github.com/Vanilagy/mediabunny, commit 173f6b7): src/matroska/matroska-muxer.ts
// and the writer of src/matroska/ebml.ts. Elements are written straight into a byte buffer (a master element's size is
// patched at its end) instead of a tree of elements. Left out: Matroska (only WebM's codecs), subtitles, tags,
// attachments, alpha, projection, the VP9 colour-space patch for Chromium, the write-tracking callbacks.
package tk_mux

import "core:container/queue"
import "core:math"
import "core:slice"
import "core:time"

@(private) MIN_CLUSTER_TIMESTAMP_MS :: -(1 << 15)
@(private) MAX_CLUSTER_TIMESTAMP_MS :: 1 << 15 - 1
@(private) SEGMENT_SIZE_BYTES :: 6
@(private) CLUSTER_SIZE_BYTES :: 5
@(private) MASTER_SIZE_BYTES :: 4                // a master element's size, unless said otherwise
@(private) MAX_BLOCK_DATA :: 1 << 28 - 64        // what a block's 4-byte size holds, less its prelude and a BlockGroup's elements
@(private) EBML_DATE_EPOCH_UNIX :: 978_307_200   // 2001-01-01T00:00:00Z

// The EBML IDs this writer uses.
@(private)
Ebml_Id :: enum u32 {
	EBML                    = 0x1A45DFA3,
	EBMLVersion             = 0x4286,
	EBMLReadVersion         = 0x42F7,
	EBMLMaxIDLength         = 0x42F2,
	EBMLMaxSizeLength       = 0x42F3,
	DocType                 = 0x4282,
	DocTypeVersion          = 0x4287,
	DocTypeReadVersion      = 0x4285,
	Segment                 = 0x18538067,
	SeekHead                = 0x114D9B74,
	Seek                    = 0x4DBB,
	SeekID                  = 0x53AB,
	SeekPosition            = 0x53AC,
	Info                    = 0x1549A966,
	TimestampScale          = 0x2AD7B1,
	Duration                = 0x4489,
	DateUTC                 = 0x4461,
	MuxingApp               = 0x4D80,
	WritingApp              = 0x5741,
	Tracks                  = 0x1654AE6B,
	TrackEntry              = 0xAE,
	TrackNumber             = 0xD7,
	TrackUID                = 0x73C5,
	TrackType               = 0x83,
	FlagLacing              = 0x9C,
	Language                = 0x22B59C,
	CodecID                 = 0x86,
	CodecPrivate            = 0x63A2,
	CodecDelay              = 0x56AA,
	SeekPreRoll             = 0x56BB,
	DefaultDuration         = 0x23E383,
	Video                   = 0xE0,
	PixelWidth              = 0xB0,
	PixelHeight             = 0xBA,
	Colour                  = 0x55B0,
	MatrixCoefficients      = 0x55B1,
	TransferCharacteristics = 0x55BA,
	Primaries               = 0x55BB,
	Range                   = 0x55B9,
	Audio                   = 0xE1,
	SamplingFrequency       = 0xB5,
	Channels                = 0x9F,
	Cluster                 = 0x1F43B675,
	Timestamp               = 0xE7,
	SimpleBlock             = 0xA3,
	BlockGroup              = 0xA0,
	Block                   = 0xA1,
	BlockDuration           = 0x9B,
	ReferenceBlock          = 0xFB,
	Cues                    = 0x1C53BB6B,
	CuePoint                = 0xBB,
	CueTime                 = 0xB3,
	CueTrackPositions       = 0xB7,
	CueTrack                = 0xF7,
	CueClusterPosition      = 0xF1,
	CueRelativePosition     = 0xF0,
}

@(private)
Webm_Chunk :: struct {
	data:      []u8,   // owned
	key:       bool,
	timestamp: f64,
	duration:  f64,
}

@(private)
Webm_Track :: struct {
	chunk_queue:      queue.Queue(Webm_Chunk),
	last_written_ms:  i64,
	codec_private:    []u8,   // owned
	codec_delay:      f64,    // seconds; a negative start (encoder priming) is expressed so
	has_codec_delay:  bool,
}

@(private)
Cluster_Block :: struct {
	track:       ^Track_State,
	chunk:       Webm_Chunk,
	ms:          i64,
	previous_ms: i64,   // the track's previous block's
}

@(private)
Webm_State :: struct {
	append_only:         bool,
	minimum_cluster:     f64,
	wrote_segment:       bool,
	segment_offset:      i64,
	segment_data_offset: i64,
	seek_head_offset:    i64,
	info_offset:         i64,
	tracks_offset:       i64,
	duration_offset:     i64,
	cue_points:          [dynamic]u8,   // the CuePoint elements so far
	blocks:              [dynamic]Cluster_Block,   // the current cluster's
	has_cluster:         bool,
	cluster_start_ms:    i64,
	cluster_max_ms:      i64,
	start_ms, end_ms:    f64,           // +inf, -inf before a block
	scratch:             [dynamic]u8,
}

////////////////////////////////
// EBML

// The bytes an unsigned integer needs (Mediabunny's measureUnsignedInt: up to 6).
@(private = "file")
measure_unsigned :: proc(v: u64) -> int {
	switch {
	case v < 1 << 8:  return 1
	case v < 1 << 16: return 2
	case v < 1 << 24: return 3
	case v < 1 << 32: return 4
	case v < 1 << 40: return 5
	}
	return 6
}

@(private = "file")
measure_signed :: proc(v: i64) -> int {
	switch {
	case v >= -(1 << 6) && v < 1 << 6:   return 1
	case v >= -(1 << 13) && v < 1 << 13: return 2
	case v >= -(1 << 20) && v < 1 << 20: return 3
	case v >= -(1 << 27) && v < 1 << 27: return 4
	case v >= -(1 << 34) && v < 1 << 34: return 5
	}
	return 6
}

// A varint's width: all bits set is reserved (an unknown size), so 127 needs two bytes.
@(private = "file")
measure_varint :: proc(v: u64) -> int {
	for width in 1 ..= 7 {
		if v < 1 << uint(7 * width) - 1 { return width }
	}
	return 8
}

@(private = "file")
put_unsigned :: proc(b: ^[dynamic]u8, v: u64, width: int) {
	for i := width - 1; i >= 0; i -= 1 { append(b, u8(v >> uint(8 * i))) }
}

@(private = "file")
put_varint :: proc(b: ^[dynamic]u8, v: u64, width: int) {
	marker := u64(1) << uint(7 * width)   // the length marker bit, above the value's 7 * width bits
	put_unsigned(b, marker | v, width)
}

@(private = "file")
put_id :: proc(b: ^[dynamic]u8, id: Ebml_Id) { put_unsigned(b, u64(id), measure_unsigned(u64(id))) }

@(private = "file")
ebml_uint :: proc(b: ^[dynamic]u8, id: Ebml_Id, #any_int v: u64, size := 0) {
	width := size > 0 ? size : measure_unsigned(v)
	put_id(b, id)
	put_varint(b, u64(width), measure_varint(u64(width)))
	put_unsigned(b, v, width)
}

@(private = "file")
ebml_signed :: proc(b: ^[dynamic]u8, id: Ebml_Id, v: i64) {
	width := measure_signed(v)
	put_id(b, id)
	put_varint(b, u64(width), 1)
	put_unsigned(b, u64(v), width)   // two's complement, its low bytes
}

@(private = "file")
ebml_float32 :: proc(b: ^[dynamic]u8, id: Ebml_Id, v: f32) {
	put_id(b, id)
	put_varint(b, 4, 1)
	put_unsigned(b, u64(transmute(u32)v), 4)
}

@(private = "file")
ebml_float64 :: proc(b: ^[dynamic]u8, id: Ebml_Id, v: f64) {
	put_id(b, id)
	put_varint(b, 8, 1)
	put_unsigned(b, transmute(u64)v, 8)
}

@(private = "file")
ebml_bytes :: proc(b: ^[dynamic]u8, id: Ebml_Id, data: []u8) {
	put_id(b, id)
	put_varint(b, u64(len(data)), measure_varint(u64(len(data))))
	append(b, ..data)
}

@(private = "file")
ebml_string :: proc(b: ^[dynamic]u8, id: Ebml_Id, s: string) { ebml_bytes(b, id, transmute([]u8)s) }

// A master element's ID and room for its size; master_end writes the size. width -1: an unknown size (0xFF).
@(private = "file")
master_begin :: proc(b: ^[dynamic]u8, id: Ebml_Id, width := MASTER_SIZE_BYTES) -> (size_at: int) {
	put_id(b, id)
	size_at = len(b^)
	if width < 0 {
		append(b, 0xFF)
		return -1
	}
	put_zeros(b, width)
	return
}

@(private = "file")
master_end :: proc(b: ^[dynamic]u8, size_at: int, width := MASTER_SIZE_BYTES) {
	if size_at < 0 { return }
	size := u64(len(b^) - size_at - width)
	patch := make([dynamic]u8, 0, 8, context.temp_allocator)
	put_varint(&patch, size, width)
	copy(b^[size_at:], patch[:])
}

////////////////////////////////
// Start and tracks

@(private)
webm_start :: proc(m: ^Muxer, options: Webm_Options) -> Error {
	wm := &m.webm
	wm.append_only = options.append_only
	wm.minimum_cluster = options.minimum_cluster_duration > 0 ? options.minimum_cluster_duration : 1
	wm.start_ms, wm.end_ms = math.inf_f64(1), math.inf_f64(-1)
	wm.cue_points = make([dynamic]u8, m.allocator)
	wm.blocks = make([dynamic]Cluster_Block, m.allocator)
	wm.scratch = make([dynamic]u8, m.allocator)

	b := &wm.scratch
	header := master_begin(b, .EBML)
	ebml_uint(b, .EBMLVersion, 1)
	ebml_uint(b, .EBMLReadVersion, 1)
	ebml_uint(b, .EBMLMaxIDLength, 4)
	ebml_uint(b, .EBMLMaxSizeLength, 8)
	ebml_string(b, .DocType, "webm")
	ebml_uint(b, .DocTypeVersion, 4)
	ebml_uint(b, .DocTypeReadVersion, 2)
	master_end(b, header)
	writer_write(&m.writer, b^[:])
	writer_flush(&m.writer)
	return .None
}

@(private)
webm_track_init :: proc(m: ^Muxer, t: ^Track_State) {
	tr := &t.webm
	queue.init(&tr.chunk_queue, 64, m.allocator)
	context.allocator = m.allocator
	if t.is_video {
		switch t.video.codec {
		case .VP9:
			// The container spec says VP9 SHOULD have a CodecPrivate (webmproject.org/docs/container)
			tr.codec_private = vp9_codec_private(t.video.vp9)
		case .AV1:
			// The Matroska AV1 mapping requires the av1C as CodecPrivate
			record := av1_config_record(t.video.av1)
			tr.codec_private = clone(record[:])
		case .VP8, .AVC, .HEVC:
		}
	} else if t.description != nil {
		tr.codec_private = clone(t.description)
	} else {
		// A_OPUS needs the OpusHead: one with the track's channels and rate, family 0 (mono or stereo)
		head := make([]u8, 19)
		copy(head, "OpusHead")
		head[8] = 1   // version
		head[9] = u8(t.audio.channels)
		head[10], head[11] = 312 & 0xFF, 312 >> 8   // pre-skip, as the dOps default
		rate := u32(t.audio.sample_rate)
		head[12], head[13], head[14], head[15] = u8(rate), u8(rate >> 8), u8(rate >> 16), u8(rate >> 24)
		tr.codec_private = head
	}
}

// The Segment's head: its ID and size, the SeekHead (offsets 0 for now), the Info and the Tracks. Written with the
// first block, when every track has given a packet (the audio's codec delay is known).
@(private = "file")
write_segment :: proc(m: ^Muxer) {
	wm := &m.webm
	wm.wrote_segment = true
	b := &wm.scratch
	clear(b)
	base := m.writer.pos
	wm.segment_offset = base
	size_at := master_begin(b, .Segment, wm.append_only ? -1 : SEGMENT_SIZE_BYTES)
	wm.segment_data_offset = base + i64(len(b^))
	if !wm.append_only {
		wm.seek_head_offset = base + i64(len(b^))
		seek_head(m, b)
	}

	wm.info_offset = base + i64(len(b^))
	info := master_begin(b, .Info)
	ebml_uint(b, .TimestampScale, 1_000_000)   // milliseconds
	if !wm.append_only {
		wm.duration_offset = base + i64(len(b^))
		ebml_float64(b, .Duration, 0)
	}
	nanoseconds := time.time_to_unix_nano(m.creation_time) - EBML_DATE_EPOCH_UNIX * 1_000_000_000
	ebml_uint(b, .DateUTC, u64(nanoseconds), 8)   // a signed 64-bit integer
	ebml_string(b, .MuxingApp, MUXING_APP)
	ebml_string(b, .WritingApp, MUXING_APP)
	master_end(b, info)

	wm.tracks_offset = base + i64(len(b^))
	tracks := master_begin(b, .Tracks)
	for t in m.tracks { track_entry(m, t, b) }
	master_end(b, tracks)

	master_end(b, size_at, SEGMENT_SIZE_BYTES)
	writer_write(&m.writer, b^[:])
}

// The SeekHead: where the Info, the Tracks and the Cues are, from the Segment's data (0 until finalize knows them).
// The positions have a fixed size: finalize writes it again over itself.
@(private = "file")
seek_head :: proc(m: ^Muxer, b: ^[dynamic]u8, cues_offset: i64 = -1) {
	wm := &m.webm
	known := cues_offset >= 0
	Entry :: struct { id: Ebml_Id, offset: i64 }
	entries := [3]Entry{{.Info, wm.info_offset}, {.Tracks, wm.tracks_offset}, {.Cues, cues_offset}}
	head := master_begin(b, .SeekHead)
	for e in entries {
		seek := master_begin(b, .Seek)
		id: [4]u8
		id[0], id[1], id[2], id[3] = u8(u32(e.id) >> 24), u8(u32(e.id) >> 16), u8(u32(e.id) >> 8), u8(u32(e.id))
		ebml_bytes(b, .SeekID, id[:])
		ebml_uint(b, .SeekPosition, known ? u64(e.offset - wm.segment_data_offset) : 0, 5)
		master_end(b, seek)
	}
	master_end(b, head)
}

@(private = "file")
track_entry :: proc(m: ^Muxer, t: ^Track_State, b: ^[dynamic]u8) {
	tr := &t.webm
	entry := master_begin(b, .TrackEntry)
	ebml_uint(b, .TrackNumber, t.id)
	ebml_uint(b, .TrackUID, t.id)
	ebml_uint(b, .TrackType, t.is_video ? 1 : 2)
	ebml_uint(b, .FlagLacing, 0)
	ebml_string(b, .Language, "und")
	codec_id: string
	if t.is_video {
		#partial switch t.video.codec {
		case .VP8: codec_id = "V_VP8"
		case .VP9: codec_id = "V_VP9"
		case .AV1: codec_id = "V_AV1"
		}
	} else {
		codec_id = "A_OPUS"
	}
	ebml_string(b, .CodecID, codec_id)
	if tr.codec_private != nil { ebml_bytes(b, .CodecPrivate, tr.codec_private) }
	if t.is_video {
		v := &t.video
		if v.frame_rate > 0 { ebml_uint(b, .DefaultDuration, u64(1e9 / v.frame_rate)) }
		video := master_begin(b, .Video)
		ebml_uint(b, .PixelWidth, v.width)
		ebml_uint(b, .PixelHeight, v.height)
		if color, ok := v.color.?; ok {
			colour := master_begin(b, .Colour)
			ebml_uint(b, .MatrixCoefficients, color.coefficients)
			ebml_uint(b, .TransferCharacteristics, color.transfer)
			ebml_uint(b, .Primaries, color.primaries)
			ebml_uint(b, .Range, color.full_range ? 2 : 1)
			master_end(b, colour)
		}
		master_end(b, video)
	} else {
		if tr.codec_delay > 0 { ebml_uint(b, .CodecDelay, u64(js_round(1e9 * tr.codec_delay))) }
		ebml_uint(b, .SeekPreRoll, u64(js_round(1e9 * OPUS_PRE_ROLL_DURATION)))
		audio := master_begin(b, .Audio)
		ebml_float32(b, .SamplingFrequency, f32(t.audio.sample_rate))
		ebml_uint(b, .Channels, t.audio.channels)
		master_end(b, audio)
	}
	master_end(b, entry)
}

////////////////////////////////
// Packets

@(private)
webm_add_packet :: proc(m: ^Muxer, t: ^Track_State, data: []u8, timestamp, duration: f64, key: bool) -> Error {
	if len(data) > MAX_BLOCK_DATA { return .Too_Large }
	order_check(&t.order, timestamp, key) or_return
	tr := &t.webm
	at, length := timestamp, duration
	if t.is_video {
		if t.video.frame_rate > 0 {
			// The time values on the frame rate
			at = js_round(at * t.video.frame_rate) / t.video.frame_rate
			length = js_round(length * t.video.frame_rate) / t.video.frame_rate
		}
	} else {
		if !tr.has_codec_delay {
			tr.codec_delay = max(-at, 0)
			tr.has_codec_delay = true
		}
		at += tr.codec_delay
	}
	queue.push_back(&tr.chunk_queue, Webm_Chunk{clone(data), key, at, length})
	interleave(m, false)
	return .None
}

@(private)
webm_close_track :: proc(m: ^Muxer, t: ^Track_State) -> Error {
	// A track closed: blocks that were waiting for it may go out
	interleave(m, false)
	return .None
}

// Moves chunks from the queues to the clusters by timestamp, while every open track has one queued (or all, at the end).
@(private = "file")
interleave :: proc(m: ^Muxer, final: bool) {
	outer: for {
		best: ^Track_State
		lowest := math.inf_f64(1)
		for t in m.tracks {
			n := queue.len(t.webm.chunk_queue)
			if !final && n == 0 && !t.closed { break outer }
			if n > 0 {
				front := queue.front(&t.webm.chunk_queue)
				if front.timestamp < lowest {
					best = t
					lowest = front.timestamp
				}
			}
		}
		if best == nil { break }
		add_block(m, best, queue.pop_front(&best.webm.chunk_queue))
	}
	if !final { writer_flush(&m.writer) }
}

@(private = "file")
add_block :: proc(m: ^Muxer, t: ^Track_State, chunk: Webm_Chunk) {
	wm := &m.webm
	if !wm.wrote_segment { write_segment(m) }
	ms := i64(js_round(1000 * chunk.timestamp))

	// A cluster ends only when every track can start the next one with a key frame
	key_everywhere := true
	for other in m.tracks {
		if other == t {
			if !chunk.key { key_everywhere = false }
		} else if queue.len(other.webm.chunk_queue) > 0 {
			if !queue.front(&other.webm.chunk_queue).key { key_everywhere = false }
		} else if !other.closed {
			key_everywhere = false
		}
	}

	new_cluster := true
	if wm.has_cluster {
		relative := ms - wm.cluster_start_ms
		// A block at the cluster's highest timestamp keeps the next cluster from starting there (the block written
		// would belong in it). Past the largest relative timestamp, the next cluster starts on a delta frame: not
		// wanted, but allowed by the spec and played.
		new_cluster = (key_everywhere && ms > wm.cluster_max_ms && f64(relative) >= 1000 * wm.minimum_cluster) ||
			relative > MAX_CLUSTER_TIMESTAMP_MS
	}
	if new_cluster {
		if wm.has_cluster { write_cluster(m) }
		wm.has_cluster = true
		wm.cluster_start_ms = max(0, ms)   // a cluster's timestamp is not negative
		wm.cluster_max_ms = wm.cluster_start_ms
	}

	if ms - wm.cluster_start_ms < MIN_CLUSTER_TIMESTAMP_MS {
		// Too far in the past for this cluster: not representable, dropped
		delete(chunk.data)
		return
	}
	append(&wm.blocks, Cluster_Block{t, chunk, ms, t.webm.last_written_ms})
	wm.start_ms = min(wm.start_ms, f64(ms))
	wm.end_ms = max(wm.end_ms, f64(ms) + js_round(1000 * chunk.duration))
	t.webm.last_written_ms = ms
	wm.cluster_max_ms = max(wm.cluster_max_ms, ms)
}

// Writes the current cluster and the CuePoints of its first key frames.
@(private = "file")
write_cluster :: proc(m: ^Muxer) {
	wm := &m.webm
	cluster_ms := wm.cluster_start_ms
	first_key, last := make([]int, len(m.tracks) + 1, context.temp_allocator), make([]int, len(m.tracks) + 1, context.temp_allocator)
	slice.fill(first_key, -1)
	key_order := make([dynamic]int, context.temp_allocator)   // the first key blocks, in the order they come
	for blk, i in wm.blocks {
		id := blk.track.id
		if blk.chunk.key && first_key[id] < 0 {
			first_key[id] = i
			append(&key_order, i)
		}
		last[id] = i
	}

	b := &wm.scratch
	clear(b)
	base := m.writer.pos
	width := wm.append_only ? -1 : CLUSTER_SIZE_BYTES
	size_at := master_begin(b, .Cluster, width)
	data_offset := base + i64(len(b^))
	ebml_uint(b, .Timestamp, u64(cluster_ms))
	offsets := make([]i64, len(wm.blocks), context.temp_allocator)
	for &blk, i in wm.blocks {
		offsets[i] = base + i64(len(b^))
		write_block(b, &blk, cluster_ms, last[blk.track.id] == i)
	}
	master_end(b, size_at, CLUSTER_SIZE_BYTES)
	writer_write(&m.writer, b^[:])
	cluster_position := base - wm.segment_data_offset

	// A CuePoint for each timestamp of a track's first key frame, with every track whose first key frame is there
	times := make([dynamic]i64, context.temp_allocator)
	for i in key_order {
		if !slice.contains(times[:], wm.blocks[i].ms) { append(&times, wm.blocks[i].ms) }
	}
	slice.sort(times[:])
	c := &wm.cue_points
	for ms in times {
		point := master_begin(c, .CuePoint)
		ebml_uint(c, .CueTime, u64(max(0, ms)))   // CueTime is unsigned
		for i in key_order {
			if wm.blocks[i].ms != ms { continue }
			positions := master_begin(c, .CueTrackPositions)
			ebml_uint(c, .CueTrack, wm.blocks[i].track.id)
			ebml_uint(c, .CueClusterPosition, u64(cluster_position))
			ebml_uint(c, .CueRelativePosition, u64(offsets[i] - data_offset))
			master_end(c, positions)
		}
		master_end(c, point)
	}

	for blk in wm.blocks { delete(blk.chunk.data) }
	clear(&wm.blocks)
}

// A SimpleBlock; a BlockGroup for a track's last block in the cluster with a duration: a SimpleBlock has none (a
// reader takes it from the track's next block), and that block has no next one in the cluster.
@(private = "file")
write_block :: proc(b: ^[dynamic]u8, blk: ^Cluster_Block, cluster_ms: i64, last_of_track: bool) {
	relative := blk.ms - cluster_ms
	prelude := [4]u8{0x80 | u8(blk.track.id), u8(u16(i16(relative)) >> 8), u8(u16(i16(relative))), 0}
	ms_duration := i64(js_round(1000 * blk.chunk.duration))
	if !(last_of_track && ms_duration > 0) {
		prelude[3] = bit(blk.chunk.key) << 7   // (the key frame flag exists only in a SimpleBlock)
		block := master_begin(b, .SimpleBlock)
		append(b, ..prelude[:])
		append(b, ..blk.chunk.data)
		master_end(b, block)
		return
	}
	group := master_begin(b, .BlockGroup)
	block := master_begin(b, .Block)
	append(b, ..prelude[:])
	append(b, ..blk.chunk.data)
	master_end(b, block)
	if !blk.chunk.key { ebml_signed(b, .ReferenceBlock, blk.previous_ms - blk.ms) }
	ebml_uint(b, .BlockDuration, u64(ms_duration))
	master_end(b, group)
}

////////////////////////////////
// Finalize

@(private)
webm_finalize :: proc(m: ^Muxer) -> Error {
	wm := &m.webm
	w := &m.writer
	for t in m.tracks { t.closed = true }
	if !wm.wrote_segment { write_segment(m) }
	interleave(m, true)
	if wm.has_cluster { write_cluster(m) }

	b := &wm.scratch
	clear(b)
	cues_offset := w.pos
	cues := master_begin(b, .Cues)
	append(b, ..wm.cue_points[:])
	master_end(b, cues)
	writer_write(w, b^[:])

	if !wm.append_only {
		end := w.pos
		// The Segment's size
		clear(b)
		put_varint(b, u64(end - wm.segment_data_offset), SEGMENT_SIZE_BYTES)
		writer_seek(w, wm.segment_data_offset - SEGMENT_SIZE_BYTES)
		writer_write(w, b^[:])

		// The media's duration
		clear(b)
		ebml_float64(b, .Duration, math.is_inf(wm.start_ms) ? 0 : wm.end_ms)
		writer_seek(w, wm.duration_offset)
		writer_write(w, b^[:])

		// The SeekHead with its positions
		clear(b)
		seek_head(m, b, cues_offset)
		writer_seek(w, wm.seek_head_offset)
		writer_write(w, b^[:])
		writer_seek(w, end)
	}
	return .None
}

@(private)
webm_destroy :: proc(m: ^Muxer) {
	for t in m.tracks {
		tr := &t.webm
		for queue.len(tr.chunk_queue) > 0 { delete(queue.pop_front(&tr.chunk_queue).data) }
		queue.destroy(&tr.chunk_queue)
		delete(tr.codec_private)
	}
	for blk in m.webm.blocks { delete(blk.chunk.data) }
	delete(m.webm.blocks)
	delete(m.webm.cue_points)
	delete(m.webm.scratch)
}
