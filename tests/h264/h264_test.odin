// gt:h264: the pure parts with exact values (Exp-Golomb codes, an SPS, a PPS and slice headers bit for bit, the
// emulation prevention bytes, Annex B splitting, the BT.709 limited-range conversion of known pixels in NV12 and I420,
// odd sizes, the levels), then whatever encoder the system has: 30 frames in, 30 packets out, the first a keyframe
// with its SPS and PPS. Skipped, with a log line, when the system has no encoder (CI).
//   odin test tests/h264 -vet
package h264_test

import "core:log"
import "core:testing"
import "core:time"
import h264 "../../src/h264"

// The bytes of a string of '0' and '1' (spaces ignored), the last byte padded with zeros, and the count of bits.
@(private = "file")
bits_of :: proc(s: string) -> (bytes: []u8, count: int) {
	out := make([dynamic]u8, context.temp_allocator)
	current: u8
	used: uint
	for c in s {
		if c != '0' && c != '1' { continue }
		current |= u8(c == '1' ? 1 : 0) << (7 - used)
		used += 1
		count += 1
		if used == 8 { append(&out, current); current, used = 0, 0 }
	}
	if used != 0 { append(&out, current) }
	return out[:], count
}

@(private = "file")
expect_bits :: proc(t: ^testing.T, w: ^h264.Bit_Writer, expected: string, loc := #caller_location) {
	want, count := bits_of(expected)
	testing.expect_value(t, h264.bit_count(w), count, loc)
	testing.expect_value(t, string(h264.bit_writer_bytes(w)), string(want), loc)
}

@(test)
exp_golomb :: proc(t: ^testing.T) {
	w := h264.bit_writer_make()
	defer h264.bit_writer_destroy(&w)
	for v in ([]u32{0, 1, 2, 3, 7}) { h264.write_ue(&w, v) }
	expect_bits(t, &w, "1 010 011 00100 0001000")

	h264.bit_writer_reset(&w)
	for v in ([]i32{1, -1, 2, -2, 0}) { h264.write_se(&w, v) }
	expect_bits(t, &w, "010 011 00100 00101 1")

	// the largest code: 31 zeros, then 32 ones
	h264.bit_writer_reset(&w)
	h264.write_ue(&w, 0xFFFF_FFFE)
	testing.expect_value(t, h264.bit_count(&w), 63)
	testing.expect_value(t, string(h264.bit_writer_bytes(&w)), str([]u8{0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFE}))

	h264.bit_writer_reset(&w)
	h264.write_bits(&w, 0b101, 3)
	h264.write_trailing_bits(&w)
	expect_bits(t, &w, "101 1 0000")
}

@(test)
sps_constrained_baseline :: proc(t: ^testing.T) {
	w := h264.bit_writer_make()
	defer h264.bit_writer_destroy(&w)
	h264.write_sps(&w, h264.Sequence{
		profile_idc = h264.PROFILE_CONSTRAINED_BASELINE, level_idc = 30,
		width = 640, height = 480, log2_max_frame_num = 4, max_ref_frames = 1, fps = 0, qp = 23,
	})
	expect_bits(t, &w,
		"01000010 11000000 00011110" +                // profile_idc 66, constraint_set0 and 1, level 3.0
		"1 1 011 010 0" +                             // sps id 0, log2_max_frame_num 4, poc type 2, 1 reference, no gaps
		"00000101000 000011110" +                     // 40 x 30 macroblocks
		"1 1 0 1" +                                   // frames only, direct 8x8, no cropping, VUI
		"0 0 1 101 0 1 00000001 00000001 00000001" +  // BT.709, limited range
		"0 0 0 0 0" +                                 // no chroma location, timing, HRD, pic_struct
		"1 1 1 1 000010000 000010000 1 010" +         // bitstream restriction: no reordering, 1 frame buffered
		"1 0000000")                                  // trailing bits
}

@(test)
sps_high_cropped :: proc(t: ^testing.T) {
	w := h264.bit_writer_make()
	defer h264.bit_writer_destroy(&w)
	h264.write_sps(&w, h264.Sequence{
		profile_idc = h264.PROFILE_HIGH, level_idc = 42,
		width = 1920, height = 1080, log2_max_frame_num = 8, max_ref_frames = 1, fps = 60, qp = 26,
	})
	expect_bits(t, &w,
		"01100100 00000000 00101010" +                // profile_idc 100, level 4.2
		"1 010 1 1 0 0" +                             // sps id, 4:2:0, 8 bits, 8 bits, no bypass, no scaling matrix
		"00101 011 010 0" +                           // log2_max_frame_num 8, poc type 2, 1 reference, no gaps
		"0000001111000 0000001000100" +               // 120 x 68 macroblocks
		"1 1" +
		"1 1 1 1 00101" +                             // cropping: 1088 - 1080 = 8 rows, 4 units at the bottom
		"1" +
		"0 0 1 101 0 1 00000001 00000001 00000001 0" +
		"1 00000000000000000000000000000001 00000000000000000000000001111000 0" + // ticks of 1 / 120 s: 60 frames
		"0 0 0" +
		"1 1 1 1 000010000 000010000 1 010" +
		"1 00000")                                    // trailing bits to the byte's end (211 bits, then 216)
}

