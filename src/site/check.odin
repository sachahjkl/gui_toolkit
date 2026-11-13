package tk_site

// A site in a real browser, Chrome or Edge with no window, on the pages its project makes of it (in a folder of its own, removed
// after). The image viewer (gallery.js of the site), on the home page and the classic screenshots: a click on a capture opens it,
// the picture loads at its own size, the arrows go through the captures, Esc closes and gives the keyboard back to the link. Every
// page: its links, pictures, styles and scripts are there, and the anchors they point at; it links the same page in the other
// presentation ("Classic version", "Modern version"). The classic pages: no sideways scrolling on a phone or a desktop, a skip link
// the keyboard reaches first and shows, a main landmark, a text for every picture, light and dark; the classic home about a screen
// high. The documentation pages (build_docs): nothing sticks out of a phone's screen but in the frame of a code block or a table, the
// menu closed there and open beside the page on a desktop, its toggle and the search working. Then the project's own checks
// (Check_Options.extra). Nothing is published: the folder is served on 127.0.0.1 for the time
// of the check. Nothing waits for a delay to run out: what a step leads to is awaited, under a limit.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import cdp "../cdp"

CHECK_CLASSIC      :: CLASSIC + "/"
CHECK_MADE_TEMP     :: "tk_site_check_pages_*"
CHECK_PROFILE_NAME  :: "tk_site_check_profile_"
CHECK_PROFILE_TEMP  :: CHECK_PROFILE_NAME + "*"
CHECK_PORT_FILE     :: "DevToolsActivePort"
CHECK_HOME_SCREENS  :: 1.5   // the classic home's height, in screens of the desktop at most
CHECK_HEAD_MAX      :: 8 * 1024
CHECK_REST_MS       :: "10000"   // (read by the page's own clock, in its text)
CHECK_START_LIMIT   :: 30 * time.Second
CHECK_PAGE_LIMIT    :: 15 * time.Second
CHECK_PICTURE_LIMIT :: 5 * time.Second
CHECK_INPUT_LIMIT   :: 2 * time.Second   // (a key's effect is there when the call ends: this is for a viewer that does not answer)
CHECK_READ_LIMIT    :: 5 * time.Second
CHECK_CLOSE_LIMIT   :: 5 * time.Second
CHECK_GONE_LIMIT    :: 30 * time.Second   // (reached only by what a slow disk holds up: it costs nothing when all is well)
CHECK_REMOVE_LIMIT  :: 30 * time.Second   // (the browser's helpers let go of the profile a moment after it ends)

// The third capture: where it stays. The lazy pictures above it load as it comes into view, and move it.
CHECK_REST :: `new Promise((ok) => {
	const a = document.querySelectorAll('.shot a.frame')[2]
	const end = Date.now() + ` + CHECK_REST_MS + `
	let last = '', still = 0
	const f = () => {
		a.scrollIntoView({ block: 'center', behavior: 'instant' })
		const r = a.getBoundingClientRect(), now = r.x + ',' + r.y
		still = now === last ? still + 1 : 0
		last = now
		still >= 6 ? ok([r.x + r.width / 2, r.y + r.height / 2]) : Date.now() > end ? ok(null) : setTimeout(f, 50)
	}
	f()
})`
// (the event is kept before the page's own handlers run: what they did to it is read after them)
CHECK_CLICK_KEPT  :: `addEventListener('click', (e) => { window.tkSiteClick = e }, { capture: true, once: true })`
CHECK_OPEN        :: `document.querySelector('dialog.lightbox').open`
CHECK_LOADED      :: `(() => { const i = document.querySelector('.lightbox img'); return i.complete && i.naturalWidth > 0 })()`
CHECK_COUNT       :: `document.querySelector('.lightbox-count').textContent`
CHECK_NO_SIDEWAYS :: `document.documentElement.scrollWidth <= innerWidth`
CHECK_FILLS       :: `(() => { const i = document.querySelector('.lightbox img').getBoundingClientRect(); return i.width > 900 && i.bottom <= innerHeight })()`
CHECK_FOCUS_BACK  :: `document.activeElement === document.querySelectorAll('.shot a.frame')[0]`
CHECK_SCROLLS     :: `!document.documentElement.classList.contains('lightbox-open')`
CHECK_LINKS       :: `[...document.querySelectorAll('a[href], img[src], link[href], script[src]')].map((e) => new URL(e.href || e.src)).filter((u) => u.origin === location.origin).map((u) => [u.pathname, decodeURIComponent(u.hash.slice(1))])`
CHECK_LANDMARKS   :: `document.querySelectorAll('main#main').length === 1 && !!document.querySelector('header') && !!document.querySelector('nav[aria-label]') && !!document.querySelector('footer')`
CHECK_ALT_TEXTS   :: `[...document.images].filter((i) => i.hasAttribute('src')).every((i) => i.hasAttribute('alt'))`
CHECK_SKIP_LINK   :: `(() => { const a = document.activeElement, r = a.getBoundingClientRect(); return a.matches('a.skip[href="#main"]') && r.left >= 0 && r.top >= 0 && getComputedStyle(a).outlineStyle !== 'none' })()`
CHECK_HIGH        :: `document.documentElement.scrollHeight / innerHeight`
CHECK_COLORS      :: `getComputedStyle(document.body).backgroundColor + ' ' + getComputedStyle(document.body).color`
CHECK_DOCS_PAGE   :: `document.body.classList.contains('docs') && !!document.querySelector('.doc-shell')`
CHECK_DOCS_MENU_SHOWN :: `getComputedStyle(document.querySelector('.doc-side')).display !== 'none'`
CHECK_DOCS_FOUND  :: `!document.getElementById('doc-search-results').hidden && document.querySelectorAll('#doc-search-results a').length > 0`
// What is drawn past the screen's right edge, but inside a code block's or a table's frame (it scrolls there): "" when nothing.
CHECK_DOCS_OUTSIDE :: `[...document.body.querySelectorAll('*')].filter((e) => !(e.parentElement && e.parentElement.closest('pre, .table-box')) && e.getClientRects().length > 0 && e.getBoundingClientRect().right > innerWidth + 1).slice(0, 3).map((e) => e.tagName.toLowerCase() + (e.className ? '.' + e.className : '') + ' ' + Math.round(e.getBoundingClientRect().right) + ' px').join(', ')`

