#+build linux
package tk_h264

// openh264 (Cisco's libopenh264, by dlopen): the software encoder when there is no GPU's. Its frames are I420
// (to_i420 on the CPU); it writes its own SPS and PPS before each IDR picture. The structures are those of
// codec_api.h / codec_app_def.h of openh264 2.4 ..= 2.6 (soname 7), the versions whose layout this file was written
// from: another major version is not loaded.

import "core:sync"
import "core:sys/posix"
import "core:time"

@(private = "file")
Encoder_Vtable :: struct {
	Initialize:          proc "c" (encoder: ^^Encoder_Vtable, params: rawptr) -> i32,
	InitializeExt:       proc "c" (encoder: ^^Encoder_Vtable, params: ^Param_Ext) -> i32,
	GetDefaultParams:    proc "c" (encoder: ^^Encoder_Vtable, params: ^Param_Ext) -> i32,
	Uninitialize:        proc "c" (encoder: ^^Encoder_Vtable) -> i32,
	EncodeFrame:         proc "c" (encoder: ^^Encoder_Vtable, source: ^Source_Picture, info: ^Frame_Info) -> i32,
	EncodeParameterSets: proc "c" (encoder: ^^Encoder_Vtable, info: ^Frame_Info) -> i32,
	ForceIntraFrame:     proc "c" (encoder: ^^Encoder_Vtable, idr: bool) -> i32,
	SetOption:           proc "c" (encoder: ^^Encoder_Vtable, option: i32, value: rawptr) -> i32,
	GetOption:           proc "c" (encoder: ^^Encoder_Vtable, option: i32, value: rawptr) -> i32,
}

@(private = "file")
Version :: struct { major, minor, revision, reserved: u32 }

@(private = "file")
Library :: struct {
	create:  proc "c" (encoder: ^^^Encoder_Vtable) -> i32,
	destroy: proc "c" (encoder: ^^Encoder_Vtable),
}

@(private = "file") MAX_SPATIAL_LAYERS :: 4
@(private = "file") MAX_SLICES :: 35            // MAX_SLICES_NUM_TMP: (128 - (4 * 4 + 1 + 4)) / 3
@(private = "file") MAX_LAYERS_OF_FRAME :: 128

@(private = "file")
Slice_Argument :: struct {
	mode:            i32,
	count:           u32,
	macroblocks:     [MAX_SLICES]u32,
	size_constraint: u32,
}

// SSpatialLayerConfig
@(private = "file")
Spatial_Layer :: struct {
	video_width, video_height: i32,
	frame_rate:                f32,
	spatial_bitrate:           i32,
	max_spatial_bitrate:       i32,
	profile_idc:               i32,
	level_idc:                 i32,
	qp:                        i32,   // iDLayerQp: the quantiser with no rate control
	slice:                     Slice_Argument,
	video_signal_type_present: bool,
	video_format:              u8,
	full_range:                bool,
	colour_description_present: bool,
	colour_primaries:          u8,
	transfer_characteristics:  u8,
	colour_matrix:             u8,
	aspect_ratio_present:      bool,
	aspect_ratio:              i32,
	aspect_ratio_width:        u16,
	aspect_ratio_height:       u16,
}

// SEncParamExt
@(private = "file")
Param_Ext :: struct {
	usage_type:                  i32,
	width, height:               i32,
	target_bitrate:              i32,
	rate_control_mode:           i32,
	max_frame_rate:              f32,
	temporal_layers:             i32,
	spatial_layers:              i32,
	layers:                      [MAX_SPATIAL_LAYERS]Spatial_Layer,
	complexity:                  i32,
	intra_period:                u32,
	ref_frames:                  i32,
	sps_pps_id_strategy:         i32,
	prefix_nal:                  bool,
	ssei:                        bool,
	simulcast_avc:               bool,
	padding:                     i32,
	entropy_coding_mode:         i32,
	frame_skip:                  bool,
	max_bitrate:                 i32,
	max_qp:                      i32,
	min_qp:                      i32,
	max_nal_size:                u32,
	long_term_reference:         bool,
	ltr_ref_count:               i32,
	ltr_mark_period:             u32,
	threads:                     u16,
	load_balancing:              bool,
	loop_filter_disable:         i32,
	loop_filter_alpha_c0_offset: i32,
	loop_filter_beta_offset:     i32,
	denoise:                     bool,
	background_detection:        bool,
	adaptive_quant:              bool,
	frame_cropping:              bool,
	scene_change_detect:         bool,
	lossless_link:               bool,
	fix_rc_overshoot:            bool,
	idr_bitrate_ratio:           i32,
	psnr_y, psnr_u, psnr_v:      bool,
}

