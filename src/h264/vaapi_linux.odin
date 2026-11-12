#+build linux
package tk_h264

// VA-API: the GPU's H.264 encoder through libva, on the first render node (/dev/dri/renderD128...) whose driver encodes
// H.264 (intel-media-driver or i965 for Intel, Mesa's radeonsi for AMD, nouveau). Modelled on libva-utils' h264encode.c
// and on ffmpeg's and GStreamer's vaapi H.264 encoders, in their simplest shape: one slice a picture, I and P pictures
// only (no reordering: a packet comes out for each frame), each picture the reference of the next.
//
// The frame becomes NV12 on the GPU when the driver has video processing (an RGB surface, then VAProcPipeline, BT.709
// limited range), else on the CPU (to_nv12) into the surface. When the driver takes packed headers, the SPS, the PPS and
// the slice headers are this package's own (bits.odin): the colours and timing the VUI says, the cropping of odd sizes.

import "core:fmt"
import "core:mem"
import "core:sys/posix"
import "core:time"

@(private = "file") RENDER_NODES :: 8   // renderD128 ..< renderD136

@(private = "file")
Device :: struct {
	fd:         posix.FD,
	display:    VA_Display,
	profile:    i32,
	entrypoint: i32,
}

// The profiles taken, the best first, with what the SPS says for each.
@(private = "file", rodata)
PROFILES := [?][2]i32{
	{VA_PROFILE_H264_HIGH, PROFILE_HIGH},
	{VA_PROFILE_H264_MAIN, PROFILE_MAIN},
	{VA_PROFILE_H264_CONSTRAINED_BASELINE, PROFILE_CONSTRAINED_BASELINE},
}

// The first render node whose driver encodes H.264, initialised.
@(private = "file")
device_open :: proc() -> (d: Device, ok: bool) {
	if !va_load() { return }
	for i in 0 ..< RENDER_NODES {
		fd := posix.open(fmt.ctprintf("/dev/dri/renderD%d", 128 + i), {.RDWR, .CLOEXEC})
		if fd < 0 { continue }
		dpy := va.get_display_drm(i32(fd))
		if dpy == nil { posix.close(fd); continue }
		// (libva prints its version and driver on stderr at each initialisation: a probe is not news)
		if va.set_info_callback != nil { va.set_info_callback(dpy, nil, nil) }
		major, minor: i32
		if va.initialize(dpy, &major, &minor) == VA_STATUS_SUCCESS {
			if profile, entrypoint, found := find_encoder(dpy); found {
				return Device{fd = fd, display = dpy, profile = profile, entrypoint = entrypoint}, true
			}
		}
		va.terminate(dpy)
		posix.close(fd)
	}
	return
}

@(private = "file")
device_close :: proc(d: ^Device) {
	va.terminate(d.display)
	posix.close(d.fd)
}

// The best H.264 profile the driver encodes, and its entry point (the full one, else the low-power one).
@(private = "file")
find_encoder :: proc(dpy: VA_Display) -> (profile, entrypoint: i32, ok: bool) {
	profiles := make([]i32, max(va.max_num_profiles(dpy), 1), context.temp_allocator)
	profile_count: i32
	if va.query_config_profiles(dpy, raw_data(profiles), &profile_count) != VA_STATUS_SUCCESS { return }
	entrypoints := make([]i32, max(va.max_num_entrypoints(dpy), 1), context.temp_allocator)
	for wanted in PROFILES {
		listed := false
		for p in profiles[:profile_count] { if p == wanted[0] { listed = true } }
		if !listed { continue }
		count: i32
		if va.query_config_entrypoints(dpy, wanted[0], raw_data(entrypoints), &count) != VA_STATUS_SUCCESS { continue }
		low_power := false
		for ep in entrypoints[:count] {
			if ep == VA_ENTRYPOINT_ENC_SLICE { return wanted[0], ep, true }
			if ep == VA_ENTRYPOINT_ENC_SLICE_LP { low_power = true }
		}
		if low_power { return wanted[0], VA_ENTRYPOINT_ENC_SLICE_LP, true }
	}
	return
}

