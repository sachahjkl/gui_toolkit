// Capabilities (plugins.md, "As built: capabilities"): a plugin that asks for permissions is off until the person
// allows them, a call without its grant is refused with PermissionError, a grant is kept and a version that asks more
// asks again; the broker's checks: a path that leaves its folder or goes through a link, a redirect to another origin,
// the clipboard read outside a person's act. Each call crosses the plugin's process to the program's broker and back.
package plugins_test

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "gt:platform"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

// A plugin of commands that say, as a toast, what each call gave: "ok <value>" or "<error's name>: <message>".
BROKER_MAIN :: `import { clipboard, commands, files, http, toast } from "gt";
const say = (p) => p.then((v) => toast.show("ok " + (v && typeof v === "object" ? v.status + " " + v.text : v)), (e) => toast.show(e.name + ": " + e.message));
export function activate(context) {
	commands.on("copy", () => say(clipboard.write("copied")));
	commands.on("paste", () => say(clipboard.read()));
	commands.on("save", () => say(files.write("notes/a.txt", "hi").then(() => files.read("notes/a.txt"))));
	commands.on("escape", () => say(files.read("../outside.txt")));
	commands.on("docs", () => say(files.read("~documents/x.txt")));
	commands.on("pick", () => say(files.pick().then((p) => files.read(p))));
	commands.on("same", () => say(http.fetch(globalThis.base + "/same")));
	commands.on("away", () => say(http.fetch(globalThis.base + "/away")));
	commands.on("other", () => say(http.fetch("http://192.168.0.1/")));
	// (the read runs in the turn of the write's answer, not in the command's: no person's act any more)
	commands.on("later", () => say(files.write("t.txt", "x").then(() => clipboard.read())));
	globalThis.base = context.name.split(" ")[1] || "";
}
`

broker_manifest :: proc(permissions: string, base := "") -> string {
	return fmt.tprintf(`{{
	"id": "broker", "name": "Broker %s", "api": 4, "main": "main.js", "permissions": [%s],
	"commands": [{{"id": "copy"}}, {{"id": "paste"}}, {{"id": "save"}}, {{"id": "escape"}}, {{"id": "docs"}}, {{"id": "pick"}}, {{"id": "same"}}, {{"id": "away"}}, {{"id": "other"}}, {{"id": "later"}}]
}}`, base, permissions)
}

// Runs a command and waits for the toast that says what it gave.
said :: proc(s: ^session.Session, fx: ^Fx, command: string) -> string {
	toasts := fx.host.toasts
	testing.expectf(s.t, plugins.run_command(&fx.host, fmt.tprintf("plugin.broker.%s", command)), "the command %s did not run", command)
	session.wait_until(s, Count{fx, toasts + 1}, answered, "the call's answer", WAIT)
	return fx.host.last_toast
}


@(test)
a_plugin_that_asks_is_off_until_allowed :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-grant")
	write_plugin(root, "broker", broker_manifest(`"clipboard.write"`), BROKER_MAIN)
	enable(root, "broker")   // (on in plugins.toml, granted nothing: it asks first)
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	testing.expect_value(t, plugins.state_of(&fx.host, "broker"), plugins.Plugin_State.Off)
	testing.expect(t, !plugins.run_command(&fx.host, "plugin.broker.copy"), "a plugin that asks ran before it was allowed")
	// turning it on shows the dialog; Allow grants what it asks
	plugins.set_enabled(&fx.host, "broker", true)
	session.wait_text(s, "Put text on the clipboard", WAIT)
	// (a dialog is measured unseen first, and takes no click until it shows: its fade ends)
	session.wait_idle(s, WAIT)
	session.click(s, "grant_allow")
	wait_state(s, fx, "broker", .Ready)
	wait_started(s, fx, "broker")
	testing.expectf(t, strings.contains(said(s, fx, "copy"), "ok"), "clipboard.write granted: '%s'", fx.host.last_toast)
	// a call it did not ask for: refused at once
	testing.expectf(t, strings.contains(said(s, fx, "paste"), "PermissionError"), "clipboard.read not granted: '%s'", fx.host.last_toast)
	// the grant is kept; a version that asks more asks again
	session.wait_until(s, root, proc(s: ^session.Session, root: string) -> bool {
		data, err := os.read_entire_file(fmt.tprintf("%s/config/plugins.toml", root), context.temp_allocator)
		return err == nil && strings.contains(string(data), `broker = "clipboard.write"`)
	}, "the grant in plugins.toml", WAIT)
	plugins.reload(&fx.host)
	wait_state(s, fx, "broker", .Ready)
	write_plugin(root, "broker", broker_manifest(`"clipboard.write", "clipboard.read"`), BROKER_MAIN)
	plugins.reload(&fx.host)
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool {
		p := plugins.find(&fx.host, "broker")
		return p != nil && p.asks_more && p.state == .Off
	}, "the version that asks more, off", WAIT)
	plugins.revoke(&fx.host, "broker")
	testing.expect_value(t, len(plugins.find(&fx.host, "broker").granted), 0)
}

