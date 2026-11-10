package tk_http

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"

// A server of this process on a port of the loopback: /file, /moved (a redirect to /file), /big; anything else is 404.
// It answers `count` requests, then stops.
@(private = "file")
Server :: struct {
	socket: net.TCP_Socket,
	port:   int,
	count:  int,
	thread: ^thread.Thread,
}

@(private = "file") FILE_BODY :: "the file's bytes"

@(private = "file")
serve_start :: proc(t: ^testing.T, count: int) -> ^Server {
	s := new(Server)
	s.count = count
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil, "listen")
	s.socket = sock
	ep, _ := net.bound_endpoint(sock)
	s.port = ep.port
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^Server) {
		for _ in 0 ..< s.count {
			client, _, err := net.accept_tcp(s.socket)
			if err != nil { return }
			buf: [4096]u8
			n, _ := net.recv_tcp(client, buf[:])
			line := string(buf[:n])
			path := ""
			if parts := strings.split(line, " ", context.temp_allocator); len(parts) >= 2 { path = parts[1] }
			answer: string
			switch path {
			case "/file":  answer = fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(FILE_BODY), FILE_BODY)
			case "/moved": answer = fmt.tprintf("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:%d/file\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", s.port)
			case "/big":   answer = fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n%s", strings.repeat("x", 4096, context.temp_allocator))
			case:          answer = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			}
			net.send_tcp(client, transmute([]u8)answer)
			net.close(client)
			free_all(context.temp_allocator)
		}
	})
	return s
}

@(private = "file")
serve_end :: proc(s: ^Server) {
	thread.join(s.thread)
	thread.destroy(s.thread)
	net.close(s.socket)
	free(s)
}

// A body, a redirect followed to it, a missing file said by its status, a body over the bound refused.
@(test)
a_get_over_http :: proc(t: ^testing.T) {
	s := serve_start(t, 5)   // (the redirect is two requests)
	defer serve_end(s)
	at := proc(s: ^Server, path: string) -> string { return fmt.tprintf("http://127.0.0.1:%d%s", s.port, path) }

	status, body, err := get(at(s, "/file"))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)
	testing.expect_value(t, string(body), FILE_BODY)
	delete(body)

	status, body, err = get(at(s, "/moved"))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)
	testing.expect_value(t, string(body), FILE_BODY)
	delete(body)

	status, body, err = get(at(s, "/missing"))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 404)
	delete(body)

	_, body, err = get(at(s, "/big"), {max_bytes = 1024})
	testing.expect_value(t, err, Error.Too_Large)
	testing.expect(t, body == nil)

	_, _, err = get("ftp://127.0.0.1/file")
	testing.expect_value(t, err, Error.Bad_Url)
}

@(test)
a_url_in_parts :: proc(t: ^testing.T) {
	u, ok := url_parse("https://github.com/o/r/releases/latest/download/x.json")
	testing.expect(t, ok)
	testing.expect_value(t, u, Url{secure = true, host = "github.com", port = 443, path = "/o/r/releases/latest/download/x.json"})
	u, ok = url_parse("http://127.0.0.1:8080?q=1#top")
	testing.expect(t, ok)
	testing.expect_value(t, u, Url{host = "127.0.0.1", port = 8080, path = "/?q=1"})
	_, ok = url_parse("https://user:pw@host/")
	testing.expect(t, !ok, "no credentials")
	_, ok = url_parse("https://host:99999/")
	testing.expect(t, !ok, "a port")
	_, ok = url_parse("file:///etc/passwd")
	testing.expect(t, !ok)
}