@(test)
pps :: proc(t: ^testing.T) {
	w := h264.bit_writer_make()
	defer h264.bit_writer_destroy(&w)
	h264.write_pps(&w, h264.Sequence{profile_idc = h264.PROFILE_CONSTRAINED_BASELINE, level_idc = 30, width = 640, height = 480, log2_max_frame_num = 4, max_ref_frames = 1, qp = 23})
	// ids 0 0, CAVLC, no field order, 1 slice group, 1 and 1 references, no weights, qp 26 - 3, qs 0, chroma 0,
	// deblocking control, no constrained intra, no redundant count; trailing bits
	expect_bits(t, &w, "1 1 0 0 1 1 1 0 00 00111 1 1 1 0 0 1 000")

	h264.bit_writer_reset(&w)
	h264.write_pps(&w, h264.Sequence{profile_idc = h264.PROFILE_HIGH, level_idc = 40, width = 1920, height = 1080, log2_max_frame_num = 4, max_ref_frames = 1, qp = 26})
	// CABAC, qp 26; then the 8x8 transform, no scaling matrix, second chroma offset 0
	expect_bits(t, &w, "1 1 1 0 1 1 1 0 00 1 1 1 1 0 0 1 0 1 1 0000")
}

@(test)
slice_headers :: proc(t: ^testing.T) {
	w := h264.bit_writer_make()
	defer h264.bit_writer_destroy(&w)
	baseline := h264.Sequence{profile_idc = h264.PROFILE_CONSTRAINED_BASELINE, level_idc = 30, width = 640, height = 480, log2_max_frame_num = 4, max_ref_frames = 1, qp = 23}
	h264.write_slice_header(&w, baseline, h264.Slice{idr = true})
	expect_bits(t, &w,
		"00000000 00000000 00000000 00000001 0 11 00101" + // start code, nal_ref_idc 3, IDR
		"1 011 1 0000 1" +                                 // first macroblock 0, I, pps 0, frame_num 0, idr_pic_id 0
		"0 0" +                                            // no_output_of_prior_pics, long_term_reference
		"1 1 1 1")                                         // qp delta 0, deblocking on, offsets 0 0

	h264.bit_writer_reset(&w)
	high := baseline
	high.profile_idc = h264.PROFILE_HIGH
	h264.write_slice_header(&w, high, h264.Slice{idr = false, frame_num = 3, qp_delta = -2})
	expect_bits(t, &w,
		"00000000 00000000 00000000 00000001 0 11 00001" + // a non-IDR slice
		"1 1 1 0011" +                                     // first macroblock 0, P, pps 0, frame_num 3
		"0 0 0" +                                          // no override, no list modification, sliding window
		"1 00101" +                                        // cabac_init_idc 0, qp delta -2
		"1 1 1" +
		"11111")                                           // cabac_alignment_one_bit to the byte's end
}

@(test)
emulation_prevention :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	h264.append_nal(&out, 3, h264.NAL_SPS, []u8{0, 0, 0, 0, 1, 0, 0, 2, 0, 0, 4})
	testing.expect_value(t, string(out[:]), str([]u8{0, 0, 0, 1, 0x67, 0, 0, 3, 0, 0, 3, 1, 0, 0, 3, 2, 0, 0, 4}))
}

@(test)
annex_b :: proc(t: ^testing.T) {
	// a 4-byte start code, an SPS; a 3-byte one, a PPS and a trailing zero; a 4-byte one, an IDR slice and a trailing zero
	data := []u8{0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 0, 1, 0x65, 0x01, 0x02, 0}
	at := 0
	units := make([dynamic]string, context.temp_allocator)
	for nal in h264.next_nal(data, &at) { append(&units, string(nal)) }
	testing.expect_value(t, len(units), 3)
	if len(units) == 3 {
		testing.expect_value(t, units[0], str([]u8{0x67, 0xAA}))
		testing.expect_value(t, units[1], str([]u8{0x68, 0xBB}))
		testing.expect_value(t, units[2], str([]u8{0x65, 0x01, 0x02}))
	}
	testing.expect(t, h264.has_nal_type(data, h264.NAL_IDR))
	testing.expect(t, !h264.has_nal_type(data, h264.NAL_SEI))
	sps, pps := h264.parameter_sets(data)
	testing.expect_value(t, string(sps), str([]u8{0x67, 0xAA}))
	testing.expect_value(t, string(pps), str([]u8{0x68, 0xBB}))
	at = 0
	_, found := h264.next_nal([]u8{1, 2, 3, 0, 0}, &at)
	testing.expect(t, !found)
}

