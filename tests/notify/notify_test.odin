// System notifications (platform/notify.odin): what every system's code is made of, tested on every system: the
// arguments of org.freedesktop.Notifications.Notify (read back as a server reads them), the escaping of markup and XML,
// the image of the image-data hint, the toast's XML and the arguments of its activation. notify_test_linux.odin runs the
// Linux side against a notification server of its own, on a bus of its own.
//   odin test tests/notify -vet -define:ODIN_TEST_THREADS=1
package notify_test

import "core:strings"
import "core:testing"
import "../../src/dbus"
import "../../src/platform"
import "../../src/png"

// A Notify call as a server reads it.
Notify_Call :: struct {
	app_name, app_icon, summary, body: string,
	replaces:      u32,
	actions:       [dynamic]string,
	desktop_entry: string,
	urgency:       int,      // -1: no hint
	silent:        bool,
	image:         [3]i32,   // width, height, rowstride
	image_alpha:   bool,
	image_bytes:   int,
	timeout:       i32,
	ok:            bool,     // read to the end without error
}

// Reads Notify's arguments (platform.NOTIFY_SIGNATURE); strings are copied with `allocator`.
parse_notify :: proc(body: []u8, big := false, allocator := context.allocator) -> (c: Notify_Call) {
	context.allocator = allocator
	r := dbus.reader_make(body, big)
	c.urgency = -1
	c.app_name = strings.clone(dbus.r_string(&r))
	c.replaces = dbus.r_u32(&r)
	c.app_icon = strings.clone(dbus.r_string(&r))
	c.summary = strings.clone(dbus.r_string(&r))
	c.body = strings.clone(dbus.r_string(&r))
	c.actions = make([dynamic]string)
	end := dbus.r_array_begin(&r, "s")
	for r.pos < end && !r.err { append(&c.actions, strings.clone(dbus.r_string(&r))) }
	end = dbus.r_array_begin(&r, "{sv}")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		sig := dbus.r_variant_sig(&r)
		switch {
		case key == "desktop-entry" && sig == "s": c.desktop_entry = strings.clone(dbus.r_string(&r))
		case key == "urgency" && sig == "y":       c.urgency = int(dbus.r_u8(&r))
		case key == "suppress-sound" && sig == "b": c.silent = dbus.r_bool(&r)
		case key == "image-data" && sig == "(iiibiiay)":
			dbus.r_align_entry(&r)
			c.image = {dbus.r_i32(&r), dbus.r_i32(&r), dbus.r_i32(&r)}
			c.image_alpha = dbus.r_bool(&r)
			bits, channels := dbus.r_i32(&r), dbus.r_i32(&r)
			if bits != 8 || channels != 4 { r.err = true }
			bend := dbus.r_array_begin(&r, "y")
			c.image_bytes = bend - r.pos
			r.pos = bend
		case:
			dbus.r_skip(&r, sig)
		}
	}
	c.timeout = dbus.r_i32(&r)
	c.ok = !r.err && r.pos == len(body)
	return
}

@(test)
markup_and_xml_are_escaped :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.notify_escape("plain text, é", false), "plain text, é")
	testing.expect_value(t, platform.notify_escape(`<b>"x" & 'y'</b>`, false), `&lt;b&gt;"x" &amp; 'y'&lt;/b&gt;`)
	testing.expect_value(t, platform.notify_escape(`<b>"x" & 'y'</b>`, true), "&lt;b&gt;&quot;x&quot; &amp; &apos;y&apos;&lt;/b&gt;")
	// (XML 1.0 forbids the controls but tab, newline and carriage return: a document with one does not load)
	testing.expect_value(t, platform.notify_escape("a\x00b\x1bc\td\ne\r", false), "abc\td\ne\r")
}

