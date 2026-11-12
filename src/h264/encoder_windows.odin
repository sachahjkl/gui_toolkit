#+build windows
package tk_h264

// Windows: Media Foundation's encoders, the GPU's first, then Microsoft's software one, as the preference allows.

import "core:time"

@(private) System_Encoder :: ^Mf_Encoder

@(private)
system_available :: proc() -> Backends { return mf_available() }

@(private)
system_open :: proc(e: ^Encoder) -> Error {
	m, backend, ok := mf_open(e)
	if !ok { return .Unavailable }
	e.system, e.backend = m, backend
	return .None
}

@(private)
system_encode :: proc(e: ^Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error {
	if e.system == nil { return .Failed }
	return mf_encode(e, e.system, frame, timestamp, keyframe)
}

@(private)
system_flush :: proc(e: ^Encoder) -> Error {
	if e.system == nil { return .None }
	return mf_flush(e, e.system)
}

@(private)
system_close :: proc(e: ^Encoder) {
	if e.system != nil { mf_close(e, e.system) }
	e.system = nil
}
