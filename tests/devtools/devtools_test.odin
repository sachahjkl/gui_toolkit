package devtools_test

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../../src/devtools"
import "../../src/platform"

PORT :: 9471   // (a port per test: they run at once)
PORT_HTTP :: 9472
PORT_FRAMES :: 9473
PORT_SET :: 9474
PORT_SILENT :: 9475

@(private = "file")
Client :: struct {
	port:     int,
	id:       string,   // the target's, in the path
	method:   string,   // the command ("": Browser.getVersion)
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
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = c.port})
	if err != nil { return }
	defer net.close(sock)
	req := fmt.tprintf("GET /devtools/page/%s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n", c.id, c.port)
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
	msg := fmt.tprintf(`{{"id":7,"method":"%s"}}`, c.method != "" ? c.method : "Browser.getVersion")
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

// A window with no interface (service with no ui.State) refuses a screencast, and an ack sent all the same does nothing.
@(test)
no_screencast_without_an_interface :: proc(t: ^testing.T) {
	win := platform.open_window_offscreen("devtools test", {200, 100})
	if !testing.expect(t, win != nil) { return }
	defer platform.destroy_window(win)
	srv := devtools.start_local(win, "test")
	defer devtools.stop(srv)
	l := devtools.local_connect(srv)
	defer devtools.local_close(l)
	devtools.local_send(l, `{"id":1,"method":"Page.startScreencast","params":{}}`)
	devtools.service(srv, nil, nil)
	got := devtools.local_take(l, context.temp_allocator)
	if !testing.expect_value(t, len(got), 1) { return }
	testing.expectf(t, strings.has_prefix(got[0], `{"id":1,"error":`), "%s", got[0])
	devtools.local_send(l, `{"id":2,"method":"Page.screencastFrameAck","params":{"sessionId":1}}`)
	devtools.service(srv, nil, nil)
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
	c.port = PORT
	c.id = srv.id
	defer { delete(c.reply, runtime.heap_allocator()); free(c) }
	th := thread.create_and_start_with_poly_data(c, client)
	start := time.tick_now()
	for !sync.atomic_load(&c.done) && time.tick_since(start) < 3 * time.Second {
		devtools.service(srv, nil, nil)   // (Browser.getVersion reads neither the tree nor the renderer)
		thread.yield()
	}
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, c.upgraded, "the upgrade, with the RFC's accept key")
	testing.expectf(t, strings.has_prefix(c.reply, `{"id":7,"result":{"protocolVersion":"1.3"`), "the answer: %s", c.reply)
}

