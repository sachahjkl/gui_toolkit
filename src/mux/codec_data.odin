// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Ported to Odin from Mediabunny (https://github.com/Vanilagy/mediabunny, commit 173f6b7): src/codec-data.ts (Annex B,
// the AVCDecoderConfigurationRecord, the SPS, Opus), src/codec.ts (the VP9 and AV1 configuration records),
// src/adts/adts-reader.ts and shared/aac-misc.ts (ADTS, the AudioSpecificConfig). Only what writing needs.
package tk_mux

////////////////////////////////
// Bits

@(private)
Bit_Reader :: struct {
	data: []u8,
	pos:  int,    // in bits
	ok:   bool,   // false once a read went past the end
}

@(private)
read_bits :: proc(r: ^Bit_Reader, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n {
		byte_at := r.pos >> 3
		if byte_at >= len(r.data) {
			r.ok = false
			return 0
		}
		v = v << 1 | u32(r.data[byte_at] >> (7 - uint(r.pos & 7))) & 1
		r.pos += 1
	}
	return v
}

@(private)
read_exp_golomb :: proc(r: ^Bit_Reader) -> u32 {
	zeros := 0
	for read_bits(r, 1) == 0 && zeros < 32 && r.ok { zeros += 1 }
	if zeros == 0 { return 0 }
	return (u32(1) << uint(zeros) - 1) + read_bits(r, zeros)
}

@(private)
read_signed_exp_golomb :: proc(r: ^Bit_Reader) -> i32 {
	v := read_exp_golomb(r)
	return (v & 1) == 0 ? -i32(v >> 1) : i32((v + 1) >> 1)
}

////////////////////////////////
// H.264 (Rec. ITU-T H.264, ISO 14496-15)

@(private) AVC_NAL_SPS :: 7
@(private) AVC_NAL_PPS :: 8
@(private) AVC_NAL_SPS_EXT :: 13

// The NAL units of an Annex B packet (start codes of 3 or 4 bytes), as slices of `data` (temp allocator).
@(private)
annex_b_units :: proc(data: []u8) -> [dynamic][]u8 {
	units := make([dynamic][]u8, context.temp_allocator)
	i := 0
	start := -1
	n := len(data)
	for i < n - 2 {
		if data[i] != 0 { i += 1; continue }
		code := 0
		if i + 3 < n && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
			code = 4
		} else if data[i + 1] == 0 && data[i + 2] == 1 {
			code = 3
		}
		if code == 0 { i += 1; continue }
		if start >= 0 && i > start { append(&units, data[start:i]) }
		start = i + code
		i = start
	}
	if start >= 0 && start < n { append(&units, data[start:]) }
	return units
}

// The units, each after its length on 4 bytes (big-endian): the AVCC form MP4 holds.
@(private)
length_prefixed :: proc(units: [][]u8) -> []u8 {
	total := 0
	for u in units { total += 4 + len(u) }
	out := make([]u8, total)
	at := 0
	for u in units {
		n := len(u)
		out[at], out[at + 1], out[at + 2], out[at + 3] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
		copy(out[at + 4:], u)
		at += 4 + n
	}
	return out
}

@(private = "file")
remove_emulation_prevention :: proc(data: []u8) -> []u8 {
	out := make([dynamic]u8, 0, len(data), context.temp_allocator)
	for i := 0; i < len(data); i += 1 {
		if i + 2 < len(data) && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 3 {
			append(&out, 0, 0)
			i += 2
		} else {
			append(&out, data[i])
		}
	}
	return out[:]
}

// What the avcC and the size check need of an SPS: the parse stops after the frame cropping (the VUI is not read).
@(private)
Avc_Sps :: struct {
	profile_idc, constraint_flags, level_idc: u8,
	chroma_format_idc:                        u32,
	bit_depth_luma_minus8:                    u32,
	bit_depth_chroma_minus8:                  u32,
	coded_width, coded_height:                int,
	display_width, display_height:            int,
}

