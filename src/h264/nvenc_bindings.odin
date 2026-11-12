#+build linux, windows
package tk_h264

// NVIDIA's NVENC API 12.0 (include/ffnvcodec/nvEncodeAPI.h of FFmpeg's nv-codec-headers n12.0.16.1, MIT) and the few
// CUDA driver calls it needs (dynlink_cuda.h). Drivers from 520 on take this version. Only what nvenc.odin uses is
// ported, but each structure keeps the header's whole layout, its reserved arrays included: NVENC reads a structure as
// the size its version field implies. The size after each structure is the header's on a 64-bit system; Linux and
// Windows lay them out the same (every field is a u32, an enum, a u64 or a pointer). A C bit field is one u32 here,
// its bits named by constants.

import "core:sync"

@(private) NVENCAPI_MAJOR_VERSION :: 12
@(private) NVENCAPI_MINOR_VERSION :: 0
@(private) NVENCAPI_VERSION :: u32(NVENCAPI_MAJOR_VERSION | NVENCAPI_MINOR_VERSION << 24)

// NVENCAPI_STRUCT_VERSION(ver) is NV_STRUCT | ver << 16; the structures that grew in 12.0 also carry bit 31.
@(private) NV_STRUCT :: NVENCAPI_VERSION | 0x7 << 28
@(private) NV_GREW :: u32(1) << 31

@(private) NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER :: NV_STRUCT | 1 << 16
@(private) NV_ENC_CREATE_INPUT_BUFFER_VER :: NV_STRUCT | 1 << 16
@(private) NV_ENC_CREATE_BITSTREAM_BUFFER_VER :: NV_STRUCT | 1 << 16
@(private) NV_ENC_RC_PARAMS_VER :: NV_STRUCT | 1 << 16
@(private) NV_ENC_CONFIG_VER :: NV_STRUCT | 8 << 16 | NV_GREW
@(private) NV_ENC_INITIALIZE_PARAMS_VER :: NV_STRUCT | 5 << 16 | NV_GREW
@(private) NV_ENC_PRESET_CONFIG_VER :: NV_STRUCT | 4 << 16 | NV_GREW
@(private) NV_ENC_PIC_PARAMS_VER :: NV_STRUCT | 6 << 16 | NV_GREW
@(private) NV_ENC_LOCK_BITSTREAM_VER :: NV_STRUCT | 2 << 16
@(private) NV_ENC_LOCK_INPUT_BUFFER_VER :: NV_STRUCT | 1 << 16
@(private) NV_ENCODE_API_FUNCTION_LIST_VER :: NV_STRUCT | 2 << 16

// 12.0 as NvEncodeAPIGetMaxSupportedVersion writes a version: major << 4 | minor.
@(private) NVENC_NEEDED_VERSION :: u32(NVENCAPI_MAJOR_VERSION << 4 | NVENCAPI_MINOR_VERSION)

@(private) NV_Status :: i32
@(private) NV_ENC_SUCCESS :: 0
@(private) NV_ENC_ERR_NEED_MORE_INPUT :: 17

@(private) NV_ENC_DEVICE_TYPE_CUDA :: 1
@(private) NV_ENC_BUFFER_FORMAT_NV12 :: 0x1
@(private) NV_ENC_PIC_STRUCT_FRAME :: 1
@(private) NV_ENC_PIC_FLAG_FORCEIDR :: 0x2
@(private) NV_ENC_PIC_FLAG_OUTPUT_SPSPPS :: 0x4
@(private) NV_ENC_PIC_FLAG_EOS :: 0x8
@(private) NV_ENC_PARAMS_RC_CONSTQP :: 0x0
@(private) NV_ENC_PARAMS_RC_VBR :: 0x1
@(private) NV_ENC_MULTI_PASS_DISABLED :: 0
@(private) NV_ENC_TUNING_INFO_LOW_LATENCY :: 2
@(private) NV_ENC_LEVEL_AUTOSELECT :: 0
@(private) NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED :: 5
@(private) NV_ENC_VUI_BT709 :: 1   // the colour primaries, the transfer and the matrix: each value 1 is BT.709

// NV_ENC_RC_PARAMS's bit field: enableLookahead is bit 5.
@(private) NV_ENC_RC_ENABLE_LOOKAHEAD :: u32(1) << 5
// NV_ENC_CONFIG_H264's bit field: repeatSPSPPS is bit 12 (after enableTemporalSVC ..= enableConstrainedEncoding).
@(private) NV_ENC_H264_REPEAT_SPS_PPS :: u32(1) << 12

