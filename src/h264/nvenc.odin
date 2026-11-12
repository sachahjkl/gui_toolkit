#+build linux, windows
package tk_h264

// NVENC: the H.264 encoder of NVIDIA's GPUs, through NVIDIA's own driver (libnvidia-encode, nvEncodeAPI64.dll). VA-API
// does not encode on that driver, so on Linux this is the only way to its encoder; on Windows it comes before Media
// Foundation, whose NVIDIA MFT has fewer controls. The session runs on a CUDA context of the first device whose session
// encodes H.264: the same path on both systems, simpler than a D3D11 device on Windows. The frames go in through
// NVENC's own input buffer in system memory, so no CUDA memory call is needed.
//
// The frame becomes NV12 on the CPU (to_nv12), not ARGB converted by NVENC: NVENC converts RGB with the BT.601 matrix
// (FFmpeg declares BT.601 for RGB input for that reason), and this package's streams are BT.709, as their VUI says.
// Synchronous mode, P pictures only, no lookahead: each picture comes out before encode returns, so one input buffer and
// one bitstream buffer are enough.
//
// The CUDA context is current on the calling thread only during each call of this file (pushed, then popped): the
// encoder may move from one thread to another between calls, and the thread keeps no context of ours.

import "core:time"

@(private)
Nvenc_Encoder :: struct {
	cuda_context: rawptr,
	session:      rawptr,
	input:        rawptr,   // NV12, the stream's size
	bitstream:    rawptr,
}

@(private)
nvenc_probe :: proc() -> bool {
	n, ok := session_open()
	if ok { session_close(&n) }
	return ok
}

@(private)
nvenc_open :: proc(e: ^Encoder) -> (^Nvenc_Encoder, bool) {
	session, found := session_open()
	if !found { return nil, false }
	n := new(Nvenc_Encoder, e.allocator)
	n^ = session
	cuda_push(n)
	ok := session_setup(e, n)
	cuda_pop()
	if !ok {
		nvenc_close(e, n)
		return nil, false
	}
	return n, true
}

