// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Ported to Odin from Mediabunny (https://github.com/Vanilagy/mediabunny, commit 173f6b7): src/isobmff/isobmff-boxes.ts.
// The boxes are written straight into a byte buffer (a box's size is patched at its end) instead of a tree of boxes;
// a box is measured by writing it. Left out: QuickTime, CMAF, subtitles, PCM, metadata tags, rotation.
package tk_mux

////////////////////////////////
// Bytes (big-endian)

@(private) put_u8 :: proc(b: ^[dynamic]u8, #any_int v: i64) { append(b, u8(v)) }
@(private) put_u16 :: proc(b: ^[dynamic]u8, #any_int v: i64) { append(b, u8(v >> 8), u8(v)) }
@(private) put_u24 :: proc(b: ^[dynamic]u8, #any_int v: i64) { append(b, u8(v >> 16), u8(v >> 8), u8(v)) }
@(private) put_u32 :: proc(b: ^[dynamic]u8, #any_int v: i64) { append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }

@(private)
put_u64 :: proc(b: ^[dynamic]u8, #any_int v: i64) {
	put_u32(b, v >> 32)
	put_u32(b, v)
}

@(private) put_fourcc :: proc(b: ^[dynamic]u8, s: string) { append(b, s) }
@(private) put_zeros :: proc(b: ^[dynamic]u8, n: int) { for _ in 0 ..< n { append(b, 0) } }

@(private)
box_begin :: proc(b: ^[dynamic]u8, type: string) -> int {
	start := len(b^)
	put_u32(b, 0)
	put_fourcc(b, type)
	return start
}

// A FullBox always starts with a version byte, followed by three flag bytes.
@(private)
full_box_begin :: proc(b: ^[dynamic]u8, type: string, version: u8, #any_int flags: i64) -> int {
	start := box_begin(b, type)
	put_u8(b, version)
	put_u24(b, flags)
	return start
}

@(private)
box_end :: proc(b: ^[dynamic]u8, start: int) {
	n := len(b^) - start
	b^[start], b^[start + 1], b^[start + 2], b^[start + 3] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
}

@(private = "file")
is_u32 :: proc(v: i64) -> bool { return v >= 0 && v < 1 << 32 }

@(private = "file")
is_i32 :: proc(v: i64) -> bool { return v >= -(1 << 31) && v < 1 << 31 }

@(private = "file")
put_u32_or_u64 :: proc(b: ^[dynamic]u8, wide: bool, v: i64) { if wide { put_u64(b, v) } else { put_u32(b, v) } }

// The identity transformation matrix: 16.16 fixed point, the last column 2.30.
@(private = "file")
put_identity_matrix :: proc(b: ^[dynamic]u8) {
	put_u32(b, 0x00010000); put_u32(b, 0); put_u32(b, 0)
	put_u32(b, 0); put_u32(b, 0x00010000); put_u32(b, 0)
	put_u32(b, 0); put_u32(b, 0); put_u32(b, 0x40000000)
}

// 'und', three letters of 5 bits
@(private = "file") LANGUAGE_UNDETERMINED :: 21 << 10 | 14 << 5 | 4

////////////////////////////////
// File Type and Movie

// File Type Compatibility Box: Allows the reader to determine whether this is a type of file that the reader
// understands. (The full logic is FFmpeg's movenc.c; this needs a small subset of it.)
@(private)
mp4_ftyp :: proc(b: ^[dynamic]u8, fragmented, holds_avc: bool) {
	MINOR_VERSION :: 0x200
	start := box_begin(b, "ftyp")
	if fragmented {
		put_fourcc(b, "iso5")
		put_u32(b, MINOR_VERSION)
		put_fourcc(b, "iso5"); put_fourcc(b, "iso6"); put_fourcc(b, "mp41")
	} else {
		put_fourcc(b, "isom")
		put_u32(b, MINOR_VERSION)
		put_fourcc(b, "isom")
		if holds_avc { put_fourcc(b, "avc1") }
		put_fourcc(b, "mp41")
	}
	box_end(b, start)
}

// Movie Box: the information that allows an application to interpret the sample data that is stored elsewhere.
@(private)
mp4_moov :: proc(m: ^Muxer, b: ^[dynamic]u8) {
	start := box_begin(b, "moov")
	mvhd(m, b)
	for t in m.tracks { if t.configured { trak(m, t, b) } }
	if m.mp4.fragmented {
		mvex := box_begin(b, "mvex")
		for t in m.tracks { if t.configured { trex(t, b) } }
		box_end(b, mvex)
	}
	box_end(b, start)
}

// The duration of a track in the movie's timescale. Round separately to match the edit list.
@(private = "file")
movie_duration :: proc(t: ^Track_State) -> i64 {
	return max(0, into_timescale(presentation_span(t), GLOBAL_TIMESCALE) + into_timescale(t.mp4.start_offset, GLOBAL_TIMESCALE))
}

// Movie Header Box: the characteristics of the entire movie, such as timescale and duration.
@(private = "file")
mvhd :: proc(m: ^Muxer, b: ^[dynamic]u8) {
	duration: i64
	next_id := 0
	for t in m.tracks {
		if !t.configured { continue }
		duration = max(duration, movie_duration(t))
		next_id = max(next_id, t.id)
	}
	wide := !is_u32(m.mp4.creation_time) || !is_u32(duration)   // u64 when u32 is not enough
	start := full_box_begin(b, "mvhd", wide ? 1 : 0, 0)
	put_u32_or_u64(b, wide, m.mp4.creation_time)   // creation time
	put_u32_or_u64(b, wide, m.mp4.creation_time)   // modification time
	put_u32(b, GLOBAL_TIMESCALE)
	put_u32_or_u64(b, wide, duration)
	put_u32(b, 0x00010000)   // preferred rate 1.0
	put_u16(b, 0x0100)       // preferred volume 1.0
	put_zeros(b, 10)         // reserved
	put_identity_matrix(b)
	put_zeros(b, 24)         // pre-defined
	put_u32(b, next_id + 1)
	box_end(b, start)
}

// Track Box: a single track of the movie, with its own temporal and spatial information and its Media Box.
@(private = "file")
trak :: proc(m: ^Muxer, t: ^Track_State, b: ^[dynamic]u8) {
	start := box_begin(b, "trak")
	tkhd(m, t, b)
	if t.mp4.has_start_offset && t.mp4.start_offset != 0 { edts(t, b) }
	mdia(m, t, b)
	box_end(b, start)
}

// Track Header Box: the characteristics of a single track within a movie.
@(private = "file")
tkhd :: proc(m: ^Muxer, t: ^Track_State, b: ^[dynamic]u8) {
	duration := movie_duration(t)
	wide := !is_u32(m.mp4.creation_time) || !is_u32(duration)
	// Track enabled (0x1) and in movie (0x2)
	start := full_box_begin(b, "tkhd", wide ? 1 : 0, 0x3)
	put_u32_or_u64(b, wide, m.mp4.creation_time)
	put_u32_or_u64(b, wide, m.mp4.creation_time)
	put_u32(b, t.id)
	put_u32(b, 0)   // reserved
	put_u32_or_u64(b, wide, duration)
	put_zeros(b, 8)   // reserved
	put_u16(b, 0)     // layer
	// Alternate group by type, as FFmpeg does; video must be in group 0 (Mediabunny issue 454)
	put_u16(b, t.is_video ? 0 : 1)
	put_u16(b, t.is_video ? 0 : 0x0100)   // volume
	put_u16(b, 0)     // reserved
	put_identity_matrix(b)
	put_u32(b, t.is_video ? t.video.width << 16 : 0)
	put_u32(b, t.is_video ? t.video.height << 16 : 0)
	box_end(b, start)
}

// Edit Box: a positive start offset is an empty segment, then the media; a negative one trims the media's start.
@(private = "file")
edts :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	offset := t.mp4.start_offset
	start := box_begin(b, "edts")
	if offset > 0 {
		start_offset := into_timescale(offset, GLOBAL_TIMESCALE)
		media_duration := into_timescale(presentation_span(t), GLOBAL_TIMESCALE)
		wide := !is_u32(start_offset) || !is_u32(media_duration)
		elst := full_box_begin(b, "elst", wide ? 1 : 0, 0)
		put_u32(b, 2)   // entry count
		put_u32_or_u64(b, wide, start_offset)   // segment duration
		put_u32_or_u64(b, wide, -1)             // media time: empty
		put_u32(b, 0x00010000)                  // media rate
		put_u32_or_u64(b, wide, media_duration)
		put_u32_or_u64(b, wide, 0)
		put_u32(b, 0x00010000)
		box_end(b, elst)
	} else {
		media_time := into_timescale(-offset, t.mp4.timescale)
		// For fragmented files this is zero: "the segment_duration of this edit may be zero" (an unknown duration)
		media_duration := max(0, into_timescale(presentation_span(t), GLOBAL_TIMESCALE) + into_timescale(offset, GLOBAL_TIMESCALE))
		wide := !is_i32(media_time) || !is_u32(media_duration)
		elst := full_box_begin(b, "elst", wide ? 1 : 0, 0)
		put_u32(b, 1)
		put_u32_or_u64(b, wide, media_duration)
		put_u32_or_u64(b, wide, media_time)
		put_u32(b, 0x00010000)
		box_end(b, elst)
	}
	box_end(b, start)
}

// Media Box, with its Media Header Box (the raw media's duration: edit lists are not taken into account).
@(private = "file")
mdia :: proc(m: ^Muxer, t: ^Track_State, b: ^[dynamic]u8) {
	start := box_begin(b, "mdia")
	duration := into_timescale(presentation_span(t), t.mp4.timescale)
	wide := !is_u32(m.mp4.creation_time) || !is_u32(duration)
	mdhd := full_box_begin(b, "mdhd", wide ? 1 : 0, 0)
	put_u32_or_u64(b, wide, m.mp4.creation_time)
	put_u32_or_u64(b, wide, m.mp4.creation_time)
	put_u32(b, t.mp4.timescale)
	put_u32_or_u64(b, wide, duration)
	put_u16(b, LANGUAGE_UNDETERMINED)
	put_u16(b, 0)   // quality
	box_end(b, mdhd)

	// Handler Reference Box
	hdlr := full_box_begin(b, "hdlr", 0, 0)
	put_fourcc(b, "mhlr")   // component type
	put_fourcc(b, t.is_video ? "vide" : "soun")
	put_u32(b, 0)   // component manufacturer
	put_u32(b, 0)   // component flags
	put_u32(b, 0)   // component flags mask
	append(b, t.is_video ? "VideoHandler" : "SoundHandler")
	put_u8(b, 0)
	box_end(b, hdlr)

	minf(t, b)
	box_end(b, start)
}

// Media Information Box: the media header, the data reference and the sample table.
@(private = "file")
minf :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	start := box_begin(b, "minf")
	if t.is_video {
		vmhd := full_box_begin(b, "vmhd", 0, 1)
		put_u16(b, 0)   // graphics mode
		put_zeros(b, 6) // opcolor
		box_end(b, vmhd)
	} else {
		smhd := full_box_begin(b, "smhd", 0, 0)
		put_u16(b, 0)   // balance
		put_u16(b, 0)   // reserved
		box_end(b, smhd)
	}
	dinf := box_begin(b, "dinf")
	dref := full_box_begin(b, "dref", 0, 0)
	put_u32(b, 1)   // entry count
	url := full_box_begin(b, "url ", 0, 1)   // self-reference
	box_end(b, url)
	box_end(b, dref)
	box_end(b, dinf)
	stbl(t, b)
	box_end(b, start)
}

////////////////////////////////
// Sample table

// Sample Table Box: from media time to sample number to sample location, and how to decode the samples.
@(private = "file")
stbl :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	tr := &t.mp4
	needs_ctts := len(tr.composition_offsets) > 1
	for e in tr.composition_offsets { if e.offset != 0 { needs_ctts = true } }

	start := box_begin(b, "stbl")
	stsd(t, b)

	// Time-To-Sample Box, compactly coded
	stts := full_box_begin(b, "stts", 0, 0)
	put_u32(b, len(tr.time_to_sample))
	for e in tr.time_to_sample { put_u32(b, e.count); put_u32(b, e.delta) }
	box_end(b, stts)

	if needs_ctts {
		// Composition Time to Sample Box (PTS - DTS), compactly coded
		ctts := full_box_begin(b, "ctts", 1, 0)
		put_u32(b, len(tr.composition_offsets))
		for e in tr.composition_offsets { put_u32(b, e.count); put_u32(b, e.offset) }
		box_end(b, ctts)
		cslg(t, b)
	}

	// Sample-To-Chunk Box, compactly coded
	stsc := full_box_begin(b, "stsc", 0, 0)
	put_u32(b, len(tr.chunk_table))
	for e in tr.chunk_table { put_u32(b, e.first_chunk); put_u32(b, e.samples_per_chunk); put_u32(b, 1) }
	box_end(b, stsc)

	// Sample Size Box (0: sizes differ)
	stsz := full_box_begin(b, "stsz", 0, 0)
	put_u32(b, 0)
	put_u32(b, len(tr.samples))
	for s in tr.samples { put_u32(b, s.size) }
	box_end(b, stsz)

	// Chunk Offset Box; co64 when the file is large
	if len(tr.chunks) > 0 && tr.chunks[len(tr.chunks) - 1].offset >= 1 << 32 {
		co64 := full_box_begin(b, "co64", 0, 0)
		put_u32(b, len(tr.chunks))
		for c in tr.chunks { put_u64(b, c.offset) }
		box_end(b, co64)
	} else {
		stco := full_box_begin(b, "stco", 0, 0)
		put_u32(b, len(tr.chunks))
		for c in tr.chunks { put_u32(b, c.offset) }
		box_end(b, stco)
	}

	// Sync Sample Box: none when every sample is a key frame
	keys := 0
	for s in tr.samples { if s.key { keys += 1 } }
	if keys < len(tr.samples) {
		stss := full_box_begin(b, "stss", 0, 0)
		put_u32(b, keys)
		for s, i in tr.samples { if s.key { put_u32(b, i + 1) } }
		box_end(b, stss)
	}

	sgpd_and_sbgp(b, tr.samples[:], false)
	box_end(b, start)
}

// Composition to Decode Box. None before samples (a moov measured early) or when the end does not fit an i32
// (QuickTime fails to read a version 1 cslg).
@(private = "file")
cslg :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	tr := &t.mp4
	if len(tr.samples) == 0 { return }
	least, greatest := max(i64), min(i64)
	for e in tr.composition_offsets {
		least = min(least, e.offset)
		greatest = max(greatest, e.offset)
	}
	composition_start, composition_end := max(i64), min(i64)
	for s in tr.samples {
		composition_start = min(composition_start, into_timescale(s.timestamp, tr.timescale))
		composition_end = max(composition_end, into_timescale(s.timestamp + s.duration, tr.timescale))
	}
	if composition_end >= 1 << 31 { return }
	start := full_box_begin(b, "cslg", 0, 0)
	put_u32(b, max(-least, 0))   // composition to DTS shift
	put_u32(b, least)
	put_u32(b, greatest)
	put_u32(b, composition_start)
	put_u32(b, composition_end)
	box_end(b, start)
}

