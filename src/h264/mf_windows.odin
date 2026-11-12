#+build windows
package tk_h264

// Media Foundation's H.264 encoder MFTs: the GPU's (Intel Quick Sync, NVIDIA NVENC, AMD AMF, as MFTEnumEx lists them
// with MFT_ENUM_FLAG_HARDWARE), else Microsoft's software one. A hardware MFT is asynchronous: unlocked
// (MF_TRANSFORM_ASYNC_UNLOCK), it says through its events when it wants input and has output. The software one is
// synchronous: input, then output until it needs more. Frames go in as NV12 in memory (to_nv12 on the CPU); the rate
// control, keyframe interval and low latency (no B pictures: a packet for each frame, a frame or two late at most) go
// through ICodecAPI, each setting skipped when the encoder lacks it.
//
// COM: open joins the calling thread to the multithreaded apartment; close leaves it. One encoder for one thread.

import win "core:sys/windows"
import "core:time"

@(private)
Mf_Encoder :: struct {
	activate:         rawptr,   // IMFActivate: shut down at close (a hardware MFT frees its device then)
	transform:        rawptr,   // IMFTransform
	events:           rawptr,   // IMFMediaEventGenerator, of an asynchronous MFT
	codec_api:        rawptr,   // ICodecAPI, nil when the MFT has none
	input_id:         u32,
	output_id:        u32,
	async:            bool,
	need_input:       int,      // inputs an asynchronous MFT asked for and has not had yet
	provides_samples: bool,     // the MFT makes its output samples
	output_sample:    rawptr,   // ours, when it does not
	output_buffer:    rawptr,
	sequence_header:  [dynamic]u8,   // the SPS and PPS of the output type: put before a keyframe without them
	access:           [dynamic]u8,
	com_joined:       bool,
	started:          bool,     // MFStartup succeeded
	streaming:        bool,     // NOTIFY_BEGIN_STREAMING sent
}

// The encoders of each kind, listed (not opened): what available says.
@(private)
mf_available :: proc() -> Backends {
	if !mf_load() { return {} }
	joined := win.CoInitializeEx(nil, .MULTITHREADED) >= 0
	defer if joined { win.CoUninitialize() }
	if mf.startup(MF_VERSION, MFSTARTUP_FULL) < 0 { return {} }
	defer mf.shutdown()
	found: Backends
	if mf_count(MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER) > 0 { found += {.Media_Foundation_Hardware} }
	if mf_count(MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER) > 0 { found += {.Media_Foundation_Software} }
	return found
}

@(private = "file")
mf_enum :: proc(flags: u32) -> (activates: [^]rawptr, count: u32) {
	input := MFT_Register_Type_Info{MF_MEDIA_TYPE_VIDEO, MF_VIDEO_FORMAT_NV12}
	output := MFT_Register_Type_Info{MF_MEDIA_TYPE_VIDEO, MF_VIDEO_FORMAT_H264}
	if mf.enum_ex(MFT_CATEGORY_VIDEO_ENCODER, flags, &input, &output, &activates, &count) < 0 { return nil, 0 }
	return
}

@(private = "file")
mf_enum_free :: proc(activates: [^]rawptr, count: u32) {
	if activates == nil { return }
	for i in 0 ..< count { com_release(activates[i]) }
	win.CoTaskMemFree(activates)
}

@(private = "file")
mf_count :: proc(flags: u32) -> u32 {
	activates, count := mf_enum(flags)
	mf_enum_free(activates, count)
	return count
}

@(private)
mf_open :: proc(e: ^Encoder) -> (^Mf_Encoder, Backend, bool) {
	if !mf_load() { return nil, .Media_Foundation_Software, false }
	m := new(Mf_Encoder, e.allocator)
	m.sequence_header = make([dynamic]u8, e.allocator)
	m.access = make([dynamic]u8, e.allocator)
	// (S_FALSE: joined already, to be left all the same; RPC_E_CHANGED_MODE: a single-threaded apartment, usable)
	m.com_joined = win.CoInitializeEx(nil, .MULTITHREADED) >= 0
	if mf.startup(MF_VERSION, MFSTARTUP_FULL) >= 0 {
		m.started = true
		if e.options.backend != .Software && mf_try(e, m, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER) {
			return m, .Media_Foundation_Hardware, true
		}
		if e.options.backend != .Hardware && mf_try(e, m, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER) {
			return m, .Media_Foundation_Software, true
		}
	}
	mf_close(e, m)
	return nil, .Media_Foundation_Software, false
}