// A frame of one colour, `width` x `height`, BGRA.
@(private = "file")
solid :: proc(width, height: int, r, g, b: u8) -> h264.Frame {
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	for i := 0; i < len(pixels); i += 4 { pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = b, g, r, 255 }
	return h264.Frame{pixels = pixels, width = width, height = height, stride = width * 4, format = .BGRA}
}

@(test)
colours :: proc(t: ^testing.T) {
	// BT.709, limited range: Y, Cb, Cr of black, white, the primaries and a grey
	Case :: struct { r, g, b: u8, y, cb, cr: u8 }
	cases := []Case{
		{0, 0, 0, 16, 128, 128},
		{255, 255, 255, 235, 128, 128},
		{255, 0, 0, 63, 102, 240},
		{0, 255, 0, 173, 42, 26},
		{0, 0, 255, 32, 240, 118},
		{128, 128, 128, 126, 128, 128},
	}
	for c in cases {
		frame := solid(2, 2, c.r, c.g, c.b)
		luma: [4]u8
		chroma: [2]u8
		h264.to_nv12(frame, luma[:], 2, chroma[:], 2)
		testing.expectf(t, luma == [4]u8{c.y, c.y, c.y, c.y}, "%v: luma %v, want %v", c, luma, c.y)
		testing.expectf(t, chroma == [2]u8{c.cb, c.cr}, "%v: chroma %v, want %v %v", c, chroma, c.cb, c.cr)
	}
}

@(test)
odd_sizes_and_layouts :: proc(t: ^testing.T) {
	// 3 x 1: red, red, blue; the stream is 4 x 2, the last column and the row repeated
	pixels := []u8{0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255}
	frame := h264.Frame{pixels = pixels, width = 3, height = 1, stride = 12, format = .BGRA}
	w, h := h264.even_size(3, 1)
	testing.expect_value(t, w, 4)
	testing.expect_value(t, h, 2)

	luma: [8]u8
	chroma: [4]u8
	h264.to_nv12(frame, luma[:], 4, chroma[:], 4)
	testing.expect_value(t, luma, [8]u8{63, 63, 32, 32, 63, 63, 32, 32})
	testing.expect_value(t, chroma, [4]u8{102, 240, 240, 118})

	cb, cr: [2]u8
	luma = {}
	h264.to_i420(frame, luma[:], 4, cb[:], cr[:], 2)
	testing.expect_value(t, luma, [8]u8{63, 63, 32, 32, 63, 63, 32, 32})
	testing.expect_value(t, cb, [2]u8{102, 240})
	testing.expect_value(t, cr, [2]u8{240, 118})

	// the same pixels as RGBA
	rgba := []u8{255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255}
	frame = h264.Frame{pixels = rgba, width = 3, height = 1, stride = 12, format = .RGBA}
	luma, chroma = {}, {}
	h264.to_nv12(frame, luma[:], 4, chroma[:], 4)
	testing.expect_value(t, luma, [8]u8{63, 63, 32, 32, 63, 63, 32, 32})
	testing.expect_value(t, chroma, [4]u8{102, 240, 240, 118})

	// a stride wider than the row: the bytes after it are not read as pixels
	padded := []u8{0, 0, 255, 255, 9, 9, 9, 9, 0, 0, 255, 255, 9, 9, 9, 9}
	frame = h264.Frame{pixels = padded, width = 1, height = 2, stride = 8, format = .BGRA}
	small_luma: [4]u8
	small_chroma: [2]u8
	h264.to_nv12(frame, small_luma[:], 2, small_chroma[:], 2)
	testing.expect_value(t, small_luma, [4]u8{63, 63, 63, 63})
	testing.expect_value(t, small_chroma, [2]u8{102, 240})
}