Site_View :: struct {
	width, height: int,
	mobile:        bool,
}

CHECK_DESKTOP :: Site_View{width = 1400, height = 900}
CHECK_PHONE   :: Site_View{width = 375, height = 812, mobile = true}
CHECK_DOCS_PHONE :: Site_View{width = 390, height = 844, mobile = true}

Site_Link :: struct {
	path, anchor: string,
}

Site_Server :: struct {
	root:     string,
	listener: net.TCP_Socket,
	port:     int,
	accepter: ^thread.Thread,
	stop:     bool,   // (atomic)
	serving:  int,    // connections being answered (atomic)
}

@(private = "file")
Site_Client :: struct {
	server: ^Site_Server,
	sock:   net.TCP_Socket,
}

Check :: struct {
	client:         cdp.Client,
	browser:        os.Process,
	started, ended: bool,
	connected:      bool,
	origin, root:   string,
	shot:           string,
	threw:          string,   // what the last expression threw
	passed, failed: int,
	left_behind:    bool,     // a process or a folder that would not go: the run failed, whatever its checks said
	extra:          proc(s: ^Check),
	user:           rawptr,   // the project's, for its checks
}

// The file of a path of the site, or !ok: what comes from a browser or a page never leaves `root`. A folder is its index. A
// backslash separates on Windows, a colon names a stream or a drive, and a name's trailing dots and spaces are dropped there:
// ".. " would be "..".
site_file :: proc(root, path: string) -> (file: string, ok: bool) {
	whole := strings.has_suffix(path, "/") ? strings.concatenate({path, "index.html"}, context.temp_allocator) : path
	slashes, _ := strings.replace_all(whole, "\\", "/", context.temp_allocator)
	parts := make([dynamic]string, context.temp_allocator)
	for part in strings.split(slashes, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(parts) == 0 { return "", false }
			pop(&parts)
		case:
			if strings.contains_any(part, ":\x00") || part[len(part) - 1] == '.' || part[len(part) - 1] == ' ' { return "", false }
			append(&parts, part)
		}
	}
	if len(parts) == 0 { return "", false }
	return fmt.tprintf("%s/%s", root, strings.join(parts[:], "/", context.temp_allocator)), true
}

site_mime :: proc(path: string) -> string {
	switch {
	case strings.has_suffix(path, ".html"): return "text/html"
	case strings.has_suffix(path, ".css"):  return "text/css"
	case strings.has_suffix(path, ".js"):   return "text/javascript"
	case strings.has_suffix(path, ".png"):  return "image/png"
	}
	return "application/octet-stream"
}

// The path a request asks for, decoded, without its query.
site_request_path :: proc(head: string) -> (path: string, ok: bool) {
	line := head[:max(strings.index(head, "\r\n"), 0)]
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 3 || !strings.has_prefix(fields[1], "/") { return "", false }
	target := fields[1]
	if at := strings.index_any(target, "?#"); at >= 0 { target = target[:at] }
	return net.percent_decode(target, context.temp_allocator)
}

