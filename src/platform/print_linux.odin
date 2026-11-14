#+build linux
package platform

// Printing through the XDG print portal (print.odin): PreparePrint shows the system's dialog and answers, on its
// request's Response signal, with a token and the page setup the person chose; Print then takes the page as a PDF
// (print_pdf), in a memory file passed as a descriptor, with that token: no second dialog. Both on a connection of
// their own on the calling thread, which waits for the person as the file dialogs do.

import "core:strings"
import "core:sys/linux"
import "../dbus"

@(private = "file") PRINT_IFACE :: "org.freedesktop.portal.Print"
@(private = "file") PRINT_CALL_MS :: 8000   // a request's own answer, not the time the person takes
@(private = "file") PRINT_POLL_MS :: 200

// What a Response of the print portal said: its code (0 done, 1 cancelled, 2 ended), PreparePrint's token, and the
// page's size and margins in points (0: not said).
@(private = "file")
Print_Answer :: struct {
	done:      bool,
	code:      u32,
	token:     u32,
	has_token: bool,
	page:      [2]f64,
	margin:    f64,
	landscape: bool,
}

print_image :: proc(owner: ^Window, title: string, rgba: []u8, size: [2]int) -> Print_Status {
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return .Failed }
	conn := dbus.connect_bus(.Session, unix_fds = true)
	if conn == nil { return .Unsupported }
	defer dbus.conn_close(conn)
	if !dbus.conn_unix_fds(conn) { return .Unsupported }

	// the dialog
	prepared: Print_Answer
	{
		token := portal_token()
		w := dbus.body_writer()
		dbus.w_string(&w, "")   // parent_window ("" is fine: the portal centres it)
		dbus.w_string(&w, title)
		sl, sc := dbus.arg_dict_begin(&w); dbus.arg_dict_end(&w, sl, sc)   // settings: the system's last
		pl, pc := dbus.arg_dict_begin(&w); dbus.arg_dict_end(&w, pl, pc)   // page setup: the system's last
		ol, oc := dbus.arg_dict_begin(&w)
		dbus.arg_dict_entry(&w, "handle_token"); dbus.arg_variant_string(&w, token)
		dbus.arg_dict_end(&w, ol, oc)
		if !print_request(conn, token, "PreparePrint", "ssa{sv}a{sv}a{sv}", w.buf[:], nil, &prepared) { return .Unsupported }
	}
	if !prepared.done { return .Failed }
	if prepared.code != 0 || !prepared.has_token { return .Cancelled }

	// the page, as a PDF in a memory file
	page := prepared.page.x > 0 && prepared.page.y > 0 ? prepared.page : PRINT_A4_PT
	if prepared.landscape && page.y > page.x { page = {page.y, page.x} }
	margin := prepared.margin > 0 ? prepared.margin : PRINT_MARGIN_PT
	pdf := print_pdf(rgba, size, page, margin, context.temp_allocator)
	if pdf == nil { return .Failed }
	fd, err := linux.memfd_create("print.pdf", {.CLOEXEC})
	if err != .NONE { return .Failed }
	defer linux.close(fd)
	for rest := pdf; len(rest) > 0; {
		n, werr := linux.write(fd, rest)
		if werr == .EINTR { continue }
		if werr != .NONE || n <= 0 { return .Failed }
		rest = rest[n:]
	}
	// (the portal reads its copy of the descriptor from where it stands)
	if _, serr := linux.lseek(fd, 0, .SET); serr != .NONE { return .Failed }

	printed: Print_Answer
	token := portal_token()
	w := dbus.body_writer()
	dbus.w_string(&w, "")
	dbus.w_string(&w, title)
	dbus.w_u32(&w, 0)   // (the 'h': the first descriptor of the call)
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "handle_token"); dbus.arg_variant_string(&w, token)
	dbus.arg_dict_entry(&w, "token"); dbus.w_signature(&w, "u"); dbus.w_u32(&w, prepared.token)
	dbus.arg_dict_end(&w, ol, oc)
	fds := [1]i32{i32(fd)}
	if !print_request(conn, token, "Print", "ssha{sv}", w.buf[:], fds[:], &printed) { return .Failed }
	if !printed.done { return .Failed }
	switch printed.code {
	case 0: return .Printed
	case 1: return .Cancelled
	}
	return .Failed
}

