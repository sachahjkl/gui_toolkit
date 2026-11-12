#+build windows
package tk_h264

// Windows: NVENC (NVIDIA's driver) first, then Media Foundation's encoders, the GPU's first, then Microsoft's software
// one, as the preference allows. A backend that fails to open gives way to the next one.

import "core:time"

@(private)
System_Encoder :: union {
	^Nvenc_Encoder,
	^Mf_Encoder,
}

@(private)
system_available :: proc() -> Backends {
	found := mf_available()
	if nvenc_probe() { found += {.Nvenc} }
	return found
}

@(private)
system_open :: proc(e: ^Encoder) -> Error {
	if e.options.backend != .Software {
		if n, ok := nvenc_open(e); ok {
			e.system, e.backend = n, .Nvenc
			return .None
		}
	}
	m, backend, ok := mf_open(e)
	if !ok { return .Unavailable }
	e.system, e.backend = m, backend
	return .None
}

@(private)
system_encode :: proc(e: ^Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error {
	switch s in e.system {
	case ^Nvenc_Encoder: return nvenc_encode(e, s, frame, timestamp, keyframe)
	case ^Mf_Encoder:    return mf_encode(e, s, frame, timestamp, keyframe)
	}
	return .Failed
}

@(private)
system_flush :: proc(e: ^Encoder) -> Error {
	switch s in e.system {
	case ^Nvenc_Encoder: return nvenc_flush(e, s)
	case ^Mf_Encoder:    return mf_flush(e, s)
	}
	return .None
}

@(private)
system_close :: proc(e: ^Encoder) {
	switch s in e.system {
	case ^Nvenc_Encoder: nvenc_close(e, s)
	case ^Mf_Encoder:    mf_close(e, s)
	}
	e.system = nil
}
