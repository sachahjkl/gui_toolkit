// Package h264: screen frames (BGRA or RGBA, 8 bits a channel) to an H.264 stream, with the encoders the system has:
// VA-API (the GPU) then openh264 on Linux, Media Foundation's encoders (the GPU's, then Microsoft's) on Windows. No
// ffmpeg. The libraries are opened at run time: a program starts on a system without them, and `available` says so.
//
// Every call blocks (the GPU, the encoder's own threads): a program calls them on a worker, one encoder for one thread.
// The pure parts (the bit writer, SPS / PPS / slice headers, the colour conversions, Annex B) run everywhere and are
// tested on every system. See docs/h264.md.
package tk_h264

import "base:runtime"
import "core:time"

// An encoder of the system.
Backend :: enum u8 {
	Vaapi,                       // Linux: the GPU through libva (Intel, AMD, NVIDIA with nouveau)
	Openh264,                    // Linux: Cisco's software encoder (libopenh264)
	Media_Foundation_Hardware,   // Windows: the GPU's H.264 encoder MFT (its vendor's driver)
	Media_Foundation_Software,   // Windows: Microsoft's software H.264 encoder MFT
}

Backends :: bit_set[Backend]

// The backends that run on a GPU.
HARDWARE_BACKENDS :: Backends{.Vaapi, .Media_Foundation_Hardware}

// The kind of encoder `open` takes.
Preference :: enum u8 {
	Auto,       // the GPU's when there is one, else software
	Hardware,   // the GPU's only
	Software,   // software only
}

Pixel_Format :: enum u8 {
	BGRA,   // bytes B, G, R, A (Windows and Wayland screens)
	RGBA,   // bytes R, G, B, A
}

// One picture: rows top to bottom, `stride` bytes apart; the alpha channel is ignored.
Frame :: struct {
	pixels:        []u8,
	width, height: int,
	stride:        int,
	format:        Pixel_Format,
}

// One access unit (all the NAL units of one picture) in Annex B: start codes, then each NAL unit. The first packet is a
// keyframe and carries the SPS and the PPS; so does every keyframe after it.
Packet :: struct {
	data:      []u8,
	timestamp: time.Duration,   // what encode was given with the frame
	keyframe:  bool,            // an IDR picture: a decoder can start here
}

// The zero value is the defaults: constant quantiser DEFAULT_QP, a keyframe every 2 seconds, the best backend.
Options :: struct {
	bitrate:           int,             // bits a second (a variable or constant rate, as the backend offers); 0: `qp`
	qp:                int,             // constant quantiser, 1 (best) ..= 51; 0: DEFAULT_QP. Used when bitrate is 0
	keyframe_interval: time.Duration,   // 0: DEFAULT_KEYFRAME_INTERVAL
	backend:           Preference,
}

DEFAULT_QP :: 23
DEFAULT_KEYFRAME_INTERVAL :: 2 * time.Second
// The largest side taken (H.264 levels 6.x reach 8192 pixels; most GPUs stop at 4096).
MAX_SIDE :: 8192

Error :: enum u8 {
	None,
	Bad_Size,      // a side not in 1 ..= MAX_SIDE, or fps not in 1 ..= 240
	Bad_Frame,     // a frame of another size than open's, or its pixels shorter than its stride and size say
	Unavailable,   // no encoder of the kind asked on this system
	Failed,        // the encoder refused a call (the driver, the library)
}

// What open returns. The fields are read-only for the program.
Encoder :: struct {
	width, height:               int,   // the frames' size: what the muxer writes in its header
	stream_width, stream_height: int,   // the stream's picture: the frames' size rounded up to even (see even_size)
	fps:                         int,
	options:                     Options,
	backend:                     Backend,
	keyframe_frames:             int,   // a keyframe every this many frames
	frames:                      int,   // the frames given to encode
	allocator:                   runtime.Allocator,
	packet_bytes:                [dynamic]u8,     // the packets of the last call, one after the other
	packet_marks:                [dynamic]Packet_Mark,
	packets:                     [dynamic]Packet,
	system:                      System_Encoder,  // the backend's own state (encoder_<system>.odin)
}

@(private)
Packet_Mark :: struct {
	start, end: int,
	timestamp:  time.Duration,
	keyframe:   bool,
}

// The backends this system has now (libraries found, a device that encodes H.264). Blocks: it opens the devices.
available :: proc() -> Backends { return system_available() }

