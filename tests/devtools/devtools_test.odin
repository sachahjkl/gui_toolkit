package devtools_test

import "base:runtime"
import "core:bytes"
import "core:image"
import "core:image/png"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../../devtools"
import "../../platform"

// The PNG the screenshots are sent as reads back to the same pixels.
@(test)
png_round_trip :: proc(t: ^testing.T) {
	px := [?]u8{
		255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,
		10, 20, 30, 255,  10, 20, 30, 255,  200, 100, 50, 255,
	}
	data := devtools.png_encode(px[:], 3, 2)
	defer delete(data)
	img, err := png.load_from_bytes(data)
	if !testing.expectf(t, err == nil, "decodes: %v", err) { return }
	defer image.destroy(img)
	testing.expect_value(t, img.width, 3)
	testing.expect_value(t, img.height, 2)
	testing.expect_value(t, img.channels, 4)
	testing.expect(t, bytes.equal(img.pixels.buf[:], px[:]), "same pixels")
}

// A window's worth of what a picture holds: flat areas, rows like the last, gradients, noise. Pixel for pixel through the
// PNG decoder, at sizes either side of the row distance the window of 32 KiB allows.
@(test)
png_of_a_large_picture :: proc(t: ^testing.T) {
	for size in ([?][2]int{{1, 1}, {2310, 1505}, {9000, 40}}) {
		w, h := size.x, size.y
		px := make([]u8, w * h * 4)
		defer delete(px)
		seed: u32 = 12345
		for y in 0 ..< h {
			for x in 0 ..< w {
				p := px[(y * w + x) * 4:][:4]
				switch {
				case y % 200 < 100 && x < w / 2: p[0], p[1], p[2], p[3] = 20, 22, 24, 255
				case y % 200 < 100:              p[0], p[1], p[2], p[3] = u8(x), u8(x >> 8), 90, 255
				case y % 200 < 150:              p[0], p[1], p[2], p[3] = u8(x % 7 * 30), u8(x % 5 * 40), u8(y / 10), 255
				case:
					seed = seed * 1664525 + 1013904223
					p[0], p[1], p[2], p[3] = u8(seed >> 24), u8(seed >> 16), u8(seed >> 8), u8(seed)
				}
			}
		}
		data := devtools.png_encode(px, w, h)
		defer delete(data)
		img, err := png.load_from_bytes(data)
		if !testing.expectf(t, err == nil, "%v decodes: %v", size, err) { return }
		defer image.destroy(img)
		testing.expect(t, bytes.equal(img.pixels.buf[:], px), "same pixels")
	}
}

PORT :: 9471   // (a port per test: they run at once)
PORT_HTTP :: 9472
PORT_FRAMES :: 9473

@(private = "file")
Client :: struct {
	id:       string,   // the target's, in the path
	done:     bool,
	upgraded: bool,
	reply:    string,
}

// What the server says to one HTTP request with these headers: its status line and the rest.
@(private = "file")
http_get :: proc(path, headers: string) -> string {
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT_HTTP})
	if err != nil { return "" }
	defer net.close(sock)
	req := strings.concatenate({"GET ", path, " HTTP/1.1\r\n", headers, "\r\n"}, context.temp_allocator)
	net.send_tcp(sock, transmute([]u8)req)
	buf: [4096]u8
	got := 0
	for got < len(buf) {
		n, e := net.recv_tcp(sock, buf[got:])
		if e != nil || n <= 0 { break }
		got += n
		if strings.contains(string(buf[:got]), "\r\n\r\n") && !strings.contains(string(buf[:got]), "Content-Length") { break }
		if strings.contains(string(buf[:got]), "101 Switching") { break }
	}
	return strings.clone(string(buf[:got]), context.temp_allocator)
}

// A WebSocket client as a tool would be: the upgrade, one command (masked, as clients must), its answer.
@(private = "file")
client :: proc(c: ^Client) {
	defer sync.atomic_store(&c.done, true)
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT})
	if err != nil { return }
	defer net.close(sock)
	req := strings.concatenate({"GET /devtools/page/", c.id, " HTTP/1.1\r\nHost: 127.0.0.1:9471\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"}, context.temp_allocator)
	net.send_tcp(sock, transmute([]u8)req)
	buf: [4096]u8
	got := 0
	for !strings.contains(string(buf[:got]), "\r\n\r\n") {
		n, e := net.recv_tcp(sock, buf[got:])
		if e != nil || n <= 0 { return }
		got += n
	}
	head := string(buf[:got])
	// RFC 6455's example key and its accept value
	c.upgraded = strings.contains(head, "101") && strings.contains(head, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
	msg := `{"id":7,"method":"Browser.getVersion"}`
	mask := [4]u8{1, 2, 3, 4}
	frame := make([dynamic]u8, context.temp_allocator)
	append(&frame, 0x81, 0x80 | u8(len(msg)))
	append(&frame, ..mask[:])
	for b, i in transmute([]u8)msg { append(&frame, b ~ mask[i % 4]) }
	net.send_tcp(sock, frame[:])
	got = 0
	size :: proc(b: []u8) -> (head, n: int) {
		if len(b) < 2 { return 2, 0 }
		n = int(b[1] & 0x7f)
		if n == 126 { return 4, len(b) >= 4 ? int(b[2]) << 8 | int(b[3]) : 1 << 30 }
		return 2, n
	}
	for {
		h, n := size(buf[:got])
		if got >= h + n { c.reply = strings.clone(string(buf[h:h + n]), runtime.heap_allocator()); return }
		r, e := net.recv_tcp(sock, buf[got:])
		if e != nil || r <= 0 { return }
		got += r
	}
}