@(private = "file")
site_answer :: proc(c: ^Site_Client) {
	defer free(c)
	defer sync.atomic_sub(&c.server.serving, 1)
	defer net.close(c.sock)
	_ = net.set_option(c.sock, .Receive_Timeout, CHECK_READ_LIMIT)
	head: [CHECK_HEAD_MAX]byte
	got := 0
	for !strings.contains(string(head[:got]), "\r\n\r\n") {
		n, err := net.recv_tcp(c.sock, head[got:])
		if err != nil || n == 0 { return }   // (a browser opens connections ahead of what it asks)
		got += n
		if got == len(head) { return }
	}
	path, asked := site_request_path(string(head[:got]))
	file, inside := site_file(c.server.root, path)
	if asked && inside && os.is_file(file) {
		if data, err := os.read_entire_file(file, context.temp_allocator); err == nil {
			answer := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", site_mime(file), len(data))
			if _, e := net.send_tcp(c.sock, transmute([]byte)answer); e != nil { return }
			_, _ = net.send_tcp(c.sock, data)
			return
		}
	}
	answer := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	_, _ = net.send_tcp(c.sock, transmute([]byte)answer)
}

// One thread a connection: one the browser opened ahead and leaves silent must hold nothing up.
@(private = "file")
site_accept :: proc(srv: ^Site_Server) {
	for {
		client, _, err := net.accept_tcp(srv.listener)
		if sync.atomic_load(&srv.stop) {
			if err == nil { net.close(client) }
			return
		}
		if err != nil { return }
		c := new(Site_Client)
		c^ = {srv, client}
		sync.atomic_add(&srv.serving, 1)
		thread.create_and_start_with_poly_data(c, site_answer, self_cleanup = true)
	}
}

site_serve :: proc(root: string) -> (srv: ^Site_Server, ok: bool) {
	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if err != nil { return nil, false }
	at, bound := net.bound_endpoint(listener)
	if bound != nil { net.close(listener); return nil, false }
	srv = new(Site_Server)
	srv.root, srv.listener, srv.port = root, listener, at.port
	srv.accepter = thread.create_and_start_with_poly_data(srv, site_accept)
	return srv, true
}

// (accept may be waiting for someone, and closing the socket under it ends that on Windows only: someone comes)
site_serve_end :: proc(srv: ^Site_Server) {
	sync.atomic_store(&srv.stop, true)
	if wake, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = srv.port}); err == nil { net.close(wake) }
	net.close(srv.listener)
	thread.join(srv.accepter)
	thread.destroy(srv.accepter)
	begun := time.now()
	for sync.atomic_load(&srv.serving) > 0 && time.since(begun) < CHECK_CLOSE_LIMIT { time.sleep(CHECK_POLL) }
}

// The site's pages under `dir`, as paths from `root`, in no order.
@(private = "file")
site_pages_in :: proc(root, dir: string, out: ^[dynamic]string) -> bool {
	at := dir == "" ? root : fmt.tprintf("%s/%s", root, dir)
	entries, err := os.read_all_directory_by_path(at, context.temp_allocator)
	if err != nil { return false }
	for e in entries {
		path := dir == "" ? e.name : fmt.tprintf("%s/%s", dir, e.name)
		if e.type == .Directory {
			if !site_pages_in(root, path, out) { return false }
		} else if strings.has_suffix(e.name, ".html") {
			append(out, path)
		}
	}
	return true
}

site_pages :: proc(root: string) -> (pages: []string, ok: bool) {
	out := make([dynamic]string, context.temp_allocator)
	if !site_pages_in(root, "", &out) { return nil, false }
	slice.sort(out[:])
	return out[:], true
}

// What the page gives for CHECK_LINKS: [path, anchor] pairs.
site_links :: proc(v: json.Value) -> []Site_Link {
	list, _ := v.(json.Array)
	out := make([]Site_Link, len(list), context.temp_allocator)
	for item, i in list {
		pair, _ := item.(json.Array)
		if len(pair) != 2 { continue }
		path, _ := pair[0].(json.String)
		anchor, _ := pair[1].(json.String)
		out[i] = {path, anchor}
	}
	return out
}

site_anchor_in :: proc(html, anchor: string) -> bool {
	return strings.contains(html, fmt.tprintf(`id="%s"`, anchor))
}

site_link_resolves :: proc(root: string, link: Site_Link) -> bool {
	file, inside := site_file(root, link.path)
	if !inside || !os.exists(file) { return false }
	return link.anchor == "" || site_anchor_in(read_text(file), link.anchor)
}

site_link_text :: proc(link: Site_Link) -> string {
	return link.anchor == "" ? link.path : fmt.tprintf("%s#%s", link.path, link.anchor)
}

// What a browser leaves in its profile about the port it chose: the port, then the path of its own socket.
site_port_file :: proc(text: string) -> (port: int, path: string, ok: bool) {
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) < 2 { return }
	parsed, is_port := strconv.parse_int(strings.trim_space(lines[0]), 10)
	path = strings.trim_space(lines[1])
	if !is_port || parsed <= 0 || !strings.has_prefix(path, "/devtools/browser/") { return 0, "", false }
	return parsed, path, true
}