@(test)
sizes_levels_and_cadence :: proc(t: ^testing.T) {
	testing.expect_value(t, h264.keyframe_frames_of(2 * time.Second, 30), 60)
	testing.expect_value(t, h264.keyframe_frames_of(10 * time.Millisecond, 30), 1)
	testing.expect_value(t, h264.log2_max_frame_num_for(1), 4)
	testing.expect_value(t, h264.log2_max_frame_num_for(60), 6)
	testing.expect_value(t, h264.log2_max_frame_num_for(1_000_000), 16)
	testing.expect_value(t, h264.level_for(640, 480, 30, 0), 30)
	testing.expect_value(t, h264.level_for(1920, 1080, 30, 8_000_000), 40)
	testing.expect_value(t, h264.level_for(1920, 1080, 60, 0), 42)
	testing.expect_value(t, h264.level_for(3840, 2160, 60, 0), 52)

	frame := solid(4, 2, 0, 0, 0)
	testing.expect(t, h264.frame_fits(frame, 4, 2))
	testing.expect(t, !h264.frame_fits(frame, 4, 3))
	frame.pixels = frame.pixels[:len(frame.pixels) - 1]
	testing.expect(t, !h264.frame_fits(frame, 4, 2))

	e, err := h264.open(0, 10, 30)
	testing.expect(t, e == nil)
	testing.expect_value(t, err, h264.Error.Bad_Size)
	e, err = h264.open(10, 10, 0)
	testing.expect_value(t, err, h264.Error.Bad_Size)
}

// A frame whose content moves: a bar that slides, on a gradient.
@(private = "file")
moving :: proc(pixels: []u8, width, height, index: int) {
	for y in 0 ..< height {
		for x in 0 ..< width {
			p := (y * width + x) * 4
			bar := (x - index * 4) %% width < 16
			pixels[p] = bar ? 255 : u8(x * 255 / width)
			pixels[p + 1] = bar ? 255 : u8(y * 255 / height)
			pixels[p + 2] = bar ? 255 : 64
			pixels[p + 3] = 255
		}
	}
}

// What the packets of one stream showed so far.
@(private = "file")
Seen :: struct {
	count, keyframes: int,
	started:          bool,
	last:             time.Duration,
}

@(private = "file")
check_packets :: proc(t: ^testing.T, packets: []h264.Packet, seen: ^Seen) {
	for p in packets {
		if !seen.started {
			testing.expect(t, p.keyframe, "the first packet is a keyframe")
			sps, pps := h264.parameter_sets(p.data)
			testing.expect(t, sps != nil && pps != nil, "the first packet carries the SPS and the PPS")
			seen.started = true
		}
		testing.expect(t, p.timestamp > seen.last, "the timestamps grow")
		seen.last = p.timestamp
		if p.keyframe { seen.keyframes += 1 }
		seen.count += 1
	}
}

@(test)
encode_with_the_system :: proc(t: ^testing.T) {
	found := h264.available()
	if found == {} {
		log.info("h264: no encoder on this system (no libva driver that encodes H.264, no libopenh264, no Media Foundation): the encoding is not tested")
		return
	}
	// (odd sides: the padding to even goes through each encoder too)
	W, H :: 321, 241
	pixels := make([]u8, W * H * 4)
	defer delete(pixels)
	frame := h264.Frame{pixels = pixels, width = W, height = H, stride = W * 4, format = .BGRA}
	for backend in found {
		preference := backend in h264.HARDWARE_BACKENDS ? h264.Preference.Hardware : h264.Preference.Software
		e, err := h264.open(W, H, 30, {qp = 28, keyframe_interval = time.Second, backend = preference})
		if err != .None {
			testing.expectf(t, false, "%v is listed but does not open: %v", backend, err)
			continue
		}
		testing.expect_value(t, e.stream_width, 322)
		testing.expect_value(t, e.stream_height, 242)
		seen := Seen{last = -1}
		for i in 0 ..< 30 {
			moving(pixels, W, H, i)
			packets, encode_err := h264.encode(e, frame, time.Duration(i) * time.Second / 30)
			testing.expect_value(t, encode_err, h264.Error.None)
			check_packets(t, packets, &seen)
		}
		packets, flush_err := h264.flush(e)
		testing.expect_value(t, flush_err, h264.Error.None)
		check_packets(t, packets, &seen)
		testing.expectf(t, seen.count == 30, "%v: %d packets for 30 frames", backend, seen.count)
		testing.expectf(t, seen.keyframes >= 1, "%v: %d keyframes", backend, seen.keyframes)
		log.infof("h264: %v encoded 30 frames of %d x %d: %d packets, %d keyframes", h264.backend_of(e), W, H, seen.count, seen.keyframes)
		h264.close(e)
	}
}

// The bytes as a string, for a comparison that prints them (a literal of bytes cannot be cast directly).
@(private = "file")
str :: proc(b: []u8) -> string { return string(b) }
