#+build linux
package tk_h264

// libva's types and calls, as va.h, va_enc_h264.h and va_vpp.h (libva 2.x) declare them: the fields in order, with
// their C types; a union of bit fields is its u32 (bits packed from the lowest, as GCC and Clang lay them out on x86 and
// ARM). Loaded by dlopen (libva.so.2, libva-drm.so.2) in vaapi_linux.odin.

import "core:sync"
import "core:sys/posix"

@(private) VA_Display :: distinct rawptr
@(private) VA_Status :: i32
@(private) VA_ID :: u32

@(private) VA_STATUS_SUCCESS :: 0
@(private) VA_INVALID_ID :: 0xffffffff
@(private) VA_PROGRESSIVE :: 1

@(private) VA_PROFILE_NONE :: -1
@(private) VA_PROFILE_H264_MAIN :: 6
@(private) VA_PROFILE_H264_HIGH :: 7
@(private) VA_PROFILE_H264_CONSTRAINED_BASELINE :: 13

@(private) VA_ENTRYPOINT_ENC_SLICE :: 6
@(private) VA_ENTRYPOINT_ENC_SLICE_LP :: 8
@(private) VA_ENTRYPOINT_VIDEO_PROC :: 10

@(private) VA_CONFIG_ATTRIB_RT_FORMAT :: 0
@(private) VA_CONFIG_ATTRIB_RATE_CONTROL :: 5
@(private) VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS :: 10
@(private) VA_ATTRIB_NOT_SUPPORTED :: 0x80000000

@(private) VA_RT_FORMAT_YUV420 :: 0x00000001
@(private) VA_RT_FORMAT_RGB32 :: 0x00020000

@(private) VA_RC_CBR :: 0x02
@(private) VA_RC_VBR :: 0x04
@(private) VA_RC_CQP :: 0x10

@(private) VA_ENC_PACKED_HEADER_SEQUENCE :: 0x1
@(private) VA_ENC_PACKED_HEADER_PICTURE :: 0x2
@(private) VA_ENC_PACKED_HEADER_SLICE :: 0x4

@(private) VA_PICTURE_PARAMETER_BUFFER :: 0
@(private) VA_ENC_CODED_BUFFER :: 21
@(private) VA_ENC_SEQUENCE_PARAMETER_BUFFER :: 22
@(private) VA_ENC_PICTURE_PARAMETER_BUFFER :: 23
@(private) VA_ENC_SLICE_PARAMETER_BUFFER :: 24
@(private) VA_ENC_PACKED_HEADER_PARAMETER_BUFFER :: 25
@(private) VA_ENC_PACKED_HEADER_DATA_BUFFER :: 26
@(private) VA_ENC_MISC_PARAMETER_BUFFER :: 27
@(private) VA_PROC_PIPELINE_PARAMETER_BUFFER :: 41

@(private) VA_ENC_MISC_FRAME_RATE :: 0
@(private) VA_ENC_MISC_RATE_CONTROL :: 1
@(private) VA_ENC_MISC_HRD :: 5

@(private) VA_ENC_PACKED_HEADER_TYPE_SEQUENCE :: 1
@(private) VA_ENC_PACKED_HEADER_TYPE_PICTURE :: 2
@(private) VA_ENC_PACKED_HEADER_TYPE_SLICE :: 3

@(private) VA_PICTURE_H264_INVALID :: 0x01
@(private) VA_PICTURE_H264_SHORT_TERM_REFERENCE :: 0x08

@(private) VA_FOURCC_NV12 :: 0x3231564E
@(private) VA_FOURCC_RGBA :: 0x41424752
@(private) VA_FOURCC_RGBX :: 0x58424752
@(private) VA_FOURCC_BGRA :: 0x41524742
@(private) VA_FOURCC_BGRX :: 0x58524742

@(private) VA_SURFACE_ATTRIB_PIXEL_FORMAT :: 1
@(private) VA_SURFACE_ATTRIB_SETTABLE :: 0x2
@(private) VA_GENERIC_VALUE_INTEGER :: 1

@(private) VA_PROC_COLOR_STANDARD_BT709 :: 2
@(private) VA_PROC_COLOR_STANDARD_SRGB :: 8
@(private) VA_SOURCE_RANGE_REDUCED :: 1
@(private) VA_SOURCE_RANGE_FULL :: 2

