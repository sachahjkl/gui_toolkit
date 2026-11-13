// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Ported to Odin from Mediabunny (https://github.com/Vanilagy/mediabunny, commit 173f6b7): src/isobmff/isobmff-muxer.ts.
// Left out: QuickTime, CMAF, fastStart 'reserve', subtitles, PCM, the write-tracking callbacks.
package tk_mux

import "core:container/queue"
import "core:math"
import "core:slice"
import "core:time"

GLOBAL_TIMESCALE :: 57600       // LCM of a bunch of common frame rates (24, 25, 30, 60, 144, ...)
@(private) MIN_CHUNK_DURATION :: 0.5   // in seconds
@(private) TIMESTAMP_OFFSET :: 2_082_844_800   // seconds between Jan 1 1904 and Jan 1 1970
@(private) MIN_BOX_HEADER_SIZE :: 8
@(private) MAX_BOX_HEADER_SIZE :: 16

@(private)
Sample :: struct {
	timestamp:        f64,
	decode_timestamp: f64,     // may be refined later
	duration:         f64,
	data:             []u8,    // nil once written
	size:             int,
	key:              bool,
	units_to_next:    i64,     // timescale units to the next sample; refined
	preroll:          int,     // samples before this one needed to decode it (roll groups), negative
}

@(private)
Chunk :: struct {
	start_timestamp: f64,      // the lowest presentation timestamp in this chunk
	samples:         [dynamic]^Sample,
	offset:          i64,
	moof_offset:     i64,      // fragmented: where the moof pointing to the chunk's data is
	traf_index:      int,      // fragmented: the traf of that moof
}

@(private) Stts_Entry :: struct { count, delta: i64 }
@(private) Ctts_Entry :: struct { count, offset: i64 }
@(private) Stsc_Entry :: struct { first_chunk, samples_per_chunk: i64 }
@(private) Tfra_Entry :: struct { time, moof_offset: i64, traf_number, sample_number: int }

@(private)
Mp4_Track :: struct {
	timescale:           i64,
	samples:             [dynamic]^Sample,          // not fragmented: every sample, in decode order (owned)
	sample_queue:        queue.Queue(^Sample),      // waiting to be interleaved (owned)
	timestamp_queue:     [dynamic]^Sample,          // the group of pictures whose decode times are not known yet
	time_to_sample:      [dynamic]Stts_Entry,
	composition_offsets: [dynamic]Ctts_Entry,
	last_units:          f64,
	has_last_units:      bool,
	last_sample:         ^Sample,
	start_offset:        f64,
	has_start_offset:    bool,
	chunks:              [dynamic]^Chunk,           // finalized (not fragmented)
	current_chunk:       ^Chunk,
	chunk_table:         [dynamic]Stsc_Entry,
	random_access:       [dynamic]Tfra_Entry,       // fragmented: the tfra's entries
	avg_bitrate:         i64,                       // 0: unknown
	max_bitrate:         i64,
	preroll_packets:     int,
	preroll_accumulated: int,
	preroll_history:     [dynamic]int,              // Opus: the durations of the packets in the preroll window
}

@(private)
Mp4_State :: struct {
	fast_start:            Fast_Start,   // In_Memory, Fragmented or Off
	fragmented:            bool,
	creation_time:         i64,          // seconds since 1904
	minimum_fragment:      f64,
	wrote_header:          bool,
	mdat_offset:           i64,          // Off: the mdat whose size finalize writes
	chunks:                [dynamic]^Chunk,   // every finalized chunk, in order (In_Memory lays them out)
	wrote_moov:            bool,         // fragmented
	next_fragment:         u32,
	max_written_timestamp: f64,          // fragmented: a new fragment starts past the highest timestamp written
	scratch:               [dynamic]u8,  // boxes being made
}

@(private)
into_timescale :: proc(seconds: f64, #any_int timescale: i64) -> i64 {
	return i64(js_round(seconds * f64(timescale)))
}