@(private = "file")
site_find_browser :: proc() -> string {
	places := [?]string{
		os.get_env("CHROME", context.temp_allocator),
		"C:/Program Files/Google/Chrome/Application/chrome.exe",
		"C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
		"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
		"C:/Program Files/Microsoft/Edge/Application/msedge.exe",
		"/usr/bin/google-chrome",
		"/usr/bin/chromium",
		"/usr/bin/chromium-browser",
	}
	for place in places {
		if place != "" && os.exists(place) { return place }
	}
	return ""
}

// (once ended its handle is closed: it must not be asked twice)
@(private = "file")
site_gone :: proc(s: ^Check) -> bool {
	if s.ended { return true }
	state, err := os.process_wait(s.browser, 0)
	s.ended = state.exited || (err != nil && err != os.General_Error.Timeout)
	return s.ended
}

@(private = "file")
site_browser_start :: proc(s: ^Check, program, profile: string) -> bool {
	cmd := []string{program, "--headless=new", "--remote-debugging-port=0", fmt.tprintf("--user-data-dir=%s", profile), fmt.tprintf("--window-size=%d,%d", CHECK_DESKTOP.width, CHECK_DESKTOP.height), "--no-first-run", "about:blank"}
	p, err := os.process_start({command = cmd})
	if err != nil { fmt.eprintfln("site check: %s: %v", program, err); return false }
	s.browser, s.started = p, true
	begun := time.now()
	for time.since(begun) < CHECK_START_LIMIT {
		if site_gone(s) { fmt.eprintfln("site check: the browser ended: %s", program); return false }
		if port, path, written := site_port_file(read_text(fmt.tprintf("%s/%s", profile, CHECK_PORT_FILE))); written {
			if c, connected := cdp.open(port, path); connected {
				s.client, s.connected = c, true
				return true
			}
		}
		time.sleep(CHECK_POLL)
	}
	fmt.eprintfln("site check: no devtools from %s", program)
	return false
}

// What the command lines of this run's processes hold, and no one else's: the name of a folder made for it. "" if `profile` is
// not such a folder: every command line holds "", and what is found here is killed.
site_run_mark :: proc(profile: string) -> string {
	name := profile[strings.last_index_any(profile, "/\\") + 1:]
	return strings.has_prefix(name, CHECK_PROFILE_NAME) && len(name) > len(CHECK_PROFILE_NAME) ? name : ""
}

// The processes of this run: no one else's browser is ever among them.
site_processes :: proc(profile: string) -> []int {
	name := site_run_mark(profile)
	if name == "" { return nil }
	out := make([dynamic]int, context.temp_allocator)
	pids, err := os.process_list(context.temp_allocator)
	if err != nil { return nil }
	for pid in pids {
		// (what may not be read is not ours: this user started ours)
		info, info_err := os.process_info_by_pid(pid, {.Command_Line}, context.temp_allocator)
		if info_err == nil && strings.contains(info.command_line, name) { append(&out, pid) }
	}
	return out[:]
}

// (by its number: on Windows os.process_open does not ask for the right to end what it opens)
@(private = "file")
site_kill :: proc(pid: int) {
	id := fmt.tprintf("%d", pid)
	when ODIN_OS == .Windows {
		run_quiet({"taskkill", "/F", "/PID", id})
	} else {
		run_quiet({"kill", "-9", id})
	}
}

// Asked to leave, then made to, its helpers with it: what ends the browser does not end them, and they hold its profile.
// (The call has a limit of its own: a browser that does not answer must not hold the rest up.)
@(private = "file")
site_browser_end :: proc(s: ^Check, profile: string) {
	if !s.started { return }
	if s.connected {
		if !site_gone(s) {
			s.client.session = ""
			cdp.set_read_limit(&s.client, CHECK_CLOSE_LIMIT)
			cdp.call(&s.client, "Browser.close")
		}
		cdp.close(&s.client)
	}
	if !s.ended {
		state, err := os.process_wait(s.browser, CHECK_CLOSE_LIMIT)
		s.ended = state.exited || (err != nil && err != os.General_Error.Timeout)
	}
	if !s.ended {
		fmt.eprintln("site check: the browser did not leave: it is killed")
		_ = os.process_kill(s.browser)
		_, _ = os.process_wait(s.browser, CHECK_CLOSE_LIMIT)
		s.ended = true
	}
	for pid in site_processes(profile) { site_kill(pid) }
	// (killed is not gone: a process in the middle of a read of the disk ends when that read does)
	begun := time.now()
	for {
		left := site_processes(profile)
		if len(left) == 0 { return }
		if time.since(begun) > CHECK_GONE_LIMIT { fmt.eprintfln("left behind: the processes %v", left); s.left_behind = true; return }
		time.sleep(CHECK_POLL)
	}
}