#assert(size_of(Spatial_Layer) == 200)
#assert(size_of(Param_Ext) == 924)

// The parameters with room after them: GetDefaultParams of a later 2.x that grew the structure writes there, not past it.
@(private = "file")
Param_Room :: struct {
	params: Param_Ext,
	spare:  [1024]u8,
}

// SSourcePicture
@(private = "file")
Source_Picture :: struct {
	colour_format: i32,
	strides:       [4]i32,
	planes:        [4][^]u8,
	width, height: i32,
	timestamp_ms:  i64,
	psnr_y, psnr_u, psnr_v: bool,
}

// SLayerBSInfo
@(private = "file")
Layer_Info :: struct {
	temporal_id, spatial_id, quality_id: u8,
	frame_type:  i32,
	layer_type:  u8,
	sub_seq_id:  i32,
	nal_count:   i32,
	nal_lengths: [^]i32,
	bytes:       [^]u8,
	psnr:        [3]f32,
}

// SFrameBSInfo
@(private = "file")
Frame_Info :: struct {
	layer_count: i32,
	layers:      [MAX_LAYERS_OF_FRAME]Layer_Info,
	frame_type:  i32,
	size:        i32,
	timestamp:   i64,
}

#assert(size_of(Source_Picture) == 80)
#assert(size_of(Layer_Info) == 56)

@(private = "file") SCREEN_CONTENT_REAL_TIME :: 1
@(private = "file") RC_BITRATE_MODE :: 1
@(private = "file") RC_OFF_MODE :: -1
@(private = "file") CONSTANT_ID :: 0
@(private = "file") VIDEO_FORMAT_I420 :: 23
@(private = "file") ENCODER_OPTION_DATAFORMAT :: 0
@(private = "file") FRAME_TYPE_INVALID :: 0
@(private = "file") FRAME_TYPE_SKIP :: 4

@(private = "file") library: Library
@(private = "file") library_once: sync.Once
@(private = "file") library_found: bool

@(private = "file")
library_load :: proc() {
	for name in ([]cstring{"libopenh264.so.7", "libopenh264.so"}) {
		h := posix.dlopen(name, posix.RTLD_LOCAL + {.NOW})
		if h == nil { continue }
		version_of: proc "c" (version: ^Version) = auto_cast posix.dlsym(h, "WelsGetCodecVersionEx")
		library.create = auto_cast posix.dlsym(h, "WelsCreateSVCEncoder")
		library.destroy = auto_cast posix.dlsym(h, "WelsDestroySVCEncoder")
		if version_of == nil || library.create == nil || library.destroy == nil { posix.dlclose(h); continue }
		v: Version
		version_of(&v)
		// (2.4 is the first of soname 7; the plain name may be any version)
		if v.major != 2 || v.minor < 4 { posix.dlclose(h); continue }
		library_found = true
		return
	}
}

@(private)
Openh264_Encoder :: struct {
	encoder: ^^Encoder_Vtable,
	planes:  []u8,          // the I420 picture of the stream's size
	info:    ^Frame_Info,   // 7 KB: not on the stack of every call
	access:  [dynamic]u8,   // the layers of one frame, together
}

@(private)
openh264_probe :: proc() -> bool {
	sync.once_do(&library_once, library_load)
	return library_found
}