// The roll groups of audio samples that need samples before them to decode (AAC, Opus); none when no sample does.
@(private = "file")
sgpd_and_sbgp :: proc(b: ^[dynamic]u8, samples: []^Sample, in_fragment: bool) {
	Entry :: struct { count, preroll: int }
	entries := make([dynamic]Entry, context.temp_allocator)
	rolls := 0
	for s in samples {
		if len(entries) > 0 && entries[len(entries) - 1].preroll == s.preroll {
			entries[len(entries) - 1].count += 1
		} else {
			append(&entries, Entry{1, s.preroll})
			if s.preroll != 0 { rolls += 1 }
		}
	}
	if rolls == 0 { return }

	sgpd := full_box_begin(b, "sgpd", 1, 0)
	put_fourcc(b, "roll")
	put_u32(b, 2)       // default length
	put_u32(b, rolls)
	for e in entries { if e.preroll != 0 { put_u16(b, e.preroll) } }
	box_end(b, sgpd)

	group := in_fragment ? 0x10001 : 1
	sbgp := full_box_begin(b, "sbgp", 0, 0)
	put_fourcc(b, "roll")
	put_u32(b, len(entries))
	for e in entries {
		put_u32(b, e.count)
		if e.preroll != 0 {
			put_u32(b, group)
			group += 1
		} else {
			put_u32(b, 0)   // no preroll: no group
		}
	}
	box_end(b, sbgp)
}