@(private)
NV_Guid :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

@(private) NV_ENC_CODEC_H264_GUID := NV_Guid{0x6bc82762, 0x4e63, 0x4ca4, {0xaa, 0x85, 0x1e, 0x50, 0xf3, 0x21, 0xf6, 0xbf}}
@(private) NV_ENC_H264_PROFILE_HIGH_GUID := NV_Guid{0xe7cbc309, 0x4f7a, 0x4b89, {0xaf, 0x2a, 0xd5, 0x37, 0xc9, 0x2b, 0xe3, 0x10}}
@(private) NV_ENC_PRESET_P4_GUID := NV_Guid{0x90a7b826, 0xdf06, 0x4862, {0xb9, 0xd2, 0xcd, 0x6d, 0x73, 0xa0, 0x86, 0x81}}

// NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS: 1552 bytes.
@(private)
NV_Open_Session_Params :: struct {
	version:     u32,
	device_type: u32,
	device:      rawptr,
	reserved:    rawptr,
	api_version: u32,
	reserved1:   [253]u32,
	reserved2:   [64]rawptr,
}

// NV_ENC_CREATE_INPUT_BUFFER: 776 bytes.
@(private)
NV_Create_Input_Buffer :: struct {
	version:       u32,
	width:         u32,
	height:        u32,
	memory_heap:   u32,
	buffer_format: u32,
	reserved:      u32,
	input_buffer:  rawptr,   // out
	system_memory: rawptr,
	reserved1:     [57]u32,
	reserved2:     [63]rawptr,
}

// NV_ENC_CREATE_BITSTREAM_BUFFER: 776 bytes.
@(private)
NV_Create_Bitstream_Buffer :: struct {
	version:              u32,
	size:                 u32,
	memory_heap:          u32,
	reserved:             u32,
	bitstream_buffer:     rawptr,   // out
	bitstream_buffer_ptr: rawptr,
	reserved1:            [58]u32,
	reserved2:            [64]rawptr,
}

// NV_ENC_QP: 12 bytes.
@(private)
NV_QP :: struct {
	inter_p, inter_b, intra: u32,
}

// NV_ENC_RC_PARAMS: 128 bytes.
@(private)
NV_RC_Params :: struct {
	version:                   u32,
	rate_control_mode:         u32,
	const_qp:                  NV_QP,
	average_bitrate:           u32,
	max_bitrate:               u32,
	vbv_buffer_size:           u32,
	vbv_initial_delay:         u32,
	flags:                     u32,   // enableMinQP ..= reservedBitFields
	min_qp:                    NV_QP,
	max_qp:                    NV_QP,
	initial_rc_qp:             NV_QP,
	temporal_layer_index_mask: u32,
	temporal_layer_qp:         [8]u8,
	target_quality:            u8,
	target_quality_lsb:        u8,
	lookahead_depth:           u16,
	low_delay_key_frame_scale: u8,
	y_dc_qp_index_offset:      i8,
	u_dc_qp_index_offset:      i8,
	v_dc_qp_index_offset:      i8,
	qp_map_mode:               u32,
	multi_pass:                u32,
	alpha_layer_bitrate_ratio: u32,
	cb_qp_index_offset:        i8,
	cr_qp_index_offset:        i8,
	reserved2:                 u16,
	reserved:                  [4]u32,
}

// NV_ENC_CONFIG_H264_VUI_PARAMETERS: 112 bytes.
@(private)
NV_VUI :: struct {
	overscan_info_present_flag:      u32,
	overscan_info:                   u32,
	video_signal_type_present_flag:  u32,
	video_format:                    u32,
	video_full_range_flag:           u32,
	colour_description_present_flag: u32,
	colour_primaries:                u32,
	transfer_characteristics:        u32,
	colour_matrix:                   u32,
	chroma_sample_location_flag:     u32,
	chroma_sample_location_top:      u32,
	chroma_sample_location_bottom:   u32,
	bitstream_restriction_flag:      u32,
	timing_info_present_flag:        u32,
	num_unit_in_ticks:               u32,
	time_scale:                      u32,
	reserved:                        [12]u32,
}

