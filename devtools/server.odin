package devtools

import "base:runtime"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "../platform"

// The network side: a listener on 127.0.0.1, one thread per connection. HTTP for the discovery endpoints (/json/version,
// /json/list) and the upgrade to a WebSocket; then each text message (a command) goes to the inbox and wakes the window.
// The UI thread takes the inbox in `service` and answers on the connection (send_text, under its write lock).

@(private)
Conn :: struct {
	srv:    ^Server,
	sock:   net.TCP_Socket,
	thread: ^thread.Thread,
	write:  sync.Mutex,
	closed: bool,
}

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
	defer { c.closed = true; net.close(c.sock) }
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
	key := ""
	for l in lines[1:] {
		i := strings.index_byte(l, ':')
		if i < 0 { continue }
		if strings.equal_fold(strings.trim_space(l[:i]), "Sec-WebSocket-Key") { key = strings.trim_space(l[i + 1:]) }
	}
	if key == "" {
		srv := c.srv
		switch {
		case strings.has_prefix(path, "/json/version"):
			http_reply(c, "200 OK", "application/json", fmt.tprintf(`{{"Browser":"gui_toolkit/%s","Protocol-Version":"1.3","User-Agent":"gui_toolkit","webSocketDebuggerUrl":"ws://127.0.0.1:%d/devtools/browser/%s"}}`, VERSION, srv.port, srv.id))
		case path == "/json" || strings.has_prefix(path, "/json/list"):
			http_reply(c, "200 OK", "application/json", fmt.tprintf(`[{{"description":"","devtoolsFrontendUrl":"","id":"%s","title":%s,"type":"page","url":"toolkit://window","webSocketDebuggerUrl":"ws://127.0.0.1:%d/devtools/page/%s"}}]`, srv.id, json_quote(srv.title, context.temp_allocator), srv.port, srv.id))
		case:
			http_reply(c, "404 Not Found", "text/plain", "not found: /json/version, /json/list, or a WebSocket on /devtools/page/<id>")
		}
		free_all(context.temp_allocator)
		return
	}
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
		masked := frame[1] & 0x80 != 0
		n := u64(frame[1] & 0x7f)
		if n >= 126 {
			clear(&frame)
			k := n == 126 ? 2 : 8
			if !read_exact(&r, k, &frame) { return }
			n = 0
			for b in frame[:k] { n = n << 8 | u64(b) }
		}
		mask: [4]u8
		if masked {
			clear(&frame)
			if !read_exact(&r, 4, &frame) { return }
			copy(mask[:], frame[:4])
		}
		if n > 256 * 1024 * 1024 { return }
		clear(&frame)
		if !read_exact(&r, int(n), &frame) { return }
		if masked { for &b, i in frame { b ~= mask[i % 4] } }
		switch op {
		case 0x8:   // close
			send_frame(c, 0x8, frame[:min(len(frame), 2)])
			return
		case 0x9:   // ping
			send_frame(c, 0xA, frame[:])
		case 0xA:   // pong
		case 0x0, 0x1, 0x2:
			append(&msg, ..frame[:])
			if fin {
				srv := c.srv
				sync.lock(&srv.lock)
				append(&srv.inbox, Message{conn = c, text = strings.clone(string(msg[:]), runtime.heap_allocator())})
				sync.unlock(&srv.lock)
				platform.wake(srv.win)
				clear(&msg)
			}
		}
	}
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
	return send_all(c, head[:k]) && send_all(c, payload)
}

@(private)
send_text :: proc(c: ^Conn, text: string) -> bool { return send_frame(c, 0x1, transmute([]u8)text) }
