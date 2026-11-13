package platform

// System notifications: a program shows a desktop notification without an icon in the notification area
// (docs/notifications.md). Linux: org.freedesktop.Notifications on the session bus (notify_linux.odin); Windows: toast
// notifications through the Windows Runtime (notify_windows.odin); other systems: none (notify_supported is false).
//
//   id, ok := notify(w, {title = "Build done", body = "3 warnings", actions = {{1, "Open log"}}})
//
// What the user does with a notification comes back as events of the window that showed it: Notification_Click (a click
// on its body), Notification_Action (a button: Event.notification.action is its id), Notification_Closed (it is gone:
// Event.notification.reason says why; no event of it comes after). tray_notify (tray.odin) uses the same code on Linux.
//
// The pure parts (the D-Bus arguments, the toast's XML, the escaping, the image) are here, tested on every system.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../dbus"
import "../png"

// A notification of the window, given by notify. 0 is none.
Notification_Id :: distinct u32

// How much a notification asks for attention. Linux: the `urgency` hint (a server does not expire a Critical one, and
// may show a Low one only in its list). Windows: Low goes straight to the notification centre (no popup), Critical
// stays on the screen longer (duration "long").
Notification_Urgency :: enum u8 { Normal, Low, Critical }

// A button of a notification: `id` comes back in Event.notification.action when it is pressed.
Notification_Action :: struct {
	id:    int,
	label: string,
}

Notification :: struct {
	title:    string,
	body:     string,                  // plain text (escaped where the system reads markup)
	icon_png: []u8,                    // a PNG file's bytes, shown with the text; nil: the program's own icon
	urgency:  Notification_Urgency,
	actions:  []Notification_Action,   // buttons (a system may show fewer: Windows at most 5)
	replace:  Notification_Id,         // an earlier notification of the window this one updates in place (0: a new one)
	silent:   bool,                    // no sound
}

// What notify_async calls once the system answered: the notification's id, or ok false (no notification server, or it
// refused). From the window loop, on the interface's thread.
Notify_Done :: #type proc(user: rawptr, id: Notification_Id, ok: bool)

// A copy of `n` that owns its strings and bytes (notification_destroy): what an asynchronous send keeps until it is out.
notification_clone :: proc(n: Notification, allocator := context.allocator) -> Notification {
	out := n
	out.title = strings.clone(n.title, allocator)
	out.body = strings.clone(n.body, allocator)
	out.icon_png = slice.clone(n.icon_png, allocator)
	out.actions = make([]Notification_Action, len(n.actions), allocator)
	for a, i in n.actions { out.actions[i] = {id = a.id, label = strings.clone(a.label, allocator)} }
	return out
}

notification_destroy :: proc(n: ^Notification, allocator := context.allocator) {
	delete(n.title, allocator)
	delete(n.body, allocator)
	delete(n.icon_png, allocator)
	for a in n.actions { delete(a.label, allocator) }
	delete(n.actions, allocator)
	n^ = {}
}

// Why a notification is gone.
Notification_Reason :: enum u8 {
	Unknown,
	Expired,     // its time on the screen ran out (Linux)
	Dismissed,   // the user closed it, or clicked it and the system took it away
	Closed,      // notify_close, or a newer notification replaced it
	Failed,      // the system could not show it (Windows: the toast's Failed event)
}

// What a Notification_* event is about (Event.notification).
Notification_Event :: struct {
	id:     Notification_Id,
	action: int,                   // Notification_Action: the button's id
	reason: Notification_Reason,   // Notification_Closed
}

// What the program is to the notification system, once at start, before the first window: notify_set_app.
Notify_App :: struct {
	name:      string,   // the name shown with the notifications ("" = the executable's file name)
	aumid:     string,   // Windows: the AppUserModelID ("" = the process's own if it set one, else the executable's name)
	icon_path: string,   // an absolute path to the program's icon (.png or .ico; "" = none: the system's default)
}

@(private) notify_app: Notify_App

// Sets what the program is to the notification system (copied). Windows: the AppUserModelID of the process is set when it
// has none yet (the taskbar groups the windows by it: call this before the first window), and the id is registered for
// the user under HKCU\Software\Classes\AppUserModelId with the name and the icon at the first notification.
// Linux: `name` is the notification's app_name, `icon_path` its app_icon; the server finds the program's .desktop file by
// its app id (set_app_id).
notify_set_app :: proc(app: Notify_App) {
	notify_app = {name = clone_string(app.name), aumid = clone_string(app.aumid), icon_path = clone_string(app.icon_path)}
	notify_app_declared()
}

////////////////////////////////
// Escaping

