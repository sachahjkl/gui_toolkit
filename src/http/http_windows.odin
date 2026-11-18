#+build windows
package tk_http

// WinHTTP: the system's, with its proxy settings and its certificates. Redirects are followed by it (never https to http;
// a POST becomes a GET on 301, 302 and 303, as browsers do).

import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"

foreign import winhttp "system:Winhttp.lib"

@(private) HINTERNET :: rawptr

@(default_calling_convention = "system", private)
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

@(private) WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
@(private) WINHTTP_FLAG_SECURE                 :: 0x0080_0000
@(private) WINHTTP_QUERY_STATUS_CODE           :: 19
@(private) WINHTTP_QUERY_RAW_HEADERS_CRLF      :: 22
@(private) WINHTTP_QUERY_FLAG_NUMBER           :: 0x2000_0000
@(private) WINHTTP_OPTION_URL                  :: 34
@(private) WINHTTP_ADDREQ_FLAG_ADD             :: 0x2000_0000
@(private) WINHTTP_ADDREQ_FLAG_REPLACE         :: 0x8000_0000
@(private) WINHTTP_NO_LENGTH                   :: 0xFFFF_FFFF   // (the header's string ends with a 0)
@(private) WINHTTP_OPTION_DECOMPRESSION        :: 118
@(private) WINHTTP_DECOMPRESSION_FLAG_GZIP     :: 0x1
@(private) WINHTTP_DECOMPRESSION_FLAG_DEFLATE  :: 0x2
@(private) WINHTTP_OPTION_REDIRECT_POLICY       :: 88
@(private) WINHTTP_OPTION_REDIRECT_POLICY_NEVER :: 0

// The requests' session (src/md/features/http-connections.md): WinHTTP pools a session's connections by server, so one
// session for the process reuses them. Never closed: the process's end takes it.
@(private = "file") requests_session: HINTERNET
@(private = "file") requests_once: sync.Once

request_system :: proc(method, url: string, req: Request, allocator := context.allocator) -> (res: Response, err: Error) {
	u, _ := url_parse(url)
	if u64(len(req.body)) > 0xFFFF_FFFF { return {}, .Too_Large }   // (WinHTTP counts a body in 32 bits)
	sync.once_do(&requests_once, proc() {
		requests_session = WinHttpOpen(win.utf8_to_wstring("tk_http"), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
	})
	if requests_session == nil { return {}, .Unreachable }
	conn := WinHttpConnect(requests_session, win.utf8_to_wstring(u.host), u16(u.port), 0)
	if conn == nil { return {}, .Unreachable }
	defer WinHttpCloseHandle(conn)
	h := WinHttpOpenRequest(conn, win.utf8_to_wstring(method), win.utf8_to_wstring(u.path), nil, nil, nil, u.secure ? WINHTTP_FLAG_SECURE : 0)
	if h == nil { return {}, .Unreachable }
	defer WinHttpCloseHandle(h)
	// (a request's own: the session is every request's)
	winhttp_timeouts(h, req)
	winhttp_compression(h, req)
	if req.no_redirects {
		policy := u32(WINHTTP_OPTION_REDIRECT_POLICY_NEVER)
		WinHttpSetOption(h, WINHTTP_OPTION_REDIRECT_POLICY, &policy, size_of(policy))
	}
	if req.user_agent != "" {
		line := win.utf8_to_wstring(strings.concatenate({"User-Agent: ", req.user_agent}, context.temp_allocator))
		if !WinHttpAddRequestHeaders(h, line, WINHTTP_NO_LENGTH, WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE) { return {}, .Bad_Request }
	}
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

// The time limits of a session or of one request (`h`): the name's lookup and the connection connect_bound's, the sends
// and the receives `timeout`'s. (WinHTTP's own lookup has no limit: an unanswered DNS server held a request for ever)
@(private)
winhttp_timeouts :: proc(h: HINTERNET, req: Request) {
	ms := i32(min(req.timeout / time.Millisecond, 0x7FFF_FFFF))
	connect := i32(min(connect_bound(req) / time.Millisecond, 0x7FFF_FFFF))
	WinHttpSetTimeouts(h, connect, connect, ms, ms)
}

// A compressed answer asked (Request.compressed): WinHTTP sends Accept-Encoding and decodes the body as it is read. A
// system before Windows 8.1 has no such option: the request then asks for no compression and gets none.
@(private)
winhttp_compression :: proc(request: HINTERNET, req: Request) {
	if !req.compressed { return }
	flags := u32(WINHTTP_DECOMPRESSION_FLAG_GZIP | WINHTTP_DECOMPRESSION_FLAG_DEFLATE)
	WinHttpSetOption(request, WINHTTP_OPTION_DECOMPRESSION, &flags, size_of(flags))
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
