package tk_update

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../fsx"
import signing "../signing"

// A release served on the loopback: its files by name, 404 for the others. Stopped by a last connection of its own.
@(private = "file")
Release_Server :: struct {
	socket:  net.TCP_Socket,
	port:    int,
	files:   map[string][]byte,
	stop:    bool,
	served:  int,   // (atomic)
	thread:  ^thread.Thread,
}

@(private = "file")
release_serve :: proc(t: ^testing.T, files: map[string][]byte) -> ^Release_Server {
	s := new(Release_Server)
	s.files = files
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil, "listen")
	s.socket = sock
	ep, _ := net.bound_endpoint(sock)
	s.port = ep.port
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^Release_Server) {
		for {
			client, _, err := net.accept_tcp(s.socket)
			if err != nil || sync.atomic_load(&s.stop) { if err == nil { net.close(client) }; return }
			buf: [4096]u8
			n, _ := net.recv_tcp(client, buf[:])
			parts := strings.split(string(buf[:n]), " ", context.temp_allocator)
			name := len(parts) >= 2 ? strings.trim_prefix(parts[1], "/") : ""
			if body, ok := s.files[name]; ok {
				head := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(body))
				net.send_tcp(client, transmute([]u8)head)
				net.send_tcp(client, body)
			} else {
				net.send_tcp(client, transmute([]u8)string("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
			}
			net.close(client)
			sync.atomic_add(&s.served, 1)
			free_all(context.temp_allocator)
		}
	})
	return s
}

@(private = "file")
release_end :: proc(s: ^Release_Server) {
	sync.atomic_store(&s.stop, true)
	if c, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, s.port}); err == nil { net.close(c) }
	thread.join(s.thread)
	thread.destroy(s.thread)
	net.close(s.socket)
	free(s)
}

@(private = "file")
updater_product :: proc() -> Product {
	key, _ := signing.public_key_of(TEST_SEED[:], context.temp_allocator)
	return {name = "app", sign_context = "app-update-v1\n", public_key = key}
}

// A program of this system, of `n` bytes, the same for the same `mark`.
@(private = "file")
program_bytes :: proc(mark: byte) -> []byte {
	data := make([]byte, MIN_BINARY, context.temp_allocator)
	for i in 0 ..< len(data) { data[i] = byte(i * 31) ~ mark }
	copy(data, PLATFORM == PLATFORM_WINDOWS_X64 ? "MZ" : "\x7fELF")
	return data
}

// The files of a release of `version` for this system: its manifest, signed, and the program.
@(private = "file")
release_files :: proc(version: string, program: []byte) -> map[string][]byte {
	p := updater_product()
	m := manifest_of(p, program, {version = version, platform = PLATFORM, published = "2026-11-10"}, context.temp_allocator)
	bytes := manifest_bytes(p, m, context.temp_allocator)
	sig, _ := sign(p, TEST_SEED[:], bytes, context.temp_allocator)
	files := make(map[string][]byte, context.temp_allocator)
	name := manifest_name(PLATFORM, "", context.temp_allocator)
	files[name] = bytes
	files[fmt.tprintf("%s.sig", name)] = transmute([]byte)sig
	files[m.file] = program
	return files
}

// Waits for the updater to reach `phase` (10 s at most).
@(private = "file")
wait_phase :: proc(u: ^Updater, phase: Phase) -> Status {
	deadline := time.time_add(time.now(), 10 * time.Second)
	for {
		st := status(u)
		if st.phase == phase || time.diff(time.now(), deadline) <= 0 { return st }
		time.sleep(5 * time.Millisecond)
	}
}

@(private = "file")
News :: struct { count: int }

@(private = "file")
on_news :: proc(user: rawptr) { sync.atomic_add(&(^News)(user).count, 1) }

@(private = "file")
program_folder :: proc(name: string) -> (dir, exe: string) {
	dir = fmt.tprintf("%s/tk_updater_%s_%d", fsx.temp_dir(context.temp_allocator), name, os.get_pid())
	_ = fsx.remove_tree(dir)
	_ = os.make_directory_all(dir)
	exe = fmt.tprintf("%s/app", dir)
	_ = os.write_entire_file(exe, program_bytes(1))
	return
}

