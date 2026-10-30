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

PORT :: 9471

@(private = "file")
Client :: struct {
	done:     bool,
	upgraded: bool,
	reply:    string,
}

// A WebSocket client as a tool would be: the upgrade, one command (masked, as clients must), its answer.
@(private = "file")
client :: proc(c: ^Client) {
	defer sync.atomic_store(&c.done, true)
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT})
	if err != nil { return }
	defer net.close(sock)
	req := "GET /devtools/page/x HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
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
