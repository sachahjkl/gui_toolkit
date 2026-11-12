package tk_h264

// The bit writer of H.264 headers (ITU-T H.264, 7.2: u(n), ue(v), se(v)) and the headers this package writes: the SPS,
// the PPS and the slice header of the one stream shape the encoders make (progressive frames, one slice a picture, I
// and P slices only, each picture a reference of the next, picture order count type 2). VA-API takes them as packed
// headers when the driver asks; the tests check them bit for bit.

Bit_Writer :: struct {
	data:    [dynamic]u8,
	current: u8,    // the bits of the byte not yet in data, from the high bit
	used:    uint,  // how many bits of current are written (0 ..< 8)
}

bit_writer_make :: proc(allocator := context.allocator) -> Bit_Writer {
	return Bit_Writer{data = make([dynamic]u8, 0, 64, allocator)}
}

bit_writer_destroy :: proc(w: ^Bit_Writer) { delete(w.data) }

// Empty again, its memory kept.
bit_writer_reset :: proc(w: ^Bit_Writer) {
	clear(&w.data)
	w.current, w.used = 0, 0
}

// u(n): the low `count` bits of `value` (count in 0 ..= 32), the highest first.
write_bits :: proc(w: ^Bit_Writer, value: u32, count: uint) {
	assert(count <= 32)
	for i := count; i > 0; i -= 1 {
		bit := u8(value >> (i - 1)) & 1
		w.current |= bit << (7 - w.used)
		w.used += 1
		if w.used == 8 {
			append(&w.data, w.current)
			w.current, w.used = 0, 0
		}
	}
}

write_bit :: proc(w: ^Bit_Writer, flag: bool) { write_bits(w, bit_of(flag), 1) }

// 1 for true: a flag in a field of bits.
bit_of :: #force_inline proc "contextless" (flag: bool) -> u32 { return flag ? 1 : 0 }

// ue(v): Exp-Golomb, v + 1 in n bits after n - 1 zeros.
write_ue :: proc(w: ^Bit_Writer, value: u32) {
	code := u64(value) + 1
	n: uint = 0
	for c := code; c > 0; c >>= 1 { n += 1 }
	// (the zeros and the code apart: value + 1 may take 33 bits)
	zeros := n - 1
	for zeros > 32 { write_bits(w, 0, 32); zeros -= 32 }
	write_bits(w, 0, zeros)
	if n > 32 {
		write_bits(w, u32(code >> 32), n - 32)
		write_bits(w, u32(code), 32)
	} else {
		write_bits(w, u32(code), n)
	}
}

// se(v): 1 -> 1, -1 -> 2, 2 -> 3, -2 -> 4...
write_se :: proc(w: ^Bit_Writer, value: i32) {
	if value > 0 {
		write_ue(w, u32(value) * 2 - 1)
	} else {
		write_ue(w, u32(-i64(value)) * 2)
	}
}

// The bits written so far.
bit_count :: proc(w: ^Bit_Writer) -> int { return len(w.data) * 8 + int(w.used) }

// rbsp_trailing_bits: a 1, then zeros to the byte's end.
write_trailing_bits :: proc(w: ^Bit_Writer) {
	write_bits(w, 1, 1)
	align_with(w, 0)
}

// Fills the byte with `bit` (0 or 1); nothing when aligned.
align_with :: proc(w: ^Bit_Writer, bit: u32) {
	for w.used != 0 { write_bits(w, bit, 1) }
}

// The bytes written; the last one with its unwritten low bits at 0 when not aligned.
bit_writer_bytes :: proc(w: ^Bit_Writer) -> []u8 {
	if w.used != 0 {
		append(&w.data, w.current)
		w.current, w.used = 0, 0
		// (only at the end: a later write would start a new byte; callers take the bytes once)
	}
	return w.data[:]
}

////////////////////////////////
// NAL units

NAL_SLICE :: 1
NAL_IDR :: 5
NAL_SEI :: 6
NAL_SPS :: 7
NAL_PPS :: 8
NAL_AUD :: 9