////////////////////////////////
// Sample descriptions

// Sample Description Box: one entry, the codec's sample entry.
@(private = "file")
stsd :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	start := full_box_begin(b, "stsd", 0, 0)
	put_u32(b, 1)
	if t.is_video { video_sample_entry(t, b) } else { audio_sample_entry(t, b) }
	box_end(b, start)
}

@(private = "file")
video_sample_entry :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	v := &t.video
	name: string
	switch v.codec {
	case .AVC:  name = "avc1"
	case .HEVC: name = "hvc1"
	case .VP8:  name = "vp08"
	case .VP9:  name = "vp09"
	case .AV1:  name = "av01"
	}
	start := box_begin(b, name)
	put_zeros(b, 6)   // reserved
	put_u16(b, 1)     // data reference index
	put_u16(b, 0)     // pre-defined
	put_u16(b, 0)     // reserved
	put_zeros(b, 12)  // pre-defined
	put_u16(b, v.width)
	put_u16(b, v.height)
	put_u32(b, 0x00480000)   // horizontal resolution: 72 dpi
	put_u32(b, 0x00480000)   // vertical resolution
	put_u32(b, 0)     // reserved
	put_u16(b, 1)     // frame count
	// Compressor name: a Pascal-style string in 32 bytes
	put_u8(b, len(MUXING_APP))
	append(b, MUXING_APP)
	put_zeros(b, 31 - len(MUXING_APP))
	put_u16(b, 24)       // depth
	put_u16(b, 0xFFFF)   // pre-defined: -1

	switch v.codec {
	case .AVC, .HEVC:
		// The decoder configuration record (avcC, hvcC) is the description as it is
		config := box_begin(b, v.codec == .AVC ? "avcC" : "hvcC")
		append(b, ..t.description)
		box_end(b, config)
	case .VP8, .VP9:
		vpcc(t, b)
	case .AV1:
		config := box_begin(b, "av1C")
		record := av1_config_record(v.av1)
		append(b, ..record[:])
		box_end(b, config)
	}
	if color, ok := v.color.?; ok {
		// Colour Information Box
		colr := box_begin(b, "colr")
		put_fourcc(b, "nclx")
		put_u16(b, color.primaries)
		put_u16(b, color.transfer)
		put_u16(b, color.coefficients)
		put_u8(b, bit(color.full_range) << 7)
		box_end(b, colr)
	}
	btrt(t, b)
	box_end(b, start)
}

