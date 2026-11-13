#+build !windows
#+build !linux
package tk_http

// The systems with no HTTP client here yet (macOS: the port comes later): every request answers .No_Client and sends
// nothing. Windows (http_windows.odin, WinHTTP) and Linux (http_linux.odin, libcurl) have their own.
request_system :: proc(method, url: string, req: Request, allocator := context.allocator) -> (res: Response, err: Error) {
	return {}, .No_Client
}