@(test)
the_data_folder_and_paths_that_escape :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-files")
	write_plugin(root, "broker", broker_manifest(`"files"`), BROKER_MAIN)
	enable(root, "broker")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	testing.expect(t, plugins.grant(&fx.host, "broker"), "no grant")
	testing.expectf(t, said(s, fx, "save") == "ok hi", "its data folder: '%s'", fx.host.last_toast)
	data, err := os.read_entire_file(fmt.tprintf("%s/data/broker/notes/a.txt", root), context.temp_allocator)
	testing.expect(t, err == nil && string(data) == "hi", "the file is not in the plugin's data folder")
	testing.expectf(t, strings.contains(said(s, fx, "escape"), "PermissionError"), "a path out of its folder: '%s'", fx.host.last_toast)
	testing.expectf(t, strings.contains(said(s, fx, "docs"), "PermissionError"), "a folder not granted: '%s'", fx.host.last_toast)

	// a file picked in the dialog is granted, and read
	picked := fmt.tprintf("%s/picked.txt", root)
	_ = os.write_entire_file(picked, transmute([]u8)string("from the dialog"))
	picked_path = picked
	platform.dialog_test_hook = proc(kind: int, d: platform.File_Dialog, allocator: runtime.Allocator) -> platform.Dialog_Result {
		paths := make([]string, 1, allocator)
		paths[0] = strings.clone(picked_path, allocator)
		return {status = .Chosen, paths = paths}
	}
	defer platform.dialog_test_hook = nil
	// (a pick needs a person's act: a command is one)
	testing.expectf(t, said(s, fx, "pick") == "ok from the dialog", "a file picked: '%s'", fx.host.last_toast)
	p := plugins.find(&fx.host, "broker")
	testing.expect(t, len(p.picked) == 1 && p.picked[0] == picked, "the file picked is not granted")
}

// (the dialog's hook has no user data: the test's file)
@(private = "file")
picked_path: string

@(test)
path_resolve_refuses_what_leaves_its_folder :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-paths")
	data := fmt.tprintf("%s/data", root)
	folder := fmt.tprintf("%s/picked", root)
	_ = os.make_directory_all(fmt.tprintf("%s/sub", folder))
	Case :: struct { path: string, refused: bool, ok: bool }
	cases := [?]Case{
		{"notes/a.txt", false, true},
		{"../a.txt", true, false},
		{"notes/../../a.txt", true, false},
		{"~documents/a.txt", true, false},
		{fmt.tprintf("%s/sub/b.txt", folder), false, true},
		{fmt.tprintf("%s/../other.txt", folder), true, false},
		{fmt.tprintf("%s/other.txt", root), true, false},
	}
	for c in cases {
		_, refused, why := plugins.path_resolve(c.path, data, {}, {folder})
		testing.expectf(t, refused == c.refused && (why == "") == c.ok, "%s: refused %v, '%s'", c.path, refused, why)
	}
	when ODIN_OS == .Linux {
		// (a link inside the folder, to a file out of it: refused, never followed)
		_ = os.write_entire_file(fmt.tprintf("%s/secret.txt", root), transmute([]u8)string("secret"))
		_ = os.symlink(fmt.tprintf("%s/secret.txt", root), fmt.tprintf("%s/sub/link.txt", folder))
		_, refused, why := plugins.path_resolve(fmt.tprintf("%s/sub/link.txt", folder), data, {}, {folder})
		testing.expectf(t, refused && why != "", "a link: refused %v, '%s'", refused, why)
	}
}

