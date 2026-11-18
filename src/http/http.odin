// Package tk_http: HTTP and HTTPS requests with what the system has (Windows: WinHTTP; Linux: libcurl, loaded at run
// time). A request blocks: a program calls it on a thread of its own. Redirects are followed; the body is bounded. (Named
// tk_http: a program may have an `http` package of its own.)
//
//	status, body, err := http.get("https://github.com/o/r/releases/latest/download/x.json", {max_bytes = 16 * 1024})
//
//	form, content_type := http.multipart({{name = "file", file_name = "a.png", content_type = "image/png", value = png}})
//	res, err := http.request("POST", "https://example.com/upload", {headers = {{"Content-Type", content_type}}, body = form})
//
// A body received in chunks (receive.odin), a server's event stream (stream.odin) and WebSockets (socket.odin) block
// the same way, on a worker.
package tk_http

import "core:strconv"
import "core:strings"
import "core:time"
import "../ascii"
import i18n "../i18n"

// One header of a request or of an answer.
Header :: struct {
	name, value: string,
}

// What a request may take. The zero value: MAX_BYTES, TIMEOUT, no User-Agent of its own, no header, no body, no
// compression, no bound of its own on the connection.
Request :: struct {
	max_bytes:  int,             // the largest body of the answer, decoded (0: MAX_BYTES); a larger one is Too_Large
	user_agent: string,          // "": the client's own
	timeout:    time.Duration,   // the whole request, redirects and body included (0: TIMEOUT)
	connect_timeout: time.Duration,   // the name's lookup and the connection, each time one is made (0: only `timeout` bounds them)
	compressed: bool,            // asks for a compressed answer (Accept-Encoding: gzip, deflate) and gives its body decoded; not a WebSocket's
	headers:    []Header,        // sent as given; a Content-Type here says what the body is (none is added)
	body:       []u8,            // nil: none (POST, PUT and PATCH send an empty one)
	// a redirect is the answer, not followed: its status and its Location header are the caller's (a plugin's broker
	// checks each hop's origin before it goes there)
	no_redirects: bool,
}

// The bound of a connection: connect_timeout, else `timeout` (a request's whole time, a stream's silence, a socket's
// handshake), as the system's own bound is minutes long (libcurl: 300 s; WinHTTP: 60 s, and none on the name's lookup).
@(private)
connect_bound :: proc(req: Request) -> time.Duration {
	return req.connect_timeout > 0 ? req.connect_timeout : req.timeout
}

// The last answer, after the redirects. Its fields are allocated with the request's allocator: response_destroy frees them.
Response :: struct {
	status:      int,
	body:        []u8,
	headers:     []Header,   // in the answer's order; they point into header_text
	url:         string,     // the address that answered (the request's, or the last redirect's)
	header_text: string,     // the answer's header lines, as received
}

// The encodings a compressed request asks for (Request.compressed): those both systems' clients decode.
ACCEPT_ENCODING :: "gzip, deflate"

MAX_BYTES     :: 64 << 20
TIMEOUT       :: 5 * time.Minute
MAX_REDIRECTS :: 10

Error :: enum {
	None,
	No_Client,     // Linux: no libcurl on this system
	Bad_Url,       // not http:// or https://, or no host
	Bad_Request,   // a method or a header name that is not a token, a header value with a line break
	Unreachable,   // no answer: the name, the network, TLS, the time limit
	Too_Large,     // the body is larger than max_bytes (a stream: a line or an event; a socket: a message)
	Stopped,       // a stream or a socket: a stop was asked (stop_ask, ws_stop)
	Timed_Out,     // ws_recv: nothing came within its wait; the socket stays open
	Closed,        // a socket: the connection ended (after a .Close message, or cut)
	Refused,       // a WebSocket's server answered without the upgrade (its status is not 101)
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:        return i18n.tr("no error")
	case .No_Client:   return i18n.tr("this system has no HTTP client (libcurl)")
	case .Bad_Url:     return i18n.tr("the address is not an http or https URL")
	case .Bad_Request: return i18n.tr("the request's method or a header is not valid")
	case .Unreachable: return i18n.tr("the server could not be reached")
	case .Too_Large:   return i18n.tr("the answer is larger than expected")
	case .Stopped:     return i18n.tr("the connection was stopped")
	case .Timed_Out:   return i18n.tr("nothing came in time")
	case .Closed:      return i18n.tr("the connection ended")
	case .Refused:     return i18n.tr("the server refused the WebSocket")
	}
	return i18n.tr("unknown error")
}