// A start code and a NAL header (forbidden bit, nal_ref_idc, nal_unit_type), as packed headers start.
write_nal_start :: proc(w: ^Bit_Writer, ref_idc: u32, unit_type: u32) {
	write_bits(w, 1, 32)
	write_bits(w, 0, 1)
	write_bits(w, ref_idc, 2)
	write_bits(w, unit_type, 5)
}

// A NAL unit in Annex B: a start code, the header byte, then `rbsp` with an emulation prevention byte (3) after each two
// zero bytes that a byte <= 3 follows (7.4.1), so no start code appears inside.
append_nal :: proc(out: ^[dynamic]u8, ref_idc: u8, unit_type: u8, rbsp: []u8) {
	append(out, 0, 0, 0, 1, (ref_idc & 3) << 5 | (unit_type & 31))
	zeros := 0
	for b in rbsp {
		if zeros >= 2 && b <= 3 {
			append(out, 3)
			zeros = 0
		}
		append(out, b)
		zeros = b == 0 ? zeros + 1 : 0
	}
}

////////////////////////////////
// The headers

PROFILE_CONSTRAINED_BASELINE :: 66   // profile_idc 66 with constraint_set1_flag
PROFILE_MAIN :: 77
PROFILE_HIGH :: 100

// What the SPS and PPS say: one stream shape (see the file's head).
Sequence :: struct {
	profile_idc:          u8,    // PROFILE_*
	level_idc:            u8,    // level_for
	width, height:        int,   // the picture (even); the coded size is rounded up to 16 and cropped back
	log2_max_frame_num:   int,   // 4 ..= 16
	max_ref_frames:       int,
	fps:                  int,   // the timing information (0: none)
	qp:                   int,   // the PPS's initial quantiser
}

// The SPS's RBSP (seq_parameter_set_data, 7.3.2.1.1), with its trailing bits; append_nal makes it a NAL unit.
write_sps :: proc(w: ^Bit_Writer, s: Sequence) {
	width_mbs := (s.width + 15) / 16
	height_mbs := (s.height + 15) / 16
	write_bits(w, u32(s.profile_idc), 8)
	write_bits(w, profile_constraints(s.profile_idc), 8)
	write_bits(w, u32(s.level_idc), 8)
	write_ue(w, 0)                                   // seq_parameter_set_id
	if s.profile_idc == PROFILE_HIGH {
		write_ue(w, 1)                               // chroma_format_idc: 4:2:0
		write_ue(w, 0)                               // bit_depth_luma_minus8
		write_ue(w, 0)                               // bit_depth_chroma_minus8
		write_bit(w, false)                          // qpprime_y_zero_transform_bypass_flag
		write_bit(w, false)                          // seq_scaling_matrix_present_flag
	}
	write_ue(w, u32(s.log2_max_frame_num - 4))
	write_ue(w, 2)                                   // pic_order_cnt_type: the order is the decoding order
	write_ue(w, u32(s.max_ref_frames))
	write_bit(w, false)                              // gaps_in_frame_num_value_allowed_flag
	write_ue(w, u32(width_mbs - 1))
	write_ue(w, u32(height_mbs - 1))
	write_bit(w, true)                               // frame_mbs_only_flag
	write_bit(w, true)                               // direct_8x8_inference_flag
	crop_right := (width_mbs * 16 - s.width) / 2      // in units of 2 pixels (4:2:0, frames)
	crop_bottom := (height_mbs * 16 - s.height) / 2
	cropped := crop_right != 0 || crop_bottom != 0
	write_bit(w, cropped)
	if cropped {
		write_ue(w, 0)
		write_ue(w, u32(crop_right))
		write_ue(w, 0)
		write_ue(w, u32(crop_bottom))
	}
	write_bit(w, true)                               // vui_parameters_present_flag
	write_vui(w, s)
	write_trailing_bits(w)
}