@(private = "file")
profile_idc_of :: proc(va_profile: i32) -> u8 {
	for p in PROFILES { if p[0] == va_profile { return u8(p[1]) } }
	return PROFILE_CONSTRAINED_BASELINE
}

@(private)
vaapi_probe :: proc() -> bool {
	d, ok := device_open()
	if ok { device_close(&d) }
	return ok
}

// How the frame reaches the NV12 surface.
@(private = "file")
Upload :: enum u8 {
	Untried,   // video processing not tried yet (it needs the first frame's channel order)
	Gpu,       // an RGB surface, then VAProcPipeline
	Cpu,       // to_nv12 into the surface (derived), or into an image put on it
}

@(private)
Vaapi_Encoder :: struct {
	device:         Device,
	config:         VA_ID,
	ctx:            VA_ID,
	input:          VA_ID,      // the NV12 surface encoded (one: each frame is done before encode returns)
	recon:          [2]VA_ID,   // the reconstructed pictures: this one and its reference, in turn
	current:        int,        // which of recon this picture is
	coded:          VA_ID,
	rate_control:   u32,        // VA_RC_*
	bitrate:        int,        // what the rate control aims at (0 with CQP)
	packed:         u32,        // the packed headers the driver takes (VA_ENC_PACKED_HEADER_*)
	sequence:       Sequence,
	headers:        [dynamic]u8,   // the SPS and the PPS as NAL units: put before a keyframe that came without them
	frame_in_gop:   int,        // frames since the last IDR picture
	idr_count:      int,
	access:         [dynamic]u8,
	bits:           Bit_Writer,    // one packed header at a time, its memory kept from frame to frame
	upload:         Upload,
	derive_failed:  bool,       // the driver cannot map the NV12 surface: the image below is put on it
	nv12_image:     VA_Image,   // (image_id VA_INVALID_ID until made)
	vpp_config:     VA_ID,
	vpp_ctx:        VA_ID,
	rgb_surface:    VA_ID,
	rgb_fourcc:     u32,
	rgb_format:     Pixel_Format,
}

@(private)
vaapi_open :: proc(e: ^Encoder) -> (^Vaapi_Encoder, bool) {
	device, found := device_open()
	if !found { return nil, false }
	v := new(Vaapi_Encoder, e.allocator)
	v.device = device
	v.config, v.ctx, v.input, v.coded = VA_INVALID_ID, VA_INVALID_ID, VA_INVALID_ID, VA_INVALID_ID
	v.recon = {VA_INVALID_ID, VA_INVALID_ID}
	v.nv12_image.image_id = VA_INVALID_ID
	v.vpp_config, v.vpp_ctx, v.rgb_surface = VA_INVALID_ID, VA_INVALID_ID, VA_INVALID_ID
	v.headers = make([dynamic]u8, e.allocator)
	v.access = make([dynamic]u8, e.allocator)
	v.bits = bit_writer_make(e.allocator)
	if !vaapi_setup(e, v) {
		vaapi_close(e, v)
		return nil, false
	}
	return v, true
}