// The body of `url` and the status of its last answer (after the redirects). A status that is not 2xx is no Error: the
// caller reads it (404: no such file). body is nil when err != .None.
get :: proc(url: string, req := Request{}, allocator := context.allocator) -> (status: int, body: []u8, err: Error) {
	res: Response
	res, err = request("GET", url, req, allocator)
	if err != .None { return 0, nil, err }
	body = res.body
	res.body = nil
	status = res.status
	response_destroy(&res, allocator)
	return
}

// One request: `method` (GET, POST, PUT, PATCH, DELETE, HEAD or any other token) to `url`, with req's headers and body.
// The answer is the last one, after the redirects; a status that is not 2xx is no Error. res is empty when err != .None.
request :: proc(method, url: string, req := Request{}, allocator := context.allocator) -> (res: Response, err: Error) {
	if e := request_check(method, url, req); e != .None { return {}, e }
	r := req
	if r.max_bytes <= 0 { r.max_bytes = MAX_BYTES }
	if r.timeout <= 0 { r.timeout = TIMEOUT }
	res, err = request_system(method, url, r, allocator)
	// (a body given decoded is no longer encoded: its Content-Encoding and the length of the encoded one go, on every
	// system. WinHTTP drops them itself once it decodes; libcurl keeps them)
	if err == .None && r.compressed {
		n := 0
		for h in res.headers {
			if ascii.equal_fold(h.name, "Content-Encoding") || ascii.equal_fold(h.name, "Content-Length") { continue }
			res.headers[n] = h
			n += 1
		}
		res.headers = res.headers[:n]
	}
	return
}

response_destroy :: proc(res: ^Response, allocator := context.allocator) {
	delete(res.body, allocator)
	delete(res.headers, allocator)
	delete(res.url, allocator)
	delete(res.header_text, allocator)
	res^ = {}
}

// The value of the first header named `name` (names compare without case).
header_value :: proc(headers: []Header, name: string) -> (value: string, ok: bool) {
	for h in headers {
		if ascii.equal_fold(h.name, name) { return h.value, true }
	}
	return "", false
}

// The header lines of an answer ("Name: value", CRLF or LF, the status line skipped) as Headers that point into `text`.
// A line that starts with a space continues the one before: obsolete, and dropped.
@(private)
headers_parse :: proc(text: string, allocator := context.allocator) -> []Header {
	out := make([dynamic]Header, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		if l == "" || l[0] == ' ' || l[0] == '\t' || strings.has_prefix(l, "HTTP/") { continue }
		colon := strings.index_byte(l, ':')
		if colon <= 0 { continue }
		append(&out, Header{strings.trim_space(l[:colon]), strings.trim(l[colon + 1:], " \t")})
	}
	return out[:]
}

// RFC 9110's token: what a method and a header name are made of.
@(private)
is_token :: proc(s: string) -> bool {
	if s == "" { return false }
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		case: return false
		}
	}
	return true
}

// The parts of an http or https URL.
Url :: struct {
	secure: bool,
	host:   string,
	port:   int,
	path:   string,   // with its query; "/" at least
}

url_parse :: proc(url: string) -> (u: Url, ok: bool) {
	rest := url
	switch {
	case strings.has_prefix(rest, "https://"): u.secure, u.port, rest = true, 443, rest[len("https://"):]
	case strings.has_prefix(rest, "http://"):  u.port, rest = 80, rest[len("http://"):]
	case: return
	}
	end := strings.index_any(rest, "/?#")
	authority := end < 0 ? rest : rest[:end]
	u.path = end < 0 ? "/" : rest[end:]
	if i := strings.index_byte(u.path, '#'); i >= 0 { u.path = u.path[:i] }
	if strings.has_prefix(u.path, "?") { u.path = strings.concatenate({"/", u.path}, context.temp_allocator) }
	if u.path == "" { u.path = "/" }
	if strings.contains_rune(authority, '@') { return }   // (no credentials in an address)
	u.host = authority
	if i := strings.last_index_byte(authority, ':'); i >= 0 && !strings.has_suffix(authority, "]") {
		port, port_ok := strconv.parse_int(authority[i + 1:], 10)
		if !port_ok || port <= 0 || port > 65535 { return }
		u.host, u.port = authority[:i], port
	}
	return u, u.host != ""
}