@(test)
notify_arguments_as_a_server_reads_them :: proc(t: ^testing.T) {
	rgba := []u8{255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	icon := png.encode(rgba, 2, 3, allocator = context.temp_allocator)
	n := platform.Notification{
		title = "Build <done>", body = "a & b < c", icon_png = icon, urgency = .Critical, silent = true, replace = 41,
		actions = {{7, "Open"}, {-2, "Later"}},
	}
	body := platform.notify_dbus_body(n, "Notify Test", "file:///icon.png", "gt-notify-test", {.Actions, .Body_Markup})
	c := parse_notify(body, allocator = context.temp_allocator)
	testing.expect(t, c.ok, "the body reads to its end")
	testing.expect_value(t, c.app_name, "Notify Test")
	testing.expect_value(t, c.app_icon, "file:///icon.png")
	testing.expect_value(t, c.replaces, 41)
	testing.expect_value(t, c.summary, "Build <done>")   // (the summary is plain text for every server)
	testing.expect_value(t, c.body, "a &amp; b &lt; c")
	testing.expect_value(t, strings.join(c.actions[:], "|", context.temp_allocator), "default||7|Open|-2|Later")
	testing.expect_value(t, c.desktop_entry, "gt-notify-test")
	testing.expect_value(t, c.urgency, 2)
	testing.expect(t, c.silent)
	testing.expect_value(t, c.image, [3]i32{2, 3, 8})
	testing.expect(t, c.image_alpha)
	testing.expect_value(t, c.image_bytes, len(rgba))
	testing.expect_value(t, c.timeout, -1)

	// a server without markup nor actions: the body as it is, no action; no icon, no sound hint
	plain := platform.notify_dbus_body({title = "t", body = "a & b", urgency = .Low, actions = {{1, "x"}}}, "app", "", "", {})
	p := parse_notify(plain, allocator = context.temp_allocator)
	testing.expect(t, p.ok)
	testing.expect_value(t, p.body, "a & b")
	testing.expect_value(t, len(p.actions), 0)
	testing.expect_value(t, p.desktop_entry, "")
	testing.expect_value(t, p.urgency, 0)
	testing.expect(t, !p.silent)
	testing.expect_value(t, p.image_bytes, 0)

	// a picture that is not a PNG: no image, the rest stands
	bad := platform.notify_dbus_body({title = "t", icon_png = {1, 2, 3}}, "app", "", "", {})
	b := parse_notify(bad, allocator = context.temp_allocator)
	testing.expect(t, b.ok)
	testing.expect_value(t, b.urgency, 1)
	testing.expect_value(t, b.image_bytes, 0)
}

@(test)
image_data_is_the_png_as_rgba_rows :: proc(t: ^testing.T) {
	rgba := []u8{10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120}
	img, ok := platform.notify_image_of_png(png.encode(rgba, 3, 1, allocator = context.temp_allocator))
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, img.width, 3)
	testing.expect_value(t, img.height, 1)
	testing.expect_value(t, img.rowstride, 12)
	testing.expect_value(t, img.channels, 4)
	testing.expect_value(t, img.bits, 8)
	testing.expect(t, img.has_alpha)
	testing.expect_value(t, string(img.data), string(rgba))
	_, bad := platform.notify_image_of_png({0x89, 'P', 'N', 'G'})
	testing.expect(t, !bad)
}

@(test)
signals_are_read_as_events :: proc(t: ^testing.T) {
	kind, action, ok := platform.notify_action_of_key("default")
	testing.expect(t, ok && kind == .Notification_Click && action == 0)
	kind, action, ok = platform.notify_action_of_key("-12")
	testing.expect(t, ok && kind == .Notification_Action && action == -12)
	_, _, ok = platform.notify_action_of_key("inline-reply")
	testing.expect(t, !ok, "a key the toolkit did not send")
	testing.expect_value(t, platform.notify_reason_of_code(1), platform.Notification_Reason.Expired)
	testing.expect_value(t, platform.notify_reason_of_code(2), platform.Notification_Reason.Dismissed)
	testing.expect_value(t, platform.notify_reason_of_code(3), platform.Notification_Reason.Closed)
	testing.expect_value(t, platform.notify_reason_of_code(4), platform.Notification_Reason.Unknown)
}

@(test)
toast_xml_is_built_and_escaped :: proc(t: ^testing.T) {
	n := platform.Notification{
		title = `Q&A <"now">`, body = "line 1\nline 2 \x01", urgency = .Critical, silent = true,
		actions = {{3, `Say "hi"`}, {-1, "<No>"}},
	}
	testing.expect_value(t, platform.toast_xml(n, `file:///C:/Temp/a%20b/i.png`),
		`<toast launch="default" duration="long"><visual><binding template="ToastGeneric">` +
		`<text>Q&amp;A &lt;"now"&gt;</text><text>line 1` + "\n" + `line 2 </text>` +
		`<image placement="appLogoOverride" src="file:///C:/Temp/a%20b/i.png"/></binding></visual>` +
		`<actions><action content="Say &quot;hi&quot;" arguments="action:3" activationType="foreground"/>` +
		`<action content="&lt;No&gt;" arguments="action:-1" activationType="foreground"/></actions>` +
		`<audio silent="true"/></toast>`)
	// the least: a title
	testing.expect_value(t, platform.toast_xml({title = "Hi"}, ""),
		`<toast launch="default"><visual><binding template="ToastGeneric"><text>Hi</text></binding></visual></toast>`)
	// at most five buttons: a sixth makes Windows refuse the toast
	many := []platform.Notification_Action{{1, "a"}, {2, "b"}, {3, "c"}, {4, "d"}, {5, "e"}, {6, "f"}}
	x := platform.toast_xml({title = "t", actions = many}, "")
	testing.expect_value(t, strings.count(x, "<action "), platform.TOAST_MAX_ACTIONS)
}

@(test)
toast_activations_are_read :: proc(t: ^testing.T) {
	kind, action, ok := platform.toast_activation_of("default")
	testing.expect(t, ok && kind == .Notification_Click)
	kind, action, ok = platform.toast_activation_of("action:42")
	testing.expect(t, ok && kind == .Notification_Action && action == 42)
	_, _, ok = platform.toast_activation_of("action:x")
	testing.expect(t, !ok)
	_, _, ok = platform.toast_activation_of("other")
	testing.expect(t, !ok)
	testing.expect_value(t, platform.file_uri_of_path(`C:\Users\A B\AppData\Local\Temp\gt_notify\0f.png`),
		"file:///C:/Users/A%20B/AppData/Local/Temp/gt_notify/0f.png")
}
