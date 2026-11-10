#+build windows
package tk_http

// WinHTTP: the system's, with its proxy settings and its certificates. Redirects are followed by it (never https to http).

import win "core:sys/windows"

foreign import winhttp "system:Winhttp.lib"

@(private = "file") HINTERNET :: rawptr

@(default_calling_convention = "system", private = "file")
foreign winhttp {
	WinHttpOpen :: proc(agent: win.LPCWSTR, access: u32, proxy, bypass: win.LPCWSTR, flags: u32) -> HINTERNET ---
	WinHttpSetTimeouts :: proc(h: HINTERNET, resolve, connect, send, receive: i32) -> win.BOOL ---
	WinHttpConnect :: proc(session: HINTERNET, host: win.LPCWSTR, port: u16, reserved: u32) -> HINTERNET ---
	WinHttpOpenRequest :: proc(connect: HINTERNET, verb, object, version, referrer: win.LPCWSTR, accept: ^win.LPCWSTR, flags: u32) -> HINTERNET ---
	WinHttpSendRequest :: proc(h: HINTERNET, headers: win.LPCWSTR, headers_length: u32, optional: rawptr, optional_length, total_length: u32, ctx: uintptr) -> win.BOOL ---
	WinHttpReceiveResponse :: proc(h: HINTERNET, reserved: rawptr) -> win.BOOL ---
	WinHttpQueryHeaders :: proc(h: HINTERNET, level: u32, name: win.LPCWSTR, buffer: rawptr, length: ^u32, index: ^u32) -> win.BOOL ---
	WinHttpQueryDataAvailable :: proc(h: HINTERNET, available: ^u32) -> win.BOOL ---
	WinHttpReadData :: proc(h: HINTERNET, buffer: rawptr, to_read: u32, read: ^u32) -> win.BOOL ---
	WinHttpCloseHandle :: proc(h: HINTERNET) -> win.BOOL ---
}

@(private = "file") WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
@(private = "file") WINHTTP_FLAG_SECURE                 :: 0x0080_0000
@(private = "file") WINHTTP_QUERY_STATUS_CODE           :: 19
@(private = "file") WINHTTP_QUERY_FLAG_NUMBER           :: 0x2000_0000

get_system :: proc(url: string, req: Request, allocator := context.allocator) -> (status: int, body: []u8, err: Error) {
	u, _ := url_parse(url)
	agent := req.user_agent != "" ? req.user_agent : "tk_http"
	session := WinHttpOpen(win.utf8_to_wstring(agent), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
	if session == nil { return 0, nil, .Unreachable }
	defer WinHttpCloseHandle(session)
	ms := i32(min(req.timeout / 1_000_000, 0x7FFF_FFFF))
	WinHttpSetTimeouts(session, ms, ms, ms, ms)
	conn := WinHttpConnect(session, win.utf8_to_wstring(u.host), u16(u.port), 0)
	if conn == nil { return 0, nil, .Unreachable }
	defer WinHttpCloseHandle(conn)
	h := WinHttpOpenRequest(conn, win.L("GET"), win.utf8_to_wstring(u.path), nil, nil, nil, u.secure ? WINHTTP_FLAG_SECURE : 0)
	if h == nil { return 0, nil, .Unreachable }
	defer WinHttpCloseHandle(h)
	if !WinHttpSendRequest(h, nil, 0, nil, 0, 0, 0) || !WinHttpReceiveResponse(h, nil) { return 0, nil, .Unreachable }
	code: u32
	size := u32(size_of(code))
	if !WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &size, nil) { return 0, nil, .Unreachable }
	data := make([dynamic]u8, allocator)
	for {
		available: u32
		if !WinHttpQueryDataAvailable(h, &available) { delete(data); return 0, nil, .Unreachable }
		if available == 0 { break }
		if len(data) + int(available) > req.max_bytes { delete(data); return 0, nil, .Too_Large }
		at := len(data)
		resize(&data, at + int(available))
		read: u32
		if !WinHttpReadData(h, &data[at], available, &read) { delete(data); return 0, nil, .Unreachable }
		resize(&data, at + int(read))
	}
	return int(code), data[:], .None
}