@(private)
VA_Config_Attrib :: struct {
	type:  i32,
	value: u32,
}

@(private)
VA_Generic_Value :: struct {
	type:  i32,
	value: struct #raw_union { i: i32, f: f32, p: rawptr },
}

@(private)
VA_Surface_Attrib :: struct {
	type:  i32,
	flags: u32,
	value: VA_Generic_Value,
}

@(private)
VA_Image_Format :: struct {
	fourcc:         u32,
	byte_order:     u32,
	bits_per_pixel: u32,
	depth:          u32,
	red_mask:       u32,
	green_mask:     u32,
	blue_mask:      u32,
	alpha_mask:     u32,
	va_reserved:    [4]u32,
}

@(private)
VA_Image :: struct {
	image_id:            VA_ID,
	format:              VA_Image_Format,
	buf:                 VA_ID,
	width, height:       u16,
	data_size:           u32,
	num_planes:          u32,
	pitches:             [3]u32,
	offsets:             [3]u32,
	num_palette_entries: i32,
	entry_bytes:         i32,
	component_order:     [4]i8,
	va_reserved:         [4]u32,
}

@(private)
VA_Coded_Buffer_Segment :: struct {
	size:        u32,
	bit_offset:  u32,
	status:      u32,
	reserved:    u32,
	buf:         [^]u8,
	next:        ^VA_Coded_Buffer_Segment,
	va_reserved: [4]u32,
}

@(private)
VA_Picture_H264 :: struct {
	picture_id:            VA_ID,
	frame_idx:             u32,
	flags:                 u32,
	top_field_order_cnt:   i32,
	bottom_field_order_cnt: i32,
	va_reserved:           [4]u32,
}

@(private)
VA_Enc_Sequence_Parameter_Buffer_H264 :: struct {
	seq_parameter_set_id:                  u8,
	level_idc:                             u8,
	intra_period:                          u32,
	intra_idr_period:                      u32,
	ip_period:                             u32,
	bits_per_second:                       u32,
	max_num_ref_frames:                    u32,
	picture_width_in_mbs:                  u16,
	picture_height_in_mbs:                 u16,
	seq_fields:                            u32,
	bit_depth_luma_minus8:                 u8,
	bit_depth_chroma_minus8:               u8,
	num_ref_frames_in_pic_order_cnt_cycle: u8,
	offset_for_non_ref_pic:                i32,
	offset_for_top_to_bottom_field:        i32,
	offset_for_ref_frame:                  [256]i32,
	frame_cropping_flag:                   u8,
	frame_crop_left_offset:                u32,
	frame_crop_right_offset:               u32,
	frame_crop_top_offset:                 u32,
	frame_crop_bottom_offset:              u32,
	vui_parameters_present_flag:           u8,
	vui_fields:                            u32,
	aspect_ratio_idc:                      u8,
	sar_width:                             u32,
	sar_height:                            u32,
	num_units_in_tick:                     u32,
	time_scale:                            u32,
	va_reserved:                           [4]u32,
}

@(private)
VA_Enc_Picture_Parameter_Buffer_H264 :: struct {
	curr_pic:                      VA_Picture_H264,
	reference_frames:              [16]VA_Picture_H264,
	coded_buf:                     VA_ID,
	pic_parameter_set_id:          u8,
	seq_parameter_set_id:          u8,
	last_picture:                  u8,
	frame_num:                     u16,
	pic_init_qp:                   u8,
	num_ref_idx_l0_active_minus1:  u8,
	num_ref_idx_l1_active_minus1:  u8,
	chroma_qp_index_offset:        i8,
	second_chroma_qp_index_offset: i8,
	pic_fields:                    u32,
	va_reserved:                   [4]u32,
}