// The server answers a command from a WebSocket client once the window's loop serves it.
@(test)
a_command_over_a_websocket :: proc(t: ^testing.T) {
	win := platform.open_window_offscreen("devtools test", {200, 100})
	if !testing.expect(t, win != nil) { return }
	defer platform.destroy_window(win)
	srv := devtools.start(win, PORT, "test")
	if !testing.expect(t, srv != nil, "listening") { return }
	defer devtools.stop(srv)
	c := new(Client)
	c.id = srv.id
	defer { delete(c.reply, runtime.heap_allocator()); free(c) }
	th := thread.create_and_start_with_poly_data(c, client)
	start := time.tick_now()
	for !sync.atomic_load(&c.done) && time.tick_since(start) < 3 * time.Second {
		devtools.service(srv, nil, nil)   // (Browser.getVersion reads neither the tree nor the renderer)
		time.sleep(2 * time.Millisecond)
	}
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, c.upgraded, "the upgrade, with the RFC's accept key")
	testing.expectf(t, strings.has_prefix(c.reply, `{"id":7,"result":{"protocolVersion":"1.3"`), "the answer: %s", c.reply)
}

// A browser's page may open a WebSocket to 127.0.0.1 whatever its own address: what it sends says so, and it is refused.
// So is a name made to resolve here, and a path without the target's id, which is not to be guessed.
@(test)
what_a_browser_page_can_do_is_refused :: proc(t: ^testing.T) {
	win := platform.open_window_offscreen("devtools test", {200, 100})
	if !testing.expect(t, win != nil) { return }
	defer platform.destroy_window(win)
	srv := devtools.start(win, PORT_HTTP, "test")
	if !testing.expect(t, srv != nil, "listening") { return }
	defer devtools.stop(srv)
	UPGRADE :: "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
	HOST :: "Host: 127.0.0.1:9472\r\n"
	page := strings.concatenate({"/devtools/page/", srv.id}, context.temp_allocator)
	status :: proc(reply: string) -> string { return reply[:min(len(reply), 12)] }

	testing.expect_value(t, status(http_get(page, HOST + UPGRADE + "Origin: https://evil.example\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get(page, HOST + UPGRADE + "Origin: null\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get(page, HOST + UPGRADE + "Origin: devtools://devtools.evil.example\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get(page, HOST + UPGRADE + "Origin: devtools://devtools\r\n")), "HTTP/1.1 101")   // Chrome's own DevTools, the WebSocket only
	testing.expect_value(t, status(http_get("/json/list", HOST + "Origin: devtools://devtools\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get("/json/list", HOST + "Origin: https://evil.example\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get("/json/list", "Host: evil.example:9472\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get("/json/list", "")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get("/devtools/page/x", HOST + UPGRADE)), "HTTP/1.1 404")
	// and a tool is served
	testing.expect_value(t, status(http_get("/json/list", HOST)), "HTTP/1.1 200")
	testing.expect_value(t, status(http_get("/json/list", "Host: localhost:9472\r\n")), "HTTP/1.1 200")
	testing.expect_value(t, status(http_get(page, HOST + UPGRADE)), "HTTP/1.1 101")
}

// A frame without the mask a client must set ends the connection, and so does a message over the limit, in one frame or
// spread over many: nothing is kept of them.
@(test)
a_bad_frame_ends_the_connection :: proc(t: ^testing.T) {
	win := platform.open_window_offscreen("devtools test", {200, 100})
	if !testing.expect(t, win != nil) { return }
	defer platform.destroy_window(win)
	srv := devtools.start(win, PORT_FRAMES, "test")
	if !testing.expect(t, srv != nil, "listening") { return }
	defer devtools.stop(srv)
	open :: proc(id: string) -> (net.TCP_Socket, bool) {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT_FRAMES})
		if err != nil { return {}, false }
		req := strings.concatenate({"GET /devtools/page/", id, " HTTP/1.1\r\nHost: 127.0.0.1:9473\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"}, context.temp_allocator)
		net.send_tcp(sock, transmute([]u8)req)
		buf: [1024]u8
		n, _ := net.recv_tcp(sock, buf[:])
		return sock, n > 0
	}
	// the server closes: a read ends with nothing
	closed :: proc(sock: net.TCP_Socket) -> bool {
		net.set_option(sock, .Receive_Timeout, 3 * time.Second)
		buf: [64]u8
		n, _ := net.recv_tcp(sock, buf[:])
		return n <= 0
	}
	{
		sock, ok := open(srv.id)
		if !testing.expect(t, ok) { return }
		defer net.close(sock)
		frame := [?]u8{0x81, 2, 'h', 'i'}   // no mask
		net.send_tcp(sock, frame[:])
		testing.expect(t, closed(sock), "an unmasked frame")
	}
	{
		sock, ok := open(srv.id)
		if !testing.expect(t, ok) { return }
		defer net.close(sock)
		frame := [?]u8{0x81, 0x80 | 127, 0, 0, 0, 0, 0x40, 0, 0, 0}   // 1 GB announced
		net.send_tcp(sock, frame[:])
		testing.expect(t, closed(sock), "a frame over the limit")
	}
}