// `s` as text of XML or of a notification server's markup: & < > as entities, and " ' too when `quotes` (an
// attribute's value). The characters XML 1.0 forbids (controls but tab, newline and carriage return) are dropped: an
// XML document that holds one does not load. Returns `s` itself when nothing changes.
notify_escape :: proc(s: string, quotes: bool, allocator := context.temp_allocator) -> string {
	clean := true
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '&' || c == '<' || c == '>' || (quotes && (c == '"' || c == '\'')) || (c < 0x20 && c != '\t' && c != '\n' && c != '\r') {
			clean = false
			break
		}
	}
	if clean { return s }
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '&': strings.write_string(&b, "&amp;")
		case c == '<': strings.write_string(&b, "&lt;")
		case c == '>': strings.write_string(&b, "&gt;")
		case quotes && c == '"':  strings.write_string(&b, "&quot;")
		case quotes && c == '\'': strings.write_string(&b, "&apos;")
		case c < 0x20 && c != '\t' && c != '\n' && c != '\r':
		case: strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

////////////////////////////////
// Linux: the arguments of org.freedesktop.Notifications.Notify

// What a notification server says it can do (GetCapabilities), of what the toolkit uses.
Notify_Cap :: enum u8 {
	Actions,       // "actions": it shows the buttons and tells when one is pressed
	Body_Markup,   // "body-markup": the body is read as markup (so its text is escaped)
}
Notify_Caps :: bit_set[Notify_Cap; u8]

// The capabilities among the names GetCapabilities returned.
notify_caps_of :: proc(names: []string) -> (caps: Notify_Caps) {
	for n in names {
		switch n {
		case "actions":     caps += {.Actions}
		case "body-markup": caps += {.Body_Markup}
		}
	}
	return
}

// The signature of Notify's arguments: app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout.
NOTIFY_SIGNATURE :: "susssasa{sv}i"

// The elements of an array of strings start on this boundary.
@(private = "file") STRING_ALIGN :: 4

// The action key of a click on the notification's body (the specification's "default").
NOTIFY_DEFAULT_ACTION :: "default"

// An image of the `image-data` hint: (iiibiiay), RGBA rows of 8-bit samples.
Notify_Image :: struct {
	width, height: i32,
	rowstride:     i32,
	has_alpha:     bool,
	bits:          i32,   // per sample
	channels:      i32,
	data:          []u8,
}

// The `image-data` of a PNG file's bytes (decoded to RGBA in `allocator`).
notify_image_of_png :: proc(png_bytes: []u8, allocator := context.temp_allocator) -> (img: Notify_Image, ok: bool) {
	rgba, w, h := png.decode(png_bytes, allocator) or_return
	if w <= 0 || h <= 0 { return {}, false }
	return {width = i32(w), height = i32(h), rowstride = i32(w * 4), has_alpha = true, bits = 8, channels = 4, data = rgba}, true
}

// The body of a Notify call (NOTIFY_SIGNATURE) for `n`, as `caps` allow: a "default" action (a click on the body) and
// the buttons when the server shows actions (their keys are their ids in decimal), the body escaped when it reads
// markup, and the hints: `desktop-entry` (the server groups the notifications and raises the program by it), `urgency`,
// `suppress-sound`, `image-data` (the icon, when it is a PNG that decodes). The server's default time on screen.
notify_dbus_body :: proc(n: Notification, app_name, app_icon, desktop_entry: string, caps: Notify_Caps, allocator := context.temp_allocator) -> []u8 {
	w := dbus.body_writer(allocator)
	dbus.w_string(&w, app_name)
	dbus.w_u32(&w, u32(n.replace))
	dbus.w_string(&w, app_icon)
	dbus.w_string(&w, n.title)
	dbus.w_string(&w, .Body_Markup in caps ? notify_escape(n.body, false, allocator) : n.body)
	alen, acontent := dbus.w_array_begin(&w, STRING_ALIGN)
	if .Actions in caps {
		dbus.w_string(&w, NOTIFY_DEFAULT_ACTION)
		dbus.w_string(&w, "")   // (the default action is no button: its label is not shown)
		for a in n.actions {
			dbus.w_string(&w, fmt.aprintf("%d", a.id, allocator = allocator))
			dbus.w_string(&w, a.label)
		}
	}
	dbus.w_array_end(&w, alen, acontent)
	hlen, hcontent := dbus.arg_dict_begin(&w)
	if desktop_entry != "" {
		dbus.arg_dict_entry(&w, "desktop-entry")
		dbus.arg_variant_string(&w, desktop_entry)
	}
	dbus.arg_dict_entry(&w, "urgency")
	dbus.w_signature(&w, "y")
	switch n.urgency {
	case .Low:      dbus.w_u8(&w, 0)
	case .Normal:   dbus.w_u8(&w, 1)
	case .Critical: dbus.w_u8(&w, 2)
	}
	if n.silent {
		dbus.arg_dict_entry(&w, "suppress-sound")
		dbus.arg_variant_bool(&w, true)
	}
	if len(n.icon_png) > 0 {
		if img, ok := notify_image_of_png(n.icon_png, allocator); ok {
			dbus.arg_dict_entry(&w, "image-data")
			dbus.w_signature(&w, "(iiibiiay)")
			dbus.w_struct(&w)
			dbus.w_i32(&w, img.width)
			dbus.w_i32(&w, img.height)
			dbus.w_i32(&w, img.rowstride)
			dbus.w_bool(&w, img.has_alpha)
			dbus.w_i32(&w, img.bits)
			dbus.w_i32(&w, img.channels)
			blen, bcontent := dbus.w_array_begin(&w, 1)
			dbus.w_bytes(&w, img.data)
			dbus.w_array_end(&w, blen, bcontent)
		}
	}
	dbus.arg_dict_end(&w, hlen, hcontent)
	dbus.w_i32(&w, -1)   // expire_timeout: the server's default
	return w.buf[:]
}