// The encoders of one kind in the order Windows ranks them; the first that takes the stream's types is kept.
@(private = "file")
mf_try :: proc(e: ^Encoder, m: ^Mf_Encoder, flags: u32) -> bool {
	activates, count := mf_enum(flags)
	defer mf_enum_free(activates, count)
	for i in 0 ..< count {
		a := activates[i]
		transform: rawptr
		if vtable_of(a, IMFActivate_Vtbl).ActivateObject(a, &IID_IMFTransform, &transform) < 0 || transform == nil { continue }
		m.transform = transform
		m.activate = a
		vtable_of(a, IUnknown_Vtbl).AddRef(a)
		if mf_setup(e, m) { return true }
		mf_release_transform(m)
	}
	return false
}

@(private = "file")
mf_release_transform :: proc(m: ^Mf_Encoder) {
	com_release(m.output_buffer)
	com_release(m.output_sample)
	com_release(m.codec_api)
	com_release(m.events)
	com_release(m.transform)
	if m.activate != nil {
		vtable_of(m.activate, IMFActivate_Vtbl).ShutdownObject(m.activate)
		com_release(m.activate)
	}
	m.output_buffer, m.output_sample, m.codec_api, m.events, m.transform, m.activate = nil, nil, nil, nil, nil, nil
	m.async, m.provides_samples, m.streaming = false, false, false
	m.need_input = 0
}

@(private = "file")
mf_setup :: proc(e: ^Encoder, m: ^Mf_Encoder) -> bool {
	t := m.transform
	vt := vtable_of(t, IMFTransform_Vtbl)
	attributes: rawptr
	if vt.GetAttributes(t, &attributes) >= 0 && attributes != nil {
		defer com_release(attributes)
		av := vtable_of(attributes, IMFAttributes_Vtbl)
		async: u32
		if av.GetUINT32(attributes, &MF_TRANSFORM_ASYNC, &async) >= 0 && async != 0 {
			if av.SetUINT32(attributes, &MF_TRANSFORM_ASYNC_UNLOCK, 1) < 0 { return false }
			m.async = true
		}
	}
	if m.async {
		m.events = com_query(t, &IID_IMFMediaEventGenerator)
		if m.events == nil { return false }
	}
	input_ids, output_ids: [1]u32
	if vt.GetStreamIDs(t, 1, &input_ids[0], 1, &output_ids[0]) >= 0 {
		m.input_id, m.output_id = input_ids[0], output_ids[0]
	} else {
		m.input_id, m.output_id = 0, 0   // (E_NOTIMPL: the streams are numbered from 0)
	}

	// (before the types: some encoders take the rate control only then)
	m.codec_api = com_query(t, &IID_ICodecAPI)
	if m.codec_api != nil { mf_codec_settings(e, m) }

	if !mf_set_output_type(e, m, AV_ENC_H264_PROFILE_HIGH) && !mf_set_output_type(e, m, AV_ENC_H264_PROFILE_MAIN) { return false }
	if !mf_set_input_type(e, m) { return false }

	info: MFT_Output_Stream_Info
	if vt.GetOutputStreamInfo(t, m.output_id, &info) < 0 { return false }
	m.provides_samples = info.flags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES) != 0
	if !m.provides_samples {
		size := max(info.size, u32(e.stream_width * e.stream_height * 2))
		if mf.create_sample(&m.output_sample) < 0 { return false }
		if mf.create_memory_buffer(size, &m.output_buffer) < 0 { return false }
		if vtable_of(m.output_sample, IMFSample_Vtbl).AddBuffer(m.output_sample, m.output_buffer) < 0 { return false }
	}
	mf_read_sequence_header(m)
	if vt.ProcessMessage(t, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0) < 0 { return false }
	vt.ProcessMessage(t, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
	m.streaming = true
	return true
}

@(private = "file")
mf_set_value :: proc(m: ^Mf_Encoder, api: ^GUID, vt: u16, value: u64) -> bool {
	v := Variant{vt = vt, value = value}
	return vtable_of(m.codec_api, ICodecAPI_Vtbl).SetValue(m.codec_api, api, &v) >= 0
}