@(test)
origins_and_private_hosts :: proc(t: ^testing.T) {
	testing.expect(t, plugins.net_allowed({"net:https://api.example.com"}, "https://api.example.com/v1?x=1"), "the origin named")
	testing.expect(t, !plugins.net_allowed({"net:https://api.example.com"}, "https://api.example.com:8443/"), "another port")
	testing.expect(t, !plugins.net_allowed({"net:https://api.example.com"}, "http://api.example.com/"), "another scheme")
	testing.expect(t, plugins.net_allowed({"net:*"}, "https://example.org/"), "any public origin")
	for host in ([?]string{"localhost", "127.0.0.1", "10.1.2.3", "192.168.0.1", "172.20.0.1", "169.254.1.1", "[::1]", "printer.local"}) {
		testing.expectf(t, !plugins.net_allowed({"net:*"}, fmt.tprintf("http://%s/", host)), "net:* reached %s", host)
	}
	testing.expect(t, plugins.net_allowed({"net:http://localhost:8080"}, "http://localhost:8080/x"), "a private host named")
	_, _, ok := plugins.permission_parse("net:https://a.com/path")
	testing.expect(t, !ok, "a permission with a path")
	testing.expect_value(t, plugins.url_join("https://a.com/x/y?q", "z"), "https://a.com/x/z")
	testing.expect_value(t, plugins.url_join("https://a.com/x/y", "/z"), "https://a.com/z")
	testing.expect_value(t, plugins.url_join("https://a.com/x", "//b.com/z"), "https://b.com/z")
}

// A server on the loopback: /same redirects to /ok of its own origin, /away to /ok of another origin (localhost, not
// 127.0.0.1), /ok answers "fine".
@(private = "file")
Server :: struct { socket: net.TCP_Socket, port: int, count: int, thread: ^thread.Thread }

@(private = "file")
serve :: proc(count: int) -> ^Server {
	s := new(Server)
	s.count = count
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil { return s }
	s.socket = sock
	ep, _ := net.bound_endpoint(sock)
	s.port = ep.port
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^Server) {
		for _ in 0 ..< s.count {
			client, _, err := net.accept_tcp(s.socket)
			if err != nil { return }
			buf: [4096]u8
			got := 0
			for got < len(buf) {
				n, rerr := net.recv_tcp(client, buf[got:])
				if rerr != nil || n <= 0 { break }
				got += n
				if strings.contains(string(buf[:got]), "\r\n\r\n") { break }
			}
			line := string(buf[:got])
			if nl := strings.index_byte(line, '\r'); nl >= 0 { line = line[:nl] }
			answer: string
			switch {
			case strings.contains(line, " /same "): answer = fmt.tprintf("HTTP/1.1 302 Found\r\nLocation: /ok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
			case strings.contains(line, " /away "): answer = fmt.tprintf("HTTP/1.1 302 Found\r\nLocation: http://localhost:%d/ok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", s.port)
			case strings.contains(line, " /ok "):   answer = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nfine"
			case:                                    answer = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			}
			net.send_tcp(client, transmute([]u8)answer)
			net.close(client)
		}
	})
	return s
}

@(test)
each_redirect_is_checked :: proc(t: ^testing.T) {
	srv := serve(3)   // (/same and its /ok, /away: its hop is refused before it is asked)
	defer {
		// (its three requests came: the thread ended on its own)
		if srv.thread != nil { thread.join(srv.thread); thread.destroy(srv.thread) }
		net.close(srv.socket)
		free(srv)
	}
	if !testing.expect(t, srv.port != 0, "no server") { return }
	base := fmt.tprintf("http://127.0.0.1:%d", srv.port)
	root := testkit.temp_folder(t, "plugin-fetch")
	write_plugin(root, "broker", broker_manifest(fmt.tprintf(`"net:%s"`, base), base), BROKER_MAIN)
	enable(root, "broker")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	testing.expect(t, plugins.grant(&fx.host, "broker"), "no grant")
	testing.expectf(t, said(s, fx, "same") == "ok 200 fine", "a redirect in its origin: '%s'", fx.host.last_toast)
	testing.expectf(t, strings.contains(said(s, fx, "away"), "PermissionError"), "a redirect to another origin: '%s'", fx.host.last_toast)
	testing.expectf(t, strings.contains(said(s, fx, "other"), "PermissionError"), "an origin not granted: '%s'", fx.host.last_toast)
}

@(test)
the_clipboard_is_read_only_during_a_persons_act :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-clipboard")
	write_plugin(root, "broker", broker_manifest(`"clipboard.read", "clipboard.write"`), BROKER_MAIN)
	enable(root, "broker")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	testing.expect(t, plugins.grant(&fx.host, "broker"), "no grant")
	testing.expectf(t, said(s, fx, "copy") == "ok undefined", "clipboard.write: '%s'", fx.host.last_toast)
	testing.expectf(t, strings.contains(said(s, fx, "later"), "PermissionError"), "a read out of a person's act: '%s'", fx.host.last_toast)
}