// An edit that cannot be done answers an error, or a client shows it as done; what clients send on attaching is accepted.
@(test)
what_cannot_be_done_is_refused_what_attaching_sends_is_not :: proc(t: ^testing.T) {
	win := platform.open_window_offscreen("devtools test", {200, 100})
	if !testing.expect(t, win != nil) { return }
	defer platform.destroy_window(win)
	srv := devtools.start(win, PORT_SET, "test")
	if !testing.expect(t, srv != nil, "listening") { return }
	defer devtools.stop(srv)
	ask :: proc(srv: ^devtools.Server, method: string) -> string {
		c := Client{port = PORT_SET, id = srv.id, method = method}
		th := thread.create_and_start_with_poly_data(&c, client)
		start := time.tick_now()
		for !sync.atomic_load(&c.done) && time.tick_since(start) < 3 * time.Second {
			devtools.service(srv, nil, nil)
			thread.yield()
		}
		thread.join(th)
		thread.destroy(th)
		defer delete(c.reply, runtime.heap_allocator())
		return strings.clone(c.reply, context.temp_allocator)
	}
	for m in ([?]string{"DOM.setAttributesAsText", "DOM.setAttributeValue", "DOM.setOuterHTML", "DOM.setNodeName", "DOM.setFileInputFiles", "CSS.setEffectivePropertyValueForNode", "CSS.setStyleSheetText", "Page.setDocumentContent", "Network.setCookies", "Storage.setCookies"}) {
		r := ask(srv, m)
		testing.expectf(t, strings.has_prefix(r, `{"id":7,"error":`), "%s: %s", m, r)
	}
	// what Chrome's frontend, Puppeteer and Playwright send on attaching and as they go
	for m in ([?]string{"DOM.enable", "CSS.enable", "Overlay.enable", "Page.enable", "Runtime.enable", "Network.enable", "Log.enable",
		"Target.setAutoAttach", "Target.setDiscoverTargets", "Target.setRemoteLocations", "DOM.setInspectedNode", "DOM.setNodeStackTracesEnabled",
		"CSS.setLocalFontsEnabled", "Page.setLifecycleEventsEnabled", "Page.setAdBlockingEnabled", "Page.setBypassCSP", "Page.setFontFamilies",
		"Network.setCacheDisabled", "Network.setAttachDebugStack", "Network.setExtraHTTPHeaders", "Network.setUserAgentOverride", "Network.setBlockedURLs",
		"Emulation.setDeviceMetricsOverride", "Emulation.setEmulatedMedia", "Emulation.setFocusEmulationEnabled", "Emulation.setTouchEmulationEnabled",
		"Autofill.setAddresses", "Emulation.setEmulatedVisionDeficiency", "Browser.setDownloadBehavior", "Browser.setWindowBounds", "Runtime.setAsyncCallStackDepth", "Runtime.setCustomObjectFormatterEnabled",
		"Debugger.setAsyncCallStackDepth", "Debugger.setPauseOnExceptions", "Debugger.setBlackboxPatterns", "Overlay.setShowViewportSizeOnResize",
		"Overlay.setInspectMode", "Security.setIgnoreCertificateErrors", "ServiceWorker.setForceUpdateOnPageLoad"}) {
		r := ask(srv, m)
		testing.expectf(t, strings.has_prefix(r, `{"id":7,"result":`), "%s: %s", m, r)
	}
	// asked by the frontend as it goes, answered as Chrome would
	sk := ask(srv, "Storage.getStorageKey")
	testing.expectf(t, strings.contains(sk, `"storageKey":`), "%s", sk)
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
	// a key alone upgrades nothing, nor a version that is not this protocol's
	testing.expect_value(t, status(http_get(page, HOST + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n")), "HTTP/1.1 400")
	testing.expect_value(t, status(http_get(page, HOST + "Upgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n")), "HTTP/1.1 400")
	// header names and the Host fold by ASCII alone: the Kelvin sign U+212A is no 'K', the long s U+017F no 's'
	testing.expect_value(t, status(http_get("/json/list", "HOST: LOCALHOST:9472\r\n")), "HTTP/1.1 200")
	testing.expect_value(t, status(http_get("/json/list", "Ho\u017Ft: 127.0.0.1:9472\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get("/json/list", "Host: localho\u017Ft:9472\r\n")), "HTTP/1.1 403")
	testing.expect_value(t, status(http_get(page, HOST + "Sec-WebSocket-\u212Aey: dGhlIHNhbXBsZSBub25jZQ==\r\n")), "HTTP/1.1 404")   // no key: no WebSocket
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
		req := strings.concatenate({"GET /devtools/page/", id, " HTTP/1.1\r\nHost: 127.0.0.1:9473\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"}, context.temp_allocator)
		net.send_tcp(sock, transmute([]u8)req)
		buf: [1024]u8
		n, _ := net.recv_tcp(sock, buf[:])
		return sock, n > 0
	}
	// the server closes: a read ends with nothing
	closed :: proc(sock: net.TCP_Socket) -> bool {
		net.set_option(sock, .Receive_Timeout, 3 * time.Second)
		buf: [64]u8
		n, e := net.recv_tcp(sock, buf[:])
		return n <= 0 && e != .Timeout
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
	// a frame of these bytes, masked (by zeros, which leave them as they are): RFC 6455 has no place for what follows
	bad := [?][]u8{
		{0x80, 0x80, 0, 0, 0, 0},                                  // a continuation of nothing
		{0x01, 0x81, 0, 0, 0, 0, 'a', 0x81, 0x81, 0, 0, 0, 0, 'b'},   // a message begun within a message
		{0x83, 0x80, 0, 0, 0, 0},                                  // an opcode with no meaning
		{0xC1, 0x80, 0, 0, 0, 0},                                  // an extension nobody agreed on
	}
	for frame, i in bad {
		sock, ok := open(srv.id)
		if !testing.expect(t, ok) { return }
		defer net.close(sock)
		net.send_tcp(sock, frame)
		testing.expectf(t, closed(sock), "bad frame %d", i)
	}
}

// A connection that says nothing does not hold a thread as long as the program lives.
@(test)
a_silent_connection_is_closed :: proc(t: ^testing.T) {
	win := platform.open_window_offscreen("devtools test", {200, 100})
	if !testing.expect(t, win != nil) { return }
	defer platform.destroy_window(win)
	srv := devtools.start(win, PORT_SILENT, "test")
	if !testing.expect(t, srv != nil, "listening") { return }
	defer devtools.stop(srv)
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT_SILENT})
	if !testing.expect(t, err == nil) { return }
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 2 * devtools.REQUEST_TIMEOUT)
	buf: [64]u8
	n, e := net.recv_tcp(sock, buf[:])
	testing.expect(t, n <= 0 && e != .Timeout, "closed by the server")
}
