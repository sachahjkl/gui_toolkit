#+build !windows
#+build !linux
package tk_http

import "core:time"

// The systems with no HTTP client here yet (macOS: the port comes later): every request, stream and socket answers
// .No_Client and sends nothing. Windows (WinHTTP) and Linux (libcurl) have their own.
request_system :: proc(method, url: string, req: Request, allocator := context.allocator) -> (res: Response, err: Error) {
	return {}, .No_Client
}

receive_system :: proc(method, url: string, req: Request, sink: ^Receive_Sink, stop: ^Stop, allocator := context.allocator) -> (res: Response, err: Error) {
	return {}, .No_Client
}

events_system :: proc(url: string, req: Request, parser: ^Event_Parser, on_event: Event_Proc, user: rawptr, stop: ^Stop) -> (status: int, err: Error) {
	return 0, .No_Client
}

Socket :: struct {}

ws_connect_system :: proc(url, http_url: string, req: Request) -> (^Socket, Error) { return nil, .No_Client }
ws_recv_system :: proc(s: ^Socket, wait: time.Duration) -> (Message, Error) { return {}, .No_Client }
ws_send_system :: proc(s: ^Socket, data: []u8, kind: Message_Kind) -> Error { return .No_Client }
ws_stop_system :: proc(s: ^Socket) {}
ws_close_system :: proc(s: ^Socket) {}
