// Package tk_http: one GET over HTTP or HTTPS, with what the system has (Windows: WinHTTP; Linux: libcurl, loaded at run
// time). It blocks: a program calls it on a thread of its own. Redirects are followed; the body is bounded. (Named tk_http:
// a program may have an `http` package of its own.)
//
//	status, body, err := http.get("https://github.com/o/r/releases/latest/download/x.json", {max_bytes = 16 * 1024})
package tk_http

import "core:strconv"
import "core:strings"
import "core:time"

// What a GET may take. The zero value: MAX_BYTES, TIMEOUT, no User-Agent of its own.
Request :: struct {
	max_bytes:  int,             // the largest body (0: MAX_BYTES); a larger one is Too_Large
	user_agent: string,          // "": the client's own
	timeout:    time.Duration,   // the whole request, redirects and body included (0: TIMEOUT)
}

MAX_BYTES     :: 64 << 20
TIMEOUT       :: 5 * time.Minute
MAX_REDIRECTS :: 10

Error :: enum {
	None,
	No_Client,     // Linux: no libcurl on this system
	Bad_Url,       // not http:// or https://, or no host
	Unreachable,   // no answer: the name, the network, TLS, the time limit
	Too_Large,     // the body is larger than max_bytes
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:        return "no error"
	case .No_Client:   return "this system has no HTTP client (libcurl)"
	case .Bad_Url:     return "the address is not an http or https URL"
	case .Unreachable: return "the server could not be reached"
	case .Too_Large:   return "the answer is larger than expected"
	}
	return "unknown error"
}

// The body of `url` and the status of its last answer (after the redirects). A status that is not 2xx is no Error: the
// caller reads it (404: no such file). body is nil when err != .None.
get :: proc(url: string, req := Request{}, allocator := context.allocator) -> (status: int, body: []u8, err: Error) {
	if _, ok := url_parse(url); !ok { return 0, nil, .Bad_Url }
	r := req
	if r.max_bytes <= 0 { r.max_bytes = MAX_BYTES }
	if r.timeout <= 0 { r.timeout = TIMEOUT }
	return get_system(url, r, allocator)
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