@(private)
VA_Enc_Slice_Parameter_Buffer_H264 :: struct {
	macroblock_address:               u32,
	num_macroblocks:                  u32,
	macroblock_info:                  VA_ID,
	slice_type:                       u8,
	pic_parameter_set_id:             u8,
	idr_pic_id:                       u16,
	pic_order_cnt_lsb:                u16,
	delta_pic_order_cnt_bottom:       i32,
	delta_pic_order_cnt:              [2]i32,
	direct_spatial_mv_pred_flag:      u8,
	num_ref_idx_active_override_flag: u8,
	num_ref_idx_l0_active_minus1:     u8,
	num_ref_idx_l1_active_minus1:     u8,
	ref_pic_list0:                    [32]VA_Picture_H264,
	ref_pic_list1:                    [32]VA_Picture_H264,
	luma_log2_weight_denom:           u8,
	chroma_log2_weight_denom:         u8,
	luma_weight_l0_flag:              u8,
	luma_weight_l0:                   [32]i16,
	luma_offset_l0:                   [32]i16,
	chroma_weight_l0_flag:            u8,
	chroma_weight_l0:                 [32][2]i16,
	chroma_offset_l0:                 [32][2]i16,
	luma_weight_l1_flag:              u8,
	luma_weight_l1:                   [32]i16,
	luma_offset_l1:                   [32]i16,
	chroma_weight_l1_flag:            u8,
	chroma_weight_l1:                 [32][2]i16,
	chroma_offset_l1:                 [32][2]i16,
	cabac_init_idc:                   u8,
	slice_qp_delta:                   i8,
	disable_deblocking_filter_idc:    u8,
	slice_alpha_c0_offset_div2:       i8,
	slice_beta_offset_div2:           i8,
	va_reserved:                      [4]u32,
}

@(private)
VA_Enc_Packed_Header_Parameter_Buffer :: struct {
	type:                u32,
	bit_length:          u32,
	has_emulation_bytes: u8,
	va_reserved:         [4]u32,
}

@(private)
VA_Enc_Misc_Parameter_Rate_Control :: struct {
	bits_per_second:    u32,
	target_percentage:  u32,
	window_size:        u32,
	initial_qp:         u32,
	min_qp:             u32,
	basic_unit_size:    u32,
	rc_flags:           u32,
	icq_quality_factor: u32,
	max_qp:             u32,
	quality_factor:     u32,
	target_frame_size:  u32,
	va_reserved:        [4]u32,
}

@(private)
VA_Enc_Misc_Parameter_Frame_Rate :: struct {
	framerate:       u32,
	framerate_flags: u32,
	va_reserved:     [4]u32,
}

@(private)
VA_Enc_Misc_Parameter_HRD :: struct {
	initial_buffer_fullness: u32,
	buffer_size:             u32,
	va_reserved:             [4]u32,
}

@(private)
VA_Rectangle :: struct {
	x, y:          i16,
	width, height: u16,
}

@(private)
VA_Proc_Color_Properties :: struct {
	chroma_sample_location:   u8,
	color_range:              u8,
	colour_primaries:         u8,
	transfer_characteristics: u8,
	matrix_coefficients:      u8,
	reserved:                 [3]u8,
}

@(private) VPP_RESERVED :: 16 when size_of(rawptr) == 8 else 19

@(private)
VA_Proc_Pipeline_Parameter_Buffer :: struct {
	surface:                 VA_ID,
	surface_region:          ^VA_Rectangle,
	surface_color_standard:  i32,
	output_region:           ^VA_Rectangle,
	output_background_color: u32,
	output_color_standard:   i32,
	pipeline_flags:          u32,
	filter_flags:            u32,
	filters:                 ^VA_ID,
	num_filters:             u32,
	forward_references:      ^VA_ID,
	num_forward_references:  u32,
	backward_references:     ^VA_ID,
	num_backward_references: u32,
	rotation_state:          u32,
	blend_state:             rawptr,
	mirror_state:            u32,
	additional_outputs:      ^VA_ID,
	num_additional_outputs:  u32,
	input_surface_flag:      u32,
	output_surface_flag:     u32,
	input_color_properties:  VA_Proc_Color_Properties,
	output_color_properties: VA_Proc_Color_Properties,
	processing_mode:         i32,
	output_hdr_metadata:     rawptr,
	va_reserved:             [VPP_RESERVED]u32,
}

when size_of(rawptr) == 8 {
	#assert(size_of(VA_Image) == 120)
	#assert(size_of(VA_Coded_Buffer_Segment) == 48)
	#assert(size_of(VA_Proc_Pipeline_Parameter_Buffer) == 224)
	#assert(size_of(VA_Surface_Attrib) == 24)
}