// The time from the earliest sample's start to the latest sample's end; 0 without samples.
@(private)
presentation_span :: proc(t: ^Track_State) -> f64 {
	if len(t.mp4.samples) == 0 { return 0 }
	lowest, highest := math.inf_f64(1), math.inf_f64(-1)
	for s in t.mp4.samples {
		lowest = min(lowest, s.timestamp)
		highest = max(highest, s.timestamp + s.duration)
	}
	return highest - lowest
}

// The denominator of the best rational approximation of `x` (continued fractions) with one up to `max_denominator`.
@(private = "file")
rational_denominator :: proc(x: f64, max_denominator: f64) -> i64 {
	previous_numerator, previous_denominator: f64 = 0, 1
	numerator, denominator: f64 = 1, 0
	remainder := x
	for {
		whole := math.floor(remainder)
		next_numerator := whole * numerator + previous_numerator
		next_denominator := whole * denominator + previous_denominator
		if next_denominator > max_denominator { break }
		previous_numerator, previous_denominator = numerator, denominator
		numerator, denominator = next_numerator, next_denominator
		remainder = 1 / (remainder - whole)
		if math.is_inf(remainder) || math.is_nan(remainder) { break }   // guard against precision issues
	}
	return i64(denominator)
}

////////////////////////////////
// Start and tracks

@(private)
mp4_start :: proc(m: ^Muxer, o: Mp4_Options) -> Error {
	mp := &m.mp4
	mp.fast_start = o.fast_start
	if mp.fast_start == .Default {
		// In memory, fast start costs no more memory: the file is held whole anyway
		mp.fast_start = m.writer.sink == .Memory ? .In_Memory : .Off
	}
	mp.fragmented = mp.fast_start == .Fragmented
	mp.creation_time = time.time_to_unix(m.creation_time) + TIMESTAMP_OFFSET
	mp.minimum_fragment = o.minimum_fragment_duration > 0 ? o.minimum_fragment_duration : 1
	mp.next_fragment = 1
	mp.max_written_timestamp = math.inf_f64(-1)
	mp.chunks = make([dynamic]^Chunk, m.allocator)
	mp.scratch = make([dynamic]u8, m.allocator)
	return .None
}

@(private)
mp4_track_init :: proc(m: ^Muxer, t: ^Track_State) {
	tr := &t.mp4
	if t.is_video {
		// The frame rate may not be an integer, and a timescale is: the denominator of a rational approximation
		// of the frame time is the timescale
		rate := t.video.frame_rate > 0 ? t.video.frame_rate : GLOBAL_TIMESCALE
		tr.timescale = rational_denominator(1 / rate, 1e6)
	} else {
		tr.timescale = i64(t.audio.sample_rate)
	}
	queue.init(&tr.sample_queue, 64, m.allocator)
}

// The ftyp, and without fast start the mdat whose size finalize writes: when the tracks are known (the first packet).
@(private = "file")
write_header :: proc(m: ^Muxer) {
	mp := &m.mp4
	mp.wrote_header = true
	holds_avc := false
	for t in m.tracks { if t.is_video && t.video.codec == .AVC { holds_avc = true } }
	clear(&mp.scratch)
	mp4_ftyp(&mp.scratch, mp.fragmented, holds_avc)
	if mp.fast_start == .Off {
		// A large size reserved by default; finalize writes the size it needs
		mp.mdat_offset = m.writer.pos + i64(len(mp.scratch))
		put_u32(&mp.scratch, 1)
		put_fourcc(&mp.scratch, "mdat")
		put_u64(&mp.scratch, MAX_BOX_HEADER_SIZE)
	}
	writer_write(&m.writer, mp.scratch[:])
	writer_flush(&m.writer)
}

////////////////////////////////
// Packets