// A call of the print portal that answers on a request's Response, waited for (the person takes their time). False:
// the portal refused the call (none here, or no Print on it).
@(private = "file")
print_request :: proc(conn: ^dbus.Conn, token, method, signature: string, body: []u8, fds: []i32, answer: ^Print_Answer) -> bool {
	expected := portal_request_path(conn, token)
	sub := dbus.subscribe(conn, PORTAL_SERVICE, expected, REQUEST_IFACE, "Response", print_response, answer)
	defer dbus.unsubscribe(conn, sub)
	msg, ok := dbus.call_with_fds(conn, PORTAL_SERVICE, PORTAL_PATH, PRINT_IFACE, method, signature, body, fds, PRINT_CALL_MS)
	if !ok { return false }
	r := dbus.msg_reader(&msg)
	request_path := dbus.r_string(&r)
	// (an old portal chose the handle itself)
	other: u32
	if request_path != expected { other = dbus.subscribe(conn, PORTAL_SERVICE, request_path, REQUEST_IFACE, "Response", print_response, answer) }
	defer if other != 0 { dbus.unsubscribe(conn, other) }
	for !answer.done {
		dbus.dispatch(conn)
		if !dbus.conn_alive(conn) { break }
		portal_wait_fd(dbus.conn_fd(conn), PRINT_POLL_MS)
	}
	return true
}

// The Response signal (u response, a{sv} results): PreparePrint's has "token" (u) and "page-setup" (a{sv}: Width and
// Height in millimetres, the margins, the orientation); Print's nothing needed.
@(private = "file")
print_response :: proc(user: rawptr, msg: ^dbus.Message) {
	a := (^Print_Answer)(user)
	r := dbus.msg_reader(msg)
	a.code = dbus.r_u32(&r)
	end := dbus.r_array_begin(&r, "{sv}")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		switch key {
		case "token":
			vs := dbus.r_variant_sig(&r)
			if vs == "u" { a.token, a.has_token = dbus.r_u32(&r), true } else { dbus.r_skip(&r, vs) }
		case "page-setup":
			vs := dbus.r_variant_sig(&r)
			if vs != "a{sv}" { dbus.r_skip(&r, vs); continue }
			margins: [4]f64
			pend := dbus.r_array_begin(&r, "{sv}")
			for r.pos < pend && !r.err {
				dbus.r_align_entry(&r)
				k := dbus.r_string(&r)
				ks := dbus.r_variant_sig(&r)
				switch {
				case ks == "d" && k == "Width":        a.page.x = dbus.r_f64(&r) * POINTS_PER_INCH / MM_PER_INCH
				case ks == "d" && k == "Height":       a.page.y = dbus.r_f64(&r) * POINTS_PER_INCH / MM_PER_INCH
				case ks == "d" && k == "MarginTop":    margins[0] = dbus.r_f64(&r) * POINTS_PER_INCH / MM_PER_INCH
				case ks == "d" && k == "MarginBottom": margins[1] = dbus.r_f64(&r) * POINTS_PER_INCH / MM_PER_INCH
				case ks == "d" && k == "MarginLeft":   margins[2] = dbus.r_f64(&r) * POINTS_PER_INCH / MM_PER_INCH
				case ks == "d" && k == "MarginRight":  margins[3] = dbus.r_f64(&r) * POINTS_PER_INCH / MM_PER_INCH
				case ks == "s" && k == "Orientation":  a.landscape = strings.contains(dbus.r_string(&r), "landscape")
				case:                                  dbus.r_skip(&r, ks)
				}
			}
			// (one margin for every side: the largest, so that nothing falls where the printer cannot print)
			a.margin = max(margins[0], margins[1], margins[2], margins[3])
		case:
			dbus.read_variant_skip(&r)
		}
	}
	a.done = true
}