// The rate control, the keyframe interval and low latency. Each one the encoder refuses is left at its default.
@(private = "file")
mf_codec_settings :: proc(e: ^Encoder, m: ^Mf_Encoder) {
	mf_set_value(m, &CODECAPI_AVLowLatencyMode, VT_BOOL, VARIANT_TRUE)
	mf_set_value(m, &CODECAPI_AVEncMPVDefaultBPictureCount, VT_UI4, 0)
	mf_set_value(m, &CODECAPI_AVEncMPVGOPSize, VT_UI4, u64(e.keyframe_frames))
	if e.options.bitrate > 0 {
		if !mf_set_value(m, &CODECAPI_AVEncCommonRateControlMode, VT_UI4, AV_ENC_RATE_CONTROL_UNCONSTRAINED_VBR) {
			mf_set_value(m, &CODECAPI_AVEncCommonRateControlMode, VT_UI4, AV_ENC_RATE_CONTROL_CBR)
		}
		mf_set_value(m, &CODECAPI_AVEncCommonMeanBitRate, VT_UI4, u64(e.options.bitrate))
	} else {
		mf_set_value(m, &CODECAPI_AVEncCommonRateControlMode, VT_UI4, AV_ENC_RATE_CONTROL_QUALITY)
		// (Quality is 0 ..= 100; some encoders read the quantiser itself)
		mf_set_value(m, &CODECAPI_AVEncCommonQuality, VT_UI4, u64((51 - e.options.qp) * 100 / 50))
		mf_set_value(m, &CODECAPI_AVEncVideoEncodeQP, VT_UI8, u64(e.options.qp))
	}
}

// The attributes both types share: the size, the rate, progressive frames, square pixels, BT.709 limited range.
@(private = "file")
mf_video_attributes :: proc(e: ^Encoder, t: rawptr) {
	a := vtable_of(t, IMFAttributes_Vtbl)
	a.SetGUID(t, &MF_MT_MAJOR_TYPE, &MF_MEDIA_TYPE_VIDEO)
	a.SetUINT64(t, &MF_MT_FRAME_SIZE, u64(e.stream_width) << 32 | u64(e.stream_height))
	a.SetUINT64(t, &MF_MT_FRAME_RATE, u64(e.fps) << 32 | 1)
	a.SetUINT64(t, &MF_MT_PIXEL_ASPECT_RATIO, 1 << 32 | 1)
	a.SetUINT32(t, &MF_MT_INTERLACE_MODE, MF_VIDEO_INTERLACE_PROGRESSIVE)
	a.SetUINT32(t, &MF_MT_VIDEO_NOMINAL_RANGE, MF_NOMINAL_RANGE_16_235)
	a.SetUINT32(t, &MF_MT_YUV_MATRIX, MF_VIDEO_TRANSFER_MATRIX_BT709)
	a.SetUINT32(t, &MF_MT_VIDEO_PRIMARIES, MF_VIDEO_PRIMARIES_BT709)
	a.SetUINT32(t, &MF_MT_TRANSFER_FUNCTION, MF_VIDEO_TRANSFER_FUNCTION_709)
}

@(private = "file")
mf_set_output_type :: proc(e: ^Encoder, m: ^Mf_Encoder, profile: u32) -> bool {
	t: rawptr
	if mf.create_media_type(&t) < 0 { return false }
	defer com_release(t)
	mf_video_attributes(e, t)
	a := vtable_of(t, IMFAttributes_Vtbl)
	a.SetGUID(t, &MF_MT_SUBTYPE, &MF_VIDEO_FORMAT_H264)
	// (required by the encoders even with a quality: about 0.1 bit a pixel then)
	bitrate := e.options.bitrate > 0 ? e.options.bitrate : max(e.stream_width * e.stream_height * e.fps / 10, 100_000)
	a.SetUINT32(t, &MF_MT_AVG_BITRATE, u32(bitrate))
	a.SetUINT32(t, &MF_MT_MPEG2_PROFILE, profile)
	return vtable_of(m.transform, IMFTransform_Vtbl).SetOutputType(m.transform, m.output_id, t, 0) >= 0
}

@(private = "file")
mf_set_input_type :: proc(e: ^Encoder, m: ^Mf_Encoder) -> bool {
	t: rawptr
	if mf.create_media_type(&t) < 0 { return false }
	defer com_release(t)
	mf_video_attributes(e, t)
	vtable_of(t, IMFAttributes_Vtbl).SetGUID(t, &MF_MT_SUBTYPE, &MF_VIDEO_FORMAT_NV12)
	return vtable_of(m.transform, IMFTransform_Vtbl).SetInputType(m.transform, m.input_id, t, 0) >= 0
}