@(private)
mp4_add_packet :: proc(m: ^Muxer, t: ^Track_State, data: []u8, timestamp, duration: f64, key: bool) -> Error {
	if !m.mp4.wrote_header { write_header(m) }
	tr := &t.mp4
	if t.is_video {
		packet: []u8
		if t.annex_b {
			if !t.configured {
				// MP4 holds H.264 in AVCC, not in Annex B: the avcC comes from the first packet's SPS and PPS
				record, sps, ok := avc_config_from_annex_b(data)
				if !ok { return .No_Parameter_Sets }
				// (4:2:0 crops by pairs of pixels: an odd side is coded one pixel larger, and the track keeps the true size)
				if !size_fits(sps.display_width, t.video.width) || !size_fits(sps.display_height, t.video.height) {
					delete(record)
					return .Size_Mismatch
				}
				t.description = record
				t.video.description = record
				t.configured = true
			}
			units := annex_b_units(data)
			if len(units) == 0 { return .Invalid_Packet }   // not Annex B
			// The SPS and PPS stay in the samples: they can also appear in the middle of a stream and change it
			packet = length_prefixed(units[:])
		} else {
			packet = clone(data)
		}
		if err := order_check(&t.order, timestamp, key); err != .None {
			delete(packet)
			return err
		}
		register_sample(m, t, new_sample(packet, timestamp, duration, key, 0))
		return .None
	}

	packet := data
	if t.adts {
		// MP4 holds raw AAC, not ADTS: the AudioSpecificConfig comes from the first header, every header goes
		header, ok := read_adts_header(data)
		if !ok { return .Invalid_Packet }
		if !t.configured {
			t.description = aac_config_from_adts(header)
			t.audio.description = t.description
			t.configured = true
		}
		packet = data[header.header_size:]
		if len(packet) == 0 { return .Invalid_Packet }
	}
	order_check(&t.order, timestamp, key) or_return

	// How many samples (packets) of preroll the codec needs to decode properly
	preroll := 0
	switch t.audio.codec {
	case .AAC:
		preroll = -min(1, tr.preroll_packets)
	case .Opus:
		OPUS_PREROLL_SAMPLES :: 19200   // round(OPUS_PRE_ROLL_DURATION * OPUS_SAMPLE_RATE)
		preroll = -len(tr.preroll_history)
		samples := opus_packet_samples(packet)
		tr.preroll_accumulated += samples
		append(&tr.preroll_history, samples)
		for len(tr.preroll_history) > 1 && tr.preroll_accumulated - tr.preroll_history[0] >= OPUS_PREROLL_SAMPLES {
			tr.preroll_accumulated -= tr.preroll_history[0]
			ordered_remove(&tr.preroll_history, 0)
		}
	}
	tr.preroll_packets += 1
	register_sample(m, t, new_sample(clone(packet), timestamp, duration, key, preroll))
	return .None
}

@(private = "file")
new_sample :: proc(data: []u8, timestamp, duration: f64, key: bool, preroll: int) -> ^Sample {
	s := new(Sample)
	s^ = {
		timestamp        = timestamp,
		decode_timestamp = timestamp,
		duration         = duration,
		data             = data,
		size             = len(data),
		key              = key,
		preroll          = preroll,
	}
	return s
}

@(private)
mp4_close_track :: proc(m: ^Muxer, t: ^Track_State) -> Error {
	process_timestamps(m, t)
	// A track closed: chunks that were waiting for it may go out
	interleave(m, false)
	return .None
}