// NV_ENC_CONFIG_H264: 1792 bytes, the largest member of the union NV_ENC_CODEC_CONFIG (HEVC 1560, AV1 1552, the
// motion-only ones 1536, reserved[320] 1280): the union is this structure.
@(private)
NV_Config_H264 :: struct {
	flags:                         u32,   // enableTemporalSVC ..= reservedBitFields
	level:                         u32,
	idr_period:                    u32,
	separate_colour_plane_flag:    u32,
	disable_deblocking_filter_idc: u32,
	num_temporal_layers:           u32,
	sps_id:                        u32,
	pps_id:                        u32,
	adaptive_transform_mode:       u32,
	fmo_mode:                      u32,
	bdirect_mode:                  u32,
	entropy_coding_mode:           u32,
	stereo_mode:                   u32,
	intra_refresh_period:          u32,
	intra_refresh_count:           u32,
	max_num_ref_frames:            u32,
	slice_mode:                    u32,
	slice_mode_data:               u32,
	vui:                           NV_VUI,
	ltr_num_frames:                u32,
	ltr_trust_mode:                u32,
	chroma_format_idc:             u32,
	max_temporal_layers:           u32,
	use_b_frames_as_ref:           u32,
	num_ref_l0:                    u32,
	num_ref_l1:                    u32,
	reserved1:                     [267]u32,
	reserved2:                     [64]rawptr,
}

// NV_ENC_CONFIG: 3584 bytes.
@(private)
NV_Config :: struct {
	version:          u32,
	profile_guid:     NV_Guid,
	gop_length:       u32,
	frame_interval_p: i32,
	monochrome:       u32,
	frame_field_mode: u32,
	mv_precision:     u32,
	rc:               NV_RC_Params,
	h264:             NV_Config_H264,   // encodeCodecConfig
	reserved:         [278]u32,
	reserved2:        [64]rawptr,
}

// NV_ENC_PRESET_CONFIG: 5128 bytes.
@(private)
NV_Preset_Config :: struct {
	version:   u32,
	config:    NV_Config,   // out (presetCfg)
	reserved1: [255]u32,
	reserved2: [64]rawptr,
}

// NVENC_EXTERNAL_ME_HINT_COUNTS_PER_BLOCKTYPE: 16 bytes.
@(private)
NV_ME_Hint_Counts :: struct {
	flags:     u32,
	reserved1: [3]u32,
}

// NV_ENC_INITIALIZE_PARAMS: 1808 bytes.
@(private)
NV_Initialize_Params :: struct {
	version:             u32,
	encode_guid:         NV_Guid,
	preset_guid:         NV_Guid,
	encode_width:        u32,
	encode_height:       u32,
	dar_width:           u32,
	dar_height:          u32,
	frame_rate_num:      u32,
	frame_rate_den:      u32,
	enable_encode_async: u32,
	enable_ptd:          u32,
	flags:               u32,   // reportSliceOffsets ..= reservedBitFields
	private_data_size:   u32,
	private_data:        rawptr,
	encode_config:       ^NV_Config,
	max_encode_width:    u32,
	max_encode_height:   u32,
	max_me_hint_counts:  [2]NV_ME_Hint_Counts,
	tuning_info:         u32,
	buffer_format:       u32,
	reserved:            [287]u32,
	reserved2:           [64]rawptr,
}

// NV_ENC_PIC_PARAMS: 3360 bytes.
@(private)
NV_Pic_Params :: struct {
	version:              u32,
	input_width:          u32,
	input_height:         u32,
	input_pitch:          u32,
	encode_pic_flags:     u32,
	frame_index:          u32,
	input_timestamp:      u64,
	input_duration:       u64,
	input_buffer:         rawptr,
	output_bitstream:     rawptr,
	completion_event:     rawptr,
	buffer_format:        u32,
	picture_struct:       u32,
	picture_type:         u32,
	// The union NV_ENC_CODEC_PIC_PARAMS, left zero: its largest member is the AV1 one, 1552 bytes, aligned to 8.
	codec_pic_params:     [1552 / 8]u64,
	me_hint_counts:       [2]NV_ME_Hint_Counts,
	me_external_hints:    rawptr,
	reserved1:            [6]u32,
	reserved2:            [2]rawptr,
	qp_delta_map:         rawptr,
	qp_delta_map_size:    u32,
	reserved_bit_fields:  u32,
	me_hint_ref_pic_dist: [2]u16,
	alpha_buffer:         rawptr,
	me_external_sb_hints: rawptr,
	me_sb_hints_count:    u32,
	reserved3:            [285]u32,
	reserved4:            [58]rawptr,
}