// The calls this package makes; nil until loaded.
@(private)
VA_Library :: struct {
	get_display_drm:       proc "c" (fd: i32) -> VA_Display,
	initialize:            proc "c" (dpy: VA_Display, major, minor: ^i32) -> VA_Status,
	terminate:             proc "c" (dpy: VA_Display) -> VA_Status,
	set_info_callback:     proc "c" (dpy: VA_Display, callback: rawptr, user: rawptr) -> rawptr,
	max_num_profiles:      proc "c" (dpy: VA_Display) -> i32,
	max_num_entrypoints:   proc "c" (dpy: VA_Display) -> i32,
	query_config_profiles: proc "c" (dpy: VA_Display, profiles: [^]i32, count: ^i32) -> VA_Status,
	query_config_entrypoints: proc "c" (dpy: VA_Display, profile: i32, entrypoints: [^]i32, count: ^i32) -> VA_Status,
	get_config_attributes: proc "c" (dpy: VA_Display, profile, entrypoint: i32, attribs: [^]VA_Config_Attrib, count: i32) -> VA_Status,
	create_config:         proc "c" (dpy: VA_Display, profile, entrypoint: i32, attribs: [^]VA_Config_Attrib, count: i32, config: ^VA_ID) -> VA_Status,
	destroy_config:        proc "c" (dpy: VA_Display, config: VA_ID) -> VA_Status,
	create_surfaces:       proc "c" (dpy: VA_Display, format: u32, width, height: u32, surfaces: [^]VA_ID, count: u32, attribs: [^]VA_Surface_Attrib, attrib_count: u32) -> VA_Status,
	destroy_surfaces:      proc "c" (dpy: VA_Display, surfaces: [^]VA_ID, count: i32) -> VA_Status,
	create_context:        proc "c" (dpy: VA_Display, config: VA_ID, width, height: i32, flag: i32, targets: [^]VA_ID, count: i32, ctx: ^VA_ID) -> VA_Status,
	destroy_context:       proc "c" (dpy: VA_Display, ctx: VA_ID) -> VA_Status,
	create_buffer:         proc "c" (dpy: VA_Display, ctx: VA_ID, type: i32, size: u32, count: u32, data: rawptr, buffer: ^VA_ID) -> VA_Status,
	destroy_buffer:        proc "c" (dpy: VA_Display, buffer: VA_ID) -> VA_Status,
	map_buffer:            proc "c" (dpy: VA_Display, buffer: VA_ID, data: ^rawptr) -> VA_Status,
	unmap_buffer:          proc "c" (dpy: VA_Display, buffer: VA_ID) -> VA_Status,
	begin_picture:         proc "c" (dpy: VA_Display, ctx: VA_ID, target: VA_ID) -> VA_Status,
	render_picture:        proc "c" (dpy: VA_Display, ctx: VA_ID, buffers: [^]VA_ID, count: i32) -> VA_Status,
	end_picture:           proc "c" (dpy: VA_Display, ctx: VA_ID) -> VA_Status,
	sync_surface:          proc "c" (dpy: VA_Display, surface: VA_ID) -> VA_Status,
	max_num_image_formats: proc "c" (dpy: VA_Display) -> i32,
	query_image_formats:   proc "c" (dpy: VA_Display, formats: [^]VA_Image_Format, count: ^i32) -> VA_Status,
	create_image:          proc "c" (dpy: VA_Display, format: ^VA_Image_Format, width, height: i32, image: ^VA_Image) -> VA_Status,
	derive_image:          proc "c" (dpy: VA_Display, surface: VA_ID, image: ^VA_Image) -> VA_Status,
	destroy_image:         proc "c" (dpy: VA_Display, image: VA_ID) -> VA_Status,
	put_image:             proc "c" (dpy: VA_Display, surface: VA_ID, image: VA_ID, src_x, src_y: i32, src_width, src_height: u32, dest_x, dest_y: i32, dest_width, dest_height: u32) -> VA_Status,
}

@(private) va: VA_Library
@(private = "file") va_once: sync.Once
@(private = "file") va_found: bool