// The decode times of a group of pictures (the samples since the last key frame) and the stts and ctts entries.
// Only presentation times are given, possibly out of order: a sensible decode time is the sorted presentation times.
@(private = "file")
process_timestamps :: proc(m: ^Muxer, t: ^Track_State, next: ^Sample = nil) {
	tr := &t.mp4
	if len(tr.timestamp_queue) == 0 { return }
	fragmented := m.mp4.fragmented

	sorted := make([]f64, len(tr.timestamp_queue), context.temp_allocator)
	for s, i in tr.timestamp_queue { sorted[i] = s.timestamp }
	slice.sort(sorted)
	if !tr.has_start_offset {
		tr.start_offset = fragmented ? min(sorted[0], 0) : sorted[0]
		tr.has_start_offset = true
	}

	for s, i in tr.timestamp_queue {
		s.decode_timestamp = sorted[i]
		offset := into_timescale(s.timestamp - s.decode_timestamp, tr.timescale)
		duration := into_timescale(s.duration, tr.timescale)

		if tr.has_last_units {
			units := s.decode_timestamp * f64(tr.timescale)
			delta := i64(js_round(units - tr.last_units))
			tr.last_units += f64(delta)
			tr.last_sample.units_to_next = delta

			if !fragmented {
				last := len(tr.time_to_sample) - 1
				if tr.time_to_sample[last].count == 1 {
					tr.time_to_sample[last].delta = delta
					if last > 0 && tr.time_to_sample[last - 1].delta == delta {
						// The same delta as the entry before: merge the two
						tr.time_to_sample[last - 1].count += 1
						pop(&tr.time_to_sample)
						last -= 1
					}
				} else if tr.time_to_sample[last].delta != delta {
					// The delta changed: a new entry reaches the current sample
					tr.time_to_sample[last].count -= 1
					append(&tr.time_to_sample, Stts_Entry{1, delta})
					last += 1
				}
				if tr.time_to_sample[last].delta == duration {
					tr.time_to_sample[last].count += 1
				} else {
					// A new entry keeps the last sample's true duration
					append(&tr.time_to_sample, Stts_Entry{1, duration})
				}

				last_offset := len(tr.composition_offsets) - 1
				if tr.composition_offsets[last_offset].offset == offset {
					tr.composition_offsets[last_offset].count += 1
				} else {
					append(&tr.composition_offsets, Ctts_Entry{1, offset})
				}
			}
		} else {
			// The decode time of the first sample
			tr.last_units = s.decode_timestamp * f64(tr.timescale)
			tr.has_last_units = true
			if !fragmented {
				append(&tr.time_to_sample, Stts_Entry{1, duration})
				append(&tr.composition_offsets, Ctts_Entry{1, offset})
			}
		}
		tr.last_sample = s
	}
	clear(&tr.timestamp_queue)

	if next != nil && tr.last_sample.units_to_next == 0 {
		// The next key frame gives a guess of the last sample's duration, so that a fragment's last sample does not
		// last 0; it is right most of the time (a delta frame with a lower timestamp rarely follows a key frame)
		units := next.timestamp * f64(tr.timescale)
		tr.last_sample.units_to_next = i64(js_round(units - tr.last_units))
	}
}

@(private = "file")
register_sample :: proc(m: ^Muxer, t: ^Track_State, s: ^Sample) {
	s.units_to_next = into_timescale(s.duration, t.mp4.timescale)   // (refined by process_timestamps)
	if s.key { process_timestamps(m, t, s) }
	append(&t.mp4.timestamp_queue, s)
	queue.push_back(&t.mp4.sample_queue, s)
	interleave(m, false)
}

// Moves samples from the queues to the tracks by timestamp, while every open track has one queued (or all, at the end).
@(private = "file")
interleave :: proc(m: ^Muxer, final: bool) {
	for {
		best: ^Track_State
		lowest := math.inf_f64(1)
		for t in m.tracks {
			n := queue.len(t.mp4.sample_queue)
			if !final && n == 0 && !t.closed { return }
			if n > 0 {
				front := queue.front(&t.mp4.sample_queue)
				if front.timestamp < lowest {
					best = t
					lowest = front.timestamp
				}
			}
		}
		if best == nil { return }
		add_sample_to_track(m, best, queue.pop_front(&best.mp4.sample_queue))
	}
}

