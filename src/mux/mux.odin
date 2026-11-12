// MP4 (ISOBMFF) and WebM (Matroska) muxers: encoded video and audio packets in, a playable file out, in memory, in a
// file or through a writer procedure. The muxers are a port of Mediabunny's (MPL-2.0: the ported files say so at their
// top); this file, the API and the output, is the toolkit's. Every procedure blocks on the output: call them on a
// worker, not on an interface thread. Pure Odin, any target. See docs/mux.md.
package tk_mux

import "base:runtime"
import "core:os"
import "core:time"

Error :: enum u8 {
	None,
	Invalid_Track,       // a size, rate, channel count or decoder configuration the format cannot hold
	Unsupported_Codec,   // the codec has no place in this format (WebM: VP8, VP9, AV1 and Opus only)
	Tracks_Started,      // a track added after the first packet
	Unknown_Track,
	Track_Closed,
	Invalid_Packet,      // empty, or not what the track's configuration says (Annex B, ADTS, an Opus packet)
	No_Parameter_Sets,   // the first H.264 packet in Annex B has no SPS and PPS, or its SPS does not parse
	Size_Mismatch,       // the SPS's picture size is not the track's
	Not_Key_Frame,       // a track's first packet is not a key frame
	Timestamp_Order,     // a packet earlier than the group of pictures before the last key frame
	Too_Large,           // a packet past what the format holds (WebM: 256 MiB a block)
	Open_Failed,
	Write_Failed,
}

Video_Codec :: enum u8 {
	AVC,    // H.264: Annex B (description nil) or AVCC with its avcC as description
	HEVC,   // H.265: length-prefixed packets, the hvcC as description (MP4 only)
	VP8,
	VP9,
	AV1,
}

Audio_Codec :: enum u8 {
	AAC,    // raw frames with the AudioSpecificConfig as description, or ADTS frames (description nil) (MP4 only)
	Opus,   // description: the OpusHead (RFC 7845), or nil for one of 48 kHz, no pre-skip gain and family 0
}

// ISO/IEC 23091-2 codes (H.273): primaries 1, transfer 1, matrix 1 is BT.709; full_range false is the studio range.
Color_Space :: struct {
	primaries, transfer, coefficients: u8,
	full_range:                  bool,
}

// VP9's codec configuration (the vpcC and WebM's CodecPrivate). chroma_subsampling as vpcC writes it: 0 4:2:0
// vertical, 1 4:2:0 colocated with luma (what libvpx makes), 2 4:2:2, 3 4:4:4.
Vp9_Config :: struct {
	profile, level:     u8,   // level: 10 for 1.0 ... 62 for 6.2
	bit_depth:          u8,   // 0: 8
	chroma_subsampling: u8,
}

// AV1's codec configuration (the av1C and WebM's CodecPrivate).
Av1_Config :: struct {
	profile, level:         u8,     // level: seq_level_idx (0 is 2.0, 8 is 4.0)
	high_tier:              bool,
	bit_depth:              u8,     // 0: 8
	monochrome:             bool,
	chroma_subsampling_x:   bool,   // both true: 4:2:0 (set them; false, false is 4:4:4)
	chroma_subsampling_y:   bool,
	chroma_sample_position: u8,
}

Video_Track :: struct {
	codec:         Video_Codec,
	width, height: int,                // the picture's size (H.264: the SPS's after cropping)
	frame_rate:    f64,                // 0: unknown. MP4: the timescale; WebM: DefaultDuration, timestamps on frames
	description:   []u8,               // the decoder configuration record (copied), see Video_Codec
	vp9:           Vp9_Config,
	av1:           Av1_Config,
	color:         Maybe(Color_Space), // nil: none written
}

Audio_Track :: struct {
	codec:       Audio_Codec,
	sample_rate: int,
	channels:    int,
	description: []u8,   // copied, see Audio_Codec
}

// A track of a muxer, 1 for the first one added.
Track :: distinct int

// Where a stream muxer sends its bytes: `data` goes at byte `position` of the file. A position is always the end of
// what came before, except for a patch of bytes already given: the mdat's size (MP4 without fast start) and, in
// WebM without append_only, the Segment's size, its duration and its SeekHead. False stops the muxer (Write_Failed).
Write_Proc :: #type proc(user: rawptr, data: []u8, position: i64) -> bool

Fast_Start :: enum u8 {
	Default,      // In_Memory for a muxer in memory, else Off
	In_Memory,    // moov first: every packet is kept until finalize
	Fragmented,   // fragmented MP4: a moof and its mdat a fragment; a crash leaves the fragments written playable
	Off,          // moov at the end; packets go out as they come (chunks of half a second)
}

