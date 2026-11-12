#+build windows
package tk_http

// WinHTTP: the system's, with its proxy settings and its certificates. Redirects are followed by it (never https to http;
// a POST becomes a GET on 301, 302 and 303, as browsers do).

import "core:strings"
import win "core:sys/windows"

foreign import winhttp "system:Winhttp.lib"

@(private = "file") HINTERNET :: rawptr

@(default_calling_convention = "system", private = "file")
foreign winhttp {
	WinHttpOpen :: proc(agent: win.LPCWSTR, access: u32, proxy, bypass: win.LPCWSTR, flags: u32) -> HINTERNET ---
	WinHttpSetTimeouts :: proc(h: HINTERNET, resolve, connect, send, receive: i32) -> win.BOOL ---
	WinHttpConnect :: proc(session: HINTERNET, host: win.LPCWSTR, port: u16, reserved: u32) -> HINTERNET ---
	WinHttpOpenRequest :: proc(connect: HINTERNET, verb, object, version, referrer: win.LPCWSTR, accept: ^win.LPCWSTR, flags: u32) -> HINTERNET ---
	WinHttpAddRequestHeaders :: proc(h: HINTERNET, headers: win.LPCWSTR, length: u32, modifiers: u32) -> win.BOOL ---
	WinHttpSendRequest :: proc(h: HINTERNET, headers: win.LPCWSTR, headers_length: u32, optional: rawptr, optional_length, total_length: u32, ctx: uintptr) -> win.BOOL ---
	WinHttpReceiveResponse :: proc(h: HINTERNET, reserved: rawptr) -> win.BOOL ---
	WinHttpQueryHeaders :: proc(h: HINTERNET, level: u32, name: win.LPCWSTR, buffer: rawptr, length: ^u32, index: ^u32) -> win.BOOL ---
	WinHttpQueryOption :: proc(h: HINTERNET, option: u32, buffer: rawptr, length: ^u32) -> win.BOOL ---
	WinHttpQueryDataAvailable :: proc(h: HINTERNET, available: ^u32) -> win.BOOL ---
	WinHttpReadData :: proc(h: HINTERNET, buffer: rawptr, to_read: u32, read: ^u32) -> win.BOOL ---
	WinHttpCloseHandle :: proc(h: HINTERNET) -> win.BOOL ---
}

@(private = "file") WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
@(private = "file") WINHTTP_FLAG_SECURE                 :: 0x0080_0000
@(private = "file") WINHTTP_QUERY_STATUS_CODE           :: 19
@(private = "file") WINHTTP_QUERY_RAW_HEADERS_CRLF      :: 22
@(private = "file") WINHTTP_QUERY_FLAG_NUMBER           :: 0x2000_0000
@(private = "file") WINHTTP_OPTION_URL                  :: 34
@(private = "file") WINHTTP_ADDREQ_FLAG_ADD             :: 0x2000_0000
@(private = "file") WINHTTP_ADDREQ_FLAG_REPLACE         :: 0x8000_0000
@(private = "file") WINHTTP_NO_LENGTH                   :: 0xFFFF_FFFF   // (the header's string ends with a 0)

request_system :: proc(method, url: string, req: Request, allocator := context.allocator) -> (res: Response, err: Error) {
	u, _ := url_parse(url)
	if u64(len(req.body)) > 0xFFFF_FFFF { return {}, .Too_Large }   // (WinHTTP counts a body in 32 bits)
	agent := req.user_agent != "" ? req.user_agent : "tk_http"
	session := WinHttpOpen(win.utf8_to_wstring(agent), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
	if session == nil { return {}, .Unreachable }
	defer WinHttpCloseHandle(session)
	ms := i32(min(req.timeout / 1_000_000, 0x7FFF_FFFF))
	WinHttpSetTimeouts(session, ms, ms, ms, ms)
	conn := WinHttpConnect(session, win.utf8_to_wstring(u.host), u16(u.port), 0)
	if conn == nil { return {}, .Unreachable }
	defer WinHttpCloseHandle(conn)
	h := WinHttpOpenRequest(conn, win.utf8_to_wstring(method), win.utf8_to_wstring(u.path), nil, nil, nil, u.secure ? WINHTTP_FLAG_SECURE : 0)
	if h == nil { return {}, .Unreachable }
	defer WinHttpCloseHandle(h)
	for hd in req.headers {
		// (ADD | REPLACE: the caller's value wins over WinHTTP's own, the User-Agent included)
		line := win.utf8_to_wstring(strings.concatenate({hd.name, ": ", hd.value}, context.temp_allocator))
		if !WinHttpAddRequestHeaders(h, line, WINHTTP_NO_LENGTH, WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE) { return {}, .Bad_Request }
	}
	body: rawptr = len(req.body) > 0 ? rawptr(raw_data(req.body)) : nil
	if !WinHttpSendRequest(h, nil, 0, body, u32(len(req.body)), u32(len(req.body)), 0) || !WinHttpReceiveResponse(h, nil) { return {}, .Unreachable }
	code: u32
	size := u32(size_of(code))
	if !WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &size, nil) { return {}, .Unreachable }
	data := make([dynamic]u8, allocator)
	if method != "HEAD" {
		for {
			available: u32
			if !WinHttpQueryDataAvailable(h, &available) { delete(data); return {}, .Unreachable }
			if available == 0 { break }
			if len(data) + int(available) > req.max_bytes { delete(data); return {}, .Too_Large }
			at := len(data)
			resize(&data, at + int(available))
			read: u32
			if !WinHttpReadData(h, &data[at], available, &read) { delete(data); return {}, .Unreachable }
			resize(&data, at + int(read))
		}
	}
	res.status = int(code)
	res.body = data[:]
	res.header_text = query_text(h, WINHTTP_QUERY_RAW_HEADERS_CRLF, false, allocator)
	res.headers = headers_parse(res.header_text, allocator)
	res.url = query_text(h, WINHTTP_OPTION_URL, true, allocator)
	if res.url == "" { res.url = strings.clone(url, allocator) }
	return res, .None
}

// A text WinHTTP gives in UTF-16, asked twice: once for its size in bytes, once for it. option: WinHttpQueryOption's,
// else a header query's.
@(private = "file")
query_text :: proc(h: HINTERNET, what: u32, option: bool, allocator := context.allocator) -> string {
	size: u32
	if option { WinHttpQueryOption(h, what, nil, &size) } else { WinHttpQueryHeaders(h, what, nil, nil, &size, nil) }
	if size == 0 { return "" }
	buf := make([]u16, size / 2 + 1, context.temp_allocator)
	got := u32(len(buf) * 2)
	ok := option ? WinHttpQueryOption(h, what, raw_data(buf), &got) : WinHttpQueryHeaders(h, what, nil, raw_data(buf), &got, nil)
	if !ok { return "" }
	n := min(int(got / 2), len(buf))
	for n > 0 && buf[n - 1] == 0 { n -= 1 }
	text, _ := win.utf16_to_utf8(buf[:n], allocator)
	return text
}