@(private = "file")
add_sample_to_track :: proc(m: ^Muxer, t: ^Track_State, s: ^Sample) {
	mp := &m.mp4
	tr := &t.mp4
	if !mp.fragmented { append(&tr.samples, s) }

	begin_new := false
	if tr.current_chunk == nil {
		begin_new = true
	} else {
		// Timestamps need not be monotonic (B-frames): the chunk's start may move back
		tr.current_chunk.start_timestamp = min(tr.current_chunk.start_timestamp, s.timestamp)
		chunk_duration := s.timestamp - tr.current_chunk.start_timestamp
		if mp.fragmented {
			// A fragment ends only when every track can start the next one with a key frame
			key_everywhere := true
			for other in m.tracks {
				if other == t {
					if !s.key { key_everywhere = false }
				} else if queue.len(other.mp4.sample_queue) > 0 {
					if !queue.front(&other.mp4.sample_queue).key { key_everywhere = false }
				} else if !other.closed {
					key_everywhere = false
				}
			}
			if chunk_duration >= mp.minimum_fragment && key_everywhere && s.timestamp > mp.max_written_timestamp {
				begin_new = true
				finalize_fragment(m, true)
			}
		} else {
			begin_new = chunk_duration >= MIN_CHUNK_DURATION
		}
	}

	if begin_new {
		if !mp.fragmented {
			// The other tracks' chunks may end too (samples come interleaved by timestamp). Chunks go out in
			// chronological order: some players behave better so
			ending := make([dynamic]^Track_State, context.temp_allocator)
			for other in m.tracks {
				c := other.mp4.current_chunk
				if c != nil && s.timestamp - c.start_timestamp >= MIN_CHUNK_DURATION { append(&ending, other) }
			}
			slice.stable_sort_by(ending[:], by_chunk_start)
			for other in ending { finalize_current_chunk(m, other) }
		}
		tr.current_chunk = new(Chunk)
		tr.current_chunk.start_timestamp = s.timestamp
	}
	append(&tr.current_chunk.samples, s)
	if mp.fragmented { mp.max_written_timestamp = max(mp.max_written_timestamp, s.timestamp) }
}

@(private = "file")
by_chunk_start :: proc(a, b: ^Track_State) -> bool {
	return a.mp4.current_chunk.start_timestamp < b.mp4.current_chunk.start_timestamp
}

// Not fragmented: the chunk joins the track's table and, without in-memory fast start, its data goes out.
@(private = "file")
finalize_current_chunk :: proc(m: ^Muxer, t: ^Track_State) {
	tr := &t.mp4
	chunk := tr.current_chunk
	tr.current_chunk = nil
	append(&tr.chunks, chunk)
	append(&m.mp4.chunks, chunk)

	n := i64(len(chunk.samples))
	if len(tr.chunk_table) == 0 || tr.chunk_table[len(tr.chunk_table) - 1].samples_per_chunk != n {
		append(&tr.chunk_table, Stsc_Entry{i64(len(tr.chunks)), n})   // (chunks count from 1)
	}
	if m.mp4.fast_start == .In_Memory { return }   // (finalize lays the chunks out)

	chunk.offset = m.writer.pos
	for s in chunk.samples {
		writer_write(&m.writer, s.data)
		delete(s.data)
		s.data = nil
	}
	writer_flush(&m.writer)
}