// VP Configuration Box (https://www.webmproject.org/vp9/mp4/). Mediabunny reads it from the codec string; VP8 has
// none of its fields, so it gets profile 0, 8 bits and 4:2:0.
@(private = "file")
vpcc :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	v := &t.video
	profile, level, depth, chroma: u8 = 0, 0, 8, 1
	if v.codec == .VP9 {
		profile, level, chroma = v.vp9.profile, v.vp9.level, v.vp9.chroma_subsampling
		if v.vp9.bit_depth != 0 { depth = v.vp9.bit_depth }
	}
	primaries, transfer, coefficients: u8 = 1, 1, 1
	full_range: u8
	if color, ok := v.color.?; ok {
		primaries, transfer, coefficients, full_range = color.primaries, color.transfer, color.coefficients, bit(color.full_range)
	}
	start := full_box_begin(b, "vpcC", 1, 0)
	put_u8(b, profile)
	put_u8(b, level)
	put_u8(b, depth << 4 | chroma << 1 | full_range)
	put_u8(b, primaries)
	put_u8(b, transfer)
	put_u8(b, coefficients)
	put_u16(b, 0)   // codec initialization data size
	box_end(b, start)
}

// Bit Rate Box: the average and peak bitrate; none when both are unknown (fragmented files).
@(private = "file")
btrt :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	if t.mp4.avg_bitrate == 0 && t.mp4.max_bitrate == 0 { return }
	start := box_begin(b, "btrt")
	put_u32(b, 0)   // decoding buffer size: unknown
	put_u32(b, t.mp4.max_bitrate)
	put_u32(b, t.mp4.avg_bitrate)
	box_end(b, start)
}

