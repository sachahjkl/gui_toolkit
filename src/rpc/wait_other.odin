#+build !linux
#+build !windows
package tk_rpc

// Elsewhere no peer starts (rpc.md): start ends at once with Not_Started.

import "core:os"
import "core:time"

@(private) Waker :: struct {}
@(private) Wait_Result :: enum u8 { Ended, Woken, Timed_Out }
@(private) waker_make :: proc(w: ^Waker) -> bool { return false }
@(private) waker_destroy :: proc(w: ^Waker) {}
@(private) waker_wake :: proc(w: ^Waker) {}
@(private) waker_wait :: proc(w: ^Waker, handle: uintptr, timeout: time.Duration) -> Wait_Result { return .Ended }
@(private) pipes_stop :: proc(w: ^Waker) {}
@(private) writer_prepare :: proc(f: ^os.File) {}
@(private) write_pipe :: proc(w: ^Waker, f: ^os.File, data: []u8) -> bool { return false }
@(private) read_pipe :: proc(w: ^Waker, f: ^os.File, buf: []u8) -> int { return 0 }