// constraint_set0..5 and the 2 reserved zero bits: Constrained Baseline is 66 with set0 and set1; Main sets set1 (it is
// decodable as Main, nothing more said); High none.
@(private)
profile_constraints :: proc(profile_idc: u8) -> u32 {
	switch profile_idc {
	case PROFILE_CONSTRAINED_BASELINE: return 0b1100_0000
	case PROFILE_MAIN:                 return 0b0100_0000
	}
	return 0
}

// The VUI (E.1.1): BT.709 colours in the limited range, the timing, and no reordering (each picture is shown as it is
// decoded), so a player keeps no frame back.
@(private)
write_vui :: proc(w: ^Bit_Writer, s: Sequence) {
	write_bit(w, false)                              // aspect_ratio_info_present_flag: square pixels
	write_bit(w, false)                              // overscan_info_present_flag
	write_bit(w, true)                               // video_signal_type_present_flag
	write_bits(w, 5, 3)                              // video_format: unspecified
	write_bit(w, false)                              // video_full_range_flag: 16 ..= 235
	write_bit(w, true)                               // colour_description_present_flag
	write_bits(w, 1, 8)                              // colour_primaries: BT.709
	write_bits(w, 1, 8)                              // transfer_characteristics: BT.709
	write_bits(w, 1, 8)                              // matrix_coefficients: BT.709
	write_bit(w, false)                              // chroma_loc_info_present_flag
	write_bit(w, s.fps > 0)                          // timing_info_present_flag
	if s.fps > 0 {
		write_bits(w, 1, 32)                         // num_units_in_tick
		write_bits(w, u32(s.fps * 2), 32)            // time_scale: a tick is a field
		write_bit(w, false)                          // fixed_frame_rate_flag: a screen's frames come when it changes
	}
	write_bit(w, false)                              // nal_hrd_parameters_present_flag
	write_bit(w, false)                              // vcl_hrd_parameters_present_flag
	write_bit(w, false)                              // pic_struct_present_flag
	write_bit(w, true)                               // bitstream_restriction_flag
	write_bit(w, true)                               // motion_vectors_over_pic_boundaries_flag
	write_ue(w, 0)                                   // max_bytes_per_pic_denom
	write_ue(w, 0)                                   // max_bits_per_mb_denom
	write_ue(w, 15)                                  // log2_max_mv_length_horizontal
	write_ue(w, 15)                                  // log2_max_mv_length_vertical
	write_ue(w, 0)                                   // max_num_reorder_frames
	write_ue(w, u32(s.max_ref_frames))               // max_dec_frame_buffering
}

// The PPS's RBSP (7.3.2.2), with its trailing bits. CABAC and the 8x8 transform where the profile has them.
write_pps :: proc(w: ^Bit_Writer, s: Sequence) {
	write_ue(w, 0)                                   // pic_parameter_set_id
	write_ue(w, 0)                                   // seq_parameter_set_id
	write_bit(w, uses_cabac(s.profile_idc))          // entropy_coding_mode_flag
	write_bit(w, false)                              // bottom_field_pic_order_in_frame_present_flag
	write_ue(w, 0)                                   // num_slice_groups_minus1
	write_ue(w, 0)                                   // num_ref_idx_l0_default_active_minus1
	write_ue(w, 0)                                   // num_ref_idx_l1_default_active_minus1
	write_bit(w, false)                              // weighted_pred_flag
	write_bits(w, 0, 2)                              // weighted_bipred_idc
	write_se(w, i32(s.qp - 26))                      // pic_init_qp_minus26
	write_se(w, 0)                                   // pic_init_qs_minus26
	write_se(w, 0)                                   // chroma_qp_index_offset
	write_bit(w, true)                               // deblocking_filter_control_present_flag
	write_bit(w, false)                              // constrained_intra_pred_flag
	write_bit(w, false)                              // redundant_pic_cnt_present_flag
	if s.profile_idc == PROFILE_HIGH {
		write_bit(w, true)                           // transform_8x8_mode_flag
		write_bit(w, false)                          // pic_scaling_matrix_present_flag
		write_se(w, 0)                               // second_chroma_qp_index_offset
	}
	write_trailing_bits(w)
}