// The zero value is the defaults.
Mp4_Options :: struct {
	fast_start:                Fast_Start,
	minimum_fragment_duration: f64,         // seconds (Fragmented); <= 0: 1. A fragment starts on a key frame
	creation_time:             time.Time,   // zero: now
}

// The zero value is the defaults.
Webm_Options :: struct {
	append_only:              bool,        // no seek back: unknown sizes, no SeekHead and no duration (live streams)
	minimum_cluster_duration: f64,         // seconds; <= 0: 1. A cluster starts on a key frame
	creation_time:            time.Time,   // zero: now
}

Format :: enum u8 { MP4, WebM }

// Made by mp4_open / webm_open, freed by finalize or destroy. The fields are the muxer's own.
Muxer :: struct {
	format:        Format,
	allocator:     runtime.Allocator,
	writer:        Writer,
	tracks:        [dynamic]^Track_State,
	started:       bool,
	err:           Error,
	creation_time: time.Time,
	mp4:           Mp4_State,
	webm:          Webm_State,
}

// The muxing app named in the files (the MP4 compressor name holds 31 bytes).
MUXING_APP :: "gui_toolkit mux"

@(private) MAX_TRACKS :: 126   // a WebM block's track number is one byte of EBML varint

@(private)
Track_State :: struct {
	id:          int,
	is_video:    bool,
	video:       Video_Track,
	audio:       Audio_Track,
	description: []u8,    // owned: given, or made from the first packet (H.264 Annex B, ADTS)
	configured:  bool,    // the decoder configuration is known
	annex_b:     bool,    // H.264 packets come in Annex B (MP4 makes them length-prefixed)
	adts:        bool,    // AAC packets come with ADTS headers (stripped)
	closed:      bool,
	order:       Order,
	mp4:         Mp4_Track,
	webm:        Webm_Track,
}

////////////////////////////////
// Opening

// A muxer whose file stays in memory: finalize returns it.
mp4_open_memory :: proc(options := Mp4_Options{}, allocator := context.allocator) -> (^Muxer, Error) {
	m := muxer_new(.MP4, .Memory, options.creation_time, allocator)
	return m, mp4_start(m, options)
}

// A muxer writing the file at `path` (created or truncated).
mp4_open_file :: proc(path: string, options := Mp4_Options{}, allocator := context.allocator) -> (^Muxer, Error) {
	file, err := os.create(path)
	if err != nil { return nil, .Open_Failed }
	m := muxer_new(.MP4, .File, options.creation_time, allocator)
	m.writer.file = file
	return m, mp4_start(m, options)
}

// A muxer giving its bytes to `write` (Write_Proc says which positions it gets).
mp4_open_stream :: proc(write: Write_Proc, user: rawptr, options := Mp4_Options{}, allocator := context.allocator) -> (^Muxer, Error) {
	m := muxer_new(.MP4, .Stream, options.creation_time, allocator)
	m.writer.write, m.writer.user = write, user
	return m, mp4_start(m, options)
}

mp4_open :: proc{mp4_open_file, mp4_open_stream, mp4_open_memory}

// A muxer whose file stays in memory: finalize returns it.
webm_open_memory :: proc(options := Webm_Options{}, allocator := context.allocator) -> (^Muxer, Error) {
	m := muxer_new(.WebM, .Memory, options.creation_time, allocator)
	return m, webm_start(m, options)
}

// A muxer writing the file at `path` (created or truncated).
webm_open_file :: proc(path: string, options := Webm_Options{}, allocator := context.allocator) -> (^Muxer, Error) {
	file, err := os.create(path)
	if err != nil { return nil, .Open_Failed }
	m := muxer_new(.WebM, .File, options.creation_time, allocator)
	m.writer.file = file
	return m, webm_start(m, options)
}

// A muxer giving its bytes to `write` (Write_Proc says which positions it gets).
webm_open_stream :: proc(write: Write_Proc, user: rawptr, options := Webm_Options{}, allocator := context.allocator) -> (^Muxer, Error) {
	m := muxer_new(.WebM, .Stream, options.creation_time, allocator)
	m.writer.write, m.writer.user = write, user
	return m, webm_start(m, options)
}

webm_open :: proc{webm_open_file, webm_open_stream, webm_open_memory}

