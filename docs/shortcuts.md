# shortcuts: global shortcuts

`import "gt:shortcuts"`. Keys that reach a program wherever the keyboard is: a screenshot tool's Print Screen, a
launcher's. The program names its actions and the keys it would like for each; the system says which keys each action
got, and when one is pressed.

```odin
s := shortcuts.start({app_id = "cliche", window = anchor, wake = wake_loop, user = app})
defer shortcuts.stop(s)
shortcuts.bind(s, {
	{id = "region", description = "Capture a region", trigger = hk},   // hk: platform.hotkey_parse("Print")
})
// each turn of the program's loop
for e in platform.poll_events(anchor, false) { shortcuts.feed(s, e) }   // (Windows: the presses come as window events)
for id in shortcuts.take(s) { run(id) }
st := shortcuts.status(s, "region")   // {.Bound, "Print"}
```

| Procedure | |
|---|---|
| `start(options) -> ^Service` | starts the system's side (Linux: a thread). `Options`: `app_id` (the `.desktop` file's name), `window` (Windows), `wake(user)` (called from any thread when there is something to take). |
| `bind(s, list)` | the whole set of actions and their keys, replacing the one before. Each is `Waiting` until the system answers. |
| `take(s, allocator) -> []string` | the ids pressed since the last call. |
| `status(s, id, allocator) -> Status` | `{state, trigger}`: `trigger` is the keys as the system words them. |
| `backend(s)` | `.Portal`, `.Windows` or `.None`. |
| `can_configure(s)`, `configure(s)` | the system's own page of the program's shortcuts (the portal's version 2). |
| `feed(s, event) -> bool` | Windows: a `Hotkey` event of the window that is one of the service's, taken. |
| `hold(s, held)` | Windows: while a field records keys, the shortcuts let them go. |
| `portal_trigger(hotkey) -> string` | the portal's format of a combination: `CTRL+SHIFT+a`, `LOGO+Print`. |
| `stop(s)` | |

`State`: `Waiting`, `Bound`, `No_Keys` (none asked, none given), `Taken` (another program holds the keys: Windows),
`Refused` (the user or the system said no), `Unavailable` (no global shortcuts here).

## Linux

The desktop portal's `org.freedesktop.portal.GlobalShortcuts` (KDE, GNOME 48, Hyprland's portal, ShojiWM's desktop), on
a thread with its own session bus connection:

1. The program's app id is registered (`org.freedesktop.host.portal.Registry`, xdg-desktop-portal 1.19): a program out
   of a sandbox is otherwise known by no name, and the system cannot keep its keys.
2. At each `bind`: the session before is closed, a new one created (`CreateSession`), the set bound (`BindShortcuts`, each
   action's `description` and `preferred_trigger`), and the answer waited for: the system may ask the user first, and may
   give other keys than the ones asked.
3. `Activated` becomes an activation; `ShortcutsChanged` (the user changed the keys in the system's settings) new
   statuses.

The shortcuts work while the program runs: the session ends with its connection.

## Windows

`RegisterHotKey` on `Options.window`, one id per action from 1, from the window's thread (`bind` and `hold` are called
there). A press comes as a `Hotkey` event of the window: `feed` turns it into an activation. Keys another program holds
are `Taken`.

## Print Screen

`platform.Key.Print` is Print Screen (X11 and Wayland keysym `Print`, Windows `VK_SNAPSHOT`: Windows sends only its
release, which the window gives as a press and a release). `platform.hotkey_complete` says what a shortcut may be: a key
with a modifier, or Print Screen alone; `ui.hotkey_field` and `hotkey_parse` follow it.

Tests: `odin test tests/shortcuts -vet` (the portal's triggers, Print Screen, complete combinations, a nil service).