// Asked: a check finds the newer version and offers it; asked again, it is installed in place of the program.
@(test)
an_update_found_then_installed :: proc(t: ^testing.T) {
	if PLATFORM == "" { return }
	dir, exe := program_folder("asked")
	defer fsx.remove_tree(dir)
	program := program_bytes(2)
	s := release_serve(t, release_files("2.0.0", program))
	defer release_end(s)
	news: News
	u := updater_start({product = updater_product(), folder = fmt.tprintf("http://127.0.0.1:%d/", s.port), current = "1.0.0", exe = exe, news = on_news, user = &news})
	defer updater_stop(u)

	check_now(u)
	st := wait_phase(u, .Available)
	testing.expect_value(t, st.phase, Phase.Available)
	testing.expect_value(t, st.version, "2.0.0")
	testing.expect(t, st.asked && !st.failed, "an answer to the user's question")
	back, _ := os.read_entire_file_from_path(exe, context.temp_allocator)
	testing.expect(t, string(back) != string(program), "offered, not installed")

	install_now(u)
	st = wait_phase(u, .Installed)
	testing.expect_value(t, st.phase, Phase.Installed)
	testing.expect_value(t, st.version, "2.0.0")
	back, _ = os.read_entire_file_from_path(exe, context.temp_allocator)
	testing.expect(t, string(back) == string(program), "the new program in place")
	testing.expect(t, sync.atomic_load(&news.count) >= 4, "each change heard")
}

// Automatic: a while after the start it checks and installs by itself, and says nothing was asked.
@(test)
an_update_installed_by_itself :: proc(t: ^testing.T) {
	if PLATFORM == "" { return }
	dir, exe := program_folder("auto")
	defer fsx.remove_tree(dir)
	program := program_bytes(3)
	s := release_serve(t, release_files("1.1.0", program))
	defer release_end(s)
	u := updater_start({product = updater_product(), folder = fmt.tprintf("http://127.0.0.1:%d/", s.port), current = "1.0.0", exe = exe, first_check = time.Millisecond})
	defer updater_stop(u)
	set_auto(u, .Install)
	st := wait_phase(u, .Installed)
	testing.expect_value(t, st.phase, Phase.Installed)
	testing.expect(t, !st.asked, "not asked")
	back, _ := os.read_entire_file_from_path(exe, context.temp_allocator)
	testing.expect(t, string(back) == string(program))
}

// The same version, or none published for this system: up to date. A server that cannot be reached: a failure, said.
@(test)
nothing_newer_is_up_to_date :: proc(t: ^testing.T) {
	if PLATFORM == "" { return }
	dir, exe := program_folder("same")
	defer fsx.remove_tree(dir)
	s := release_serve(t, release_files("1.0.0", program_bytes(4)))
	u := updater_start({product = updater_product(), folder = fmt.tprintf("http://127.0.0.1:%d/", s.port), current = "1.0.0", exe = exe})
	check_now(u)
	deadline := time.time_add(time.now(), 10 * time.Second)
	for status(u).serial < 2 && time.diff(time.now(), deadline) > 0 { time.sleep(5 * time.Millisecond) }
	st := status(u)
	testing.expect_value(t, st.phase, Phase.Idle)
	testing.expect_value(t, st.result, "up to date")
	updater_stop(u)

	empty := release_serve(t, {})
	u = updater_start({product = updater_product(), folder = fmt.tprintf("http://127.0.0.1:%d/", empty.port), current = "1.0.0", exe = exe})
	check_now(u)
	deadline = time.time_add(time.now(), 10 * time.Second)
	for status(u).serial < 2 && time.diff(time.now(), deadline) > 0 { time.sleep(5 * time.Millisecond) }
	testing.expect_value(t, status(u).result, "up to date")
	updater_stop(u)
	port := empty.port
	release_end(empty)
	release_end(s)

	u = updater_start({product = updater_product(), folder = fmt.tprintf("http://127.0.0.1:%d/", port), current = "1.0.0", exe = exe})
	check_now(u)
	deadline = time.time_add(time.now(), 10 * time.Second)
	for status(u).serial < 2 && time.diff(time.now(), deadline) > 0 { time.sleep(5 * time.Millisecond) }
	st = status(u)
	testing.expect(t, st.failed && st.asked, "the failure said")
	testing.expect_value(t, st.phase, Phase.Idle)
	updater_stop(u)
}

// A copy of the Nix store: its package manager updates it; nothing is asked.
@(test)
a_managed_copy_is_left_alone :: proc(t: ^testing.T) {
	u := updater_start({product = updater_product(), folder = "http://127.0.0.1:9/", current = "1.0.0", exe = "/nix/store/abc-app-1.0.0/bin/app"})
	defer updater_stop(u)
	set_auto(u, .Install)
	check_now(u)
	st := status(u)
	testing.expect_value(t, st.phase, Phase.Managed)
	testing.expect(t, st.asked && !st.failed && st.result != "", "it says why")
}
