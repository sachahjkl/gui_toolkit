# Notification area icon (`platform.tray_*`)

An icon in the notification area (the "system tray") with a tooltip, a menu and notifications. The API is the
toolkit's (`platform/tray.odin`); Windows implements it with `Shell_NotifyIconW` version 4 (`tray_win32.odin`), other
systems answer "not supported" (`tray_stub.odin`: `tray_create` returns nil, the other calls do nothing).

```odin
tray := platform.tray_create(app.win, #load("chat.png"), "Chat")
platform.tray_set_menu(tray, {
	{id = 1, text = "Open", default = true},
	{kind = .Separator},
	{id = 2, text = "Mute", kind = .Check, checked = app.muted},
	{text = "Status", children = {{id = 10, text = "Online", kind = .Radio, checked = true}, {id = 11, text = "Away", kind = .Radio}}},
	{id = 3, text = "Quit"},
})
...
events := platform.poll_events(app.win, false)
for e in platform.tray_poll(tray) {
	#partial switch e.kind {
	case .Click, .Double_Click: platform.show_window(app.win)
	case .Menu_Item: if e.item == 3 { app.quit = true }
	case .Notify_Click: open_conversation(app)
	}
}
platform.tray_notify(tray, {title = "Ada", body = "Lunch?", icon = .App})
```

| Procedure | |
|---|---|
| `tray_create(w, icon_png = nil, tooltip = "") -> ^Tray` | adds the icon; `w` (which may stay hidden) receives its notifications; nil icon: the exe's |
| `tray_set_icon(t, png)`, `tray_set_icon_rgba(t, rgba, size)` | another icon (a PNG file's bytes; straight RGBA pixels) |
| `tray_set_tooltip(t, text)` | 127 UTF-16 units at most (cut at a character's boundary) |
| `tray_set_menu(t, items)` | the menu a right click or the menu key opens (`Tray.auto_menu`, on by default); items, separators, check and radio marks, disabled, default (bold) items, submenus; a deep copy |
| `tray_show_menu(t) -> (id, ok)` | opens the menu at the pointer from the app (after a left click, say); blocks in the system's menu loop |
| `tray_poll(t) -> []Tray_Event` | what happened since the previous call |
| `tray_notify(t, Tray_Notify)` | a notification from the icon: title, body, icon (none, info, warning, error, the app's), silent, quiet time |
| `tray_destroy(t)` | removes the icon; `destroy_window` removes the icons of the window |

Events (`Tray_Event_Kind`): `Click` (left click; Enter or Space on the icon: `keyboard`), `Double_Click` (a double click
also makes a `Click` first, as the system reports it), `Right_Click`, `Middle_Click`, `Menu_Item` (`item` = the id),
`Notify_Shown`, `Notify_Click`, `Notify_Timeout`, `Notify_Hidden`, `Hover_Open`, `Hover_Close`, `Recreated`. `pos` is in
screen pixels (where to open a popup of the app).

The shell may restart (explorer.exe crashed or was restarted): the window receives `TaskbarCreated`, adds its icons
again with their tooltip and queues `Recreated`. An elevated process is allowed to receive that message too.

No `NIF_GUID`: a GUID ties the icon to the exe's path for good (a moved or copied exe could not add it any more); the
id per window identifies it.

Tests: `tests/tray` (the translation of the notifications, the calls to the shell through `tray_test_hook`, two icons on
one window, a shell restart, menus, icons from pixels): no icon appears, `tray_inject` sends the shell's notifications
through the window procedure.