// An encoder for frames of `width` x `height` pixels at about `fps` frames a second (the rate control's measure; the
// timestamps given to encode are what the packets carry). Odd sides are padded: the last column or row is repeated
// once, and the stream's picture is the even size (`stream_width`, `stream_height`); a muxer writes `width` x
// `height`. Blocks. The packets and the encoder live in `allocator`.
open :: proc(width, height: int, fps: int, options := Options{}, allocator := context.allocator) -> (^Encoder, Error) {
	if width < 1 || height < 1 || width > MAX_SIDE || height > MAX_SIDE || fps < 1 || fps > 240 { return nil, .Bad_Size }
	e := new(Encoder, allocator)
	e.width, e.height = width, height
	e.stream_width, e.stream_height = even_size(width, height)
	e.fps = fps
	e.options = options
	if e.options.qp == 0 { e.options.qp = DEFAULT_QP }
	e.options.qp = clamp(e.options.qp, 1, 51)
	if e.options.keyframe_interval <= 0 { e.options.keyframe_interval = DEFAULT_KEYFRAME_INTERVAL }
	e.keyframe_frames = keyframe_frames_of(e.options.keyframe_interval, fps)
	e.allocator = allocator
	e.packet_bytes = make([dynamic]u8, allocator)
	e.packet_marks = make([dynamic]Packet_Mark, allocator)
	e.packets = make([dynamic]Packet, allocator)
	if err := system_open(e); err != .None {
		packets_free(e)
		free(e, allocator)
		return nil, err
	}
	return e, .None
}

// Encodes one frame. The packets that came out (zero or more: an encoder with a delay gives them later) are valid until
// the next call on `e`. Blocks.
encode :: proc(e: ^Encoder, frame: Frame, timestamp: time.Duration) -> ([]Packet, Error) {
	packets_begin(e)
	if !frame_fits(frame, e.width, e.height) { return nil, .Bad_Frame }
	keyframe := e.frames % e.keyframe_frames == 0
	e.frames += 1
	if err := system_encode(e, frame, timestamp, keyframe); err != .None { return packets_end(e), err }
	return packets_end(e), .None
}

// The packets the encoder still holds, at the end of the stream; valid until the next call on `e`. Blocks.
flush :: proc(e: ^Encoder) -> ([]Packet, Error) {
	packets_begin(e)
	err := system_flush(e)
	return packets_end(e), err
}

close :: proc(e: ^Encoder) {
	if e == nil { return }
	system_close(e)
	packets_free(e)
	free(e, e.allocator)
}

// The backend `open` took.
backend_of :: proc(e: ^Encoder) -> Backend { return e.backend }

// The size of the stream's picture for frames of `width` x `height`: each side rounded up to even (4:2:0 halves the
// chroma; H.264 crops only by 2 pixels).
even_size :: proc(width, height: int) -> (int, int) { return (width + 1) &~ 1, (height + 1) &~ 1 }

// How many frames from one keyframe to the next: the interval at `fps`, at least 1.
keyframe_frames_of :: proc(interval: time.Duration, fps: int) -> int {
	n := int((i64(interval) * i64(fps) + i64(time.Second) / 2) / i64(time.Second))
	return max(n, 1)
}

// Whether `frame` is `width` x `height` with all its rows in its pixels.
frame_fits :: proc(frame: Frame, width, height: int) -> bool {
	if frame.width != width || frame.height != height { return false }
	if frame.stride < width * 4 { return false }
	return len(frame.pixels) >= frame.stride * (height - 1) + width * 4
}

////////////////////////////////
// The packets of one call

@(private)
packets_begin :: proc(e: ^Encoder) {
	clear(&e.packet_bytes)
	clear(&e.packet_marks)
	clear(&e.packets)
}

// One access unit, copied. `keyframe` is what the stream says: an IDR slice in it.
@(private)
packet_add :: proc(e: ^Encoder, data: []u8, timestamp: time.Duration) {
	if len(data) == 0 { return }
	start := len(e.packet_bytes)
	append(&e.packet_bytes, ..data)
	append(&e.packet_marks, Packet_Mark{start = start, end = len(e.packet_bytes), timestamp = timestamp, keyframe = has_nal_type(data, NAL_IDR)})
}

// The slices are made only now: packet_bytes may move while the packets are added.
@(private)
packets_end :: proc(e: ^Encoder) -> []Packet {
	for m in e.packet_marks {
		append(&e.packets, Packet{data = e.packet_bytes[m.start:m.end], timestamp = m.timestamp, keyframe = m.keyframe})
	}
	return e.packets[:]
}

@(private)
packets_free :: proc(e: ^Encoder) {
	delete(e.packet_bytes)
	delete(e.packet_marks)
	delete(e.packets)
}
