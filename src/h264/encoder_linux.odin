#+build linux
package tk_h264

// Linux: NVENC (NVIDIA's driver) first, then VA-API (the GPU through libva), then openh264 (software), as the options'
// preference allows. A backend that fails to open gives way to the next one.

import "core:time"

@(private)
System_Encoder :: union {
	^Nvenc_Encoder,
	^Vaapi_Encoder,
	^Openh264_Encoder,
}

@(private)
system_available :: proc() -> Backends {
	found: Backends
	if nvenc_probe() { found += {.Nvenc} }
	if vaapi_probe() { found += {.Vaapi} }
	if openh264_probe() { found += {.Openh264} }
	return found
}

@(private)
system_open :: proc(e: ^Encoder) -> Error {
	if e.options.backend != .Software {
		if n, ok := nvenc_open(e); ok {
			e.system, e.backend = n, .Nvenc
			return .None
		}
		if v, ok := vaapi_open(e); ok {
			e.system, e.backend = v, .Vaapi
			return .None
		}
	}
	if e.options.backend != .Hardware {
		if o, ok := openh264_open(e); ok {
			e.system, e.backend = o, .Openh264
			return .None
		}
	}
	return .Unavailable
}

@(private)
system_encode :: proc(e: ^Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error {
	switch s in e.system {
	case ^Nvenc_Encoder:    return nvenc_encode(e, s, frame, timestamp, keyframe)
	case ^Vaapi_Encoder:    return vaapi_encode(e, s, frame, timestamp, keyframe)
	case ^Openh264_Encoder: return openh264_encode(e, s, frame, timestamp, keyframe)
	}
	return .Failed
}

// (each encodes a frame before encode returns: nothing is held back; NVENC's end of stream only closes its session's)
@(private)
system_flush :: proc(e: ^Encoder) -> Error {
	if s, ok := e.system.(^Nvenc_Encoder); ok { return nvenc_flush(e, s) }
	return .None
}

@(private)
system_close :: proc(e: ^Encoder) {
	switch s in e.system {
	case ^Nvenc_Encoder:    nvenc_close(e, s)
	case ^Vaapi_Encoder:    vaapi_close(e, s)
	case ^Openh264_Encoder: openh264_close(e, s)
	}
	e.system = nil
}