@(private = "file")
muxer_new :: proc(format: Format, sink: Sink, creation_time: time.Time, allocator: runtime.Allocator) -> ^Muxer {
	m := new(Muxer, allocator)
	m.format, m.allocator = format, allocator
	m.writer.sink = sink
	m.writer.data = make([dynamic]u8, 0, 64 * 1024, allocator)
	m.tracks = make([dynamic]^Track_State, allocator)
	m.creation_time = creation_time == (time.Time{}) ? time.now() : creation_time
	return m
}

////////////////////////////////
// Tracks

// Adds a video track; every track is added before the first packet.
add_video_track :: proc(m: ^Muxer, track: Video_Track) -> (Track, Error) {
	if m.err != .None { return 0, m.err }
	if m.started { return 0, .Tracks_Started }
	if len(m.tracks) >= MAX_TRACKS { return 0, .Invalid_Track }
	if track.width < 1 || track.height < 1 || track.width > 65535 || track.height > 65535 || track.frame_rate < 0 {
		return 0, .Invalid_Track
	}
	if m.format == .WebM && track.codec != .VP8 && track.codec != .VP9 && track.codec != .AV1 { return 0, .Unsupported_Codec }
	if track.codec == .HEVC && track.description == nil { return 0, .Invalid_Track }
	context.allocator = m.allocator
	t := new(Track_State)
	t.id = len(m.tracks) + 1
	t.is_video = true
	t.video = track
	t.description = clone(track.description)
	t.video.description = t.description
	t.annex_b = track.codec == .AVC && track.description == nil
	t.configured = !t.annex_b
	append(&m.tracks, t)
	track_added(m, t)
	return Track(t.id), .None
}

// Adds an audio track; every track is added before the first packet.
add_audio_track :: proc(m: ^Muxer, track: Audio_Track) -> (Track, Error) {
	if m.err != .None { return 0, m.err }
	if m.started { return 0, .Tracks_Started }
	if len(m.tracks) >= MAX_TRACKS { return 0, .Invalid_Track }
	if track.sample_rate < 1 || track.sample_rate > 0x7FFF_FFFF || track.channels < 1 || track.channels > 255 { return 0, .Invalid_Track }
	if m.format == .WebM && track.codec != .Opus { return 0, .Unsupported_Codec }
	context.allocator = m.allocator
	t := new(Track_State)
	t.id = len(m.tracks) + 1
	t.audio = track
	t.description = clone(track.description)
	t.audio.description = t.description
	t.adts = track.codec == .AAC && track.description == nil
	t.configured = !t.adts
	append(&m.tracks, t)
	track_added(m, t)
	return Track(t.id), .None
}

@(private = "file")
track_added :: proc(m: ^Muxer, t: ^Track_State) {
	switch m.format {
	case .MP4:  mp4_track_init(m, t)
	case .WebM: webm_track_init(m, t)
	}
}

////////////////////////////////
// Packets

// Adds an encoded packet: `timestamp` and `duration` in seconds (presentation time; B-frames may come out of
// order within a group of pictures), `key` for a key frame (a track starts with one). The data is copied.
add_packet :: proc(m: ^Muxer, track: Track, data: []u8, timestamp, duration: f64, key: bool) -> Error {
	if m.err != .None { return m.err }
	t := track_of(m, track)
	if t == nil { return .Unknown_Track }
	if t.closed { return .Track_Closed }
	if len(data) == 0 || duration < 0 { return .Invalid_Packet }
	m.started = true
	context.allocator = m.allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()   // (a worker may mux for hours: the temporary bytes go each call)
	err: Error
	switch m.format {
	case .MP4:  err = mp4_add_packet(m, t, data, timestamp, duration, key)
	case .WebM: err = webm_add_packet(m, t, data, timestamp, duration, key)
	}
	return settle(m, err)
}

// Says a track has no more packets: the others' packets no longer wait for it to be interleaved.
close_track :: proc(m: ^Muxer, track: Track) -> Error {
	if m.err != .None { return m.err }
	t := track_of(m, track)
	if t == nil { return .Unknown_Track }
	if t.closed { return .None }
	t.closed = true
	context.allocator = m.allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	err: Error
	switch m.format {
	case .MP4:  err = mp4_close_track(m, t)
	case .WebM: err = webm_close_track(m, t)
	}
	return settle(m, err)
}

// Writes what is left (the moov, the Cues, the sizes), closes the file and frees the muxer. For a muxer in memory,
// `data` is the file (in the muxer's allocator); else nil. On an error, what was written stays as it is.
finalize :: proc(m: ^Muxer) -> (data: []u8, err: Error) {
	err = m.err
	if err == .None {
		context.allocator = m.allocator
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		switch m.format {
		case .MP4:  err = mp4_finalize(m)
		case .WebM: err = webm_finalize(m)
		}
		writer_flush(&m.writer)
		if err == .None && m.writer.failed { err = .Write_Failed }
	}
	if err == .None && m.writer.sink == .Memory {
		data = m.writer.data[:]
		m.writer.data = nil
	}
	destroy(m)
	return
}