@(private = "file")
vaapi_setup :: proc(e: ^Encoder, v: ^Vaapi_Encoder) -> bool {
	dpy := v.device.display
	attribs := [3]VA_Config_Attrib{
		{type = VA_CONFIG_ATTRIB_RT_FORMAT},
		{type = VA_CONFIG_ATTRIB_RATE_CONTROL},
		{type = VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS},
	}
	if va.get_config_attributes(dpy, v.device.profile, v.device.entrypoint, &attribs[0], 3) != VA_STATUS_SUCCESS { return false }
	if attribs[0].value == VA_ATTRIB_NOT_SUPPORTED || attribs[0].value & VA_RT_FORMAT_YUV420 == 0 { return false }
	rc := attribs[1].value == VA_ATTRIB_NOT_SUPPORTED ? 0 : attribs[1].value
	w, h := e.stream_width, e.stream_height

	// The rate control: the bitrate asked with the most freedom the driver offers; a quantiser with CQP, else a rate
	// that suits it (about 0.1 bit a pixel at the frame rate).
	if e.options.bitrate > 0 {
		switch {
		case rc & VA_RC_VBR != 0: v.rate_control, v.bitrate = VA_RC_VBR, e.options.bitrate
		case rc & VA_RC_CBR != 0: v.rate_control, v.bitrate = VA_RC_CBR, e.options.bitrate
		case rc & VA_RC_CQP != 0: v.rate_control = VA_RC_CQP
		case: return false
		}
	} else {
		guess := max(w * h * e.fps / 10, 100_000)
		switch {
		case rc & VA_RC_CQP != 0: v.rate_control = VA_RC_CQP
		case rc & VA_RC_VBR != 0: v.rate_control, v.bitrate = VA_RC_VBR, guess
		case rc & VA_RC_CBR != 0: v.rate_control, v.bitrate = VA_RC_CBR, guess
		case: return false
		}
	}
	config_attribs: [3]VA_Config_Attrib
	config_attribs[0] = {type = VA_CONFIG_ATTRIB_RT_FORMAT, value = VA_RT_FORMAT_YUV420}
	config_attribs[1] = {type = VA_CONFIG_ATTRIB_RATE_CONTROL, value = v.rate_control}
	attrib_count: i32 = 2
	if attribs[2].value != VA_ATTRIB_NOT_SUPPORTED {
		v.packed = attribs[2].value & (VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | VA_ENC_PACKED_HEADER_SLICE)
		if v.packed != 0 {
			config_attribs[2] = {type = VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS, value = v.packed}
			attrib_count = 3
		}
	}
	if va.create_config(dpy, v.device.profile, v.device.entrypoint, &config_attribs[0], attrib_count, &v.config) != VA_STATUS_SUCCESS {
		v.config = VA_INVALID_ID
		return false
	}
	surfaces: [3]VA_ID
	if va.create_surfaces(dpy, VA_RT_FORMAT_YUV420, u32(w), u32(h), &surfaces[0], 3, nil, 0) != VA_STATUS_SUCCESS { return false }
	v.input, v.recon[0], v.recon[1] = surfaces[0], surfaces[1], surfaces[2]
	if va.create_context(dpy, v.config, i32(w), i32(h), VA_PROGRESSIVE, &surfaces[0], 3, &v.ctx) != VA_STATUS_SUCCESS {
		v.ctx = VA_INVALID_ID
		return false
	}
	// (an I picture at a low quantiser can pass the raw size; three times it is never reached)
	coded_size := u32(max(w * h * 3, 1 << 20))
	if va.create_buffer(dpy, v.ctx, VA_ENC_CODED_BUFFER, coded_size, 1, nil, &v.coded) != VA_STATUS_SUCCESS {
		v.coded = VA_INVALID_ID
		return false
	}

	qp := v.rate_control == VA_RC_CQP ? e.options.qp : 26
	v.sequence = Sequence{
		profile_idc        = profile_idc_of(v.device.profile),
		level_idc          = level_for(w, h, e.fps, v.bitrate),
		width              = w,
		height             = h,
		log2_max_frame_num = log2_max_frame_num_for(e.keyframe_frames),
		max_ref_frames     = 1,
		fps                = e.fps,
		qp                 = qp,
	}
	sps := bit_writer_make(context.temp_allocator)
	write_sps(&sps, v.sequence)
	append_nal(&v.headers, 3, NAL_SPS, bit_writer_bytes(&sps))
	pps := bit_writer_make(context.temp_allocator)
	write_pps(&pps, v.sequence)
	append_nal(&v.headers, 3, NAL_PPS, bit_writer_bytes(&pps))
	return true
}