// Both libraries, once for the process; false when either is missing (no VA-API here).
@(private)
va_load :: proc() -> bool {
	sync.once_do(&va_once, proc() {
		core := posix.dlopen("libva.so.2", posix.RTLD_LOCAL + {.NOW})
		if core == nil { return }
		drm := posix.dlopen("libva-drm.so.2", posix.RTLD_LOCAL + {.NOW})
		if drm == nil { posix.dlclose(core); return }
		l := &va
		l.get_display_drm = auto_cast posix.dlsym(drm, "vaGetDisplayDRM")
		l.initialize = auto_cast posix.dlsym(core, "vaInitialize")
		l.terminate = auto_cast posix.dlsym(core, "vaTerminate")
		l.set_info_callback = auto_cast posix.dlsym(core, "vaSetInfoCallback")   // (may be absent: only quieter)
		l.max_num_profiles = auto_cast posix.dlsym(core, "vaMaxNumProfiles")
		l.max_num_entrypoints = auto_cast posix.dlsym(core, "vaMaxNumEntrypoints")
		l.query_config_profiles = auto_cast posix.dlsym(core, "vaQueryConfigProfiles")
		l.query_config_entrypoints = auto_cast posix.dlsym(core, "vaQueryConfigEntrypoints")
		l.get_config_attributes = auto_cast posix.dlsym(core, "vaGetConfigAttributes")
		l.create_config = auto_cast posix.dlsym(core, "vaCreateConfig")
		l.destroy_config = auto_cast posix.dlsym(core, "vaDestroyConfig")
		l.create_surfaces = auto_cast posix.dlsym(core, "vaCreateSurfaces")
		l.destroy_surfaces = auto_cast posix.dlsym(core, "vaDestroySurfaces")
		l.create_context = auto_cast posix.dlsym(core, "vaCreateContext")
		l.destroy_context = auto_cast posix.dlsym(core, "vaDestroyContext")
		l.create_buffer = auto_cast posix.dlsym(core, "vaCreateBuffer")
		l.destroy_buffer = auto_cast posix.dlsym(core, "vaDestroyBuffer")
		l.map_buffer = auto_cast posix.dlsym(core, "vaMapBuffer")
		l.unmap_buffer = auto_cast posix.dlsym(core, "vaUnmapBuffer")
		l.begin_picture = auto_cast posix.dlsym(core, "vaBeginPicture")
		l.render_picture = auto_cast posix.dlsym(core, "vaRenderPicture")
		l.end_picture = auto_cast posix.dlsym(core, "vaEndPicture")
		l.sync_surface = auto_cast posix.dlsym(core, "vaSyncSurface")
		l.max_num_image_formats = auto_cast posix.dlsym(core, "vaMaxNumImageFormats")
		l.query_image_formats = auto_cast posix.dlsym(core, "vaQueryImageFormats")
		l.create_image = auto_cast posix.dlsym(core, "vaCreateImage")
		l.derive_image = auto_cast posix.dlsym(core, "vaDeriveImage")
		l.destroy_image = auto_cast posix.dlsym(core, "vaDestroyImage")
		l.put_image = auto_cast posix.dlsym(core, "vaPutImage")
		if l.get_display_drm == nil || l.initialize == nil || l.terminate == nil || l.max_num_profiles == nil ||
		   l.max_num_entrypoints == nil || l.query_config_profiles == nil || l.query_config_entrypoints == nil ||
		   l.get_config_attributes == nil || l.create_config == nil || l.destroy_config == nil || l.create_surfaces == nil ||
		   l.destroy_surfaces == nil || l.create_context == nil || l.destroy_context == nil || l.create_buffer == nil ||
		   l.destroy_buffer == nil || l.map_buffer == nil || l.unmap_buffer == nil || l.begin_picture == nil ||
		   l.render_picture == nil || l.end_picture == nil || l.sync_surface == nil || l.max_num_image_formats == nil ||
		   l.query_image_formats == nil || l.create_image == nil || l.derive_image == nil || l.destroy_image == nil ||
		   l.put_image == nil {
			va = {}
			posix.dlclose(drm)
			posix.dlclose(core)
			return
		}
		va_found = true
	})
	return va_found
}