// The SPS and PPS the output type carries (Annex B), when the encoder says them there.
@(private = "file")
mf_read_sequence_header :: proc(m: ^Mf_Encoder) {
	clear(&m.sequence_header)
	t: rawptr
	if vtable_of(m.transform, IMFTransform_Vtbl).GetOutputCurrentType(m.transform, m.output_id, &t) < 0 || t == nil { return }
	defer com_release(t)
	a := vtable_of(t, IMFAttributes_Vtbl)
	size: u32
	if a.GetBlobSize(t, &MF_MT_MPEG_SEQUENCE_HEADER, &size) < 0 || size == 0 { return }
	resize(&m.sequence_header, int(size))
	written: u32
	if a.GetBlob(t, &MF_MT_MPEG_SEQUENCE_HEADER, raw_data(m.sequence_header), size, &written) < 0 {
		clear(&m.sequence_header)
		return
	}
	resize(&m.sequence_header, int(written))
}

@(private)
mf_close :: proc(e: ^Encoder, m: ^Mf_Encoder) {
	if m.streaming {
		vt := vtable_of(m.transform, IMFTransform_Vtbl)
		vt.ProcessMessage(m.transform, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0)
		vt.ProcessMessage(m.transform, MFT_MESSAGE_NOTIFY_END_STREAMING, 0)
	}
	mf_release_transform(m)
	if m.started { mf.shutdown() }
	if m.com_joined { win.CoUninitialize() }
	delete(m.sequence_header)
	delete(m.access)
	free(m, e.allocator)
}

////////////////////////////////
// Frames in, packets out

