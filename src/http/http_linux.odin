#+build linux
package tk_http

// libcurl, by dlopen: a program that never asks for a URL starts on a system without it.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "../ascii"

@(private = "file")
Curl :: struct {
	easy_init:    proc "c" () -> rawptr,
	easy_setopt:  proc "c" (h: rawptr, option: i32, #c_vararg args: ..any) -> i32,
	easy_perform: proc "c" (h: rawptr) -> i32,
	easy_getinfo: proc "c" (h: rawptr, info: i32, #c_vararg args: ..any) -> i32,
	easy_cleanup: proc "c" (h: rawptr),
	global_init:  proc "c" (flags: i64) -> i32,
	slist_append:   proc "c" (list: rawptr, s: cstring) -> rawptr,
	slist_free_all: proc "c" (list: rawptr),
}

@(private = "file") curl_lib: Curl
@(private = "file") curl_once: sync.Once
@(private = "file") curl_found: bool

@(private = "file") CURLOPT_WRITEDATA          :: 10001
@(private = "file") CURLOPT_URL                :: 10002
@(private = "file") CURLOPT_POSTFIELDS         :: 10015
@(private = "file") CURLOPT_USERAGENT          :: 10018
@(private = "file") CURLOPT_HTTPHEADER         :: 10023
@(private = "file") CURLOPT_HEADERDATA         :: 10029
@(private = "file") CURLOPT_CUSTOMREQUEST      :: 10036
@(private = "file") CURLOPT_WRITEFUNCTION      :: 20011
@(private = "file") CURLOPT_HEADERFUNCTION     :: 20079
@(private = "file") CURLOPT_POSTFIELDSIZE_LARGE :: 30120
@(private = "file") CURLOPT_NOBODY             :: 44
@(private = "file") CURLOPT_FOLLOWLOCATION     :: 52
@(private = "file") CURLOPT_MAXREDIRS          :: 68
@(private = "file") CURLOPT_NOSIGNAL           :: 99
@(private = "file") CURLOPT_TIMEOUT_MS         :: 155
@(private = "file") CURLOPT_PROTOCOLS_STR      :: 10318
@(private = "file") CURLOPT_REDIR_PROTOCOLS_STR :: 10319
@(private = "file") CURLINFO_EFFECTIVE_URL     :: 0x100001
@(private = "file") CURLINFO_RESPONSE_CODE     :: 0x200002
@(private = "file") CURL_GLOBAL_DEFAULT        :: 3
@(private = "file") CURLE_WRITE_ERROR          :: 23
@(private = "file") CURLFOLLOW_ALL             :: 1
@(private = "file") CURLFOLLOW_OBEYCODE        :: 2

// The header lines of the answers kept at most: no real answer comes near it.
@(private = "file") MAX_HEADER_BYTES :: 1 << 20

@(private = "file")
curl_load :: proc() {
	for name in ([]cstring{"libcurl.so.4", "libcurl.so", "libcurl-gnutls.so.4"}) {
		h := posix.dlopen(name, posix.RTLD_LOCAL + {.NOW})
		if h == nil { continue }
		c := &curl_lib
		c.easy_init = auto_cast posix.dlsym(h, "curl_easy_init")
		c.easy_setopt = auto_cast posix.dlsym(h, "curl_easy_setopt")
		c.easy_perform = auto_cast posix.dlsym(h, "curl_easy_perform")
		c.easy_getinfo = auto_cast posix.dlsym(h, "curl_easy_getinfo")
		c.easy_cleanup = auto_cast posix.dlsym(h, "curl_easy_cleanup")
		c.global_init = auto_cast posix.dlsym(h, "curl_global_init")
		c.slist_append = auto_cast posix.dlsym(h, "curl_slist_append")
		c.slist_free_all = auto_cast posix.dlsym(h, "curl_slist_free_all")
		if c.easy_init == nil || c.easy_setopt == nil || c.easy_perform == nil || c.easy_getinfo == nil || c.easy_cleanup == nil || c.global_init == nil || c.slist_append == nil || c.slist_free_all == nil {
			posix.dlclose(h)
			continue
		}
		// (once for the process, before any easy handle: libcurl's own initialisation is not for two threads at once)
		curl_found = c.global_init(CURL_GLOBAL_DEFAULT) == 0
		return
	}
}

@(private = "file")
Sink :: struct {
	data:      [dynamic]u8,
	max_bytes: int,
	too_large: bool,
	head:      [dynamic]u8,   // the header lines of the last answer
}

@(private = "file")
on_write :: proc "c" (ptr: [^]u8, size, count: uint, user: rawptr) -> uint {
	context = runtime.default_context()
	s := (^Sink)(user)
	n := int(size * count)
	if len(s.data) + n > s.max_bytes { s.too_large = true; return 0 }   // (fewer bytes than given: libcurl stops)
	append(&s.data, ..ptr[:n])
	return uint(n)
}

// One header line at a time, of every answer (a redirect's, a proxy's): a status line starts the answer kept.
@(private = "file")
on_header :: proc "c" (ptr: [^]u8, size, count: uint, user: rawptr) -> uint {
	context = runtime.default_context()
	s := (^Sink)(user)
	n := int(size * count)
	line := string(ptr[:n])
	if strings.has_prefix(line, "HTTP/") { clear(&s.head) }
	if len(s.head) + n > MAX_HEADER_BYTES { s.too_large = true; return 0 }
	append(&s.head, ..ptr[:n])
	return uint(n)
}

request_system :: proc(method, url: string, req: Request, allocator := context.allocator) -> (res: Response, err: Error) {
	sync.once_do(&curl_once, curl_load)
	if !curl_found { return {}, .No_Client }
	c := &curl_lib
	h := c.easy_init()
	if h == nil { return {}, .No_Client }
	defer c.easy_cleanup(h)
	sink := Sink{data = make([dynamic]u8, allocator), max_bytes = req.max_bytes, head = make([dynamic]u8, context.temp_allocator)}
	c.easy_setopt(h, CURLOPT_URL, strings.clone_to_cstring(url, context.temp_allocator))
	c.easy_setopt(h, CURLOPT_MAXREDIRS, i64(MAX_REDIRECTS))
	c.easy_setopt(h, CURLOPT_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_REDIR_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_NOSIGNAL, i64(1))   // (a thread of its own: no SIGALRM for the name lookup's time limit)
	c.easy_setopt(h, CURLOPT_TIMEOUT_MS, i64(req.timeout / 1_000_000))
	c.easy_setopt(h, CURLOPT_WRITEFUNCTION, on_write)
	c.easy_setopt(h, CURLOPT_WRITEDATA, rawptr(&sink))
	c.easy_setopt(h, CURLOPT_HEADERFUNCTION, on_header)
	c.easy_setopt(h, CURLOPT_HEADERDATA, rawptr(&sink))
	if req.user_agent != "" { c.easy_setopt(h, CURLOPT_USERAGENT, strings.clone_to_cstring(req.user_agent, context.temp_allocator)) }

	has_body := req.body != nil || method == "POST" || method == "PUT" || method == "PATCH"
	if has_body {
		c.easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE, i64(len(req.body)))
		// (libcurl reads the bytes during perform, without a copy; an empty body still needs a pointer)
		c.easy_setopt(h, CURLOPT_POSTFIELDS, len(req.body) > 0 ? rawptr(raw_data(req.body)) : transmute(rawptr)cstring(""))
	}
	custom := false
	switch {
	case method == "HEAD":              c.easy_setopt(h, CURLOPT_NOBODY, i64(1))
	case method == "GET" && !has_body:
	case method == "POST" && has_body:
	case:
		c.easy_setopt(h, CURLOPT_CUSTOMREQUEST, strings.clone_to_cstring(method, context.temp_allocator))
		custom = true
	}
	// A custom method is kept on every redirect unless told otherwise: OBEYCODE makes a 303 a GET, as browsers do. (Older
	// libcurl reads any value but 0 as "follow".)
	c.easy_setopt(h, CURLOPT_FOLLOWLOCATION, i64(custom ? CURLFOLLOW_OBEYCODE : CURLFOLLOW_ALL))

	list: rawptr
	defer if list != nil { c.slist_free_all(list) }
	content_type := false
	for hd in req.headers {
		if ascii.equal_fold(hd.name, "Content-Type") { content_type = true }
		next := c.slist_append(list, strings.clone_to_cstring(strings.concatenate({hd.name, ": ", hd.value}, context.temp_allocator), context.temp_allocator))
		if next == nil { delete(sink.data); return {}, .Unreachable }
		list = next
	}
	// libcurl adds what nobody asked for: a form's Content-Type to a body, and "Expect: 100-continue" to a large one (a
	// second's wait with a server that does not answer it). "Name:" with no value removes a header of libcurl's.
	if has_body && !content_type {
		if next := c.slist_append(list, "Content-Type:"); next != nil { list = next }
	}
	if has_body {
		if next := c.slist_append(list, "Expect:"); next != nil { list = next }
	}
	if list != nil { c.easy_setopt(h, CURLOPT_HTTPHEADER, list) }

	code := c.easy_perform(h)
	if code != 0 {
		delete(sink.data)
		return {}, sink.too_large && code == CURLE_WRITE_ERROR ? .Too_Large : .Unreachable
	}
	answer: i64
	c.easy_getinfo(h, CURLINFO_RESPONSE_CODE, &answer)
	effective: cstring
	c.easy_getinfo(h, CURLINFO_EFFECTIVE_URL, &effective)
	res.status = int(answer)
	res.body = sink.data[:]
	res.url = strings.clone(effective != nil ? string(effective) : url, allocator)
	res.header_text = strings.clone(string(sink.head[:]), allocator)
	res.headers = headers_parse(res.header_text, allocator)
	return res, .None
}