@(private)
openh264_open :: proc(e: ^Encoder) -> (^Openh264_Encoder, bool) {
	if !openh264_probe() { return nil, false }
	encoder: ^^Encoder_Vtable
	if library.create(&encoder) != 0 || encoder == nil { return nil, false }
	vt := encoder^
	room := new(Param_Room, context.temp_allocator)
	p := &room.params
	if vt.GetDefaultParams(encoder, p) != 0 { library.destroy(encoder); return nil, false }
	p.usage_type = SCREEN_CONTENT_REAL_TIME
	p.width, p.height = i32(e.stream_width), i32(e.stream_height)
	p.max_frame_rate = f32(e.fps)
	p.temporal_layers, p.spatial_layers = 1, 1
	p.intra_period = 0                  // only the first: encode forces each keyframe (the Encoder's cadence)
	p.ref_frames = 1
	p.sps_pps_id_strategy = CONSTANT_ID // the same ids at every keyframe: a muxer keeps one SPS and one PPS
	p.frame_skip = false                // every frame comes out: the program's timestamps stay whole
	if e.options.bitrate > 0 {
		p.rate_control_mode = RC_BITRATE_MODE
		p.target_bitrate = i32(e.options.bitrate)
		p.max_bitrate = i32(e.options.bitrate * 2)
	} else {
		p.rate_control_mode = RC_OFF_MODE
		p.min_qp, p.max_qp = i32(e.options.qp), i32(e.options.qp)
	}
	l := &p.layers[0]
	l.video_width, l.video_height = p.width, p.height
	l.frame_rate = p.max_frame_rate
	l.spatial_bitrate = p.target_bitrate
	l.max_spatial_bitrate = p.max_bitrate
	l.qp = i32(e.options.qp)
	l.video_signal_type_present = true  // BT.709, limited range: what to_i420 made
	l.video_format = 5
	l.full_range = false
	l.colour_description_present = true
	l.colour_primaries, l.transfer_characteristics, l.colour_matrix = 1, 1, 1
	if vt.InitializeExt(encoder, p) != 0 { library.destroy(encoder); return nil, false }
	format: i32 = VIDEO_FORMAT_I420
	vt.SetOption(encoder, ENCODER_OPTION_DATAFORMAT, &format)

	o := new(Openh264_Encoder, e.allocator)
	o.encoder = encoder
	w, h := e.stream_width, e.stream_height
	o.planes = make([]u8, w * h + 2 * (w / 2) * (h / 2), e.allocator)
	o.info = new(Frame_Info, e.allocator)
	o.access = make([dynamic]u8, e.allocator)
	return o, true
}

@(private)
openh264_encode :: proc(e: ^Encoder, o: ^Openh264_Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error {
	w, h := e.stream_width, e.stream_height
	luma := o.planes[:w * h]
	cb := o.planes[w * h:][:(w / 2) * (h / 2)]
	cr := o.planes[w * h + (w / 2) * (h / 2):]
	to_i420(frame, luma, w, cb, cr, w / 2)
	vt := o.encoder^
	if keyframe && e.frames > 1 { vt.ForceIntraFrame(o.encoder, true) }
	source := Source_Picture{
		colour_format = VIDEO_FORMAT_I420,
		strides       = {i32(w), i32(w / 2), i32(w / 2), 0},
		planes        = {raw_data(luma), raw_data(cb), raw_data(cr), nil},
		width         = i32(w),
		height        = i32(h),
		timestamp_ms  = i64(timestamp / time.Millisecond),
	}
	o.info^ = {}
	if vt.EncodeFrame(o.encoder, &source, o.info) != 0 { return .Failed }
	if o.info.frame_type == FRAME_TYPE_SKIP || o.info.frame_type == FRAME_TYPE_INVALID { return .None }
	clear(&o.access)
	for i in 0 ..< int(o.info.layer_count) {
		layer := &o.info.layers[i]
		size := 0
		for n in 0 ..< int(layer.nal_count) { size += int(layer.nal_lengths[n]) }
		append(&o.access, ..layer.bytes[:size])
	}
	packet_add(e, o.access[:], timestamp)
	return .None
}

@(private)
openh264_close :: proc(e: ^Encoder, o: ^Openh264_Encoder) {
	vt := o.encoder^
	vt.Uninitialize(o.encoder)
	library.destroy(o.encoder)
	delete(o.planes, e.allocator)
	free(o.info, e.allocator)
	delete(o.access)
	free(o, e.allocator)
}