// Sound Sample Description Box, version 0.
@(private = "file")
audio_sample_entry :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	a := &t.audio
	start := box_begin(b, a.codec == .AAC ? "mp4a" : "Opus")
	put_zeros(b, 6)   // reserved
	put_u16(b, 1)     // data reference index
	put_u16(b, 0)     // version
	put_u16(b, 0)     // revision level
	put_u32(b, 0)     // vendor
	put_u16(b, a.channels)
	put_u16(b, 16)    // sample size (bits)
	put_u16(b, 0)     // compression ID
	put_u16(b, 0)     // packet size
	put_u16(b, a.sample_rate < 1 << 16 ? a.sample_rate : 0)   // sample rate, 16.16
	put_u16(b, 0)
	switch a.codec {
	case .AAC:  esds(t, b)
	case .Opus: dops(t, b)
	}
	btrt(t, b)
	box_end(b, start)
}

// A descriptor length as MPEG-4 systems write it: 7 bits a byte, the high bit on all but the last.
@(private = "file")
put_descriptor_length :: proc(b: ^[dynamic]u8, n: int) {
	bytes: [5]u8
	count := 0
	rest := n
	for {
		bytes[count] = u8(rest & 0x7F)
		count += 1
		rest >>= 7
		if rest == 0 { break }
	}
	for i := count - 1; i >= 0; i -= 1 { put_u8(b, bytes[i] | (i > 0 ? 0x80 : 0)) }
}