@(private = "file")
site_remove :: proc(s: ^Check, folder: string) {
	begun := time.now()
	for {
		if os.remove_all(folder) == nil && !os.exists(folder) { return }
		if time.since(begun) > CHECK_REMOVE_LIMIT { fmt.eprintfln("left behind: %s", folder); s.left_behind = true; return }
		time.sleep(CHECK_POLL)
	}
}

check_expect :: proc(s: ^Check, ok: bool, what: string) {
	fmt.printfln("%s %s", ok ? "ok  " : "FAIL", what)
	if ok { s.passed += 1 } else { s.failed += 1 }
	if !ok && s.threw != "" { fmt.eprintfln("     %s", s.threw) }
}

// !ok: the expression threw, or the browser is gone. Either fails what asked.
check_js :: proc(s: ^Check, expression: string) -> (value: json.Value, ok: bool) {
	s.threw = ""
	if site_gone(s) { s.threw = "the browser is gone"; return nil, false }
	r, called := cdp.call(&s.client, "Runtime.evaluate", fmt.tprintf(`{{"expression":%s,"awaitPromise":true,"returnByValue":true}}`, cdp.quote(expression)))
	if !called { return nil, false }
	o, _ := r.(json.Object)
	if details, threw := o["exceptionDetails"].(json.Object); threw {
		exception, _ := details["exception"].(json.Object)
		text, _ := exception["description"].(json.String)
		s.threw = text != "" ? text : expression
		return nil, false
	}
	result, _ := o["result"].(json.Object)
	return result["value"], true
}

check_true :: proc(s: ^Check, expression: string) -> bool {
	v, ok := check_js(s, expression)
	yes, is_bool := v.(json.Boolean)
	return ok && is_bool && yes
}

check_text :: proc(s: ^Check, expression: string) -> string {
	v, _ := check_js(s, expression)
	text, _ := v.(json.String)
	return text
}

check_number :: proc(s: ^Check, expression: string) -> f64 {
	v, _ := check_js(s, expression)
	return cdp.number(v)
}

// Until the expression holds: it does at once when it can, the limit is for what never comes.
check_wait :: proc(s: ^Check, expression: string, limit: time.Duration) -> bool {
	begun := time.now()
	for {
		if check_true(s, expression) { return true }
		if s.ended || time.since(begun) > limit { return false }
		time.sleep(CHECK_POLL)
	}
}

// A call that does not go through is a failure of the run, not a step skipped: what follows would look at the wrong thing, or at
// nothing, and could pass.
check_call :: proc(s: ^Check, method, params: string) -> (result: json.Value, ok: bool) {
	result, ok = cdp.call(&s.client, method, params)
	if !ok { check_expect(s, false, fmt.tprintf("%s goes through", method)) }
	return
}

check_key :: proc(s: ^Check, key: string) {
	code: int
	switch key {
	case "ArrowRight": code = 39
	case "ArrowLeft":  code = 37
	case "End":        code = 35
	case "Escape":     code = 27
	case "Tab":        code = 9
	}
	name := cdp.quote(key)
	check_call(s, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"rawKeyDown","key":%s,"code":%s,"windowsVirtualKeyCode":%d}}`, name, name, code))
	check_call(s, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyUp","key":%s,"code":%s}}`, name, name))
}

check_view :: proc(s: ^Check, view: Site_View) {
	check_call(s, "Emulation.setDeviceMetricsOverride", fmt.tprintf(`{{"width":%d,"height":%d,"deviceScaleFactor":1,"mobile":%v}}`, view.width, view.height, view.mobile))
}

check_scheme :: proc(s: ^Check, value: string) {
	check_call(s, "Emulation.setEmulatedMedia", fmt.tprintf(`{{"features":[{{"name":"prefers-color-scheme","value":%s}}]}}`, cdp.quote(value)))
}

check_go :: proc(s: ^Check, path: string) -> bool {
	url := fmt.tprintf("%s/%s", s.origin, path)
	r, ok := check_call(s, "Page.navigate", fmt.tprintf(`{{"url":%s}}`, cdp.quote(url)))
	o, _ := r.(json.Object)
	failure, _ := o["errorText"].(json.String)
	if failure != "" { fmt.eprintfln("%s: %s", url, failure) }
	loaded := ok && failure == "" && check_wait(s, fmt.tprintf(`location.href === %s && document.readyState === 'complete'`, cdp.quote(url)), CHECK_PAGE_LIMIT)
	if !loaded { check_expect(s, false, fmt.tprintf("%s: the page loads", path)) }
	return loaded
}

