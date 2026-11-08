package tk_cdp

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import "../ascii"

@(private) HTTP_READ_LIMIT :: 10 * time.Second

// A GET on this machine's `port` (the discovery of a devtools server: /json/list, /json/version). Plain HTTP, nothing further:
// the protocol's servers listen on 127.0.0.1 only. The body is in the temporary allocator.
http_get :: proc(port: int, path: string) -> (status: int, body: string, ok: bool) {
	sock, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil { return }
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, HTTP_READ_LIMIT)
	head := fmt.tprintf("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\nAccept: application/json\r\n\r\n", path, port)
	if _, e := net.send_tcp(sock, transmute([]byte)head); e != nil { return }
	raw := make([dynamic]byte, context.temp_allocator)
	chunk: [16 * 1024]byte
	for {
		n, e := net.recv_tcp(sock, chunk[:])
		if e != nil || n == 0 { break }
		append(&raw, ..chunk[:n])
	}
	return http_parse(string(raw[:]))
}

// A response's status and body, its chunks joined.
http_parse :: proc(raw: string) -> (status: int, body: string, ok: bool) {
	end := strings.index(raw, "\r\n\r\n")
	if end < 0 { return }
	head := raw[:end]
	body = raw[end + 4:]
	first := head[:max(strings.index(head, "\r\n"), 0)]
	if first == "" { first = head }
	fields := strings.fields(first, context.temp_allocator)
	if len(fields) < 2 { return }
	status, ok = strconv.parse_int(fields[1])
	if !ok { return }
	for line in strings.split_lines(head, context.temp_allocator) {
		colon := strings.index_byte(line, ':')
		if colon < 0 || !ascii.equal_fold(strings.trim_space(line[:colon]), "transfer-encoding") { continue }
		if ascii.equal_fold(strings.trim_space(line[colon + 1:]), "chunked") { body, ok = http_unchunk(body) }
	}
	return
}

http_unchunk :: proc(text: string) -> (out: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	rest := text
	for {
		line := strings.index(rest, "\r\n")
		if line < 0 { return "", false }
		n, parsed := strconv.parse_int(rest[:line], 16)
		if !parsed || line + 2 + n > len(rest) { return "", false }
		if n == 0 { return strings.to_string(b), true }
		strings.write_string(&b, rest[line + 2:line + 2 + n])
		rest = rest[min(line + 4 + n, len(rest)):]
	}
}