// MPEG-4 Elementary Stream Descriptor Box, built inside out: the decoder config, the ES descriptor, the object one.
@(private = "file")
esds :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	config := make([dynamic]u8, context.temp_allocator)
	put_u8(&config, 0x40)   // object type indication: MPEG-4 audio (AAC)
	put_u8(&config, 0x15)   // stream type 5 (audio) << 2 | 1
	put_u24(&config, 0)     // buffer size
	put_u32(&config, t.mp4.max_bitrate)
	put_u32(&config, t.mp4.avg_bitrate)
	if len(t.description) > 0 {
		put_u8(&config, 0x05)   // DecoderSpecificInfo
		put_descriptor_length(&config, len(t.description))
		append(&config, ..t.description)
	}
	es := make([dynamic]u8, context.temp_allocator)
	put_u16(&es, 1)      // ES_ID
	put_u8(&es, 0x00)    // flags
	put_u8(&es, 0x04)    // DecoderConfigDescriptor
	put_descriptor_length(&es, len(config))
	append(&es, ..config[:])
	put_u8(&es, 0x06)    // SLConfigDescriptor
	put_u8(&es, 0x01)
	put_u8(&es, 0x02)

	start := full_box_begin(b, "esds", 0, 0)
	put_u8(b, 0x03)      // ES_Descriptor
	put_descriptor_length(b, len(es))
	append(b, ..es[:])
	box_end(b, start)
}

// Opus Specific Box (https://www.opus-codec.org/docs/opus_in_isobmff.html), from the OpusHead when there is one.
@(private = "file")
dops :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	head := Opus_Head{
		channels          = u8(t.audio.channels),
		pre_skip          = 312,
		input_sample_rate = u32(t.audio.sample_rate),
	}
	if parsed, ok := parse_opus_head(t.description); ok { head = parsed }
	start := box_begin(b, "dOps")
	put_u8(b, 0)   // version
	put_u8(b, head.channels)
	put_u16(b, head.pre_skip)
	put_u32(b, head.input_sample_rate)
	put_u16(b, head.output_gain)
	put_u8(b, head.mapping_family)
	append(b, ..head.mapping_table)
	box_end(b, start)
}

////////////////////////////////
// Fragments

// Track Extends Box: the defaults of the movie fragments.
@(private = "file")
trex :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	start := full_box_begin(b, "trex", 0, 0)
	put_u32(b, t.id)
	put_u32(b, 1)   // default sample description index
	put_u32(b, 0)   // default sample duration
	put_u32(b, 0)   // default sample size
	put_u32(b, 0)   // default sample flags
	box_end(b, start)
}

// Movie Fragment Box: the fragment header and a track fragment for each track in it.
@(private)
mp4_moof :: proc(b: ^[dynamic]u8, sequence_number: u32, tracks: []^Track_State) {
	start := box_begin(b, "moof")
	mfhd := full_box_begin(b, "mfhd", 0, 0)
	put_u32(b, sequence_number)
	box_end(b, mfhd)
	for t in tracks { traf(t, b) }
	box_end(b, start)
}

@(private = "file")
fragment_sample_flags :: proc(s: ^Sample) -> u32 {
	// A difference sample has redundant coding (1) and is_non_sync; a key frame has none (2)
	return s.key ? 2 << 24 : 1 << 24 | 1 << 16
}

