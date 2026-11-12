#+build linux
package tk_h264

// Linux: VA-API (the GPU) first, then openh264 (software), as the options' preference allows.

import "core:time"

@(private)
System_Encoder :: union {
	^Vaapi_Encoder,
	^Openh264_Encoder,
}

@(private)
system_available :: proc() -> Backends {
	found: Backends
	if vaapi_probe() { found += {.Vaapi} }
	if openh264_probe() { found += {.Openh264} }
	return found
}

@(private)
system_open :: proc(e: ^Encoder) -> Error {
	if e.options.backend != .Software {
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
	case ^Vaapi_Encoder:    return vaapi_encode(e, s, frame, timestamp, keyframe)
	case ^Openh264_Encoder: return openh264_encode(e, s, frame, timestamp, keyframe)
	}
	return .Failed
}

// (both encode a frame before encode returns: nothing is held back)
@(private)
system_flush :: proc(e: ^Encoder) -> Error { return .None }

@(private)
system_close :: proc(e: ^Encoder) {
	switch s in e.system {
	case ^Vaapi_Encoder:    vaapi_close(e, s)
	case ^Openh264_Encoder: openh264_close(e, s)
	}
	e.system = nil
}
