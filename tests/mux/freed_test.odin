package mux_test

// No write into a block the muxer freed. A fragment's samples are freed as soon as it is written, while the recording
// goes on: a pointer kept to one corrupts the heap of the program, and it crashes far from the write. The allocator here
// makes such a write visible on every system, with no sanitizer: a freed block is filled and never given out again, and
// the fill is checked at the end.

import "base:runtime"
import "core:mem"
import "core:testing"
import mux "gt:mux"

@(private = "file") FREED :: 0xDD

@(private = "file")
Quarantine :: struct {
	backing: runtime.Allocator,
	live:    map[rawptr]int,
	freed:   [dynamic][]u8,
	strays:  int,   // frees of what is not live: twice, or never given
}

@(private = "file")
quarantine_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	q := (^Quarantine)(data)
	// (the map and the list are never the muxer's: they live in the backing allocator)
	release :: proc(q: ^Quarantine, p: rawptr) {
		if p == nil { return }
		n, ok := q.live[p]
		if !ok { q.strays += 1; return }
		delete_key(&q.live, p)
		block := ([^]u8)(p)[:n]
		runtime.memset(p, FREED, n)
		append(&q.freed, block)
	}
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		block, err := mem.alloc_bytes(size, alignment, q.backing)
		if err == nil { q.live[raw_data(block)] = size }
		return block, err
	case .Resize, .Resize_Non_Zeroed:
		block, err := mem.alloc_bytes(size, alignment, q.backing)
		if err != nil { return nil, err }
		q.live[raw_data(block)] = size
		if old != nil { runtime.mem_copy(raw_data(block), old, min(size, old_size)) }
		release(q, old)
		return block, nil
	case .Free:
		release(q, old)
		return nil, nil
	case .Free_All, .Query_Features, .Query_Info:
	}
	return nil, .Mode_Not_Implemented
}

@(private = "file")
quarantine_init :: proc(q: ^Quarantine) {
	q.backing = context.allocator
	q.live = make(map[rawptr]int)
	q.freed = make([dynamic][]u8)
}

// Every freed block as it was filled, nothing freed twice, nothing kept.
@(private = "file")
quarantine_end :: proc(t: ^testing.T, q: ^Quarantine, loc := #caller_location) {
	for block in q.freed {
		for b, i in block {
			if b == FREED { continue }
			testing.expectf(t, false, "byte %d of a freed block of %d bytes was written", i, len(block), loc = loc)
			break
		}
		mem.free_bytes(block, q.backing)
	}
	testing.expect_value(t, q.strays, 0, loc = loc)
	testing.expect_value(t, len(q.live), 0, loc = loc)
	delete(q.freed)
	delete(q.live)
}

// A screen recorder's file: one H.264 track, a frame a thirtieth of a second, many fragments.
@(test)
mp4_fragments_leave_freed_samples_alone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	frames := frames_annex_b(300, 30, 30, make_sps(66, 4, 3))
	q: Quarantine
	quarantine_init(&q)
	s := Stream{file = make([dynamic]u8)}
	defer delete(s.file)
	m, _ := mux.mp4_open_stream(stream_write, &s, {fast_start = .Fragmented, creation_time = CREATION}, {quarantine_proc, &q})
	mux_frames(t, m, frames, 30)
	quarantine_end(t, &q)
}

// Two tracks: the samples of one wait in its queue for the other's, so a sample outlives the group it was timed with.
// Frames longer than their track's time scale (a screen that changes rarely) and a recording given up, too.
@(test)
mp4_fragments_of_two_tracks_leave_freed_samples_alone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for finished in ([2]bool{true, false}) {
		frames := frames_annex_b(120, 15, 30, make_sps(66, 4, 3))
		q: Quarantine
		quarantine_init(&q)
		s := Stream{file = make([dynamic]u8)}
		m, _ := mux.mp4_open_stream(stream_write, &s, {fast_start = .Fragmented, creation_time = CREATION}, {quarantine_proc, &q})
		video, _ := mux.add_video_track(m, {codec = .AVC, width = 64, height = 48, frame_rate = 30})
		audio, _ := mux.add_audio_track(m, {codec = .Opus, sample_rate = 48000, channels = 2})
		next_audio: f64
		for f, i in frames {
			at := f.timestamp * 4
			testing.expect_value(t, mux.add_packet(m, video, f.data, at, 4.0 / 30, f.key), mux.Error.None)
			for i < 100 && next_audio <= at {
				testing.expect_value(t, mux.add_packet(m, audio, {0xFC, 1, 2, 3}, next_audio, 0.02, true), mux.Error.None)
				next_audio += 0.02
			}
			if i == 100 { testing.expect_value(t, mux.close_track(m, audio), mux.Error.None) }
		}
		if finished {
			_, err := mux.finalize(m)
			testing.expect_value(t, err, mux.Error.None)
		} else {
			mux.destroy(m)
		}
		quarantine_end(t, &q)
		delete(s.file)
	}
}
