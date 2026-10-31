package devtools

import "base:runtime"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../platform"

// The network side: a listener on 127.0.0.1, one thread per connection. HTTP for the discovery endpoints (/json/version,
// /json/list) and the upgrade to a WebSocket; then each text message (a command) goes to the inbox and wakes the window.
// The UI thread takes the inbox in `service` and answers on the connection (send_text, under its write lock).
//
// 127.0.0.1 is not a wall against the browsers of the machine: a WebSocket is not bound by the same-origin policy, so any
// page could connect here and drive the window, and a name made to resolve to 127.0.0.1 could read the HTTP endpoints. So
// a request with an Origin (what a browser's page sends and a tool's client does not), a Host that is not this address,
// or a WebSocket path without the target's id is refused.

@(private)
Conn :: struct {
	srv:    ^Server,
	sock:   net.TCP_Socket,
	thread: ^thread.Thread,
	write:  sync.Mutex,
	closed: bool,   // (under write)
	done:   bool,   // the thread is at its end (atomic): `service` joins and frees it
	page:   bool,   // on the page's endpoint, not the browser's
}

// A command is small: a message over this ends the connection.
@(private)
MAX_MESSAGE :: 16 * 1024 * 1024
// A client that stops reading must not hold the UI thread, which answers on its socket.
@(private)
SEND_TIMEOUT :: 5 * time.Second

@(private)
Message :: struct {
	conn: ^Conn,
	text: string,   // owned (the server's allocator)
}

@(private)
accept_loop :: proc(srv: ^Server) {
	for {
		sock, _, err := net.accept_tcp(srv.listener)
		if sync.atomic_load(&srv.stopping) { if err == nil { net.close(sock) }; return }
		if err != nil { continue }
		c := new(Conn, runtime.heap_allocator())   // (what crosses threads comes from the heap and goes back to it)
		c.srv, c.sock = srv, sock
		net.set_option(sock, .Send_Timeout, SEND_TIMEOUT)
		sync.lock(&srv.lock)
		append(&srv.conns, c)
		sync.unlock(&srv.lock)
		c.thread = thread.create_and_start_with_poly_data(c, conn_loop)
	}
}

// Bytes read past what was asked for (the next frame's start, after the HTTP headers).
@(private)
Reader :: struct {
	sock: net.TCP_Socket,
	buf:  [dynamic]u8,
}

@(private)
read_more :: proc(r: ^Reader) -> bool {
	tmp: [16 * 1024]u8
	n, err := net.recv_tcp(r.sock, tmp[:])
	if err != nil || n <= 0 { return false }
	append(&r.buf, ..tmp[:n])
	return true
}

@(private)
read_exact :: proc(r: ^Reader, n: int, out: ^[dynamic]u8) -> bool {
	for len(r.buf) < n { if !read_more(r) { return false } }
	append(out, ..r.buf[:n])
	remove_range(&r.buf, 0, n)
	return true
}