@(private)
parse_avc_sps :: proc(sps: []u8) -> (info: Avc_Sps, ok: bool) {
	r := Bit_Reader{data = remove_emulation_prevention(sps), ok = true}
	read_bits(&r, 3)   // forbidden_zero_bit, nal_ref_idc
	if read_bits(&r, 5) != AVC_NAL_SPS { return }
	info.profile_idc = u8(read_bits(&r, 8))
	info.constraint_flags = u8(read_bits(&r, 8))
	info.level_idc = u8(read_bits(&r, 8))
	read_exp_golomb(&r)   // seq_parameter_set_id

	// "When chroma_format_idc is not present, it shall be inferred to be equal to 1 (4:2:0 chroma format)."
	info.chroma_format_idc = 1
	separate_colour_plane: u32
	switch info.profile_idc {
	case 100, 110, 122, 244, 44, 83, 86, 118, 128:
		info.chroma_format_idc = read_exp_golomb(&r)
		if info.chroma_format_idc == 3 { separate_colour_plane = read_bits(&r, 1) }
		info.bit_depth_luma_minus8 = read_exp_golomb(&r)
		info.bit_depth_chroma_minus8 = read_exp_golomb(&r)
		read_bits(&r, 1)   // qpprime_y_zero_transform_bypass_flag
		if read_bits(&r, 1) == 1 {   // seq_scaling_matrix_present_flag
			for i in 0 ..< (info.chroma_format_idc != 3 ? 8 : 12) {
				if read_bits(&r, 1) == 0 { continue }
				size := i < 6 ? 16 : 64
				last, next: i32 = 8, 8
				for _ in 0 ..< size {
					if next != 0 { next = (last + read_signed_exp_golomb(&r) + 256) % 256 }
					if next != 0 { last = next }
				}
			}
		}
	}

	read_exp_golomb(&r)   // log2_max_frame_num_minus4
	switch read_exp_golomb(&r) {   // pic_order_cnt_type
	case 0:
		read_exp_golomb(&r)   // log2_max_pic_order_cnt_lsb_minus4
	case 1:
		read_bits(&r, 1)   // delta_pic_order_always_zero_flag
		read_signed_exp_golomb(&r)   // offset_for_non_ref_pic
		read_signed_exp_golomb(&r)   // offset_for_top_to_bottom_field
		cycle := read_exp_golomb(&r)
		for _ in 0 ..< min(cycle, 255) { read_signed_exp_golomb(&r) }
	}
	read_exp_golomb(&r)   // max_num_ref_frames
	read_bits(&r, 1)      // gaps_in_frame_num_value_allowed_flag

	width_in_mbs := int(read_exp_golomb(&r)) + 1
	height_in_map_units := int(read_exp_golomb(&r)) + 1
	frame_mbs_only := int(read_bits(&r, 1))
	if frame_mbs_only == 0 { read_bits(&r, 1) }   // mb_adaptive_frame_field_flag
	info.coded_width = 16 * width_in_mbs
	// (FrameHeightInMbs: a map unit is two macroblocks high in field coding; Mediabunny leaves the factor out)
	info.coded_height = 16 * height_in_map_units * (2 - frame_mbs_only)
	info.display_width, info.display_height = info.coded_width, info.coded_height
	read_bits(&r, 1)   // direct_8x8_inference_flag
	if read_bits(&r, 1) == 1 {   // frame_cropping_flag
		left, right := int(read_exp_golomb(&r)), int(read_exp_golomb(&r))
		top, bottom := int(read_exp_golomb(&r)), int(read_exp_golomb(&r))
		unit_x, unit_y: int
		chroma_array_type := separate_colour_plane == 0 ? info.chroma_format_idc : 0
		if chroma_array_type == 0 {
			unit_x, unit_y = 1, 2 - frame_mbs_only
		} else {
			sub_width := info.chroma_format_idc == 3 ? 1 : 2
			sub_height := info.chroma_format_idc == 1 ? 2 : 1
			unit_x, unit_y = sub_width, sub_height * (2 - frame_mbs_only)
		}
		info.display_width -= unit_x * (left + right)
		info.display_height -= unit_y * (top + bottom)
	}
	if !r.ok || info.display_width <= 0 || info.display_height <= 0 { return }
	return info, true
}