// What an ActionInvoked key is: the body's click, or a button of that id. ok = false for a key the toolkit did not send.
notify_action_of_key :: proc(key: string) -> (kind: Event_Kind, action: int, ok: bool) {
	if key == NOTIFY_DEFAULT_ACTION { return .Notification_Click, 0, true }
	v, parsed := strconv.parse_int(key, 10)
	if !parsed { return .None, 0, false }
	return .Notification_Action, v, true
}

// The reason of a NotificationClosed signal.
notify_reason_of_code :: proc(code: u32) -> Notification_Reason {
	switch code {
	case 1: return .Expired
	case 2: return .Dismissed
	case 3: return .Closed
	}
	return .Unknown
}

////////////////////////////////
// Windows: the toast's XML and its arguments

// The `launch` argument of a toast (a click on its body) and the `arguments` of its buttons.
TOAST_DEFAULT_ARGUMENT :: "default"
TOAST_ACTION_PREFIX :: "action:"

// Windows shows at most this many buttons on a toast (more: the toast fails).
TOAST_MAX_ACTIONS :: 5

// The XML of a toast (the ToastGeneric template, Windows 10 and later) for `n`: the title and the body as two texts,
// the icon (`image_uri`, a file:/// URI; "" none) as the app logo, the buttons, the sound, the duration.
toast_xml :: proc(n: Notification, image_uri: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `<toast launch="`)
	strings.write_string(&b, TOAST_DEFAULT_ARGUMENT)
	strings.write_byte(&b, '"')
	if n.urgency == .Critical { strings.write_string(&b, ` duration="long"`) }
	strings.write_string(&b, `><visual><binding template="ToastGeneric"><text>`)
	strings.write_string(&b, notify_escape(n.title, false, allocator))
	strings.write_string(&b, `</text>`)
	if n.body != "" {
		strings.write_string(&b, `<text>`)
		strings.write_string(&b, notify_escape(n.body, false, allocator))
		strings.write_string(&b, `</text>`)
	}
	if image_uri != "" {
		strings.write_string(&b, `<image placement="appLogoOverride" src="`)
		strings.write_string(&b, notify_escape(image_uri, true, allocator))
		strings.write_string(&b, `"/>`)
	}
	strings.write_string(&b, `</binding></visual>`)
	if len(n.actions) > 0 {
		strings.write_string(&b, `<actions>`)
		for a in n.actions[:min(len(n.actions), TOAST_MAX_ACTIONS)] {
			fmt.sbprintf(&b, `<action content="%s" arguments="%s%d" activationType="foreground"/>`,
				notify_escape(a.label, true, allocator), TOAST_ACTION_PREFIX, a.id)
		}
		strings.write_string(&b, `</actions>`)
	}
	if n.silent { strings.write_string(&b, `<audio silent="true"/>`) }
	strings.write_string(&b, `</toast>`)
	return strings.to_string(b)
}

// What the Arguments of a toast's activation are: the body's click, or a button of that id.
toast_activation_of :: proc(arguments: string) -> (kind: Event_Kind, action: int, ok: bool) {
	if arguments == TOAST_DEFAULT_ARGUMENT || arguments == "" { return .Notification_Click, 0, true }
	if !strings.has_prefix(arguments, TOAST_ACTION_PREFIX) { return .None, 0, false }
	v, parsed := strconv.parse_int(arguments[len(TOAST_ACTION_PREFIX):], 10)
	if !parsed { return .None, 0, false }
	return .Notification_Action, v, true
}

// The `file:///` URI of an absolute Windows path (C:\a b\c.png -> file:///C:/a%20b/c.png).
file_uri_of_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file:///")
	for i in 0 ..< len(path) {
		c := path[i]
		switch {
		case c == '\\': strings.write_byte(&b, '/')
		case c == ' ' || c == '%' || c == '#' || c == '?': fmt.sbprintf(&b, "%%%02X", c)
		case: strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}