// NV_ENC_LOCK_BITSTREAM: 1544 bytes.
@(private)
NV_Lock_Bitstream :: struct {
	version:              u32,
	flags:                u32,   // doNotWait, ltrFrame, getRCStats, reservedBitFields
	output_bitstream:     rawptr,
	slice_offsets:        rawptr,
	frame_index:          u32,
	hw_encode_status:     u32,
	num_slices:           u32,
	bitstream_size:       u32,      // out
	output_timestamp:     u64,      // out: the input's inputTimeStamp
	output_duration:      u64,
	bitstream_buffer_ptr: rawptr,   // out
	picture_type:         u32,
	picture_struct:       u32,
	frame_avg_qp:         u32,
	frame_satd:           u32,
	ltr_frame_index:      u32,
	ltr_frame_bitmap:     u32,
	temporal_id:          u32,
	reserved:             [12]u32,
	intra_mb_count:       u32,
	inter_mb_count:       u32,
	average_mv_x:         i32,
	average_mv_y:         i32,
	alpha_layer_size:     u32,
	reserved1:            [218]u32,
	reserved2:            [64]rawptr,
}

// NV_ENC_LOCK_INPUT_BUFFER: 1544 bytes.
@(private)
NV_Lock_Input_Buffer :: struct {
	version:         u32,
	flags:           u32,      // doNotWait, reservedBitFields
	input_buffer:    rawptr,
	buffer_data_ptr: rawptr,   // out
	pitch:           u32,      // out
	reserved1:       [251]u32,
	reserved2:       [64]rawptr,
}

// NV_ENCODE_API_FUNCTION_LIST: 2552 bytes. The entries this package does not call stay untyped.
@(private)
NV_Function_List :: struct {
	version:                       u32,
	reserved:                      u32,
	open_encode_session:           rawptr,
	get_encode_guid_count:         proc "system" (encoder: rawptr, count: ^u32) -> NV_Status,
	get_encode_profile_guid_count: rawptr,
	get_encode_profile_guids:      rawptr,
	get_encode_guids:              proc "system" (encoder: rawptr, guids: [^]NV_Guid, size: u32, count: ^u32) -> NV_Status,
	get_input_format_count:        rawptr,
	get_input_formats:             rawptr,
	get_encode_caps:               rawptr,
	get_encode_preset_count:       rawptr,
	get_encode_preset_guids:       rawptr,
	get_encode_preset_config:      rawptr,
	initialize_encoder:            proc "system" (encoder: rawptr, params: ^NV_Initialize_Params) -> NV_Status,
	create_input_buffer:           proc "system" (encoder: rawptr, params: ^NV_Create_Input_Buffer) -> NV_Status,
	destroy_input_buffer:          proc "system" (encoder: rawptr, buffer: rawptr) -> NV_Status,
	create_bitstream_buffer:       proc "system" (encoder: rawptr, params: ^NV_Create_Bitstream_Buffer) -> NV_Status,
	destroy_bitstream_buffer:      proc "system" (encoder: rawptr, buffer: rawptr) -> NV_Status,
	encode_picture:                proc "system" (encoder: rawptr, params: ^NV_Pic_Params) -> NV_Status,
	lock_bitstream:                proc "system" (encoder: rawptr, params: ^NV_Lock_Bitstream) -> NV_Status,
	unlock_bitstream:              proc "system" (encoder: rawptr, buffer: rawptr) -> NV_Status,
	lock_input_buffer:             proc "system" (encoder: rawptr, params: ^NV_Lock_Input_Buffer) -> NV_Status,
	unlock_input_buffer:           proc "system" (encoder: rawptr, buffer: rawptr) -> NV_Status,
	get_encode_stats:              rawptr,
	get_sequence_params:           rawptr,
	register_async_event:          rawptr,
	unregister_async_event:        rawptr,
	map_input_resource:            rawptr,
	unmap_input_resource:          rawptr,
	destroy_encoder:               proc "system" (encoder: rawptr) -> NV_Status,
	invalidate_ref_frames:         rawptr,
	open_encode_session_ex:        proc "system" (params: ^NV_Open_Session_Params, encoder: ^rawptr) -> NV_Status,
	register_resource:             rawptr,
	unregister_resource:           rawptr,
	reconfigure_encoder:           rawptr,
	reserved1:                     rawptr,
	create_mv_buffer:              rawptr,
	destroy_mv_buffer:             rawptr,
	run_motion_estimation_only:    rawptr,
	get_last_error_string:         rawptr,
	set_io_cuda_streams:           rawptr,
	get_encode_preset_config_ex:   proc "system" (encoder: rawptr, encode_guid: NV_Guid, preset_guid: NV_Guid, tuning_info: u32, config: ^NV_Preset_Config) -> NV_Status,
	get_sequence_param_ex:         rawptr,
	reserved2:                     [277]rawptr,
}

