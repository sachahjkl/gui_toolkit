package tk_http

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "../ascii"

// A server of this process on a port of the loopback: /file, /moved (a redirect to /file), /big, /echo (the method, the
// X-Test header and the body, sent back; the answer has an X-Echo header); anything else is 404. It answers `count`
// requests, then stops.
@(private = "file")
Server :: struct {
	socket: net.TCP_Socket,
	port:   int,
	count:  int,
	thread: ^thread.Thread,
}

@(private = "file") FILE_BODY :: "the file's bytes"

// One request read whole: its head, then as many body bytes as its Content-Length says (they may come in several reads).
@(private = "file")
read_request :: proc(client: net.TCP_Socket) -> (head: string, body: string) {
	data := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	head_end := -1
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n <= 0 { break }
		append(&data, ..buf[:n])
		if head_end < 0 { head_end = strings.index(string(data[:]), "\r\n\r\n") }
		if head_end < 0 { continue }
		length := 0
		for line in strings.split_lines(string(data[:head_end]), context.temp_allocator) {
			if colon := strings.index_byte(line, ':'); colon > 0 && ascii.lower(line[:colon], context.temp_allocator) == "content-length" {
				length, _ = strconv.parse_int(strings.trim_space(line[colon + 1:]))
			}
		}
		if len(data) >= head_end + 4 + length { return string(data[:head_end]), string(data[head_end + 4:head_end + 4 + length]) }
	}
	return string(data[:]), ""
}

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
			head, body := read_request(client)
			lines := strings.split_lines(head, context.temp_allocator)
			method, path := "", ""
			if parts := strings.split(lines[0], " ", context.temp_allocator); len(parts) >= 2 { method, path = parts[0], parts[1] }
			answer: string
			switch path {
			case "/file":  answer = fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(FILE_BODY), FILE_BODY)
			case "/moved": answer = fmt.tprintf("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:%d/file\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", s.port)
			case "/big":   answer = fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n%s", strings.repeat("x", 4096, context.temp_allocator))
			case "/echo":
				test, content_type := "", ""
				for line in lines[1:] {
					colon := strings.index_byte(line, ':')
					if colon <= 0 { continue }
					switch ascii.lower(line[:colon], context.temp_allocator) {
					case "x-test":       test = strings.trim_space(line[colon + 1:])
					case "content-type": content_type = strings.trim_space(line[colon + 1:])
					}
				}
				echo := fmt.tprintf("%s\n%s\n%s\n%s", method, test, content_type, body)
				answer = fmt.tprintf("HTTP/1.1 201 Created\r\nX-Echo: yes\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(echo), echo)
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

@(private = "file")
at :: proc(s: ^Server, path: string) -> string { return fmt.tprintf("http://127.0.0.1:%d%s", s.port, path) }

// A body, a redirect followed to it, a missing file said by its status, a body over the bound refused.
@(test)
a_get_over_http :: proc(t: ^testing.T) {
	s := serve_start(t, 5)   // (the redirect is two requests)
	defer serve_end(s)

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

// A POST and a PUT with a header and a body: the server sees the method, the header, the body and no Content-Type of the
// client's own; the answer's headers and its address come back. A redirect's answer is the last one's.
@(test)
a_request_with_a_body :: proc(t: ^testing.T) {
	s := serve_start(t, 5)
	defer serve_end(s)

	form, content_type := multipart({form_text("a", "1"), form_file("f", "x.png", "image/png", transmute([]u8)string("PNG"))}, context.temp_allocator)
	res, err := request("POST", at(s, "/echo"), {headers = {{"X-Test", "hello"}, {"Content-Type", content_type}}, body = form})
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, res.status, 201)
	testing.expect_value(t, string(res.body), fmt.tprintf("POST\nhello\n%s\n%s", content_type, string(form)))
	echo, has_echo := header_value(res.headers, "x-echo")
	testing.expect(t, has_echo)
	testing.expect_value(t, echo, "yes")
	testing.expect_value(t, res.url, at(s, "/echo"))
	response_destroy(&res)

	res, err = request("PUT", at(s, "/echo"), {body = transmute([]u8)string("put body")})
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, string(res.body), "PUT\n\n\nput body")
	response_destroy(&res)

	res, err = request("GET", at(s, "/moved"))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, res.status, 200)
	testing.expect_value(t, res.url, at(s, "/file"))
	_, has_location := header_value(res.headers, "Location")
	testing.expect(t, !has_location, "the headers are the last answer's")
	response_destroy(&res)

	_, err = request("GET POST", at(s, "/file"))
	testing.expect_value(t, err, Error.Bad_Request)
	_, err = request("GET", at(s, "/file"), {headers = {{"X-Test", "a\r\nX-Other: b"}}})
	testing.expect_value(t, err, Error.Bad_Request)
	_, err = request("GET", at(s, "/file"), {headers = {{"X Test", "a"}}})
	testing.expect_value(t, err, Error.Bad_Request)
	// (the server still waits for one request: the refused ones never reached it)
	_, body, _ := get(at(s, "/file"))
	delete(body)
}