@(private = "file")
has_extended_avc_data :: proc(profile: u8) -> bool { return profile == 100 || profile == 110 || profile == 122 || profile == 144 }

// The AVCDecoderConfigurationRecord (ISO 14496-15, 5.3.3.1) of an Annex B packet's SPS and PPS, and the first SPS.
@(private)
avc_config_from_annex_b :: proc(packet: []u8) -> (record: []u8, sps: Avc_Sps, ok: bool) {
	sps_units := make([dynamic][]u8, context.temp_allocator)
	pps_units := make([dynamic][]u8, context.temp_allocator)
	ext_units := make([dynamic][]u8, context.temp_allocator)
	for unit in annex_b_units(packet) {
		if len(unit) == 0 { continue }
		// The counts are capped at what the record can hold
		switch unit[0] & 0x1F {
		case AVC_NAL_SPS:     if len(sps_units) < 31 { append(&sps_units, unit) }
		case AVC_NAL_PPS:     if len(pps_units) < 255 { append(&pps_units, unit) }
		case AVC_NAL_SPS_EXT: if len(ext_units) < 255 { append(&ext_units, unit) }
		}
	}
	if len(sps_units) == 0 || len(pps_units) == 0 { return }
	sps = parse_avc_sps(sps_units[0]) or_return

	out := make([dynamic]u8)
	append(&out, 1, sps.profile_idc, sps.constraint_flags, sps.level_idc)
	append(&out, 0xFC | 3)   // reserved (6) + lengthSizeMinusOne (2): 4-byte lengths
	append(&out, 0xE0 | u8(len(sps_units)))
	for u in sps_units {
		append(&out, u8(len(u) >> 8), u8(len(u)))
		append(&out, ..u)
	}
	append(&out, u8(len(pps_units)))
	for u in pps_units {
		append(&out, u8(len(u) >> 8), u8(len(u)))
		append(&out, ..u)
	}
	if has_extended_avc_data(sps.profile_idc) {
		append(&out, 0xFC | u8(sps.chroma_format_idc & 3))
		append(&out, 0xF8 | u8(sps.bit_depth_luma_minus8 & 7))
		append(&out, 0xF8 | u8(sps.bit_depth_chroma_minus8 & 7))
		append(&out, u8(len(ext_units)))
		for u in ext_units {
			append(&out, u8(len(u) >> 8), u8(len(u)))
			append(&out, ..u)
		}
	}
	return out[:], sps, true
}

////////////////////////////////
// AAC (ISO 13818-7 ADTS, ISO 14496-3 AudioSpecificConfig)

@(private) ADTS_HEADER_SIZE :: 7   // 9 with a CRC

@(private)
AAC_FREQUENCIES :: [?]int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}

@(private)
Adts_Header :: struct {
	object_type:        u32,
	frequency_index:    u32,
	channel_config:     u32,
	header_size:        int,
}

@(private)
read_adts_header :: proc(data: []u8) -> (h: Adts_Header, ok: bool) {
	if len(data) < ADTS_HEADER_SIZE { return }
	r := Bit_Reader{data = data[:ADTS_HEADER_SIZE], ok = true}
	if read_bits(&r, 12) != 0xFFF { return }
	read_bits(&r, 1)   // MPEG version
	if read_bits(&r, 2) != 0 { return }   // layer
	protection_absent := read_bits(&r, 1)
	h.object_type = read_bits(&r, 2) + 1
	h.frequency_index = read_bits(&r, 4)
	if int(h.frequency_index) >= len(AAC_FREQUENCIES) { return }
	read_bits(&r, 1)   // private bit
	h.channel_config = read_bits(&r, 3)
	if h.channel_config == 0 { return }   // (a channel configuration in the stream: not supported)
	read_bits(&r, 4)   // originality, home, copyright bits
	read_bits(&r, 13)  // frame length
	read_bits(&r, 11)  // buffer fullness
	if read_bits(&r, 2) != 0 { return }   // more than one AAC frame: not supported
	h.header_size = protection_absent == 1 ? ADTS_HEADER_SIZE : ADTS_HEADER_SIZE + 2
	if len(data) < h.header_size { return }
	return h, r.ok
}