// Frees a muxer given up before its finalize (finalize does it); a file keeps what was written.
destroy :: proc(m: ^Muxer) {
	if m == nil { return }
	context.allocator = m.allocator
	if m.writer.file != nil { os.close(m.writer.file) }
	delete(m.writer.data)
	switch m.format {
	case .MP4:  mp4_destroy(m)
	case .WebM: webm_destroy(m)
	}
	for t in m.tracks {
		delete(t.description)
		free(t)
	}
	delete(m.tracks)
	free(m)
}

@(private = "file")
track_of :: proc(m: ^Muxer, track: Track) -> ^Track_State {
	i := int(track) - 1
	return i >= 0 && i < len(m.tracks) ? m.tracks[i] : nil
}

// A failed write stops the muxer: what the file holds is no longer what the muxer thinks.
@(private = "file")
settle :: proc(m: ^Muxer, err: Error) -> Error {
	if m.writer.failed {
		m.err = .Write_Failed
		return m.err
	}
	return err
}

@(private)
clone :: proc(data: []u8) -> []u8 {
	if data == nil { return nil }
	c := make([]u8, len(data))
	copy(c, data)
	return c
}

////////////////////////////////
// Packet order (Mediabunny's PacketOrderValidator)

@(private)
Order :: struct {
	max, max_before_last_key: f64,
	has_max, has_before:      bool,
}

// A track starts with a key frame; a packet is not earlier than the largest timestamp of the group of pictures before.
@(private)
order_check :: proc(o: ^Order, timestamp: f64, key: bool) -> Error {
	if !o.has_max {
		if !key { return .Not_Key_Frame }
	} else if key {
		if timestamp < o.max { return .Timestamp_Order }
	} else if o.has_before && timestamp < o.max_before_last_key {
		return .Timestamp_Order
	}
	if key {
		o.max_before_last_key, o.has_before = o.max, o.has_max
	}
	o.max = o.has_max ? max(o.max, timestamp) : timestamp
	o.has_max = true
	return .None
}

// JavaScript's Math.round (half up, -0.5 is 0), which the ported arithmetic assumes.
@(private)
js_round :: proc "contextless" (x: f64) -> f64 {
	f := x + 0.5
	i := f64(i64(f))
	return i > f ? i - 1 : i
}

////////////////////////////////
// Output

@(private)
Sink :: enum u8 { Memory, File, Stream }

// Bytes at positions: in memory the whole file; for a file or a stream, the bytes from `start` on that the sink has
// not been given yet (the muxers patch sizes there, then flush). A write before `start` goes to the sink at once.
@(private)
Writer :: struct {
	sink:   Sink,
	file:   ^os.File,
	write:  Write_Proc,
	user:   rawptr,
	data:   [dynamic]u8,
	start:  i64,
	pos:    i64,
	failed: bool,
}

@(private)
writer_write :: proc(w: ^Writer, bytes: []u8) {
	bytes := bytes
	pos := w.pos
	w.pos += i64(len(bytes))
	if w.failed || len(bytes) == 0 { return }
	if pos < w.start {
		n := min(i64(len(bytes)), w.start - pos)
		sink_put(w, bytes[:n], pos)
		bytes = bytes[n:]
		pos += n
		if len(bytes) == 0 { return }
	}
	at := int(pos - w.start)
	end := at + len(bytes)
	if end > len(w.data) { resize(&w.data, end) }   // (new bytes are zero: a gap left by a seek is zeros)
	copy(w.data[at:end], bytes)
}

@(private)
writer_seek :: proc(w: ^Writer, pos: i64) { w.pos = pos }

@(private)
writer_flush :: proc(w: ^Writer) {
	if w.sink == .Memory || len(w.data) == 0 { return }
	sink_put(w, w.data[:], w.start)
	w.start += i64(len(w.data))
	clear(&w.data)
}

@(private = "file")
sink_put :: proc(w: ^Writer, bytes: []u8, pos: i64) {
	if w.failed { return }
	switch w.sink {
	case .Memory:
	case .File:
		n, err := os.write_at(w.file, bytes, pos)
		if err != nil || n != len(bytes) { w.failed = true }
	case .Stream:
		if !w.write(w.user, bytes, pos) { w.failed = true }
	}
}
