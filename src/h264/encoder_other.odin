#+build !linux
#+build !windows
package tk_h264

import "core:time"

// (no encoder on this system: open says so)
@(private) System_Encoder :: struct {}
@(private) system_available :: proc() -> Backends { return {} }
@(private) system_open :: proc(e: ^Encoder) -> Error { return .Unavailable }
@(private) system_encode :: proc(e: ^Encoder, frame: Frame, timestamp: time.Duration, keyframe: bool) -> Error { return .Failed }
@(private) system_flush :: proc(e: ^Encoder) -> Error { return .None }
@(private) system_close :: proc(e: ^Encoder) {}
