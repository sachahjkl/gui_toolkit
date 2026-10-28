#+build linux
package platform

// The Linux side of the smaller services (services_linux.odin). Idle inhibition goes through org.freedesktop.ScreenSaver
// (Inhibit returns a cookie, UnInhibit takes it) over the session bus — the portal's Inhibit is the sandboxed
// equivalent, left as a note. Recent files are appended to the freedesktop recently-used.xbel the file managers read.

import "core:os"
import "core:strings"
import "core:time"
import "../dbus"

@(private) SCREENSAVER_SERVICE :: "org.freedesktop.ScreenSaver"
@(private) SCREENSAVER_PATH :: "/org/freedesktop/ScreenSaver"

// A live inhibition: the ScreenSaver cookie, to pass back to UnInhibit.
@(private)
Idle_Record :: struct {
	handle: Idle_Inhibit,
	cookie: u32,
}
@(private) idle_records: [dynamic]Idle_Record
@(private) idle_next: u64

@(private)
idle_inhibit_linux :: proc(w: ^Window, reason: string) -> Idle_Inhibit {
	conn := session_bus()
	if conn == nil { return 0 }
	wr := dbus.body_writer()
	dbus.w_string(&wr, "gui_toolkit")
	dbus.w_string(&wr, reason)
	msg, ok := dbus.call(conn, SCREENSAVER_SERVICE, SCREENSAVER_PATH, SCREENSAVER_SERVICE, "Inhibit", "ss", wr.buf[:], 3000)
	if !ok || msg.type != .Method_Return { return 0 }
	r := dbus.msg_reader(&msg)
	cookie := dbus.r_u32(&r)
	idle_next += 1
	h := Idle_Inhibit(idle_next)
	append(&idle_records, Idle_Record{handle = h, cookie = cookie})
	return h
}

@(private)
idle_uninhibit_linux :: proc(h: Idle_Inhibit) {
	if h == 0 { return }
	conn := session_bus()
	if conn == nil { return }
	for rec, i in idle_records {
		if rec.handle != h { continue }
		wr := dbus.body_writer()
		dbus.w_u32(&wr, rec.cookie)
		dbus.call_noreply(conn, SCREENSAVER_SERVICE, SCREENSAVER_PATH, SCREENSAVER_SERVICE, "UnInhibit", "u", wr.buf[:])
		unordered_remove(&idle_records, i)
		return
	}
}

////////////////////////////////
// recent files

// Appends a file to the freedesktop recent list ($XDG_DATA_HOME or ~/.local/share recently-used.xbel). A minimal XBEL
// append: if the file does not exist yet, write a fresh document; otherwise insert a bookmark before the closing tag.
// The format the GTK / Qt recent managers read is an XBEL 1.0 with a per-entry modified / visited / added time and an
// application record; this writes the common subset they accept.
@(private)
add_recent_file_linux :: proc(path: string, mime: string) {
	if path == "" { return }
	dir := recent_dir()
	if dir == "" { return }
	file := strings.concatenate({dir, "/recently-used.xbel"}, context.temp_allocator)
	uri := file_uri(path)
	m := mime != "" ? mime : guess_mime(path)
	now := rfc3339_now()
	entry := strings.concatenate({
		"  <bookmark href=\"", uri, "\" added=\"", now, "\" modified=\"", now, "\" visited=\"", now, "\">\n",
		"    <info><metadata owner=\"http://freedesktop.org\">\n",
		"      <mime:mime-type type=\"", m, "\"/>\n",
		"      <bookmark:applications>\n",
		"        <bookmark:application name=\"gui_toolkit\" exec=\"&apos;gui_toolkit %u&apos;\" modified=\"", now, "\" count=\"1\"/>\n",
		"      </bookmark:applications>\n",
		"    </metadata></info>\n",
		"  </bookmark>\n",
	}, context.temp_allocator)
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil {
		header := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xbel version=\"1.0\"\n  xmlns:bookmark=\"http://www.freedesktop.org/standards/desktop-bookmarks\"\n  xmlns:mime=\"http://www.freedesktop.org/standards/shared-mime-info\">\n"
		out := strings.concatenate({header, entry, "</xbel>\n"}, context.temp_allocator)
		_ = os.write_entire_file(file, transmute([]u8)out)
		return
	}
	text := string(data)
	close := "</xbel>"
	idx := strings.last_index(text, close)
	if idx < 0 {
		_ = os.write_entire_file(file, transmute([]u8)strings.concatenate({text, entry}, context.temp_allocator))
		return
	}
	out := strings.concatenate({text[:idx], entry, text[idx:]}, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)out)
}

@(private)
recent_dir :: proc() -> string {
	if x := posix_getenv("XDG_DATA_HOME"); x != "" { return x }
	if home := posix_getenv("HOME"); home != "" { return strings.concatenate({home, "/.local/share"}, context.temp_allocator) }
	return ""
}

@(private)
posix_getenv :: proc(name: string) -> string {
	c := strings.clone_to_cstring(name, context.temp_allocator)
	v := _getenv(c)
	return v != nil ? string(v) : ""
}

foreign import libc_svc "system:c"
@(default_calling_convention = "c", private)
foreign libc_svc {
	@(link_name="getenv") _getenv :: proc(name: cstring) -> cstring ---
}

@(private)
file_uri :: proc(path: string) -> string {
	// file:// + percent-encode the reserved bytes of the path
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	for i in 0 ..< len(path) {
		c := path[i]
		if c == '/' || c == '-' || c == '_' || c == '.' || c == '~' ||
		   (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex_up(c >> 4))
			strings.write_byte(&b, hex_up(c & 0xf))
		}
	}
	return strings.to_string(b)
}

@(private)
hex_up :: proc(v: u8) -> u8 { return v < 10 ? '0' + v : 'A' + (v - 10) }

@(private)
guess_mime :: proc(path: string) -> string {
	ext := ""
	if i := strings.last_index_byte(path, '.'); i >= 0 { ext = strings.to_lower(path[i:], context.temp_allocator) }
	switch ext {
	case ".txt": return "text/plain"
	case ".html", ".htm": return "text/html"
	case ".png": return "image/png"
	case ".jpg", ".jpeg": return "image/jpeg"
	case ".pdf": return "application/pdf"
	case ".json": return "application/json"
	}
	return "application/octet-stream"
}

@(private)
rfc3339_now :: proc() -> string {
	// a coarse UTC timestamp good enough for the recent list; the file managers only sort by it
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	b := strings.builder_make(context.temp_allocator)
	write2 :: proc(b: ^strings.Builder, v: int) { strings.write_byte(b, '0' + u8(v / 10 % 10)); strings.write_byte(b, '0' + u8(v % 10)) }
	strings.write_byte(&b, '0' + u8(y / 1000 % 10))
	strings.write_byte(&b, '0' + u8(y / 100 % 10))
	strings.write_byte(&b, '0' + u8(y / 10 % 10))
	strings.write_byte(&b, '0' + u8(y % 10))
	strings.write_byte(&b, '-'); write2(&b, int(mo))
	strings.write_byte(&b, '-'); write2(&b, d)
	strings.write_byte(&b, 'T'); write2(&b, h)
	strings.write_byte(&b, ':'); write2(&b, mi)
	strings.write_byte(&b, ':'); write2(&b, s)
	strings.write_byte(&b, 'Z')
	return strings.to_string(b)
}