@(private)
nvenc_encode :: proc(e: ^Encoder, n: ^Nvenc_Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error {
	cuda_push(n)
	defer cuda_pop()

	lock := NV_Lock_Input_Buffer{version = NV_ENC_LOCK_INPUT_BUFFER_VER, input_buffer = n.input}
	if nvenc_api.lock_input_buffer(n.session, &lock) != NV_ENC_SUCCESS || lock.buffer_data_ptr == nil { return .Failed }
	pitch, rows := int(lock.pitch), e.stream_height
	planes := ([^]u8)(lock.buffer_data_ptr)
	// (the chroma plane follows the luma's rows at the same pitch: NVENC's NV12 layout in its own buffers)
	to_nv12(frame, planes[:pitch * rows], pitch, planes[pitch * rows:pitch * rows + pitch * (rows / 2)], pitch)
	if nvenc_api.unlock_input_buffer(n.session, n.input) != NV_ENC_SUCCESS { return .Failed }

	params: NV_Pic_Params
	params.version = NV_ENC_PIC_PARAMS_VER
	params.input_width, params.input_height = u32(e.stream_width), u32(e.stream_height)
	params.input_pitch = u32(pitch)
	params.input_buffer = n.input
	params.output_bitstream = n.bitstream
	params.buffer_format = NV_ENC_BUFFER_FORMAT_NV12
	params.picture_struct = NV_ENC_PIC_STRUCT_FRAME
	params.input_timestamp = u64(i64(timestamp))
	if keyframe { params.encode_pic_flags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS }
	// NEED_MORE_INPUT would mean a picture held back, its input buffer still in use and its output due in the one
	// bitstream buffer: the configuration (no B pictures, no lookahead) never asks for it, and it is not taken.
	if nvenc_api.encode_picture(n.session, &params) != NV_ENC_SUCCESS { return .Failed }
	return take_output(e, n)
}

// The end of the stream: nothing is held back (see the top of the file), the picture only closes the session's stream.
@(private)
nvenc_flush :: proc(e: ^Encoder, n: ^Nvenc_Encoder) -> Error {
	cuda_push(n)
	defer cuda_pop()
	params := NV_Pic_Params{version = NV_ENC_PIC_PARAMS_VER, encode_pic_flags = NV_ENC_PIC_FLAG_EOS}
	if nvenc_api.encode_picture(n.session, &params) != NV_ENC_SUCCESS { return .Failed }
	return .None
}

@(private)
nvenc_close :: proc(e: ^Encoder, n: ^Nvenc_Encoder) {
	session_close(n)
	free(n, e.allocator)
}

// A CUDA context on the first device whose NVENC session encodes H.264, and that session; the context is not current
// on the calling thread when this returns.
@(private = "file")
session_open :: proc() -> (n: Nvenc_Encoder, ok: bool) {
	if !nvenc_load() { return }
	count: i32
	if cuda.device_get_count(&count) != CUDA_SUCCESS { return }
	for ordinal in 0 ..< count {
		device: i32
		if cuda.device_get(&device, ordinal) != CUDA_SUCCESS { continue }
		cuda_context: rawptr
		// (a new context is current on this thread: it stays so while the session opens, then it is popped)
		if cuda.ctx_create(&cuda_context, 0, device) != CUDA_SUCCESS || cuda_context == nil { continue }
		params := NV_Open_Session_Params{
			version     = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER,
			device_type = NV_ENC_DEVICE_TYPE_CUDA,
			device      = cuda_context,
			api_version = NVENCAPI_VERSION,
		}
		session: rawptr
		status := nvenc_api.open_encode_session_ex(&params, &session)
		if status == NV_ENC_SUCCESS && session != nil && encodes_h264(session) {
			cuda_pop()
			return {cuda_context = cuda_context, session = session}, true
		}
		// (NVENC asks for the session to be destroyed even when it failed to open)
		if session != nil { nvenc_api.destroy_encoder(session) }
		cuda_pop()
		cuda.ctx_destroy(cuda_context)
	}
	return
}

@(private = "file")
session_close :: proc(n: ^Nvenc_Encoder) {
	if n.cuda_context == nil { return }
	cuda_push(n)
	if n.session != nil {
		if n.input != nil { nvenc_api.destroy_input_buffer(n.session, n.input) }
		if n.bitstream != nil { nvenc_api.destroy_bitstream_buffer(n.session, n.bitstream) }
		nvenc_api.destroy_encoder(n.session)
	}
	cuda_pop()
	cuda.ctx_destroy(n.cuda_context)
	n^ = {}
}

@(private = "file")
encodes_h264 :: proc(session: rawptr) -> bool {
	count: u32
	if nvenc_api.get_encode_guid_count(session, &count) != NV_ENC_SUCCESS || count == 0 { return false }
	guids := make([]NV_Guid, count, context.temp_allocator)
	written: u32
	if nvenc_api.get_encode_guids(session, raw_data(guids), count, &written) != NV_ENC_SUCCESS { return false }
	for g in guids[:min(written, count)] {
		if g == NV_ENC_CODEC_H264_GUID { return true }
	}
	return false
}

// The preset P4 tuned for low latency (no B pictures), then this package's stream: High profile, a keyframe every
// keyframe_frames with its SPS and PPS, the rate control asked for, BT.709 limited range in the VUI. Then the two
// buffers.
@(private = "file")
session_setup :: proc(e: ^Encoder, n: ^Nvenc_Encoder) -> bool {
	preset := new(NV_Preset_Config, context.temp_allocator)   // 5 KB: not on a worker's stack
	preset.version = NV_ENC_PRESET_CONFIG_VER
	preset.config.version = NV_ENC_CONFIG_VER
	if nvenc_api.get_encode_preset_config_ex(n.session, NV_ENC_CODEC_H264_GUID, NV_ENC_PRESET_P4_GUID, NV_ENC_TUNING_INFO_LOW_LATENCY, preset) != NV_ENC_SUCCESS {
		return false
	}
	config := &preset.config
	config.version = NV_ENC_CONFIG_VER
	config.profile_guid = NV_ENC_H264_PROFILE_HIGH_GUID
	config.gop_length = u32(e.keyframe_frames)
	config.frame_interval_p = 1   // I and P pictures only: a packet for each frame, no reordering

	rc := &config.rc
	rc.version = NV_ENC_RC_PARAMS_VER
	rc.flags &~= NV_ENC_RC_ENABLE_LOOKAHEAD   // a lookahead holds frames back
	rc.lookahead_depth = 0
	if e.options.bitrate > 0 {
		rc.rate_control_mode = NV_ENC_PARAMS_RC_VBR
		rc.average_bitrate = u32(min(e.options.bitrate, int(max(u32))))
		rc.max_bitrate = u32(min(e.options.bitrate * 2, int(max(u32))))
	} else {
		qp := u32(e.options.qp)
		rc.rate_control_mode = NV_ENC_PARAMS_RC_CONSTQP
		rc.const_qp = {inter_p = qp, inter_b = qp, intra = qp}
		rc.multi_pass = NV_ENC_MULTI_PASS_DISABLED
	}

	h := &config.h264
	h.flags |= NV_ENC_H264_REPEAT_SPS_PPS   // every keyframe carries the SPS and the PPS
	h.idr_period = config.gop_length
	h.level = NV_ENC_LEVEL_AUTOSELECT
	h.chroma_format_idc = 1                 // 4:2:0
	vui := &h.vui
	vui.video_signal_type_present_flag = 1
	vui.video_format = NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED
	vui.video_full_range_flag = 0           // limited range: what to_nv12 makes
	vui.colour_description_present_flag = 1
	vui.colour_primaries = NV_ENC_VUI_BT709
	vui.transfer_characteristics = NV_ENC_VUI_BT709
	vui.colour_matrix = NV_ENC_VUI_BT709

	init := new(NV_Initialize_Params, context.temp_allocator)
	init^ = {
		version        = NV_ENC_INITIALIZE_PARAMS_VER,
		encode_guid    = NV_ENC_CODEC_H264_GUID,
		preset_guid    = NV_ENC_PRESET_P4_GUID,
		encode_width   = u32(e.stream_width),
		encode_height  = u32(e.stream_height),
		dar_width      = u32(e.stream_width),
		dar_height     = u32(e.stream_height),
		frame_rate_num = u32(e.fps),
		frame_rate_den = 1,
		enable_ptd     = 1,   // NVENC picks each picture's type; encode forces the keyframes
		encode_config  = config,
		tuning_info    = NV_ENC_TUNING_INFO_LOW_LATENCY,
	}
	if nvenc_api.initialize_encoder(n.session, init) != NV_ENC_SUCCESS { return false }

	input := NV_Create_Input_Buffer{
		version       = NV_ENC_CREATE_INPUT_BUFFER_VER,
		width         = u32(e.stream_width),
		height        = u32(e.stream_height),
		buffer_format = NV_ENC_BUFFER_FORMAT_NV12,
	}
	if nvenc_api.create_input_buffer(n.session, &input) != NV_ENC_SUCCESS || input.input_buffer == nil { return false }
	n.input = input.input_buffer
	bitstream := NV_Create_Bitstream_Buffer{version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER}
	if nvenc_api.create_bitstream_buffer(n.session, &bitstream) != NV_ENC_SUCCESS || bitstream.bitstream_buffer == nil { return false }
	n.bitstream = bitstream.bitstream_buffer
	return true
}

// The picture encode_picture finished, from the bitstream buffer (lock_bitstream waits for it): one access unit in
// Annex B, with the timestamp it was given.
@(private = "file")
take_output :: proc(e: ^Encoder, n: ^Nvenc_Encoder) -> Error {
	lock := NV_Lock_Bitstream{version = NV_ENC_LOCK_BITSTREAM_VER, output_bitstream = n.bitstream}
	if nvenc_api.lock_bitstream(n.session, &lock) != NV_ENC_SUCCESS { return .Failed }
	if lock.bitstream_buffer_ptr != nil && lock.bitstream_size > 0 {
		data := ([^]u8)(lock.bitstream_buffer_ptr)[:lock.bitstream_size]
		packet_add(e, data, time.Duration(i64(lock.output_timestamp)))
	}
	nvenc_api.unlock_bitstream(n.session, n.bitstream)
	return .None
}

@(private = "file")
cuda_push :: proc(n: ^Nvenc_Encoder) { cuda.ctx_push_current(n.cuda_context) }

@(private = "file")
cuda_pop :: proc() {
	popped: rawptr
	cuda.ctx_pop_current(&popped)
}