// The AudioSpecificConfig of an ADTS stream: object type, frequency index, channel configuration and an empty
// GASpecificConfig (an ADTS object type is 1 to 4: no SBR signalling, no escape).
@(private)
aac_config_from_adts :: proc(h: Adts_Header) -> []u8 {
	bits := h.object_type << 11 | h.frequency_index << 7 | h.channel_config << 3
	out := make([]u8, 2)
	out[0], out[1] = u8(bits >> 8), u8(bits)
	return out
}

////////////////////////////////
// Opus (RFC 7845, RFC 6716)

@(private) OPUS_SAMPLE_RATE :: 48000
// RFC 7845 recommends 80 ms, but that one's very far from convergence (gives around -30 dBFS error). 400 ms was found
// empirically to almost always give an error well below -100 dBFS, so we're using that
@(private) OPUS_PRE_ROLL_DURATION :: 0.4

@(private)
OPUS_FRAME_DURATIONS :: [32]int{
	480, 960, 1920, 2880,
	480, 960, 1920, 2880,
	480, 960, 1920, 2880,
	480, 960,
	480, 960,
	120, 240, 480, 960,
	120, 240, 480, 960,
	120, 240, 480, 960,
	120, 240, 480, 960,
}

// A packet's duration in 48 kHz samples, from its TOC byte.
@(private)
opus_packet_samples :: proc(packet: []u8) -> int {
	durations := OPUS_FRAME_DURATIONS
	config := packet[0] >> 3
	frames: int
	switch packet[0] & 3 {
	case 0:    frames = 1
	case 1, 2: frames = 2
	case:      frames = len(packet) > 1 ? int(packet[1] & 0x3F) : 0   // code 3: the frame count byte
	}
	return durations[config] * frames
}

@(private)
Opus_Head :: struct {
	channels:          u8,
	pre_skip:          u16,
	input_sample_rate: u32,
	output_gain:       i16,
	mapping_family:    u8,
	mapping_table:     []u8,
}

// The identification header's fields (little-endian); false when it is too short.
@(private)
parse_opus_head :: proc(bytes: []u8) -> (h: Opus_Head, ok: bool) {
	if len(bytes) < 19 { return }
	h.channels = bytes[9]
	h.pre_skip = u16(bytes[10]) | u16(bytes[11]) << 8
	h.input_sample_rate = u32(bytes[12]) | u32(bytes[13]) << 8 | u32(bytes[14]) << 16 | u32(bytes[15]) << 24
	h.output_gain = i16(u16(bytes[16]) | u16(bytes[17]) << 8)
	h.mapping_family = bytes[18]
	if h.mapping_family != 0 { h.mapping_table = bytes[19:min(len(bytes), 19 + 2 + int(h.channels))] }
	return h, true
}

////////////////////////////////
// VP9 and AV1

// https://www.webmproject.org/docs/container/#vp9-codec-feature-metadata-codecprivate
@(private)
vp9_codec_private :: proc(c: Vp9_Config) -> []u8 {
	out := make([]u8, 12)
	bytes := [12]u8{1, 1, c.profile, 2, 1, c.level, 3, 1, c.bit_depth == 0 ? 8 : c.bit_depth, 4, 1, c.chroma_subsampling}
	copy(out, bytes[:])
	return out
}

// The AV1CodecConfigurationRecord's four bytes (https://aomediacodec.github.io/av1-isobmff/).
@(private)
av1_config_record :: proc(c: Av1_Config) -> [4]u8 {
	depth := c.bit_depth == 0 ? 8 : c.bit_depth
	marker_version := u8(1 << 7 | 1)
	profile_level := c.profile << 5 | c.level
	third := bit(c.high_tier) << 7 | bit(depth != 8) << 6 | bit(depth == 12) << 5 | bit(c.monochrome) << 4 |
		bit(c.chroma_subsampling_x) << 3 | bit(c.chroma_subsampling_y) << 2 | c.chroma_sample_position
	return {marker_version, profile_level, third, 0}   // (initial_presentation_delay_present: 0)
}

@(private)
bit :: #force_inline proc "contextless" (b: bool) -> u8 { return b ? 1 : 0 }
