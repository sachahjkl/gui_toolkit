#+build !linux
#+build !windows
package capture

import "base:runtime"
import "core:time"

// (no capture on this system: open says so)
@(private) platform_open :: proc(s: ^Session) -> Error { return .Unsupported }
@(private) platform_close :: proc(s: ^Session) {}
@(private) platform_outputs :: proc(s: ^Session) {}
@(private) platform_windows :: proc(s: ^Session) {}
@(private) platform_windows_have_rects :: proc(s: ^Session) -> bool { return false }
@(private) platform_output :: proc(s: ^Session, id: u64, allocator: runtime.Allocator) -> (Frame, Error) { return {}, .Unsupported }
@(private) platform_window :: proc(s: ^Session, id: u64, allocator: runtime.Allocator) -> (Frame, Error) { return {}, .Unsupported }
@(private) platform_desktop :: proc(s: ^Session, allocator: runtime.Allocator) -> (Frame, Error) { return {}, .Unsupported }
@(private) platform_stream_open :: proc(s: ^Session, st: ^Stream) -> Error { return .Unsupported }
@(private) platform_stream_next :: proc(st: ^Stream, timeout: time.Duration) -> (Stream_Frame, bool, Error) { return {}, false, .Unsupported }
@(private) platform_stream_close :: proc(st: ^Stream) {}
@(private) platform_pointer :: proc(s: ^Session) -> ([2]i32, u64, bool) { return {}, 0, false }