@(private = "file")
check_count_is :: proc(n, of: int) -> string {
	return fmt.tprintf(`%s === '%d / %d'`, CHECK_COUNT, n, of)
}

check_click :: proc(s: ^Check, x, y: f64) {
	moves := [?]string{"mouseMoved", "mousePressed", "mouseReleased"}
	for type in moves {
		moved := type == "mouseMoved"
		check_call(s, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"%s","x":%f,"y":%f,"button":"%s","clickCount":%d}}`, type, x, y, moved ? "none" : "left", moved ? 0 : 1))
	}
}

@(private = "file")
site_viewer :: proc(s: ^Check, path: string) {
	if !check_go(s, path) { return }
	count := int(check_number(s, `document.querySelectorAll('.shot a.frame').length`))
	pictures := int(check_number(s, `document.querySelectorAll('.shot img').length`))
	check_expect(s, count > 0 && count == pictures, fmt.tprintf("%s: every capture is a link (%d of %d)", path, count, pictures))

	// a real click, on the third capture
	at, rested := check_js(s, CHECK_REST)
	spot, _ := at.(json.Array)
	if !rested || len(spot) != 2 { check_expect(s, false, fmt.tprintf("%s: the third capture comes to rest", path)); return }
	check_js(s, CHECK_CLICK_KEPT)
	check_click(s, cdp.number(spot[0]), cdp.number(spot[1]))
	check_expect(s, check_wait(s, CHECK_OPEN, CHECK_INPUT_LIMIT), fmt.tprintf("%s: a click opens the viewer", path))
	// (that nothing follows cannot be awaited: what says so is the link's click, prevented, on a page that is still this one)
	check_expect(s, check_true(s, fmt.tprintf(`location.pathname === %s && !!window.tkSiteClick && window.tkSiteClick.defaultPrevented`, cdp.quote(fmt.tprintf("/%s", path)))), fmt.tprintf("%s: the page stays where it is", path))
	check_expect(s, check_wait(s, CHECK_LOADED, CHECK_PICTURE_LIMIT), fmt.tprintf("%s: the picture loads", path))
	check_expect(s, check_true(s, check_count_is(3, count)), fmt.tprintf("%s: it is the capture clicked", path))
	check_expect(s, check_number(s, `document.querySelector('.lightbox-caption').textContent.length`) > 0, fmt.tprintf("%s: its caption is shown", path))
	check_expect(s, check_true(s, CHECK_FILLS), fmt.tprintf("%s: the picture is large and within the window", path))
	check_expect(s, check_true(s, CHECK_NO_SIDEWAYS), fmt.tprintf("%s: no sideways scrolling", path))
	if s.shot != "" && path == "index.html" {
		if cdp.shot(&s.client, s.shot) { fmt.printfln("saved %s", s.shot) } else { check_expect(s, false, fmt.tprintf("%s is written", s.shot)) }
	}

	check_key(s, "ArrowRight")
	next := check_wait(s, check_count_is(4, count), CHECK_INPUT_LIMIT)
	check_wait(s, CHECK_LOADED, CHECK_PICTURE_LIMIT)
	check_expect(s, next, fmt.tprintf("%s: Right: the next one", path))
	check_key(s, "ArrowLeft")
	check_wait(s, check_count_is(3, count), CHECK_INPUT_LIMIT)
	check_key(s, "ArrowLeft")
	check_expect(s, check_wait(s, check_count_is(2, count), CHECK_INPUT_LIMIT), fmt.tprintf("%s: Left: the previous one", path))
	check_key(s, "End")
	check_expect(s, check_wait(s, check_count_is(count, count), CHECK_INPUT_LIMIT), fmt.tprintf("%s: End: the last one", path))
	check_key(s, "ArrowRight")
	check_expect(s, check_wait(s, check_count_is(1, count), CHECK_INPUT_LIMIT), fmt.tprintf("%s: Right from the last: the first one", path))
	check_key(s, "Escape")
	check_expect(s, check_wait(s, "!" + CHECK_OPEN, CHECK_INPUT_LIMIT), fmt.tprintf("%s: Esc closes", path))
	check_expect(s, check_true(s, CHECK_FOCUS_BACK), fmt.tprintf("%s: the keyboard is back on the link last shown", path))
	check_expect(s, check_true(s, CHECK_SCROLLS), fmt.tprintf("%s: the page scrolls again", path))
}

@(private = "file")
site_classic :: proc(s: ^Check, path: string) {
	check_expect(s, check_true(s, CHECK_LANDMARKS), fmt.tprintf("%s: a main, a header, a nav and a footer", path))
	check_expect(s, check_true(s, CHECK_ALT_TEXTS), fmt.tprintf("%s: every picture shown has a text", path))
	check_key(s, "Tab")
	check_expect(s, check_wait(s, CHECK_SKIP_LINK, CHECK_INPUT_LIMIT), fmt.tprintf("%s: Tab reaches the skip link first, shown with its focus ring", path))
	for view in ([2]Site_View{CHECK_PHONE, CHECK_DESKTOP}) {
		check_view(s, view)
		check_expect(s, check_true(s, CHECK_NO_SIDEWAYS), fmt.tprintf("%s: no sideways scrolling at %d px", path, view.width))
	}
	if path == CHECK_CLASSIC + "index.html" {
		high := check_number(s, CHECK_HIGH)
		check_expect(s, high > 0 && high <= CHECK_HOME_SCREENS, fmt.tprintf("%s: %.2f screens high (%v at most)", path, high, CHECK_HOME_SCREENS))
	}
	check_scheme(s, "light")
	light := check_text(s, CHECK_COLORS)
	check_scheme(s, "dark")
	dark := check_text(s, CHECK_COLORS)
	check_scheme(s, "")
	check_expect(s, light != "" && dark != "" && light != dark, fmt.tprintf("%s: light and dark (%s / %s)", path, light, dark))
}

// A page of build_docs (docs.odin). On a phone: nothing sticks out of the screen but inside the frame of a code block or a table,
// which scrolls; the menu is closed. On a wide screen: the menu is beside the page. On the documentation's home: the toggle opens
// the menu, and the search finds pages.
@(private = "file")
site_docs_page :: proc(s: ^Check, path: string) {
	check_view(s, CHECK_DOCS_PHONE)
	out := check_text(s, CHECK_DOCS_OUTSIDE)
	check_expect(s, out == "", fmt.tprintf("%s: nothing sticks out at %d px%s%s", path, CHECK_DOCS_PHONE.width, out == "" ? "" : ": ", out))
	check_expect(s, check_true(s, "!" + CHECK_DOCS_MENU_SHOWN), fmt.tprintf("%s: the menu is closed at %d px", path, CHECK_DOCS_PHONE.width))
	if strings.has_suffix(path, "docs/index.html") {
		check_js(s, `document.querySelector('.doc-nav-open').click()`)
		check_expect(s, check_wait(s, CHECK_DOCS_MENU_SHOWN, CHECK_INPUT_LIMIT), fmt.tprintf("%s: the toggle opens the menu", path))
		check_js(s, `document.querySelector('.doc-nav-open').click()`)
		check_js(s, `(() => { const box = document.getElementById('doc-search-input'); box.value = 'the'; box.dispatchEvent(new Event('input')) })()`)
		check_expect(s, check_wait(s, CHECK_DOCS_FOUND, CHECK_READ_LIMIT), fmt.tprintf("%s: the search finds pages", path))
	}
	check_view(s, CHECK_DESKTOP)
	check_expect(s, check_true(s, CHECK_DOCS_MENU_SHOWN), fmt.tprintf("%s: the menu is beside the page at %d px", path, CHECK_DESKTOP.width))
}

@(private = "file")
site_page :: proc(s: ^Check, path: string, pages: []string) {
	if !check_go(s, path) { return }
	// what the page loads or links on this site, as paths with their anchor
	v, read := check_js(s, CHECK_LINKS)
	links := site_links(v)
	broken := make([dynamic]string, context.temp_allocator)
	for link in links {
		if !site_link_resolves(s.root, link) { append(&broken, site_link_text(link)) }
	}
	said := len(broken) > 0 ? fmt.tprintf(": not %s", strings.join(broken[:], ", ", context.temp_allocator)) : ""
	check_expect(s, read && len(broken) == 0, fmt.tprintf("%s: its %d links resolve%s", path, len(links), said))

	if check_true(s, CHECK_DOCS_PAGE) { site_docs_page(s, path) }
	classic := strings.has_prefix(path, CHECK_CLASSIC)
	// (only the pages the changelog step pairs have the other presentation: the docs pages and the 404 have none)
	if !classic && path != HOME_PAGE && path != CHANGELOG_PAGE { return }
	other := classic ? "Modern version" : "Classic version"
	found, _ := check_js(s, fmt.tprintf(`[...document.querySelectorAll('footer a')].filter((a) => a.textContent === %s).map((a) => new URL(a.href).pathname)`, cdp.quote(other)))
	list, _ := found.(json.Array)
	to := make([]string, len(list), context.temp_allocator)
	for item, i in list { to[i], _ = item.(json.String) }
	same := classic ? path[len(CHECK_CLASSIC):] : strings.concatenate({CHECK_CLASSIC, path}, context.temp_allocator)
	want := fmt.tprintf("/%s", classic && !slice.contains(pages, same) ? "index.html" : same)
	wanted, _ := site_file(s.root, want)
	there := ""
	if len(to) == 1 { there, _ = site_file(s.root, to[0]) }
	check_expect(s, there != "" && there == wanted, fmt.tprintf(`%s: "%s" is %s (%s)`, path, other, want, strings.join(to, ", ", context.temp_allocator)))
	if classic { site_classic(s, path) }
}

@(private = "file")
site_checks :: proc(s: ^Check, pages: []string) -> bool {
	r, made := cdp.call(&s.client, "Target.createTarget", `{"url":"about:blank"}`)
	if !made { return false }
	o, _ := r.(json.Object)
	target, _ := o["targetId"].(json.String)
	r, made = cdp.call(&s.client, "Target.attachToTarget", fmt.tprintf(`{{"targetId":%s,"flatten":true}}`, cdp.quote(target)))
	if !made { return false }
	o, _ = r.(json.Object)
	s.client.session, _ = o["sessionId"].(json.String)
	if _, enabled := cdp.call(&s.client, "Page.enable"); !enabled { return false }
	check_view(s, CHECK_DESKTOP)
	viewers := [?]string{"index.html", CHECK_CLASSIC + "screenshots.html"}
	for path in viewers { site_viewer(s, path) }
	for path in pages {
		// (a page left at an old address goes on to the new one while it is checked: check_links reads its one link)
		if strings.contains(read_text(fmt.tprintf("%s/%s", s.root, path)), `http-equiv="refresh"`) { continue }
		site_page(s, path, pages)
	}
	if s.extra != nil { s.extra(s) }
	return true
}

// Everything it opens is closed on the way out of here, whatever happened: what could not be is in `s` after it.
@(private = "file")
check_all :: proc(s: ^Check, o: Check_Options, program: string) -> bool {
	made, made_err := os.make_directory_temp("", CHECK_MADE_TEMP, context.allocator)
	if made_err != nil { fmt.eprintfln("site check: %v", made_err); return false }
	defer site_remove(s, made)
	s.root = fmt.aprintf("%s/site", made)
	if !o.generate(o.site, s.root, o.user) { return false }
	pages, listed := site_pages(s.root)
	if !listed { fmt.eprintfln("site check: no pages in %s", s.root); return false }

	server, served := site_serve(s.root)
	if !served { fmt.eprintln("site check: nothing can listen on this machine"); return false }
	defer site_serve_end(server)
	s.origin = fmt.aprintf("http://127.0.0.1:%d", server.port)
	profile, profile_err := os.make_directory_temp("", CHECK_PROFILE_TEMP, context.allocator)
	if profile_err != nil { fmt.eprintfln("site check: %v", profile_err); return false }
	defer site_remove(s, profile)
	defer site_browser_end(s, profile)
	if !site_browser_start(s, program, profile) { return false }

	whole := site_checks(s, pages)
	gone := site_gone(s)
	if gone { fmt.eprintln("site check: the browser ended during the run") }
	fmt.printfln("site check: %d of %d passed", s.passed, s.passed + s.failed)
	return whole && s.failed == 0 && !gone
}

Check_Options :: struct {
	site:     string,   // the site's sources
	shot:     string,   // a picture of the home page with the viewer open ("": none)
	browser:  string,   // Chrome or Edge ("": the first found, CHROME first)
	generate: proc(site, out: string, user: rawptr) -> bool,   // the pages the project makes of `site`, into `out`; it gets `user`
	extra:    proc(s: ^Check),                   // the project's own checks, on the same page, after the others (nil: none)
	user:     rawptr,                            // what `generate` and `extra` need (`extra`: as `s.user`)
}

// "--site folder", "--shot file.png", "--browser program" into `o`. "": understood; else what is not.
check_arguments :: proc(args: []string, o: ^Check_Options) -> (why: string) {
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--site" && i + 1 < len(args):
			i += 1
			o.site = args[i]
		case args[i] == "--shot" && i + 1 < len(args):
			i += 1
			o.shot = args[i]
		case args[i] == "--browser" && i + 1 < len(args):
			i += 1
			o.browser = args[i]
		case:
			return fmt.tprintf("what is %s?", args[i])
		}
	}
	return ""
}

// The site checked in a browser: true when every check passed and nothing was left behind.
check :: proc(o: Check_Options) -> bool {
	program := o.browser != "" ? o.browser : site_find_browser()
	if program == "" { fmt.eprintln("site check: no Chrome or Edge found: give --browser or set CHROME"); return false }
	s := Check{shot = o.shot, extra = o.extra, user = o.user}
	passed := check_all(&s, o, program)
	return passed && !s.left_behind
}

@(private)
CHECK_POLL :: 50 * time.Millisecond

@(private)
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}

@(private)
run_quiet :: proc(command: []string) {
	_, _, _, _ = os.process_exec({command = command}, context.temp_allocator)
}
