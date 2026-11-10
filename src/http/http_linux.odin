#+build linux
package tk_http

// libcurl, by dlopen: a program that never asks for a URL starts on a system without it.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sys/posix"

@(private = "file")
Curl :: struct {
	easy_init:    proc "c" () -> rawptr,
	easy_setopt:  proc "c" (h: rawptr, option: i32, #c_vararg args: ..any) -> i32,
	easy_perform: proc "c" (h: rawptr) -> i32,
	easy_getinfo: proc "c" (h: rawptr, info: i32, #c_vararg args: ..any) -> i32,
	easy_cleanup: proc "c" (h: rawptr),
	global_init:  proc "c" (flags: i64) -> i32,
}

@(private = "file") curl_lib: Curl
@(private = "file") curl_once: sync.Once
@(private = "file") curl_found: bool

@(private = "file") CURLOPT_WRITEDATA          :: 10001
@(private = "file") CURLOPT_URL                :: 10002
@(private = "file") CURLOPT_USERAGENT          :: 10018
@(private = "file") CURLOPT_WRITEFUNCTION      :: 20011
@(private = "file") CURLOPT_FOLLOWLOCATION     :: 52
@(private = "file") CURLOPT_MAXREDIRS          :: 68
@(private = "file") CURLOPT_NOSIGNAL           :: 99
@(private = "file") CURLOPT_TIMEOUT_MS         :: 155
@(private = "file") CURLOPT_PROTOCOLS_STR      :: 10318
@(private = "file") CURLOPT_REDIR_PROTOCOLS_STR :: 10319
@(private = "file") CURLINFO_RESPONSE_CODE     :: 0x200002
@(private = "file") CURL_GLOBAL_DEFAULT        :: 3
@(private = "file") CURLE_WRITE_ERROR          :: 23

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
		if c.easy_init == nil || c.easy_setopt == nil || c.easy_perform == nil || c.easy_getinfo == nil || c.easy_cleanup == nil || c.global_init == nil {
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

get_system :: proc(url: string, req: Request, allocator := context.allocator) -> (status: int, body: []u8, err: Error) {
	sync.once_do(&curl_once, curl_load)
	if !curl_found { return 0, nil, .No_Client }
	c := &curl_lib
	h := c.easy_init()
	if h == nil { return 0, nil, .No_Client }
	defer c.easy_cleanup(h)
	sink := Sink{data = make([dynamic]u8, allocator), max_bytes = req.max_bytes}
	c.easy_setopt(h, CURLOPT_URL, strings.clone_to_cstring(url, context.temp_allocator))
	c.easy_setopt(h, CURLOPT_FOLLOWLOCATION, i64(1))
	c.easy_setopt(h, CURLOPT_MAXREDIRS, i64(MAX_REDIRECTS))
	c.easy_setopt(h, CURLOPT_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_REDIR_PROTOCOLS_STR, cstring("http,https"))
	c.easy_setopt(h, CURLOPT_NOSIGNAL, i64(1))   // (a thread of its own: no SIGALRM for the name lookup's time limit)
	c.easy_setopt(h, CURLOPT_TIMEOUT_MS, i64(req.timeout / 1_000_000))
	c.easy_setopt(h, CURLOPT_WRITEFUNCTION, on_write)
	c.easy_setopt(h, CURLOPT_WRITEDATA, rawptr(&sink))
	if req.user_agent != "" { c.easy_setopt(h, CURLOPT_USERAGENT, strings.clone_to_cstring(req.user_agent, context.temp_allocator)) }
	code := c.easy_perform(h)
	if code != 0 {
		delete(sink.data)
		return 0, nil, sink.too_large && code == CURLE_WRITE_ERROR ? .Too_Large : .Unreachable
	}
	answer: i64
	c.easy_getinfo(h, CURLINFO_RESPONSE_CODE, &answer)
	return int(answer), sink.data[:], .None
}