uses_cabac :: proc(profile_idc: u8) -> bool { return profile_idc != PROFILE_CONSTRAINED_BASELINE }

SLICE_P :: 0
SLICE_I :: 2

// One picture's slice header (7.3.3), from the start code: what VA-API takes as a packed slice header, the driver
// writing the slice data after it. With CABAC, aligned with ones (cabac_alignment_one_bit); else not aligned.
Slice :: struct {
	idr:        bool,
	frame_num:  int,
	idr_pic_id: int,
	qp_delta:   int,
}

write_slice_header :: proc(w: ^Bit_Writer, s: Sequence, slice: Slice) {
	write_nal_start(w, 3, slice.idr ? NAL_IDR : NAL_SLICE)
	write_ue(w, 0)                                   // first_mb_in_slice
	write_ue(w, slice.idr ? SLICE_I : SLICE_P)       // slice_type
	write_ue(w, 0)                                   // pic_parameter_set_id
	write_bits(w, u32(slice.frame_num), uint(s.log2_max_frame_num))
	if slice.idr { write_ue(w, u32(slice.idr_pic_id)) }
	if !slice.idr {
		write_bit(w, false)                          // num_ref_idx_active_override_flag
		write_bit(w, false)                          // ref_pic_list_modification_flag_l0
	}
	// dec_ref_pic_marking: every picture is a reference (nal_ref_idc 3)
	if slice.idr {
		write_bit(w, false)                          // no_output_of_prior_pics_flag
		write_bit(w, false)                          // long_term_reference_flag
	} else {
		write_bit(w, false)                          // adaptive_ref_pic_marking_mode_flag: sliding window
	}
	cabac := uses_cabac(s.profile_idc)
	if cabac && !slice.idr { write_ue(w, 0) }        // cabac_init_idc
	write_se(w, i32(slice.qp_delta))
	write_ue(w, 0)                                   // disable_deblocking_filter_idc: the filter on
	write_se(w, 0)                                   // slice_alpha_c0_offset_div2
	write_se(w, 0)                                   // slice_beta_offset_div2
	if cabac { align_with(w, 1) }
}

// The smallest log2_max_frame_num that holds a whole keyframe interval (frame_num never wraps inside one), 4 ..= 16.
log2_max_frame_num_for :: proc(keyframe_frames: int) -> int {
	n := 4
	for n < 16 && 1 << uint(n) < keyframe_frames { n += 1 }
	return n
}

// The levels of Table A-1: level_idc, the largest macroblock rate, frame size in macroblocks, and bitrate (kbit/s, the
// Baseline and Main column).
@(private, rodata)
LEVELS := [?][4]int{
	{10, 1485, 99, 64}, {11, 3000, 396, 192}, {12, 6000, 396, 384}, {13, 11880, 396, 768},
	{20, 11880, 396, 2000}, {21, 19800, 792, 4000}, {22, 20250, 1620, 4000},
	{30, 40500, 1620, 10000}, {31, 108000, 3600, 14000}, {32, 216000, 5120, 20000},
	{40, 245760, 8192, 20000}, {41, 245760, 8192, 50000}, {42, 522240, 8704, 50000},
	{50, 589824, 22080, 135000}, {51, 983040, 36864, 240000}, {52, 2073600, 36864, 240000},
	{60, 4177920, 139264, 240000}, {61, 8355840, 139264, 480000}, {62, 16711680, 139264, 800000},
}

// The lowest level (level_idc) whose limits hold a picture of `width` x `height` at `fps` and `bitrate` bits a second
// (0: not counted). 62 when none does.
level_for :: proc(width, height, fps, bitrate: int) -> u8 {
	frame_mbs := ((width + 15) / 16) * ((height + 15) / 16)
	rate := frame_mbs * fps
	kbits := (bitrate + 999) / 1000
	for l in LEVELS {
		if frame_mbs <= l[2] && rate <= l[1] && kbits <= l[3] { return u8(l[0]) }
	}
	return 62
}