// Fragmented: the moov before the first fragment, then a moof and its mdat with every track's current chunk.
@(private = "file")
finalize_fragment :: proc(m: ^Muxer, flush: bool) {
	mp := &m.mp4
	w := &m.writer
	if !mp.wrote_moov {
		// The moov goes out with the first fragment: every decoder configuration is known by then
		mp.wrote_moov = true
		clear(&mp.scratch)
		mp4_moov(m, &mp.scratch)
		writer_write(w, mp.scratch[:])
	}

	// Not every track needs to be in every fragment
	in_fragment := make([dynamic]^Track_State, context.temp_allocator)
	for t in m.tracks { if t.mp4.current_chunk != nil { append(&in_fragment, t) } }
	if len(in_fragment) == 0 {
		if flush { writer_flush(w) }
		return
	}

	sequence := mp.next_fragment
	mp.next_fragment += 1

	// A moof made once to measure it: where the mdat after it begins
	clear(&mp.scratch)
	mp4_moof(&mp.scratch, sequence, in_fragment[:])
	moof_offset := w.pos
	mdat_start := moof_offset + i64(len(mp.scratch))

	position := mdat_start + MIN_BOX_HEADER_SIZE
	for t, i in in_fragment {
		c := t.mp4.current_chunk
		c.offset = position
		c.moof_offset = moof_offset
		c.traf_index = i
		c.start_timestamp -= t.mp4.start_offset
		for s in c.samples {
			position += i64(s.size)
			s.timestamp -= t.mp4.start_offset
			s.decode_timestamp -= t.mp4.start_offset
		}
	}
	mdat_size := position - mdat_start
	large := mdat_size >= 1 << 32
	if large {
		// Mediabunny shifts the offsets by the larger header (a WebKit bug with offsets made for it from the start);
		// the size counts that header too (Mediabunny leaves it 8 bytes short)
		for t in in_fragment { t.mp4.current_chunk.offset += MAX_BOX_HEADER_SIZE - MIN_BOX_HEADER_SIZE }
		mdat_size += MAX_BOX_HEADER_SIZE - MIN_BOX_HEADER_SIZE
	}

	clear(&mp.scratch)
	mp4_moof(&mp.scratch, sequence, in_fragment[:])
	if large {
		put_u32(&mp.scratch, 1)
		put_fourcc(&mp.scratch, "mdat")
		put_u64(&mp.scratch, mdat_size)
	} else {
		put_u32(&mp.scratch, mdat_size)
		put_fourcc(&mp.scratch, "mdat")
	}
	writer_write(w, mp.scratch[:])

	for t, i in in_fragment {
		tr := &t.mp4
		c := tr.current_chunk
		for s in c.samples { writer_write(w, s.data) }
		// The tfra points at sync samples; every fragment starts with one for every track anyway
		for s, k in c.samples {
			if !s.key { continue }
			append(&tr.random_access, Tfra_Entry{into_timescale(s.timestamp, tr.timescale), c.moof_offset, i + 1, k + 1})
			break
		}
		free_chunk(c, true)
		tr.current_chunk = nil
	}
	if flush { writer_flush(w) }
}

@(private = "file")
free_chunk :: proc(c: ^Chunk, with_samples: bool) {
	if with_samples {
		for s in c.samples {
			delete(s.data)
			free(s)
		}
	}
	delete(c.samples)
	free(c)
}

////////////////////////////////
// Finalize