@(private)
vaapi_close :: proc(e: ^Encoder, v: ^Vaapi_Encoder) {
	dpy := v.device.display
	vpp_release(v)
	if v.nv12_image.image_id != VA_INVALID_ID { va.destroy_image(dpy, v.nv12_image.image_id) }
	if v.coded != VA_INVALID_ID { va.destroy_buffer(dpy, v.coded) }
	if v.ctx != VA_INVALID_ID { va.destroy_context(dpy, v.ctx) }
	if v.input != VA_INVALID_ID {
		surfaces := [3]VA_ID{v.input, v.recon[0], v.recon[1]}
		va.destroy_surfaces(dpy, &surfaces[0], 3)
	}
	if v.config != VA_INVALID_ID { va.destroy_config(dpy, v.config) }
	device_close(&v.device)
	delete(v.headers)
	delete(v.access)
	bit_writer_destroy(&v.bits)
	free(v, e.allocator)
}

////////////////////////////////
// One frame

// The buffers of one picture, destroyed once it is encoded (libva 2 leaves that to the program).
@(private = "file")
Buffer_List :: struct {
	ids:   [16]VA_ID,
	count: int,
}

@(private = "file")
buffer_add :: proc(v: ^Vaapi_Encoder, list: ^Buffer_List, type: i32, data: rawptr, size: int) -> bool {
	if list.count == len(list.ids) { return false }
	id: VA_ID
	if va.create_buffer(v.device.display, v.ctx, type, u32(size), 1, data, &id) != VA_STATUS_SUCCESS { return false }
	list.ids[list.count] = id
	list.count += 1
	return true
}

// A VAEncMiscParameterBuffer: its type, then the parameters.
@(private = "file")
misc_add :: proc(v: ^Vaapi_Encoder, list: ^Buffer_List, misc_type: u32, payload: rawptr, size: int) -> bool {
	bytes: [128]u32   // (u32s: the type and the parameters are read as such)
	assert(4 + size <= size_of(bytes))
	bytes[0] = misc_type
	mem.copy(&bytes[1], payload, size)
	return buffer_add(v, list, VA_ENC_MISC_PARAMETER_BUFFER, &bytes[0], 4 + size)
}

// A packed header: its parameters, then its bits from the start code (v.bits, written by the caller). The driver adds
// the emulation prevention bytes.
@(private = "file")
packed_add :: proc(v: ^Vaapi_Encoder, list: ^Buffer_List, kind: u32) -> bool {
	w := &v.bits
	bits := bit_count(w)
	data := bit_writer_bytes(w)
	param := VA_Enc_Packed_Header_Parameter_Buffer{type = kind, bit_length = u32(bits), has_emulation_bytes = 0}
	if !buffer_add(v, list, VA_ENC_PACKED_HEADER_PARAMETER_BUFFER, &param, size_of(param)) { return false }
	return buffer_add(v, list, VA_ENC_PACKED_HEADER_DATA_BUFFER, raw_data(data), len(data))
}

@(private = "file")
invalid_picture :: proc() -> VA_Picture_H264 {
	return VA_Picture_H264{picture_id = VA_INVALID_ID, flags = VA_PICTURE_H264_INVALID}
}