@(private)
conn_loop :: proc(c: ^Conn) {
	defer {
		sync.lock(&c.write)
		c.closed = true
		net.close(c.sock)
		sync.unlock(&c.write)
		sync.atomic_store(&c.done, true)
		platform.wake(c.srv.win)   // (the UI thread frees it)
	}
	r := Reader{sock = c.sock}
	defer delete(r.buf)
	// the request's headers
	end := -1
	for end < 0 {
		if !read_more(&r) { return }
		end = strings.index(string(r.buf[:]), "\r\n\r\n")
		if len(r.buf) > 64 * 1024 { return }
	}
	head := strings.clone(string(r.buf[:end]))
	defer delete(head)
	remove_range(&r.buf, 0, end + 4)
	lines := strings.split_lines(head)
	defer delete(lines)
	if len(lines) == 0 { return }
	parts := strings.fields(lines[0])
	defer delete(parts)
	if len(parts) < 2 || parts[0] != "GET" { http_reply(c, "405 Method Not Allowed", "text/plain", "GET only"); return }
	path := parts[1]
	key, host, origin := "", "", ""
	for l in lines[1:] {
		i := strings.index_byte(l, ':')
		if i < 0 { continue }
		h, v := strings.trim_space(l[:i]), strings.trim_space(l[i + 1:])
		switch {
		case strings.equal_fold(h, "Sec-WebSocket-Key"): key = v
		case strings.equal_fold(h, "Host"):              host = v
		case strings.equal_fold(h, "Origin"):            origin = v
		}
	}
	// (the one Origin taken: Chrome's own DevTools, on the WebSocket only. A page cannot send it, its browser writes its own.)
	if (origin != "" && !(key != "" && origin == "devtools://devtools")) || !host_allowed(host, c.srv.port) {
		http_reply(c, "403 Forbidden", "text/plain", "devtools: refused (a request from a browser's page, or for another host)")
		free_all(context.temp_allocator)
		return
	}
	if key == "" {
		srv := c.srv
		switch {
		case strings.has_prefix(path, "/json/version"):
			http_reply(c, "200 OK", "application/json", fmt.tprintf(`{{"Browser":"gui_toolkit/%s","Protocol-Version":"1.3","User-Agent":"gui_toolkit","webSocketDebuggerUrl":"ws://127.0.0.1:%d/devtools/browser/%s"}}`, VERSION, srv.port, srv.id))
		case path == "/json" || strings.has_prefix(path, "/json/list"):
			http_reply(c, "200 OK", "application/json", fmt.tprintf(`[{{"description":"","devtoolsFrontendUrl":"devtools://devtools/bundled/inspector.html?ws=127.0.0.1:%d/devtools/page/%s","id":"%s","title":%s,"type":"page","url":"toolkit://window","webSocketDebuggerUrl":"ws://127.0.0.1:%d/devtools/page/%s"}}]`, srv.port, srv.id, srv.id, json_quote(srv.title, context.temp_allocator), srv.port, srv.id))
		case:
			http_reply(c, "404 Not Found", "text/plain", "not found: /json/version, /json/list, or a WebSocket on /devtools/page/<id>")
		}
		free_all(context.temp_allocator)
		return
	}
	if !target_path(path, c.srv.id) {
		http_reply(c, "404 Not Found", "text/plain", "no such target: see /json/list")
		free_all(context.temp_allocator)
		return
	}
	c.page = strings.has_prefix(path, "/devtools/page/")
	// the upgrade (RFC 6455): the accept key is base64(sha1(key + the protocol's GUID))
	h: sha1.Context
	sha1.init(&h)
	sha1.update(&h, transmute([]u8)key)
	sha1.update(&h, transmute([]u8)string("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&h, digest[:])
	accept := base64.encode(digest[:], allocator = context.temp_allocator)
	send_all(c, transmute([]u8)fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept))
	free_all(context.temp_allocator)

	msg := make([dynamic]u8)
	defer delete(msg)
	frame := make([dynamic]u8)
	defer delete(frame)
	for {
		clear(&frame)
		if !read_exact(&r, 2, &frame) { return }
		fin := frame[0] & 0x80 != 0
		op := frame[0] & 0x0f
		if frame[1] & 0x80 == 0 { return }   // (a client must mask its frames)
		n := u64(frame[1] & 0x7f)
		if op >= 0x8 && (n > 125 || !fin) { return }   // (a control frame is short and whole)
		if n >= 126 {
			clear(&frame)
			k := n == 126 ? 2 : 8
			if !read_exact(&r, k, &frame) { return }
			n = 0
			for b in frame[:k] { n = n << 8 | u64(b) }
		}
		if n > MAX_MESSAGE { return }
		mask: [4]u8
		clear(&frame)
		if !read_exact(&r, 4, &frame) { return }
		copy(mask[:], frame[:4])
		clear(&frame)
		if !read_exact(&r, int(n), &frame) { return }
		for &b, i in frame { b ~= mask[i % 4] }
		switch op {
		case 0x8:   // close
			send_frame(c, 0x8, frame[:min(len(frame), 2)])
			return
		case 0x9:   // ping
			send_frame(c, 0xA, frame[:])
		case 0xA:   // pong
		case 0x0, 0x1, 0x2:
			if len(msg) + len(frame) > MAX_MESSAGE { return }   // (the frames of one message add up)
			append(&msg, ..frame[:])
			if fin {
				srv := c.srv
				sync.lock(&srv.lock)
				append(&srv.inbox, Message{conn = c, text = strings.clone(string(msg[:]), runtime.heap_allocator())})
				sync.unlock(&srv.lock)
				if sync.atomic_load(&srv.cast_dirty) || !strings.contains(string(msg[:]), "Page.screencastFrameAck") { platform.wake(srv.win) }   // (cast.odin)
				clear(&msg)
			}
		}
	}
}

// A Host naming this address and port. (Not a name that merely resolves here: that is how a page reaches the endpoints.)
@(private)
host_allowed :: proc(host: string, port: int) -> bool {
	for name in ([?]string{"127.0.0.1", "localhost", "[::1]"}) {
		if strings.equal_fold(host, fmt.tprintf("%s:%d", name, port)) { return true }
	}
	return false
}

@(private)
target_path :: proc(path, id: string) -> bool {
	for prefix in ([?]string{"/devtools/page/", "/devtools/browser/"}) {
		if strings.has_prefix(path, prefix) && path[len(prefix):] == id { return true }
	}
	return false
}

@(private)
http_reply :: proc(c: ^Conn, status, kind, body: string) {
	send_all(c, transmute([]u8)fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, kind, len(body), body))
}

@(private)
send_all :: proc(c: ^Conn, b: []u8) -> bool {
	b := b
	for len(b) > 0 {
		n, err := net.send_tcp(c.sock, b)
		if err != nil || n <= 0 { return false }
		b = b[n:]
	}
	return true
}

@(private)
send_frame :: proc(c: ^Conn, op: u8, payload: []u8) -> bool {
	sync.lock(&c.write)
	defer sync.unlock(&c.write)
	if c.closed { return false }
	head: [10]u8
	head[0] = 0x80 | op
	k := 2
	n := len(payload)
	switch {
	case n < 126:
		head[1] = u8(n)
	case n < 65536:
		head[1] = 126
		head[2], head[3] = u8(n >> 8), u8(n)
		k = 4
	case:
		head[1] = 127
		for i in 0 ..< 8 { head[2 + i] = u8(u64(n) >> uint(56 - 8 * i)) }
		k = 10
	}
	if send_all(c, head[:k]) && send_all(c, payload) { return true }
	net.shutdown(c.sock, .Both)   // (half a frame was sent, or the client stopped reading: the connection is over)
	return false
}

@(private)
send_text :: proc(c: ^Conn, text: string) -> bool { return send_frame(c, 0x1, transmute([]u8)text) }
