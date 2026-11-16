package tk_http

// Requests reuse their connections (src/md/features/http-connections.md): a server that keeps its connections open counts
// the sockets it accepts.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

// A server of this process on a port of the loopback that keeps each connection open: every request (a GET) is answered
// "ok" on the connection it came on, until the client closes it. `accepted` counts the connections.
@(private = "file")
Keep_Server :: struct {
	socket:   net.TCP_Socket,
	port:     int,
	accepted: int,   // atomic
	served:   int,   // atomic
	lock:     sync.Mutex,
	clients:  [dynamic]net.TCP_Socket,
	threads:  [dynamic]^thread.Thread,
	acceptor: ^thread.Thread,
}

@(private = "file") KEEP_ANSWER :: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"

@(private = "file")
keep_start :: proc(t: ^testing.T) -> ^Keep_Server {
	s := new(Keep_Server)
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil, "listen")
	s.socket = sock
	ep, _ := net.bound_endpoint(sock)
	s.port = ep.port
	s.acceptor = thread.create_and_start_with_poly_data(s, proc(s: ^Keep_Server) {
		for {
			client, _, err := net.accept_tcp(s.socket)
			if err != nil { return }   // (keep_end shut the listener)
			sync.atomic_add(&s.accepted, 1)
			Conn :: struct { s: ^Keep_Server, client: net.TCP_Socket }
			sync.mutex_lock(&s.lock)
			append(&s.clients, client)
			append(&s.threads, thread.create_and_start_with_poly_data(Conn{s, client}, proc(c: Conn) {
				data := make([dynamic]u8)
				defer delete(data)
				buf: [4096]u8
				for {
					// (a GET has no body: a request ends at its blank line)
					end := strings.index(string(data[:]), "\r\n\r\n")
					if end < 0 {
						n, err := net.recv_tcp(c.client, buf[:])
						if err != nil || n <= 0 { return }   // (the client closed it, or keep_end shut it)
						append(&data, ..buf[:n])
						continue
					}
					remove_range(&data, 0, end + 4)
					sync.atomic_add(&c.s.served, 1)
					if _, err := net.send_tcp(c.client, transmute([]u8)string(KEEP_ANSWER)); err != nil { return }
				}
			}))
			sync.mutex_unlock(&s.lock)
		}
	})
	return s
}

@(private = "file")
keep_end :: proc(s: ^Keep_Server) {
	// (a shut listener wakes the accept that waits; a shut connection wakes its reader: the pool keeps the client's open)
	net.shutdown(s.socket, .Both)
	net.close(s.socket)
	thread.join(s.acceptor)
	thread.destroy(s.acceptor)
	for c in s.clients { net.shutdown(c, .Both) }
	for th in s.threads { thread.join(th); thread.destroy(th) }
	for c in s.clients { net.close(c) }
	delete(s.clients)
	delete(s.threads)
	free(s)
}

@(private = "file")
keep_url :: proc(s: ^Keep_Server) -> string { return fmt.tprintf("http://127.0.0.1:%d/n", s.port) }

// Five requests in a row to one server: one connection.
@(test)
requests_in_a_row_share_one_connection :: proc(t: ^testing.T) {
	s := keep_start(t)
	defer keep_end(s)
	for i in 0 ..< 5 {
		status, body, err := get(keep_url(s))
		testing.expectf(t, err == .None && status == 200 && string(body) == "ok", "request %d: %v %d %q", i, err, status, string(body))
		delete(body)
	}
	testing.expect_value(t, sync.atomic_load(&s.served), 5)
	testing.expect_value(t, sync.atomic_load(&s.accepted), 1)
}

// Four threads of five requests each: every request is answered, on four connections at most (one per request in
// flight), not twenty.
@(test)
requests_from_several_threads_share_connections :: proc(t: ^testing.T) {
	THREADS :: 4
	EACH :: 5
	s := keep_start(t)
	defer keep_end(s)
	Worker :: struct { url: string, ok: int }
	workers: [THREADS]Worker
	threads: [THREADS]^thread.Thread
	url := keep_url(s)
	for &w, i in workers {
		w.url = url
		threads[i] = thread.create_and_start_with_poly_data(&w, proc(w: ^Worker) {
			for _ in 0 ..< EACH {
				status, body, err := get(w.url)
				if err == .None && status == 200 && string(body) == "ok" { w.ok += 1 }
				delete(body)
			}
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	for w, i in workers { testing.expectf(t, w.ok == EACH, "thread %d: %d of %d answered", i, w.ok, EACH) }
	testing.expect_value(t, sync.atomic_load(&s.served), THREADS * EACH)
	accepted := sync.atomic_load(&s.accepted)
	testing.expectf(t, accepted >= 1 && accepted <= THREADS, "%d connections for %d threads", accepted, THREADS)
}