@(private)
mf_encode :: proc(e: ^Encoder, m: ^Mf_Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error {
	sample, ok := mf_input_sample(e, frame, timestamp)
	if !ok { return .Failed }
	defer com_release(sample)
	if keyframe && e.frames > 1 && m.codec_api != nil {
		mf_set_value(m, &CODECAPI_AVEncVideoForceKeyFrame, VT_UI4, 1)
	}
	t := m.transform
	vt := vtable_of(t, IMFTransform_Vtbl)
	if m.async {
		// (wait for the MFT to ask, taking the output it has meanwhile)
		for m.need_input == 0 {
			if !mf_next_event(e, m, wait = true) { return .Failed }
		}
		if vt.ProcessInput(t, m.input_id, sample, 0) < 0 { return .Failed }
		m.need_input -= 1
		// what is ready now, without waiting
		for mf_next_event(e, m, wait = false) {}
		return .None
	}
	hr := vt.ProcessInput(t, m.input_id, sample, 0)
	if u32(hr) == MF_E_NOTACCEPTING {
		// (full: its output first, then the input again)
		if !mf_drain_output(e, m) { return .Failed }
		hr = vt.ProcessInput(t, m.input_id, sample, 0)
	}
	if hr < 0 { return .Failed }
	return mf_drain_output(e, m) ? .None : .Failed
}

// The end: the encoder gives what it holds back.
@(private)
mf_flush :: proc(e: ^Encoder, m: ^Mf_Encoder) -> Error {
	t := m.transform
	vt := vtable_of(t, IMFTransform_Vtbl)
	if vt.ProcessMessage(t, MFT_MESSAGE_COMMAND_DRAIN, 0) < 0 { return .Failed }
	if !m.async { return mf_drain_output(e, m) ? .None : .Failed }
	for {
		ev: rawptr
		if vtable_of(m.events, IMFMediaEventGenerator_Vtbl).GetEvent(m.events, 0, &ev) < 0 { return .Failed }
		type: u32
		vtable_of(ev, IMFMediaEvent_Vtbl).GetType(ev, &type)
		com_release(ev)
		switch type {
		case ME_TRANSFORM_HAVE_OUTPUT:    if !mf_output(e, m) { return .Failed }
		case ME_TRANSFORM_NEED_INPUT:     m.need_input += 1
		case ME_TRANSFORM_DRAIN_COMPLETE: return .None
		}
	}
}

// One event of an asynchronous MFT, handled. False when there was none (not waiting) or on an error.
@(private = "file")
mf_next_event :: proc(e: ^Encoder, m: ^Mf_Encoder, wait: bool) -> bool {
	ev: rawptr
	hr := vtable_of(m.events, IMFMediaEventGenerator_Vtbl).GetEvent(m.events, wait ? 0 : MF_EVENT_FLAG_NO_WAIT, &ev)
	if hr < 0 || ev == nil { return false }
	defer com_release(ev)
	ev_vt := vtable_of(ev, IMFMediaEvent_Vtbl)
	type: u32
	ev_vt.GetType(ev, &type)
	status: HRESULT
	if ev_vt.GetStatus(ev, &status) >= 0 && status < 0 { return false }
	switch type {
	case ME_TRANSFORM_NEED_INPUT:  m.need_input += 1
	case ME_TRANSFORM_HAVE_OUTPUT: return mf_output(e, m)
	}
	return true
}

// A synchronous MFT's output, until it needs more input.
@(private = "file")
mf_drain_output :: proc(e: ^Encoder, m: ^Mf_Encoder) -> bool {
	for {
		got, ok := mf_output_once(e, m)
		if !ok { return false }
		if !got { return true }
	}
}

@(private = "file")
mf_output :: proc(e: ^Encoder, m: ^Mf_Encoder) -> bool {
	_, ok := mf_output_once(e, m)
	return ok
}

// One ProcessOutput. got: a packet came; false with ok: the MFT needs input.
@(private = "file")
mf_output_once :: proc(e: ^Encoder, m: ^Mf_Encoder) -> (got: bool, ok: bool) {
	t := m.transform
	vt := vtable_of(t, IMFTransform_Vtbl)
	for {
		if m.output_buffer != nil { vtable_of(m.output_buffer, IMFMediaBuffer_Vtbl).SetCurrentLength(m.output_buffer, 0) }
		data := [1]MFT_Output_Data_Buffer{{stream_id = m.output_id, sample = m.provides_samples ? nil : m.output_sample}}
		status: u32
		hr := vt.ProcessOutput(t, 0, 1, &data[0], &status)
		com_release(data[0].events)
		if u32(hr) == MF_E_TRANSFORM_NEED_MORE_INPUT { return false, true }
		if u32(hr) == MF_E_TRANSFORM_STREAM_CHANGE {
			// (the encoder settled its output type: take the one it offers, then ask again)
			offered: rawptr
			if vt.GetOutputAvailableType(t, m.output_id, 0, &offered) < 0 { return false, false }
			changed := vt.SetOutputType(t, m.output_id, offered, 0) >= 0
			com_release(offered)
			if !changed { return false, false }
			mf_read_sequence_header(m)
			continue
		}
		if hr < 0 { return false, false }
		sample := data[0].sample
		if sample == nil { return false, true }
		ok = mf_take_sample(e, m, sample)
		if m.provides_samples { com_release(sample) }
		return true, ok
	}
}

// A coded sample's bytes as one packet, with the time it was given.
@(private = "file")
mf_take_sample :: proc(e: ^Encoder, m: ^Mf_Encoder, sample: rawptr) -> bool {
	sv := vtable_of(sample, IMFSample_Vtbl)
	buffer: rawptr
	if sv.ConvertToContiguousBuffer(sample, &buffer) < 0 || buffer == nil { return false }
	defer com_release(buffer)
	bv := vtable_of(buffer, IMFMediaBuffer_Vtbl)
	bytes: [^]u8
	max_length, length: u32
	if bv.Lock(buffer, &bytes, &max_length, &length) < 0 { return false }
	clear(&m.access)
	append(&m.access, ..bytes[:length])
	bv.Unlock(buffer)
	time_100ns: i64
	sv.GetSampleTime(sample, &time_100ns)
	if len(m.access) == 0 { return true }
	// (a keyframe must carry the SPS and PPS; some encoders say them only in the output type)
	if has_nal_type(m.access[:], NAL_IDR) && !has_nal_type(m.access[:], NAL_SPS) && len(m.sequence_header) > 0 {
		inject_at(&m.access, 0, ..m.sequence_header[:])
	}
	packet_add(e, m.access[:], time.Duration(time_100ns * 100))
	return true
}

// The frame as an NV12 sample of the stream's size, its time in 100 ns units.
@(private = "file")
mf_input_sample :: proc(e: ^Encoder, frame: Frame, timestamp: time.Duration) -> (rawptr, bool) {
	w, h := e.stream_width, e.stream_height
	size := u32(w * h + w * (h / 2))
	buffer: rawptr
	if mf.create_memory_buffer(size, &buffer) < 0 { return nil, false }
	defer com_release(buffer)
	bv := vtable_of(buffer, IMFMediaBuffer_Vtbl)
	bytes: [^]u8
	max_length, length: u32
	if bv.Lock(buffer, &bytes, &max_length, &length) < 0 { return nil, false }
	planes := bytes[:size]
	to_nv12(frame, planes[:w * h], w, planes[w * h:], w)
	bv.Unlock(buffer)
	bv.SetCurrentLength(buffer, size)
	sample: rawptr
	if mf.create_sample(&sample) < 0 { return nil, false }
	sv := vtable_of(sample, IMFSample_Vtbl)
	if sv.AddBuffer(sample, buffer) < 0 { com_release(sample); return nil, false }
	sv.SetSampleTime(sample, i64(timestamp / 100))
	sv.SetSampleDuration(sample, 10_000_000 / i64(e.fps))
	return sample, true
}