#assert(size_of(NV_Guid) == 16)
#assert(size_of(NV_Open_Session_Params) == 1552)
#assert(size_of(NV_Create_Input_Buffer) == 776)
#assert(size_of(NV_Create_Bitstream_Buffer) == 776)
#assert(size_of(NV_RC_Params) == 128)
#assert(size_of(NV_VUI) == 112)
#assert(size_of(NV_Config_H264) == 1792)
#assert(size_of(NV_Config) == 3584)
#assert(offset_of(NV_Config, h264) == 168)
#assert(size_of(NV_Preset_Config) == 5128)
#assert(size_of(NV_Initialize_Params) == 1808)
#assert(offset_of(NV_Initialize_Params, encode_config) == 88)
#assert(size_of(NV_Pic_Params) == 3360)
#assert(offset_of(NV_Pic_Params, codec_pic_params) == 80)
#assert(size_of(NV_Lock_Bitstream) == 1544)
#assert(offset_of(NV_Lock_Bitstream, bitstream_buffer_ptr) == 56)
#assert(size_of(NV_Lock_Input_Buffer) == 1544)
#assert(size_of(NV_Function_List) == 2552)
#assert(offset_of(NV_Function_List, get_encode_preset_config_ex) == 8 + 39 * 8)

@(private) CUDA_SUCCESS :: 0

// The CUDA driver calls (cuda.h's _v2 entry points: the names the driver library exports for 64-bit contexts).
@(private)
CUDA_Library :: struct {
	init:             proc "system" (flags: u32) -> i32,
	device_get_count: proc "system" (count: ^i32) -> i32,
	device_get:       proc "system" (device: ^i32, ordinal: i32) -> i32,
	ctx_create:       proc "system" (ctx: ^rawptr, flags: u32, device: i32) -> i32,
	ctx_destroy:      proc "system" (ctx: rawptr) -> i32,
	ctx_push_current: proc "system" (ctx: rawptr) -> i32,
	ctx_pop_current:  proc "system" (ctx: ^rawptr) -> i32,
}

// The two exports of NVENC's library: the rest comes through the function list.
@(private)
NV_Entry :: struct {
	get_max_supported_version: proc "system" (version: ^u32) -> NV_Status,
	create_instance:           proc "system" (functions: ^NV_Function_List) -> NV_Status,
}

@(private) cuda: CUDA_Library
@(private) nvenc_api: NV_Function_List
@(private = "file") nvenc_once: sync.Once
@(private = "file") nvenc_found: bool

// The driver's libraries (nvenc_load_<system>.odin), once for the process: false without NVIDIA's driver, with one
// older than API 12.0, or without a CUDA driver that initialises.
@(private)
nvenc_load :: proc() -> bool {
	sync.once_do(&nvenc_once, proc() {
		entry: NV_Entry
		if !nvenc_libraries_open(&cuda, &entry) { return }
		// (an older driver rejects every structure of 12.0)
		highest: u32
		if entry.get_max_supported_version(&highest) != NV_ENC_SUCCESS || highest < NVENC_NEEDED_VERSION { return }
		nvenc_api.version = NV_ENCODE_API_FUNCTION_LIST_VER
		if entry.create_instance(&nvenc_api) != NV_ENC_SUCCESS { return }
		a := &nvenc_api
		if a.get_encode_guid_count == nil || a.get_encode_guids == nil || a.initialize_encoder == nil ||
		   a.create_input_buffer == nil || a.destroy_input_buffer == nil || a.create_bitstream_buffer == nil ||
		   a.destroy_bitstream_buffer == nil || a.encode_picture == nil || a.lock_bitstream == nil ||
		   a.unlock_bitstream == nil || a.lock_input_buffer == nil || a.unlock_input_buffer == nil ||
		   a.destroy_encoder == nil || a.open_encode_session_ex == nil || a.get_encode_preset_config_ex == nil {
			return
		}
		if cuda.init(0) != CUDA_SUCCESS { return }
		nvenc_found = true
	})
	return nvenc_found
}