// The bytes of a form, exactly: a text field, a file, a name with a quote.
@(test)
a_multipart_form :: proc(t: ^testing.T) {
	fields := []Form_Field{
		form_text("reqtype", "fileupload"),
		form_file("fileToUpload", "shot.png", "image/png", transmute([]u8)string("\x89PNG")),
		form_file("raw", "a\"b.bin", "", transmute([]u8)string("x")),
	}
	body := multipart_with(fields, "BOUND", context.temp_allocator)
	expected :=
		"--BOUND\r\nContent-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n" +
		"--BOUND\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"shot.png\"\r\nContent-Type: image/png\r\n\r\n\x89PNG\r\n" +
		"--BOUND\r\nContent-Disposition: form-data; name=\"raw\"; filename=\"a%22b.bin\"\r\nContent-Type: application/octet-stream\r\n\r\nx\r\n" +
		"--BOUND--\r\n"
	testing.expect_value(t, string(body), expected)

	empty := multipart_with(nil, "B", context.temp_allocator)
	testing.expect_value(t, string(empty), "--B--\r\n")

	// The random boundary: in the Content-Type, at the start of the body, and in no field.
	random_body, content_type := multipart(fields, context.temp_allocator)
	testing.expect(t, strings.has_prefix(content_type, "multipart/form-data; boundary="))
	boundary := content_type[len("multipart/form-data; boundary="):]
	testing.expect(t, strings.has_prefix(string(random_body), strings.concatenate({"--", boundary, "\r\n"}, context.temp_allocator)))
	testing.expect(t, boundary_free(fields, boundary))
	testing.expect(t, !boundary_free({form_text("a", "xx--BOUNDyy")}, "BOUND"), "a field that holds the boundary")
}

@(test)
a_url_encoded_form :: proc(t: ^testing.T) {
	testing.expect_value(t, form_urlencoded({{"a", "1"}, {"b c", "x y&z=é"}, {"k", "*-._~"}}, context.temp_allocator), "a=1&b+c=x+y%26z%3D%C3%A9&k=*-._%7E")
	testing.expect_value(t, form_urlencoded(nil, context.temp_allocator), "")
	testing.expect_value(t, query_append("https://h/p", {{"k", "v 1"}}, context.temp_allocator), "https://h/p?k=v+1")
	testing.expect_value(t, query_append("https://h/p?a=1", {{"k", "v"}, {"x", ""}}, context.temp_allocator), "https://h/p?a=1&k=v&x=")
	testing.expect_value(t, query_append("https://h/p?#top", {{"k", "v"}}, context.temp_allocator), "https://h/p?k=v#top")
	testing.expect_value(t, query_append("https://h/p", nil, context.temp_allocator), "https://h/p")
}

@(test)
headers_of_an_answer :: proc(t: ^testing.T) {
	text := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Two:  b c \r\n folded\r\nbroken line\r\n\r\n"
	hs := headers_parse(text, context.temp_allocator)
	testing.expect_value(t, len(hs), 2)
	testing.expect_value(t, hs[0], Header{"Content-Type", "text/plain"})
	testing.expect_value(t, hs[1], Header{"X-Two", "b c"})
	v, ok := header_value(hs, "content-type")
	testing.expect(t, ok)
	testing.expect_value(t, v, "text/plain")
	_, ok = header_value(hs, "Location")
	testing.expect(t, !ok)
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