// Track Fragment Box
@(private = "file")
traf :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	chunk := t.mp4.current_chunk
	samples := chunk.samples[:]
	start := box_begin(b, "traf")

	// Track Fragment Header Box: defaults from the second sample (the first one is a sync sample, the odd one out)
	reference := len(samples) > 1 ? samples[1] : samples[0]
	DEFAULT_DURATION :: 0x00008
	DEFAULT_SIZE :: 0x00010
	DEFAULT_FLAGS :: 0x00020
	DEFAULT_BASE_IS_MOOF :: 0x20000
	tfhd := full_box_begin(b, "tfhd", 0, DEFAULT_DURATION | DEFAULT_SIZE | DEFAULT_FLAGS | DEFAULT_BASE_IS_MOOF)
	put_u32(b, t.id)
	put_u32(b, reference.units_to_next)
	put_u32(b, reference.size)
	put_u32(b, fragment_sample_flags(reference))
	box_end(b, tfhd)

	// Track Fragment Decode Time Box: the decode time of the fragment's first sample
	tfdt := full_box_begin(b, "tfdt", 1, 0)
	put_u64(b, into_timescale(chunk.start_timestamp, t.mp4.timescale))
	box_end(b, tfdt)

	trun(t, b)
	sgpd_and_sbgp(b, samples, true)
	box_end(b, start)
}

// Track Run Box: the run of the fragment's samples, each field written only when the samples differ in it.
@(private = "file")
trun :: proc(t: ^Track_State, b: ^[dynamic]u8) {
	chunk := t.mp4.current_chunk
	samples := chunk.samples[:]
	n := len(samples)
	flags0 := fragment_sample_flags(samples[0])
	durations_differ, sizes_differ, flags_differ, offsets_present, flag0_again := false, false, false, false, false
	for s, i in samples {
		if s.units_to_next != samples[0].units_to_next { durations_differ = true }
		if s.size != samples[0].size { sizes_differ = true }
		f := fragment_sample_flags(s)
		if f != flags0 { flags_differ = true }
		if i > 0 && f == flags0 { flag0_again = true }
		if composition_offset(t, s) != 0 { offsets_present = true }
	}
	// (Two flag values only exist: key and delta.) The first sample alone has its own flags: a key frame, then deltas
	first_flags_present := flags_differ && !flag0_again
	flags_present := !first_flags_present && flags_differ

	tr_flags: i64 = 0x0001   // data offset present
	if first_flags_present { tr_flags |= 0x0004 }
	if durations_differ { tr_flags |= 0x0100 }
	if sizes_differ { tr_flags |= 0x0200 }
	if flags_present { tr_flags |= 0x0400 }
	if offsets_present { tr_flags |= 0x0800 }

	start := full_box_begin(b, "trun", 1, tr_flags)
	put_u32(b, n)
	put_u32(b, chunk.offset - chunk.moof_offset)   // data offset from the moof
	if first_flags_present { put_u32(b, flags0) }
	for s in samples {
		if durations_differ { put_u32(b, s.units_to_next) }
		if sizes_differ { put_u32(b, s.size) }
		if flags_present { put_u32(b, fragment_sample_flags(s)) }
		if offsets_present { put_u32(b, composition_offset(t, s)) }
	}
	box_end(b, start)
}

@(private = "file")
composition_offset :: proc(t: ^Track_State, s: ^Sample) -> i64 {
	return into_timescale(s.timestamp - s.decode_timestamp, t.mp4.timescale)
}

// Movie Fragment Random Access Box: for each track, the sync samples' times and fragments; its last box, mfro, says
// the size of the whole mfra (readers find it from the end of the file).
@(private)
mp4_mfra :: proc(m: ^Muxer, b: ^[dynamic]u8) {
	start := box_begin(b, "mfra")
	for t in m.tracks {
		if !t.configured { continue }
		// Version 1: 64-bit times and offsets
		tfra := full_box_begin(b, "tfra", 1, 0)
		put_u32(b, t.id)
		put_u32(b, 0b111111)   // traf, trun and sample numbers on 32 bits
		put_u32(b, len(t.mp4.random_access))
		for e in t.mp4.random_access {
			put_u64(b, e.time)
			put_u64(b, e.moof_offset)
			put_u32(b, e.traf_number)
			put_u32(b, 1)   // trun number
			put_u32(b, e.sample_number)
		}
		box_end(b, tfra)
	}
	mfro := full_box_begin(b, "mfro", 0, 0)
	put_u32(b, 0)
	box_end(b, mfro)
	box_end(b, start)
	n := len(b^) - start
	end := len(b^)
	b^[end - 4], b^[end - 3], b^[end - 2], b^[end - 1] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
}
