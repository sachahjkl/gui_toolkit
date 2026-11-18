#+build linux
package tk_http

// libcurl, by dlopen: a program that never asks for a URL starts on a system without it.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "../ascii"

@(private)
Curl :: struct {
	easy_init:    proc "c" () -> rawptr,
	easy_setopt:  proc "c" (h: rawptr, option: i32, #c_vararg args: ..any) -> i32,
	easy_perform: proc "c" (h: rawptr) -> i32,
	easy_getinfo: proc "c" (h: rawptr, info: i32, #c_vararg args: ..any) -> i32,
	easy_cleanup: proc "c" (h: rawptr),
	easy_reset:   proc "c" (h: rawptr),   // the options cleared, the connections kept (the pool's; 7.12.1)
	global_init:  proc "c" (flags: i64) -> i32,
	slist_append:   proc "c" (list: rawptr, s: cstring) -> rawptr,
	slist_free_all: proc "c" (list: rawptr),
	// a raw connection's bytes (CONNECT_ONLY = 1), the WebSocket's (socket_linux.odin); since 7.18.1
	easy_send: proc "c" (h: rawptr, buffer: rawptr, buflen: uint, sent: ^uint) -> i32,
	easy_recv: proc "c" (h: rawptr, buffer: rawptr, buflen: uint, received: ^uint) -> i32,
}

@(private) curl_lib: Curl
@(private) curl_once: sync.Once
@(private) curl_found: bool

@(private) CURLOPT_WRITEDATA          :: 10001
@(private) CURLOPT_URL                :: 10002
@(private) CURLOPT_POSTFIELDS         :: 10015
@(private) CURLOPT_USERAGENT          :: 10018
@(private) CURLOPT_HTTPHEADER         :: 10023
@(private) CURLOPT_HEADERDATA         :: 10029
@(private) CURLOPT_CUSTOMREQUEST      :: 10036
@(private) CURLOPT_WRITEFUNCTION      :: 20011
@(private) CURLOPT_HEADERFUNCTION     :: 20079
@(private) CURLOPT_POSTFIELDSIZE_LARGE :: 30120
@(private) CURLOPT_NOBODY             :: 44
@(private) CURLOPT_FOLLOWLOCATION     :: 52
@(private) CURLOPT_MAXREDIRS          :: 68
@(private) CURLOPT_NOSIGNAL           :: 99
@(private) CURLOPT_TIMEOUT_MS         :: 155
@(private) CURLOPT_ACCEPT_ENCODING    :: 10102
@(private) CURLOPT_PROTOCOLS_STR      :: 10318
@(private) CURLOPT_REDIR_PROTOCOLS_STR :: 10319
@(private) CURLINFO_EFFECTIVE_URL     :: 0x100001
@(private) CURLINFO_RESPONSE_CODE     :: 0x200002
@(private) CURL_GLOBAL_DEFAULT        :: 3
@(private) CURLE_WRITE_ERROR          :: 23
@(private) CURLFOLLOW_ALL             :: 1
@(private) CURLFOLLOW_OBEYCODE        :: 2
@(private) CURLOPT_NOPROGRESS         :: 43
@(private) CURLOPT_XFERINFODATA       :: 10057
@(private) CURLOPT_XFERINFOFUNCTION   :: 20219
@(private) CURLOPT_CONNECT_ONLY       :: 141
@(private) CURLOPT_CONNECTTIMEOUT_MS  :: 156
@(private) CURLOPT_HTTPPROXYTUNNEL    :: 61
@(private) CURLOPT_HTTP_VERSION       :: 84
@(private) CURL_HTTP_VERSION_1_1      :: 2
@(private) CURLINFO_ACTIVESOCKET      :: 0x50002C   // (7.45)
@(private) CURLINFO_LASTSOCKET        :: 0x20001D   // (before 7.45: a long)
@(private) CURLE_AGAIN                :: 81

// The header lines of the answers kept at most: no real answer comes near it.
@(private) MAX_HEADER_BYTES :: 1 << 20

@(private)
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
		c.easy_reset = auto_cast posix.dlsym(h, "curl_easy_reset")
		c.global_init = auto_cast posix.dlsym(h, "curl_global_init")
		c.slist_append = auto_cast posix.dlsym(h, "curl_slist_append")
		c.slist_free_all = auto_cast posix.dlsym(h, "curl_slist_free_all")
		c.easy_send = auto_cast posix.dlsym(h, "curl_easy_send")
		c.easy_recv = auto_cast posix.dlsym(h, "curl_easy_recv")
		if c.easy_init == nil || c.easy_setopt == nil || c.easy_perform == nil || c.easy_getinfo == nil || c.easy_cleanup == nil || c.easy_reset == nil || c.global_init == nil || c.slist_append == nil || c.slist_free_all == nil {
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

// The idle easy handles the pool keeps at most, each with its connections (libcurl keeps 5 a handle).
POOL_IDLE :: 8

// An idle handle and the origin it last spoke to.
@(private = "file")
Pooled :: struct {
	h:      rawptr,
	origin: string,   // the heap's
}

// The requests' easy handles between two requests (src/md/features/http-connections.md): a handle holds its connections
// open, so a request that takes one reuses them. One thread uses a handle at a time: libcurl's shared connection cache is
// not for concurrent threads.
@(private = "file")
Pool :: struct {
	lock:  sync.Mutex,
	idle:  [POOL_IDLE]Pooled,   // the oldest first
	count: int,
}

@(private = "file") pool: Pool

// "scheme://host:port", the host in lower case: what a connection is reused for.
@(private = "file")
origin_of :: proc(url: string) -> string {
	u, _ := url_parse(url)
	return fmt.tprintf("%s://%s:%d", u.secure ? "https" : "http", ascii.lower(u.host, context.temp_allocator), u.port)
}

// The idle handle that last spoke to `origin` (its connection is open), else a new one.
@(private = "file")
pool_take :: proc(origin: string) -> rawptr {
	sync.mutex_lock(&pool.lock)
	for i := pool.count - 1; i >= 0; i -= 1 {
		if pool.idle[i].origin != origin { continue }
		h := pool.idle[i].h
		delete(pool.idle[i].origin, runtime.heap_allocator())
		copy(pool.idle[i:pool.count - 1], pool.idle[i + 1:pool.count])
		pool.count -= 1
		sync.mutex_unlock(&pool.lock)
		return h
	}
	sync.mutex_unlock(&pool.lock)
	return curl_lib.easy_init()
}

// The handle back, its options cleared (no pointer to the request's buffers stays in it) and its connections kept. A
// full pool ends its oldest handle.
@(private = "file")
pool_give :: proc(h: rawptr, origin: string) {
	curl_lib.easy_reset(h)
	oldest: rawptr
	sync.mutex_lock(&pool.lock)
	if pool.count == POOL_IDLE {
		oldest = pool.idle[0].h
		delete(pool.idle[0].origin, runtime.heap_allocator())
		copy(pool.idle[:POOL_IDLE - 1], pool.idle[1:])
		pool.count -= 1
	}
	pool.idle[pool.count] = {h, strings.clone(origin, runtime.heap_allocator())}
	pool.count += 1
	sync.mutex_unlock(&pool.lock)
	// (outside the lock: its connections close, a TLS one with its goodbye)
	if oldest != nil { curl_lib.easy_cleanup(oldest) }
}

request_system :: proc(method, url: string, req: Request, allocator := context.allocator) -> (res: Response, err: Error) {
	sync.once_do(&curl_once, curl_load)
	if !curl_found { return {}, .No_Client }
	c := &curl_lib
	origin := origin_of(url)
	h := pool_take(origin)
	if h == nil { return {}, .No_Client }
	defer pool_give(h, origin)
	sink := Sink{data = make([dynamic]u8, allocator), max_bytes = req.max_bytes, head = make([dynamic]u8, context.temp_allocator)}
	c.easy_setopt(h, CURLOPT_URL, strings.clone_to_cstring(url, context.temp_allocator))
	c.easy_setopt(h, CURLOPT_MAXREDIRS, i64(MAX_REDIRECTS))
	c.easy_setopt(h, CURLOPT_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_REDIR_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_NOSIGNAL, i64(1))   // (a thread of its own: no SIGALRM for the name lookup's time limit)
	c.easy_setopt(h, CURLOPT_TIMEOUT_MS, i64(req.timeout / 1_000_000))
	c.easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, i64(connect_bound(req) / time.Millisecond))
	curl_compression(h, req)
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
	c.easy_setopt(h, CURLOPT_FOLLOWLOCATION, req.no_redirects ? i64(0) : i64(custom ? CURLFOLLOW_OBEYCODE : CURLFOLLOW_ALL))

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

// A compressed answer asked: libcurl sends Accept-Encoding and gives the write callback the decoded bytes (so max_bytes
// bounds what is decoded, not what came). The encodings named, not "" (all libcurl has): WinHTTP decodes these two only,
// and both systems then ask the server the same.
@(private)
curl_compression :: proc(h: rawptr, req: Request) {
	if req.compressed { curl_lib.easy_setopt(h, CURLOPT_ACCEPT_ENCODING, cstring(ACCEPT_ENCODING)) }
}

// The headers as libcurl's list ("Name: value"); nil and true for none. !ok: libcurl had no memory.
@(private)
curl_header_list :: proc(headers: []Header) -> (list: rawptr, ok: bool) {
	c := &curl_lib
	for hd in headers {
		next := c.slist_append(list, strings.clone_to_cstring(strings.concatenate({hd.name, ": ", hd.value}, context.temp_allocator), context.temp_allocator))
		if next == nil {
			if list != nil { c.slist_free_all(list) }
			return nil, false
		}
		list = next
	}
	return list, true
}

// What one stream's callbacks share: they run on the thread of easy_perform.
@(private = "file")
Stream_Sink :: struct {
	h:         rawptr,
	parser:    ^Event_Parser,
	on_event:  Event_Proc,
	user:      rawptr,
	stop:      ^Stop,
	silence:   time.Duration,
	last:      time.Tick,   // the last byte received, of a header or of the body
	status:    int,         // the answer's, read at its first body bytes
	refused:   bool,        // not 2xx: the body is not read
	by_caller: bool,        // on_event said .Stop
	stopped:   bool,        // stop was asked
	silent:    bool,        // nothing came for `silence`
}

@(private = "file")
on_stream_write :: proc "c" (ptr: [^]u8, size, count: uint, user: rawptr) -> uint {
	context = runtime.default_context()
	s := (^Stream_Sink)(user)
	n := int(size * count)
	s.last = time.tick_now()
	if s.status == 0 {
		code: i64
		curl_lib.easy_getinfo(s.h, CURLINFO_RESPONSE_CODE, &code)
		s.status = int(code)
		if s.status < 200 || s.status > 299 { s.refused = true; return 0 }
	}
	if event_parser_feed(s.parser, ptr[:n], s.on_event, s.user) == .Stop {
		if !s.parser.too_large { s.by_caller = true }
		return 0   // (fewer bytes than given: libcurl stops)
	}
	return uint(n)
}

@(private = "file")
on_stream_header :: proc "c" (ptr: [^]u8, size, count: uint, user: rawptr) -> uint {
	s := (^Stream_Sink)(user)
	s.last = time.tick_now()
	return size * count
}

// libcurl calls it about once a second, bytes or not: where a stop and the silence are seen.
@(private = "file")
on_stream_progress :: proc "c" (user: rawptr, dltotal, dlnow, ultotal, ulnow: i64) -> i32 {
	s := (^Stream_Sink)(user)
	if s.stop != nil && sync.atomic_load(&s.stop.asked) { s.stopped = true; return 1 }
	if time.tick_since(s.last) > s.silence { s.silent = true; return 1 }
	return 0
}

events_system :: proc(url: string, req: Request, parser: ^Event_Parser, on_event: Event_Proc, user: rawptr, stop: ^Stop) -> (status: int, err: Error) {
	sync.once_do(&curl_once, curl_load)
	if !curl_found { return 0, .No_Client }
	c := &curl_lib
	h := c.easy_init()
	if h == nil { return 0, .No_Client }
	defer c.easy_cleanup(h)
	sink := Stream_Sink{h = h, parser = parser, on_event = on_event, user = user, stop = stop, silence = req.timeout, last = time.tick_now()}
	c.easy_setopt(h, CURLOPT_URL, strings.clone_to_cstring(url, context.temp_allocator))
	c.easy_setopt(h, CURLOPT_FOLLOWLOCATION, i64(CURLFOLLOW_ALL))
	c.easy_setopt(h, CURLOPT_MAXREDIRS, i64(MAX_REDIRECTS))
	c.easy_setopt(h, CURLOPT_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_REDIR_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_NOSIGNAL, i64(1))
	c.easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, i64(connect_bound(req) / time.Millisecond))
	curl_compression(h, req)
	c.easy_setopt(h, CURLOPT_WRITEFUNCTION, on_stream_write)
	c.easy_setopt(h, CURLOPT_WRITEDATA, rawptr(&sink))
	c.easy_setopt(h, CURLOPT_HEADERFUNCTION, on_stream_header)
	c.easy_setopt(h, CURLOPT_HEADERDATA, rawptr(&sink))
	c.easy_setopt(h, CURLOPT_XFERINFOFUNCTION, on_stream_progress)
	c.easy_setopt(h, CURLOPT_XFERINFODATA, rawptr(&sink))
	c.easy_setopt(h, CURLOPT_NOPROGRESS, i64(0))
	if req.user_agent != "" { c.easy_setopt(h, CURLOPT_USERAGENT, strings.clone_to_cstring(req.user_agent, context.temp_allocator)) }
	list, listed := curl_header_list(req.headers)
	if !listed { return 0, .Unreachable }
	defer if list != nil { c.slist_free_all(list) }
	if list != nil { c.easy_setopt(h, CURLOPT_HTTPHEADER, list) }

	code := c.easy_perform(h)
	answer: i64
	c.easy_getinfo(h, CURLINFO_RESPONSE_CODE, &answer)
	status = int(answer)
	switch {
	case sink.refused, sink.by_caller: return status, .None
	case parser.too_large:             return status, .Too_Large
	case sink.stopped:                 return status, .Stopped
	case sink.silent:                  return status, .Unreachable
	case code != 0:                    return status, .Unreachable
	}
	return status, .None   // (the server ended the stream)
}