@(private)
mp4_finalize :: proc(m: ^Muxer) -> Error {
	mp := &m.mp4
	w := &m.writer
	if !mp.wrote_header { write_header(m) }
	for t in m.tracks {
		t.closed = true
		process_timestamps(m, t)
	}
	interleave(m, true)

	if mp.fragmented {
		finalize_fragment(m, false)   // flushed with the mfra
	} else {
		ending := make([dynamic]^Track_State, context.temp_allocator)
		for t in m.tracks { if t.mp4.current_chunk != nil { append(&ending, t) } }
		slice.stable_sort_by(ending[:], by_chunk_start)
		for t in ending { finalize_current_chunk(m, t) }

		for t in m.tracks {
			tr := &t.mp4
			// Now that every sample is known, the measured bitrates replace the nominal ones
			span := presentation_span(t)
			total: i64
			for s in tr.samples { total += i64(s.size) }
			tr.avg_bitrate = span > 0 ? i64(js_round(8 * f64(total) / span)) : 0

			// A one-second window sliding over the samples in decode order
			window_start, window_bytes, max_window_bytes: i64
			for s in tr.samples {
				window_bytes += i64(s.size)
				for s.decode_timestamp - tr.samples[window_start].decode_timestamp >= 1 {
					window_bytes -= i64(tr.samples[window_start].size)
					window_start += 1
				}
				max_window_bytes = max(max_window_bytes, window_bytes)
			}
			tr.max_bitrate = 8 * max_window_bytes

			if tr.has_start_offset {
				// The samples shift by the start offset; an edit list shifts them back in the composition
				for s in tr.samples {
					s.timestamp -= tr.start_offset
					s.decode_timestamp -= tr.start_offset
				}
			}
		}
	}

	switch mp.fast_start {
	case .In_Memory:
		// Where the first chunk goes needs the moov's size, which needs the chunk offsets: a moov with offsets 0 gives
		// the size. When the chunks then pass 4 GiB, it is made again with co64 (larger), which settles it.
		large_mdat := false
		mdat_size: i64
		for _ in 0 ..< 2 {
			clear(&mp.scratch)
			mp4_moov(m, &mp.scratch)
			mdat_size = large_mdat ? MAX_BOX_HEADER_SIZE : MIN_BOX_HEADER_SIZE
			position := w.pos + i64(len(mp.scratch)) + mdat_size
			for c in mp.chunks {
				c.offset = position
				for s in c.samples {
					position += i64(s.size)
					mdat_size += i64(s.size)
				}
			}
			if position < 1 << 32 { break }
			if mdat_size >= 1 << 32 { large_mdat = true }
		}
		clear(&mp.scratch)
		mp4_moov(m, &mp.scratch)
		if large_mdat {
			put_u32(&mp.scratch, 1)
			put_fourcc(&mp.scratch, "mdat")
			put_u64(&mp.scratch, mdat_size)
		} else {
			put_u32(&mp.scratch, mdat_size)
			put_fourcc(&mp.scratch, "mdat")
		}
		writer_write(w, mp.scratch[:])
		for c in mp.chunks {
			for s in c.samples {
				writer_write(w, s.data)
				delete(s.data)
				s.data = nil
			}
		}
	case .Fragmented:
		// The mfra at the end, for random access
		clear(&mp.scratch)
		mp4_mfra(m, &mp.scratch)
		writer_write(w, mp.scratch[:])
	case .Off, .Default:
		// The mdat's size, the large one only when needed (the 8 bytes it reserved stay in the mdat, unread)
		mdat_size := w.pos - mp.mdat_offset
		end := w.pos
		clear(&mp.scratch)
		if mdat_size >= 1 << 32 {
			put_u32(&mp.scratch, 1)
			put_fourcc(&mp.scratch, "mdat")
			put_u64(&mp.scratch, mdat_size)
		} else {
			put_u32(&mp.scratch, mdat_size)
			put_fourcc(&mp.scratch, "mdat")
		}
		writer_seek(w, mp.mdat_offset)
		writer_write(w, mp.scratch[:])
		writer_seek(w, end)
		clear(&mp.scratch)
		mp4_moov(m, &mp.scratch)
		writer_write(w, mp.scratch[:])
	}
	return .None
}

@(private)
mp4_destroy :: proc(m: ^Muxer) {
	fragmented := m.mp4.fragmented
	for t in m.tracks {
		tr := &t.mp4
		// Not fragmented, the samples are the track's; fragmented, the current chunk's
		for s in tr.samples {
			delete(s.data)
			free(s)
		}
		for queue.len(tr.sample_queue) > 0 {
			s := queue.pop_front(&tr.sample_queue)
			delete(s.data)
			free(s)
		}
		if tr.current_chunk != nil { free_chunk(tr.current_chunk, fragmented) }
		for c in tr.chunks { free_chunk(c, false) }
		queue.destroy(&tr.sample_queue)
		delete(tr.samples)
		delete(tr.timestamp_queue)
		delete(tr.time_to_sample)
		delete(tr.composition_offsets)
		delete(tr.chunks)
		delete(tr.chunk_table)
		delete(tr.random_access)
		delete(tr.preroll_history)
	}
	delete(m.mp4.chunks)
	delete(m.mp4.scratch)
}

// The SPS's side against the track's: the same, or one more for an odd side (H.264 4:2:0 cannot crop a single pixel).
@(private = "file")
size_fits :: proc(coded, track: int) -> bool {
	return coded == track || (track % 2 == 1 && coded == track + 1)
}