@(private)
vaapi_encode :: proc(e: ^Encoder, v: ^Vaapi_Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error {
	if !upload_frame(e, v, frame) { return .Failed }
	dpy := v.device.display
	if keyframe { v.frame_in_gop = 0 }
	idr := v.frame_in_gop == 0
	s := v.sequence
	max_frame_num := 1 << uint(s.log2_max_frame_num)
	frame_num := v.frame_in_gop % max_frame_num
	width_mbs, height_mbs := (s.width + 15) / 16, (s.height + 15) / 16
	cabac := uses_cabac(s.profile_idc)

	list: Buffer_List
	defer for id in list.ids[:list.count] { va.destroy_buffer(dpy, id) }

	if idr {
		seq_value: VA_Enc_Sequence_Parameter_Buffer_H264
		seq := &seq_value
		seq.level_idc = s.level_idc
		seq.intra_period = u32(e.keyframe_frames)
		seq.intra_idr_period = u32(e.keyframe_frames)
		seq.ip_period = 1
		seq.bits_per_second = u32(v.bitrate)
		seq.max_num_ref_frames = 1
		seq.picture_width_in_mbs = u16(width_mbs)
		seq.picture_height_in_mbs = u16(height_mbs)
		// chroma_format_idc 1, frame_mbs_only_flag, direct_8x8_inference_flag, log2_max_frame_num_minus4,
		// pic_order_cnt_type 2
		seq.seq_fields = 1 | 1 << 2 | 1 << 5 | u32(s.log2_max_frame_num - 4) << 6 | 2 << 10
		crop_right, crop_bottom := (width_mbs * 16 - s.width) / 2, (height_mbs * 16 - s.height) / 2
		if crop_right != 0 || crop_bottom != 0 {
			seq.frame_cropping_flag = 1
			seq.frame_crop_right_offset = u32(crop_right)
			seq.frame_crop_bottom_offset = u32(crop_bottom)
		}
		// timing_info_present_flag, bitstream_restriction_flag, log2_max_mv_length 15 and 15,
		// motion_vectors_over_pic_boundaries_flag: what the driver writes when it makes the SPS itself
		seq.vui_parameters_present_flag = 1
		seq.vui_fields = 1 << 1 | 1 << 2 | 15 << 3 | 15 << 8 | 1 << 15
		seq.num_units_in_tick = 1
		seq.time_scale = u32(e.fps * 2)
		if !buffer_add(v, &list, VA_ENC_SEQUENCE_PARAMETER_BUFFER, seq, size_of(seq^)) { return .Failed }

		frame_rate := VA_Enc_Misc_Parameter_Frame_Rate{framerate = u32(e.fps)}
		if !misc_add(v, &list, VA_ENC_MISC_FRAME_RATE, &frame_rate, size_of(frame_rate)) { return .Failed }
		if v.rate_control != VA_RC_CQP {
			// VBR: bits_per_second is the peak, the target a percentage of it
			peak := v.rate_control == VA_RC_VBR ? v.bitrate * 2 : v.bitrate
			rate := VA_Enc_Misc_Parameter_Rate_Control{
				bits_per_second   = u32(peak),
				target_percentage = v.rate_control == VA_RC_VBR ? 50 : 100,
				window_size       = 1000,
			}
			if !misc_add(v, &list, VA_ENC_MISC_RATE_CONTROL, &rate, size_of(rate)) { return .Failed }
			hrd := VA_Enc_Misc_Parameter_HRD{buffer_size = u32(peak), initial_buffer_fullness = u32(peak / 4 * 3)}
			if !misc_add(v, &list, VA_ENC_MISC_HRD, &hrd, size_of(hrd)) { return .Failed }
		}
		if v.packed & VA_ENC_PACKED_HEADER_SEQUENCE != 0 {
			bit_writer_reset(&v.bits)
			write_nal_start(&v.bits, 3, NAL_SPS)
			write_sps(&v.bits, s)
			if !packed_add(v, &list, VA_ENC_PACKED_HEADER_TYPE_SEQUENCE) { return .Failed }
		}
		if v.packed & VA_ENC_PACKED_HEADER_PICTURE != 0 {
			bit_writer_reset(&v.bits)
			write_nal_start(&v.bits, 3, NAL_PPS)
			write_pps(&v.bits, s)
			if !packed_add(v, &list, VA_ENC_PACKED_HEADER_TYPE_PICTURE) { return .Failed }
		}
	}

	current := VA_Picture_H264{
		picture_id             = v.recon[v.current],
		frame_idx              = u32(frame_num),
		top_field_order_cnt    = i32(2 * v.frame_in_gop),
		bottom_field_order_cnt = i32(2 * v.frame_in_gop),
	}
	reference := VA_Picture_H264{
		picture_id             = v.recon[1 - v.current],
		frame_idx              = u32((frame_num + max_frame_num - 1) % max_frame_num),
		flags                  = VA_PICTURE_H264_SHORT_TERM_REFERENCE,
		top_field_order_cnt    = i32(2 * (v.frame_in_gop - 1)),
		bottom_field_order_cnt = i32(2 * (v.frame_in_gop - 1)),
	}

	pic_value: VA_Enc_Picture_Parameter_Buffer_H264
	pic := &pic_value
	pic.curr_pic = current
	for &r in pic.reference_frames { r = invalid_picture() }
	if !idr { pic.reference_frames[0] = reference }
	pic.coded_buf = v.coded
	pic.frame_num = u16(frame_num)
	pic.pic_init_qp = u8(s.qp)
	// idr_pic_flag, reference_pic_flag 1, entropy_coding_mode_flag, transform_8x8_mode_flag,
	// deblocking_filter_control_present_flag
	pic.pic_fields = bit_of(idr) | 1 << 1 | bit_of(cabac) << 3 | bit_of(s.profile_idc == PROFILE_HIGH) << 8 | 1 << 9
	if !buffer_add(v, &list, VA_ENC_PICTURE_PARAMETER_BUFFER, pic, size_of(pic^)) { return .Failed }

	slice_value: VA_Enc_Slice_Parameter_Buffer_H264
	slice := &slice_value
	slice.num_macroblocks = u32(width_mbs * height_mbs)
	slice.macroblock_info = VA_INVALID_ID
	slice.slice_type = idr ? SLICE_I : SLICE_P
	slice.idr_pic_id = u16(v.idr_count % 256)
	for &r in slice.ref_pic_list0 { r = invalid_picture() }
	for &r in slice.ref_pic_list1 { r = invalid_picture() }
	if !idr { slice.ref_pic_list0[0] = reference }
	if v.packed & VA_ENC_PACKED_HEADER_SLICE != 0 {
		bit_writer_reset(&v.bits)
		write_slice_header(&v.bits, s, Slice{idr = idr, frame_num = frame_num, idr_pic_id = int(slice.idr_pic_id)})
		if !packed_add(v, &list, VA_ENC_PACKED_HEADER_TYPE_SLICE) { return .Failed }
	}
	if !buffer_add(v, &list, VA_ENC_SLICE_PARAMETER_BUFFER, slice, size_of(slice^)) { return .Failed }

	if va.begin_picture(dpy, v.ctx, v.input) != VA_STATUS_SUCCESS { return .Failed }
	if va.render_picture(dpy, v.ctx, &list.ids[0], i32(list.count)) != VA_STATUS_SUCCESS {
		va.end_picture(dpy, v.ctx)
		return .Failed
	}
	if va.end_picture(dpy, v.ctx) != VA_STATUS_SUCCESS { return .Failed }
	if va.sync_surface(dpy, v.input) != VA_STATUS_SUCCESS { return .Failed }

	clear(&v.access)
	segments: rawptr
	if va.map_buffer(dpy, v.coded, &segments) != VA_STATUS_SUCCESS { return .Failed }
	for seg := (^VA_Coded_Buffer_Segment)(segments); seg != nil; seg = seg.next {
		append(&v.access, ..seg.buf[:seg.size])
	}
	va.unmap_buffer(dpy, v.coded)
	// (a driver that takes no packed headers may write no SPS either: a keyframe must carry them)
	if idr && !has_nal_type(v.access[:], NAL_SPS) { inject_at(&v.access, 0, ..v.headers[:]) }
	packet_add(e, v.access[:], timestamp)

	v.frame_in_gop += 1
	v.current = 1 - v.current
	if idr { v.idr_count += 1 }
	return .None
}

////////////////////////////////
// The frame into the NV12 surface

@(private = "file")
upload_frame :: proc(e: ^Encoder, v: ^Vaapi_Encoder, frame: Frame) -> bool {
	if v.upload == .Untried { v.upload = vpp_setup(e, v, frame.format) ? Upload.Gpu : Upload.Cpu }
	if v.upload == .Gpu && frame.format == v.rgb_format {
		if vpp_convert(e, v, frame) { return true }
		vpp_release(v)
		v.upload = .Cpu
	}
	return cpu_upload(e, v, frame)
}

// to_nv12 into an image of the surface's format (its planes where its pitches and offsets say).
@(private = "file")
write_nv12_image :: proc(v: ^Vaapi_Encoder, image: ^VA_Image, frame: Frame) -> bool {
	dpy := v.device.display
	mapped: rawptr
	if va.map_buffer(dpy, image.buf, &mapped) != VA_STATUS_SUCCESS { return false }
	bytes := ([^]u8)(mapped)[:image.data_size]
	to_nv12(frame, bytes[image.offsets[0]:], int(image.pitches[0]), bytes[image.offsets[1]:], int(image.pitches[1]))
	va.unmap_buffer(dpy, image.buf)
	return true
}

@(private = "file")
cpu_upload :: proc(e: ^Encoder, v: ^Vaapi_Encoder, frame: Frame) -> bool {
	dpy := v.device.display
	if !v.derive_failed {
		image: VA_Image
		if va.derive_image(dpy, v.input, &image) == VA_STATUS_SUCCESS {
			ok := image.format.fourcc == VA_FOURCC_NV12 && write_nv12_image(v, &image, frame)
			va.destroy_image(dpy, image.image_id)
			if ok { return true }
		}
		v.derive_failed = true
	}
	w, h := e.stream_width, e.stream_height
	if v.nv12_image.image_id == VA_INVALID_ID {
		format, found := image_format_of(dpy, VA_FOURCC_NV12)
		if !found { return false }
		if va.create_image(dpy, &format, i32(w), i32(h), &v.nv12_image) != VA_STATUS_SUCCESS {
			v.nv12_image.image_id = VA_INVALID_ID
			return false
		}
	}
	if !write_nv12_image(v, &v.nv12_image, frame) { return false }
	return va.put_image(dpy, v.input, v.nv12_image.image_id, 0, 0, u32(w), u32(h), 0, 0, u32(w), u32(h)) == VA_STATUS_SUCCESS
}

// The driver's own description of an image format (vaCreateImage wants it as the driver lists it).
@(private = "file")
image_format_of :: proc(dpy: VA_Display, fourcc: u32) -> (VA_Image_Format, bool) {
	formats := make([]VA_Image_Format, max(va.max_num_image_formats(dpy), 1), context.temp_allocator)
	count: i32
	if va.query_image_formats(dpy, raw_data(formats), &count) != VA_STATUS_SUCCESS { return {}, false }
	for f in formats[:count] { if f.fourcc == fourcc { return f, true } }
	return {}, false
}

// Video processing: a context of VAEntrypointVideoProc and an RGB surface of the stream's size in the frames' channel
// order. False (and nothing kept) when the driver has none of it.
@(private = "file")
vpp_setup :: proc(e: ^Encoder, v: ^Vaapi_Encoder, format: Pixel_Format) -> bool {
	dpy := v.device.display
	w, h := e.stream_width, e.stream_height
	if va.create_config(dpy, VA_PROFILE_NONE, VA_ENTRYPOINT_VIDEO_PROC, nil, 0, &v.vpp_config) != VA_STATUS_SUCCESS {
		v.vpp_config = VA_INVALID_ID
		return false
	}
	v.rgb_format = format
	v.rgb_fourcc = format == .BGRA ? VA_FOURCC_BGRA : VA_FOURCC_RGBA
	attrib := VA_Surface_Attrib{type = VA_SURFACE_ATTRIB_PIXEL_FORMAT, flags = VA_SURFACE_ATTRIB_SETTABLE}
	attrib.value.type = VA_GENERIC_VALUE_INTEGER
	attrib.value.value.i = i32(v.rgb_fourcc)
	if va.create_surfaces(dpy, VA_RT_FORMAT_RGB32, u32(w), u32(h), &v.rgb_surface, 1, &attrib, 1) != VA_STATUS_SUCCESS {
		v.rgb_surface = VA_INVALID_ID
		vpp_release(v)
		return false
	}
	if va.create_context(dpy, v.vpp_config, i32(w), i32(h), VA_PROGRESSIVE, &v.input, 1, &v.vpp_ctx) != VA_STATUS_SUCCESS {
		v.vpp_ctx = VA_INVALID_ID
		vpp_release(v)
		return false
	}
	return true
}

@(private = "file")
vpp_release :: proc(v: ^Vaapi_Encoder) {
	dpy := v.device.display
	if v.vpp_ctx != VA_INVALID_ID { va.destroy_context(dpy, v.vpp_ctx) }
	if v.rgb_surface != VA_INVALID_ID { va.destroy_surfaces(dpy, &v.rgb_surface, 1) }
	if v.vpp_config != VA_INVALID_ID { va.destroy_config(dpy, v.vpp_config) }
	v.vpp_ctx, v.rgb_surface, v.vpp_config = VA_INVALID_ID, VA_INVALID_ID, VA_INVALID_ID
}

// The frame into the RGB surface (the last column and row repeated to the even size), then BT.709 limited NV12 into
// the input surface.
@(private = "file")
vpp_convert :: proc(e: ^Encoder, v: ^Vaapi_Encoder, frame: Frame) -> bool {
	dpy := v.device.display
	image: VA_Image
	if va.derive_image(dpy, v.rgb_surface, &image) != VA_STATUS_SUCCESS { return false }
	defer va.destroy_image(dpy, image.image_id)
	// (BGRX for BGRA is the same bytes: only the alpha's name differs)
	fourcc := image.format.fourcc
	same := fourcc == v.rgb_fourcc ||
	        (v.rgb_fourcc == VA_FOURCC_BGRA && fourcc == VA_FOURCC_BGRX) ||
	        (v.rgb_fourcc == VA_FOURCC_RGBA && fourcc == VA_FOURCC_RGBX)
	if !same { return false }
	mapped: rawptr
	if va.map_buffer(dpy, image.buf, &mapped) != VA_STATUS_SUCCESS { return false }
	bytes := ([^]u8)(mapped)[:image.data_size]
	pitch := int(image.pitches[0])
	w, h := e.stream_width, e.stream_height
	row_bytes := frame.width * 4
	for y in 0 ..< h {
		source := frame.pixels[min(y, frame.height - 1) * frame.stride:][:row_bytes]
		target := bytes[int(image.offsets[0]) + y * pitch:]
		copy(target[:row_bytes], source)
		if w > frame.width { copy(target[row_bytes:][:4], source[row_bytes - 4:]) }
	}
	va.unmap_buffer(dpy, image.buf)

	params := VA_Proc_Pipeline_Parameter_Buffer{
		surface                 = v.rgb_surface,
		surface_color_standard  = VA_PROC_COLOR_STANDARD_SRGB,
		output_color_standard   = VA_PROC_COLOR_STANDARD_BT709,
		input_color_properties  = {color_range = VA_SOURCE_RANGE_FULL},
		output_color_properties = {color_range = VA_SOURCE_RANGE_REDUCED, colour_primaries = 1, transfer_characteristics = 1, matrix_coefficients = 1},
	}
	buffer: VA_ID
	if va.create_buffer(dpy, v.vpp_ctx, VA_PROC_PIPELINE_PARAMETER_BUFFER, size_of(params), 1, &params, &buffer) != VA_STATUS_SUCCESS { return false }
	defer va.destroy_buffer(dpy, buffer)
	if va.begin_picture(dpy, v.vpp_ctx, v.input) != VA_STATUS_SUCCESS { return false }
	if va.render_picture(dpy, v.vpp_ctx, &buffer, 1) != VA_STATUS_SUCCESS { va.end_picture(dpy, v.vpp_ctx); return false }
	if va.end_picture(dpy, v.vpp_ctx) != VA_STATUS_SUCCESS { return false }
	// (the encoder reads the surface next: the conversion must be done)
	return va.sync_surface(dpy, v.input) == VA_STATUS_SUCCESS
}
